defmodule YellowDog.Dns.ManagedSnapshotTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.ManagedSnapshot
  alias YellowDog.Dns.ViewManager
  alias YellowDog.Dns.Zone.Auth
  alias YellowDog.Dns.ZoneController
  alias YellowDog.Sync.DnsManifest

  setup do
    dir = Path.join(System.tmp_dir!(), "managed_dns_#{System.unique_integer([:positive])}")
    {:ok, registry} = Registry.start_link(keys: :unique, name: YellowDog.Dns.ZoneRegistry)
    {:ok, view_registry} = Registry.start_link(keys: :unique, name: YellowDog.Dns.ViewRegistry)
    {:ok, controller} = ZoneController.start_link([])
    {:ok, view_manager} = ViewManager.start_link([])
    {:ok, _view} = ViewManager.start_view(%{name: "default", recursion_enabled: false})

    on_exit(fn ->
      Enum.each([view_manager, controller, view_registry, registry], fn pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end
      end)

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "installs complete A, NS and SOA and recovers after process restart", %{dir: dir} do
    manifest = manifest(1, "192.0.2.1")
    {:ok, digest} = DnsManifest.digest(manifest)

    assert {:ok, %{"generation" => 1, "digest" => ^digest}} =
             ManagedSnapshot.install(manifest, dir)

    assert {:ok, %{"generation" => 1, "digest" => ^digest}} =
             ManagedSnapshot.installed_status(dir)

    {:ok, pid} = ZoneController.find_zone("default", :auth, "example.test.")
    assert length(Auth.get_records(pid, "example.test.", :a)) == 1
    assert length(Auth.get_records(pid, "example.test.", :ns)) == 1
    assert length(Auth.get_records(pid, "example.test.", :soa)) == 1

    query = %DNS.Message{
      header: %DNS.Message.Header{id: 42, rd: false},
      qdlist: [%{name: "example.test.", type: :a, class: :in}],
      anlist: [],
      nslist: [],
      arlist: []
    }

    assert {:ok, %{header: %{aa: aa}, anlist: [_]}} =
             ViewManager.resolve(self(), {127, 0, 0, 1}, 42, query)

    assert aa in [1, true]
    assert {:error, :managed_zone} = Auth.add_record(pid, %{name: "example.test.", type: :a})

    assert :ok = ZoneController.stop_zone("default", :auth, "example.test.")
    assert {:ok, nil} = ManagedSnapshot.installed_status(dir)
    assert :ok = ManagedSnapshot.recover(dir)
    {:ok, recovered} = ZoneController.find_zone("default", :auth, "example.test.")
    assert length(Auth.get_records(recovered, "example.test.", :a)) == 1
  end

  test "rejects stale, conflicting and corrupt candidates without changing active records", %{
    dir: dir
  } do
    old = manifest(2, "192.0.2.1")
    assert {:ok, _} = ManagedSnapshot.install(old, dir)
    assert {:error, :generation_conflict} = ManagedSnapshot.install(manifest(2, "192.0.2.2"), dir)
    assert {:error, :stale_generation} = ManagedSnapshot.install(manifest(1, "192.0.2.2"), dir)

    bad =
      put_in(
        manifest(3, "192.0.2.2"),
        ["zones", Access.at(0), "digest"],
        String.duplicate("f", 64)
      )

    assert {:error, :invalid_manifest} = ManagedSnapshot.install(bad, dir)
    {:ok, pid} = ZoneController.find_zone("default", :auth, "example.test.")
    assert length(Auth.get_records(pid, "example.test.", :a)) == 1
    assert {:ok, %{"generation" => 2}} = ManagedSnapshot.installed_status(dir)
  end

  test "candidate write failure and corrupt active file recover the last valid zone", %{dir: dir} do
    assert {:ok, _} = ManagedSnapshot.install(manifest(1, "192.0.2.1"), dir)
    candidate = Path.join([dir, "managed_dns", "active.json.candidate"])
    File.mkdir_p!(candidate)
    assert {:error, :eisdir} = ManagedSnapshot.install(manifest(2, "192.0.2.2"), dir)

    {:ok, pid} = ZoneController.find_zone("default", :auth, "example.test.")
    assert [record] = Auth.get_records(pid, "example.test.", :a)
    assert record.data.data == {192, 0, 2, 1}

    File.write!(Path.join([dir, "managed_dns", "active.json"]), "corrupt")
    assert :ok = ManagedSnapshot.recover(dir)
    assert {:ok, %{"generation" => 1}} = ManagedSnapshot.installed_status(dir)
    assert ManagedSnapshot.managed_zone?("example.test.", dir)
    assert [record] = Auth.get_records(pid, "example.test.", :a)
    assert record.data.data == {192, 0, 2, 1}
  end

  test "post-rename sync failure restores the previous durable and running version", %{dir: dir} do
    assert {:ok, _} = ManagedSnapshot.install(manifest(1, "192.0.2.1"), dir)

    original_path = System.get_env("PATH")
    original_sync = System.find_executable("sync")
    bin_dir = Path.join(dir, "bin")
    File.mkdir_p!(bin_dir)
    counter = Path.join(dir, "sync_count")

    File.write!(
      Path.join(bin_dir, "sync"),
      "#!/bin/sh\ncount=$(cat '#{counter}' 2>/dev/null || echo 0)\ncount=$((count + 1))\necho $count > '#{counter}'\nif [ \"$count\" -eq 2 ]; then exit 1; fi\nexec '#{original_sync}' \"$@\"\n"
    )

    File.chmod!(Path.join(bin_dir, "sync"), 0o755)
    System.put_env("PATH", bin_dir <> ":" <> original_path)
    on_exit(fn -> System.put_env("PATH", original_path) end)

    assert {:error, {:directory_sync_failed, _}} =
             ManagedSnapshot.install(manifest(2, "192.0.2.2"), dir)

    assert :ok = ManagedSnapshot.recover(dir)
    assert {:ok, %{"generation" => 1}} = ManagedSnapshot.installed_status(dir)
    {:ok, pid} = ZoneController.find_zone("default", :auth, "example.test.")
    assert [record] = Auth.get_records(pid, "example.test.", :a)
    assert record.data.data == {192, 0, 2, 1}
  end

  test "pending activation is rolled back on restart", %{dir: dir} do
    previous = manifest(1, "192.0.2.1")
    assert {:ok, _} = ManagedSnapshot.install(previous, dir)

    File.write!(
      Path.join([dir, "managed_dns", "pending.json"]),
      Jason.encode!(%{"previous" => previous})
    )

    File.write!(
      Path.join([dir, "managed_dns", "active.json"]),
      Jason.encode!(manifest(2, "192.0.2.2"))
    )

    assert :ok = ManagedSnapshot.recover(dir)
    assert {:ok, %{"generation" => 1}} = ManagedSnapshot.installed_status(dir)
    refute File.exists?(Path.join([dir, "managed_dns", "pending.json"]))
  end

  test "applied status requires the view to route the zone", %{dir: dir} do
    assert {:ok, _} = ManagedSnapshot.install(manifest(1, "192.0.2.1"), dir)
    {:ok, view} = ViewManager.get_view("default")
    assert :ok = YellowDog.Dns.View.reload(view, %{zones: []})
    assert {:ok, nil} = ManagedSnapshot.installed_status(dir)
  end

  test "zone worker restart reloads the latest committed version", %{dir: dir} do
    assert {:ok, _} = ManagedSnapshot.install(manifest(1, "192.0.2.1"), dir)
    assert {:ok, _} = ManagedSnapshot.install(manifest(2, "192.0.2.2"), dir)
    {:ok, old_pid} = ZoneController.find_zone("default", :auth, "example.test.")
    monitor = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :killed}, 1_000

    assert {:ok, new_pid} = await_zone_restart(old_pid, 50)
    assert [record] = Auth.get_records(new_pid, "example.test.", :a)
    assert record.data.data == {192, 0, 2, 2}
  end

  test "duplicate delivery after a lost acknowledgement returns the installed identity", %{
    dir: dir
  } do
    delivered = manifest(1, "192.0.2.1")
    assert {:ok, applied} = ManagedSnapshot.install(delivered, dir)
    assert {:ok, ^applied} = ManagedSnapshot.install(delivered, dir)
    assert {:ok, ^applied} = ManagedSnapshot.installed_status(dir)
  end

  test "local checks accept A data at the nameserver without an apex A", %{dir: dir} do
    manifest = manifest(1, "192.0.2.53")
    [zone] = manifest["zones"]

    rrsets =
      Enum.map(zone["rrsets"], fn
        %{"type" => "A"} = rrset -> %{rrset | "owner" => "ns1.example.test."}
        rrset -> rrset
      end)

    zone = %{zone | "rrsets" => rrsets}
    {:ok, digest} = DnsManifest.zone_digest(zone)
    manifest = %{manifest | "zones" => [%{zone | "digest" => digest}]}

    assert {:ok, _} = ManagedSnapshot.install(manifest, dir)
    {:ok, pid} = ZoneController.find_zone("default", :auth, "example.test.")
    assert Auth.get_records(pid, "example.test.", :a) == []
    assert [_] = Auth.get_records(pid, "ns1.example.test.", :a)
  end

  test "Store.Zone rejects direct mutations of a published managed apex", %{dir: root} do
    previous_data_dir = Application.get_env(:yellow_dog, :data_dir)
    Application.put_env(:yellow_dog, :data_dir, root)

    on_exit(fn ->
      if previous_data_dir,
        do: Application.put_env(:yellow_dog, :data_dir, previous_data_dir),
        else: Application.delete_env(:yellow_dog, :data_dir)
    end)

    data_dir = YellowDog.Dns.ConfigPersistence.default_data_path()
    assert data_dir == Path.join(root, "dns")
    assert {:ok, _} = ManagedSnapshot.install(manifest(1, "192.0.2.1"), data_dir)
    soa = YellowDog.Store.Zone.default_soa("example.test")

    assert {:error, :managed_zone} = ZoneController.start_zone(:auth, "example.test")
    assert {:error, :managed_zone} = ZoneController.start_zone(:auth, "EXAMPLE.TEST")

    assert {:error, :managed_zone} =
             YellowDog.Store.Zone.create_zone("default", "EXAMPLE.TEST", soa)

    assert {:error, :managed_zone} =
             YellowDog.Store.Zone.create_forward_zone("default", "example.test", [])

    assert {:error, :managed_zone} =
             YellowDog.Store.Zone.create_stub_zone("default", "example.test", [])

    assert {:error, :managed_zone} =
             YellowDog.Store.Zone.update_zone("default", "example.test", %{default_ttl: 300})

    assert {:error, :managed_zone} =
             YellowDog.Store.Zone.put_rrset("default", "example.test", "@", :a, [])

    assert {:error, :managed_zone} =
             YellowDog.Store.Zone.delete_rrset("default", "example.test", "@", :a)

    assert {:error, {:replace_failed, :managed_zone}} =
             YellowDog.Store.Zone.replace_records("default", "example.test", [])

    assert {:error, :managed_zone} =
             YellowDog.Store.Zone.import_zone("default", "example.test", [])

    assert {:error, :managed_zone} =
             YellowDog.Store.Zone.increment_serial("default", "example.test")

    assert {:error, :managed_zone} =
             YellowDog.Store.Zone.delete_zone("default", "example.test")
  end

  test "query queued during activation sees the complete new RRset", %{dir: dir} do
    assert {:ok, _} = ManagedSnapshot.install(manifest(1, "192.0.2.1"), dir)
    {:ok, pid} = ZoneController.find_zone("default", :auth, "example.test.")

    replacement =
      Enum.map(Auth.get_all_records(pid), fn record ->
        if record.type.value == <<0, 1>> do
          DNS.Message.Record.new("example.test.", :a, :in, 3600, {192, 0, 2, 2})
        else
          record
        end
      end)

    assert :ok = :sys.suspend(pid)
    installing = Task.async(fn -> Auth.activate_managed(pid, replacement) end)
    assert :ok = await_call(pid, :activate_managed, 100)
    querying = Task.async(fn -> Auth.get_records(pid, "example.test.", :a) end)
    assert :ok = await_call(pid, :get_records, 100)
    assert :ok = :sys.resume(pid)
    assert :ok = Task.await(installing, 5_000)
    assert [record] = Task.await(querying, 5_000)
    assert record.data.data == {192, 0, 2, 2}
  end

  defp await_call(_pid, _operation, 0), do: {:error, :timeout}

  defp await_call(pid, operation, attempts) do
    queued =
      case Process.info(pid, :messages) do
        {:messages, messages} ->
          Enum.any?(messages, fn
            {:"$gen_call", _from, call} when is_tuple(call) -> elem(call, 0) == operation
            _ -> false
          end)

        _ ->
          false
      end

    if queued do
      :ok
    else
      Process.sleep(10)
      await_call(pid, operation, attempts - 1)
    end
  end

  defp await_zone_restart(_old_pid, 0), do: {:error, :timeout}

  defp await_zone_restart(old_pid, attempts) do
    case ZoneController.find_zone("default", :auth, "example.test.") do
      {:ok, pid} when pid != old_pid ->
        {:ok, pid}

      _ ->
        Process.sleep(10)
        await_zone_restart(old_pid, attempts - 1)
    end
  end

  defp manifest(generation, ip) do
    apex = "example.test."

    zone = %{
      "zone_id" => "zone-1",
      "apex" => apex,
      "version" => generation + 1,
      "rrsets" => [
        %{
          "owner" => apex,
          "type" => "SOA",
          "ttl" => 3600,
          "records" => [
            %{
              "mname" => "ns1.example.test.",
              "rname" => "hostmaster.example.test.",
              "serial" => 100 + generation,
              "refresh" => 3600,
              "retry" => 600,
              "expire" => 604_800,
              "minimum" => 300
            }
          ]
        },
        %{"owner" => apex, "type" => "NS", "ttl" => 3600, "records" => ["ns1.example.test."]},
        %{"owner" => apex, "type" => "A", "ttl" => 3600, "records" => [ip]}
      ]
    }

    {:ok, digest} = DnsManifest.zone_digest(zone)

    %{
      "schema_version" => 1,
      "server_id" => "server-1",
      "generation" => generation,
      "zones" => [Map.put(zone, "digest", digest)]
    }
  end
end
