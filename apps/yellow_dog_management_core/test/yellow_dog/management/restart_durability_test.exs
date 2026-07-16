defmodule YellowDog.Management.RestartDurabilityTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.Netman
  alias YellowDog.Management.Netmans
  alias YellowDog.Management.EventStore
  alias YellowDog.Management.ManifestStore
  alias YellowDog.Management.Server
  alias YellowDog.Management.Servers
  alias YellowDog.Management.Storage.AtomicJson
  alias YellowDog.Management.Storage.Path, as: StoragePath
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Error

  setup do
    previous_env =
      Map.new(
        [
          :data_dir,
          :max_events,
          :event_write_timeout_ms,
          :event_write_test_delay_ms,
          :event_store_test_hook,
          :atomic_json_file_ops,
          :atomic_json_file_ops_owner,
          :atomic_json_link_result
        ],
        fn key ->
          {key, Application.fetch_env(:yellow_dog_management_core, key)}
        end
      )

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-management-restart-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)
    Application.delete_env(:yellow_dog_management_core, :max_events)
    Application.delete_env(:yellow_dog_management_core, :event_write_timeout_ms)
    Application.delete_env(:yellow_dog_management_core, :event_write_test_delay_ms)
    Application.delete_env(:yellow_dog_management_core, :event_store_test_hook)
    Application.delete_env(:yellow_dog_management_core, :atomic_json_file_ops)
    Application.delete_env(:yellow_dog_management_core, :atomic_json_file_ops_owner)
    Application.delete_env(:yellow_dog_management_core, :atomic_json_link_result)
    restart_management_children()

    on_exit(fn ->
      Enum.each(previous_env, fn {key, value} -> restore_env(key, value) end)
      restart_management_children()
      File.rm_rf(data_dir)
    end)

    %{data_dir: data_dir}
  end

  test "server and Netman registrations and statuses survive registry restarts" do
    assert {:ok, %Server{registered_at: server_registered_at}} =
             ManagementCore.register_server(%{
               id: "srv-restart",
               name: "Restart Server",
               profile: :dns_only,
               services: %{dns: true}
             })

    assert {:ok,
            %Server{
              registered_at: ^server_registered_at,
              name: "Replacement Server",
              profile: :cloud_dns,
              metadata: %{site: "edge"}
            }} =
             ManagementCore.register_server(%{
               id: "srv-restart",
               name: "Replacement Server",
               profile: :cloud_dns,
               services: %{dns: true, server_agent: true},
               metadata: %{site: "edge"}
             })

    assert {:ok,
            %Server{
              status: :online,
              last_seen_at: server_last_seen_at,
              updated_at: server_updated_at
            }} =
             ManagementCore.update_server_status("srv-restart", :online)

    assert {:ok, %Netman{registered_at: netman_registered_at}} =
             ManagementCore.register_netman(%{
               id: "netman-restart",
               name: "Restart Netman",
               profile: :vm,
               features: %{interfaces: true}
             })

    assert {:ok,
            %Netman{
              registered_at: ^netman_registered_at,
              name: "Replacement Netman",
              profile: :cloud_server,
              apply_mode: :observe_first,
              metadata: %{"rack" => "r1"}
            }} =
             ManagementCore.register_netman(%{
               id: "netman-restart",
               name: "Replacement Netman",
               profile: :cloud_server,
               apply_mode: :observe_first,
               features: %{interfaces: true, routes: true},
               metadata: %{"rack" => "r1"}
             })

    assert {:ok,
            %Netman{
              status: :offline,
              last_seen_at: netman_last_seen_at,
              updated_at: netman_updated_at
            }} =
             ManagementCore.update_netman_status("netman-restart", :offline)

    restart_child(Servers)
    restart_child(Netmans)

    assert {:ok,
            %Server{
              id: "srv-restart",
              name: "Replacement Server",
              profile: :cloud_dns,
              status: :online,
              services: %{dns: true, server_agent: true},
              metadata: %{site: "edge"},
              registered_at: ^server_registered_at,
              last_seen_at: ^server_last_seen_at,
              updated_at: ^server_updated_at
            }} = ManagementCore.get_server("srv-restart")

    assert {:ok,
            %Netman{
              id: "netman-restart",
              name: "Replacement Netman",
              profile: :cloud_server,
              apply_mode: :observe_first,
              status: :offline,
              features: %{interfaces: true, routes: true},
              metadata: %{"rack" => "r1"},
              registered_at: ^netman_registered_at,
              last_seen_at: ^netman_last_seen_at,
              updated_at: ^netman_updated_at
            }} = ManagementCore.get_netman("netman-restart")
  end

  test "atom metadata is canonical before write and survives a fresh BEAM", %{
    data_dir: data_dir
  } do
    canonical_metadata = %{"rack" => "r1", "tier" => "edge"}

    assert {:ok, %Server{metadata: ^canonical_metadata}} =
             ManagementCore.register_server(%{
               id: "srv-fresh-beam-metadata",
               metadata: %{rack: "r1", tier: :edge}
             })

    restart_child(Servers)

    assert {:ok, %Server{metadata: ^canonical_metadata}} =
             ManagementCore.get_server("srv-fresh-beam-metadata")

    script = """
    Application.put_env(:yellow_dog_management_core, :data_dir, #{inspect(data_dir)})
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
    {:ok, server} = YellowDog.ManagementCore.get_server("srv-fresh-beam-metadata")
    IO.puts("FRESH_METADATA=" <> Jason.encode!(server.metadata))
    """

    mix = System.find_executable("mix")
    assert is_binary(mix)

    assert {output, 0} =
             System.cmd(
               mix,
               ["run", "--no-compile", "--no-start", "-e", script],
               cd: File.cwd!(),
               env: [{"MIX_ENV", "test"}],
               stderr_to_stdout: true
             )

    assert [_, encoded_metadata] = Regex.run(~r/FRESH_METADATA=(\{[^\n]+\})/, output)
    assert Jason.decode!(encoded_metadata) == canonical_metadata
  end

  test "events keep one global deterministic order across restarts" do
    assert {:ok, %Server{}} = ManagementCore.register_server(%{id: "srv-events"})
    assert {:ok, %Netman{}} = ManagementCore.register_netman(%{id: "netman-events"})
    assert {:ok, %Server{}} = ManagementCore.update_server_status("srv-events", :online)
    assert {:ok, %Netman{}} = ManagementCore.update_netman_status("netman-events", :offline)

    before_restart = ManagementCore.list_events()

    assert Enum.map(before_restart, & &1.sequence) ==
             Enum.sort(Enum.map(before_restart, & &1.sequence))

    restart_management_children()

    after_restart = ManagementCore.list_events()
    assert Enum.map(after_restart, & &1.id) == Enum.map(before_restart, & &1.id)
    assert Enum.map(after_restart, & &1.sequence) == Enum.map(before_restart, & &1.sequence)
  end

  test "malformed individual manifests and event files are ignored", %{data_dir: data_dir} do
    assert {:ok, %Server{}} = ManagementCore.register_server(%{id: "srv-valid"})
    assert {:ok, %Server{}} = ManagementCore.register_server(%{id: "srv-invalid-time"})
    assert {:ok, %Netman{}} = ManagementCore.register_netman(%{id: "netman-valid"})
    valid_event_ids = Enum.map(ManagementCore.list_events(), & &1.id)

    invalid_time_path =
      Path.join([
        data_dir,
        "management",
        "servers",
        "srv-invalid-time",
        "manifest.json"
      ])

    invalid_time_manifest =
      invalid_time_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.update!("registration", &Map.put(&1, "registered_at", "not-a-timestamp"))

    File.write!(invalid_time_path, Jason.encode!(invalid_time_manifest))

    write_file(data_dir, ["management", "servers", "srv-bad", "manifest.json"], "{")
    write_file(data_dir, ["management", "netmans", "netman-bad", "manifest.json"], "[]")
    write_file(data_dir, ["management", "events", "evt-999999.json"], "{")
    write_file(data_dir, ["management", "events", "not-an-event.json"], ~s({"id":"bad"}))
    write_file(data_dir, ["management", "events", ".manifest.json.tmp"], "interrupted")

    restart_management_children()

    assert [%Server{id: "srv-valid"}] = ManagementCore.list_servers()
    assert [%Netman{id: "netman-valid"}] = ManagementCore.list_netmans()
    assert Enum.map(ManagementCore.list_events(), & &1.id) == valid_event_ids
  end

  test "registration updates and restart preserve config lifecycle manifest keys" do
    assert {:ok, server_path} = StoragePath.server_manifest("srv-shared-manifest")
    assert {:ok, netman_path} = StoragePath.netman_manifest("netman-shared-manifest")

    lifecycle = %{
      "desired_version" => 7,
      "applied_version" => 6,
      "desired_digest" => String.duplicate("a", 64)
    }

    assert {:ok, ^lifecycle} =
             ManifestStore.update_section(server_path, "config_lifecycle", fn _current ->
               lifecycle
             end)

    assert {:ok, ^lifecycle} =
             ManifestStore.update_section(netman_path, "config_lifecycle", fn _current ->
               lifecycle
             end)

    assert {:ok, %Server{}} = ManagementCore.register_server(%{id: "srv-shared-manifest"})
    assert {:ok, %Netman{}} = ManagementCore.register_netman(%{id: "netman-shared-manifest"})

    restart_child(Servers)
    restart_child(Netmans)

    assert {:ok, %Server{}} = ManagementCore.get_server("srv-shared-manifest")
    assert {:ok, %Netman{}} = ManagementCore.get_netman("netman-shared-manifest")

    assert {:ok, %Server{status: :online}} =
             ManagementCore.update_server_status("srv-shared-manifest", :online)

    assert {:ok, %Netman{name: "Replacement"}} =
             ManagementCore.register_netman(%{
               id: "netman-shared-manifest",
               name: "Replacement"
             })

    assert {:ok, server_manifest} = AtomicJson.read(server_path)
    assert {:ok, netman_manifest} = AtomicJson.read(netman_path)

    assert server_manifest["config_lifecycle"] == lifecycle
    assert netman_manifest["config_lifecycle"] == lifecycle
    assert is_map(server_manifest["registration"])
    assert is_map(netman_manifest["registration"])

    restart_child(Servers)
    restart_child(Netmans)

    assert {:ok, %Server{status: :online}} =
             ManagementCore.get_server("srv-shared-manifest")

    assert {:ok, %Netman{name: "Replacement"}} =
             ManagementCore.get_netman("netman-shared-manifest")

    assert {:ok, server_manifest} = AtomicJson.read(server_path)
    assert {:ok, netman_manifest} = AtomicJson.read(netman_path)
    assert server_manifest["config_lifecycle"] == lifecycle
    assert netman_manifest["config_lifecycle"] == lifecycle
  end

  test "event failure rollback serializes and preserves a concurrent lifecycle update" do
    assert {:ok, %Server{name: "Before"}} =
             ManagementCore.register_server(%{id: "srv-write-failure", name: "Before"})

    assert {:ok, server_path} = StoragePath.server_manifest("srv-write-failure")

    Application.put_env(
      :yellow_dog_management_core,
      :atomic_json_file_ops,
      __MODULE__.BlockingEventFailureFileOps
    )

    Application.put_env(:yellow_dog_management_core, :atomic_json_file_ops_owner, self())
    restart_child(EventStore)

    registration =
      Task.async(fn ->
        ManagementCore.register_server(%{id: "srv-write-failure", name: "After"})
      end)

    assert_receive {:event_write_blocked, event_store_pid}

    lifecycle = %{"desired_version" => 9, "state" => "staged"}

    config_update =
      Task.async(fn ->
        ManifestStore.update_section(server_path, "config_lifecycle", fn _current -> lifecycle end)
      end)

    assert_manifest_update_queued(server_path)
    send(event_store_pid, :continue_event_write)

    assert {:error, %Error{code: :internal}} = Task.await(registration)
    assert {:ok, ^lifecycle} = Task.await(config_update)

    assert {:ok, %Server{name: "Before"}} = ManagementCore.get_server("srv-write-failure")

    Application.delete_env(:yellow_dog_management_core, :atomic_json_file_ops)
    restart_child(Servers)

    assert {:ok, %Server{name: "Before"}} = ManagementCore.get_server("srv-write-failure")
    assert {:ok, manifest} = AtomicJson.read(server_path)
    assert manifest["config_lifecycle"] == lifecycle
  end

  test "an unavailable EventStore returns an error and rolls registration back", %{
    data_dir: data_dir
  } do
    assert {:ok, server_path} = StoragePath.server_manifest("srv-event-store-down")
    lifecycle = %{"desired_version" => 12}

    assert {:ok, ^lifecycle} =
             ManifestStore.update_section(server_path, "config_lifecycle", fn _current ->
               lifecycle
             end)

    servers_pid = Process.whereis(Servers)
    manifest_store_pid = Process.whereis(ManifestStore)
    assert :ok = Supervisor.terminate_child(YellowDog.ManagementCore.Supervisor, EventStore)

    assert {:error, %Error{code: :internal}} =
             ManagementCore.register_server(%{id: "srv-event-store-down"})

    assert Process.whereis(Servers) == servers_pid
    assert Process.whereis(ManifestStore) == manifest_store_pid
    assert Process.alive?(servers_pid)
    assert Process.alive?(manifest_store_pid)
    assert {:error, :not_found} = ManagementCore.get_server("srv-event-store-down")

    assert {:ok, manifest} = AtomicJson.read(server_path)
    assert manifest == %{"config_lifecycle" => lifecycle}

    assert {:ok, _pid} = Supervisor.restart_child(YellowDog.ManagementCore.Supervisor, EventStore)
    restart_child(Servers)

    assert {:error, :not_found} = ManagementCore.get_server("srv-event-store-down")
    assert [] = ManagementCore.list_events()
    assert Path.wildcard(Path.join([data_dir, "management", "events", "*.json"])) == []
  end

  test "an EventStore crash returns an error and rolls registration back" do
    assert {:ok, server_path} = StoragePath.server_manifest("srv-event-store-crash")
    lifecycle = %{"desired_version" => 13}

    assert {:ok, ^lifecycle} =
             ManifestStore.update_section(server_path, "config_lifecycle", fn _current ->
               lifecycle
             end)

    Application.put_env(
      :yellow_dog_management_core,
      :atomic_json_file_ops,
      __MODULE__.BlockingEventFailureFileOps
    )

    Application.put_env(:yellow_dog_management_core, :atomic_json_file_ops_owner, self())
    restart_child(EventStore)

    servers_pid = Process.whereis(Servers)
    manifest_store_pid = Process.whereis(ManifestStore)
    old_event_store_pid = Process.whereis(EventStore)

    registration =
      Task.async(fn ->
        ManagementCore.register_server(%{id: "srv-event-store-crash"})
      end)

    assert_receive {:event_write_blocked, event_worker_pid}
    assert event_worker_pid != old_event_store_pid
    Process.exit(old_event_store_pid, :kill)
    send(event_worker_pid, :continue_event_write)

    assert {:error, %Error{code: :internal}} = Task.await(registration)
    assert Process.whereis(Servers) == servers_pid
    assert Process.whereis(ManifestStore) == manifest_store_pid
    assert Process.alive?(servers_pid)
    assert Process.alive?(manifest_store_pid)
    assert {:error, :not_found} = ManagementCore.get_server("srv-event-store-crash")

    new_event_store_pid = wait_for_replacement(EventStore, old_event_store_pid)
    assert Process.alive?(new_event_store_pid)

    Application.delete_env(:yellow_dog_management_core, :atomic_json_file_ops)
    restart_child(Servers)

    assert {:error, :not_found} = ManagementCore.get_server("srv-event-store-crash")
    assert [] = ManagementCore.list_events()
    assert {:ok, manifest} = AtomicJson.read(server_path)
    assert manifest == %{"config_lifecycle" => lifecycle}
  end

  test "killing ManifestStore after staging sync exposes no final event", %{data_dir: data_dir} do
    Application.put_env(
      :yellow_dog_management_core,
      :atomic_json_file_ops,
      __MODULE__.BlockingStagingSyncFileOps
    )

    Application.put_env(:yellow_dog_management_core, :atomic_json_file_ops_owner, self())
    restart_child(EventStore)

    old_manifest_store_pid = Process.whereis(ManifestStore)

    registration =
      Task.async(fn ->
        ManagementCore.register_server(%{id: "srv-killed-after-stage"})
      end)

    assert_receive {:event_staging_synced, worker_pid, staging_path}
    assert Process.alive?(worker_pid)
    assert String.ends_with?(staging_path, ".stage")
    refute File.exists?(Path.join(Path.dirname(staging_path), "evt-1.json"))

    Process.exit(old_manifest_store_pid, :kill)

    assert {:error, %Error{code: :internal}} = Task.await(registration)
    new_manifest_store_pid = wait_for_replacement(ManifestStore, old_manifest_store_pid)
    assert Process.alive?(new_manifest_store_pid)

    Application.delete_env(:yellow_dog_management_core, :atomic_json_file_ops)
    restart_child(Servers)

    assert {:error, :not_found} = ManagementCore.get_server("srv-killed-after-stage")
    assert [] = ManagementCore.list_events()
    assert event_files(data_dir) == []
    refute File.exists?(staging_path)
  end

  test "killing ManifestStore after outbox write restores the previous registration" do
    assert {:ok, %Server{name: "Before"}} =
             ManagementCore.register_server(%{id: "srv-killed-after-outbox", name: "Before"})

    owner = self()

    Application.put_env(:yellow_dog_management_core, :event_store_test_hook, fn
      :after_outbox_write, context ->
        send(owner, {:outbox_written, self(), context})

        receive do
          :release_outbox_write -> :ok
        end

      _point, _context ->
        :ok
    end)

    restart_child(EventStore)
    old_manifest_store_pid = Process.whereis(ManifestStore)

    registration =
      Task.async(fn ->
        ManagementCore.register_server(%{id: "srv-killed-after-outbox", name: "After"})
      end)

    assert_receive {:outbox_written, ^old_manifest_store_pid, %{path: manifest_path}}
    assert {:ok, manifest} = AtomicJson.read(manifest_path)
    assert is_map(manifest["registration"])
    assert is_map(manifest["registration_audit_outbox"])

    Process.exit(old_manifest_store_pid, :kill)

    assert {:error, %Error{code: :internal}} = Task.await(registration)
    wait_for_replacement(ManifestStore, old_manifest_store_pid)
    restart_child(Servers)

    assert {:ok, %Server{name: "Before"}} =
             ManagementCore.get_server("srv-killed-after-outbox")

    assert {:ok, reconciled_manifest} = AtomicJson.read(manifest_path)
    refute Map.has_key?(reconciled_manifest, "registration_audit_outbox")
    assert reconciled_manifest["registration"]["name"] == "Before"
    assert [%{source_id: "srv-killed-after-outbox"}] = ManagementCore.list_events()
  end

  test "a promoted event is reconciled when ManifestStore dies before clearing the outbox" do
    owner = self()

    Application.put_env(:yellow_dog_management_core, :event_store_test_hook, fn
      :after_event_promote, context ->
        send(owner, {:event_promoted, self(), context})

        receive do
          :release_promoted_event -> :ok
        end

      _point, _context ->
        :ok
    end)

    restart_child(EventStore)

    old_manifest_store_pid = Process.whereis(ManifestStore)

    registration =
      Task.async(fn ->
        ManagementCore.register_server(%{id: "srv-promoted-before-crash"})
      end)

    assert_receive {:event_promoted, ^old_manifest_store_pid,
                    %{reservation: %{event: event, final_path: event_path}}}

    assert File.exists?(event_path)

    Process.exit(old_manifest_store_pid, :kill)

    assert {:ok, %Server{id: "srv-promoted-before-crash"}} = Task.await(registration)
    wait_for_replacement(ManifestStore, old_manifest_store_pid)

    assert {:ok, %Server{id: "srv-promoted-before-crash"}} =
             ManagementCore.get_server("srv-promoted-before-crash")

    assert [^event] = ManagementCore.list_events()

    Application.delete_env(:yellow_dog_management_core, :event_store_test_hook)
    restart_child(EventStore)
    restart_child(Servers)

    assert {:ok, %Server{id: "srv-promoted-before-crash"}} =
             ManagementCore.get_server("srv-promoted-before-crash")

    assert {:ok, reconciled_manifest} =
             AtomicJson.read(manifest_path_for("srv-promoted-before-crash"))

    refute Map.has_key?(reconciled_manifest, "registration_audit_outbox")
  end

  test "a cleared outbox is reconciled when ManifestStore dies before replying" do
    owner = self()

    Application.put_env(:yellow_dog_management_core, :event_store_test_hook, fn
      :after_outbox_clear, context ->
        send(owner, {:outbox_cleared, self(), context})

        receive do
          :release_outbox_clear -> :ok
        end

      _point, _context ->
        :ok
    end)

    restart_child(EventStore)
    old_manifest_store_pid = Process.whereis(ManifestStore)

    registration =
      Task.async(fn ->
        ManagementCore.register_server(%{id: "srv-killed-after-outbox-clear"})
      end)

    assert_receive {:outbox_cleared, ^old_manifest_store_pid,
                    %{path: manifest_path, reservation: reservation}}

    assert {:ok, manifest} = AtomicJson.read(manifest_path)
    refute Map.has_key?(manifest, "registration_audit_outbox")
    assert File.exists?(reservation.final_path)

    Process.exit(old_manifest_store_pid, :kill)

    assert {:ok, %Server{id: "srv-killed-after-outbox-clear"}} = Task.await(registration)
    wait_for_replacement(ManifestStore, old_manifest_store_pid)

    assert {:ok, %Server{id: "srv-killed-after-outbox-clear"}} =
             ManagementCore.get_server("srv-killed-after-outbox-clear")

    assert [%{source_id: "srv-killed-after-outbox-clear"}] = ManagementCore.list_events()
  end

  test "an external final collision is preserved and does not wedge later writes" do
    owner = self()

    Application.put_env(:yellow_dog_management_core, :event_store_test_hook, fn
      :before_event_promote, %{reservation: reservation} ->
        foreign_event =
          Map.put(reservation.event_map, "commit_token", commit_token("foreign-writer"))

        external_contents = Jason.encode!(foreign_event)
        assert :ok = File.write(reservation.final_path, external_contents, [:exclusive])
        send(owner, {:external_event_written, reservation.final_path, external_contents})

      _point, _context ->
        :ok
    end)

    restart_child(EventStore)

    assert {:error, %Error{code: :conflict}} =
             ManagementCore.register_server(%{id: "srv-external-collision"})

    assert_receive {:external_event_written, collision_path, external_contents}
    assert File.read!(collision_path) == external_contents
    assert {:error, :not_found} = ManagementCore.get_server("srv-external-collision")

    Application.delete_env(:yellow_dog_management_core, :event_store_test_hook)
    restart_child(EventStore)

    assert {:ok, %Server{id: "srv-after-external-collision"}} =
             ManagementCore.register_server(%{id: "srv-after-external-collision"})

    assert File.read!(collision_path) == external_contents

    assert [
             %{sequence: 1, source_id: "srv-external-collision"},
             %{sequence: 2, source_id: "srv-after-external-collision"}
           ] = ManagementCore.list_events()
  end

  test "successful promotion is reconciled when the link wrapper errors or raises" do
    Application.put_env(
      :yellow_dog_management_core,
      :atomic_json_file_ops,
      __MODULE__.PromoteThenFailFileOps
    )

    restart_child(EventStore)

    for {mode, id} <- [eio: "srv-promote-eio", raise: "srv-promote-raise"] do
      Application.put_env(:yellow_dog_management_core, :atomic_json_link_result, mode)

      assert {:ok, %Server{id: ^id}} = ManagementCore.register_server(%{id: id})
      assert {:ok, %Server{id: ^id}} = ManagementCore.get_server(id)
    end

    assert Enum.map(ManagementCore.list_events(), & &1.source_id) == [
             "srv-promote-eio",
             "srv-promote-raise"
           ]
  end

  test "allocator sequence reuse cannot confuse reservations after restart" do
    {deadline, config} = EventStore.operation()

    attrs = %{
      source: :server,
      source_id: "srv-reservation-one",
      type: :server_registered,
      message: "Server registered"
    }

    assert {:ok, first} = EventStore.reserve(attrs, deadline, config)
    restart_child(EventStore)

    {second_deadline, second_config} = EventStore.operation()
    assert {:ok, second} = EventStore.reserve(attrs, second_deadline, second_config)
    assert first.event.id == second.event.id
    refute first.commit_token == second.commit_token

    assert {:ok, %{id: "evt-1"}} = ManifestStore.persist_event(first, deadline)

    assert {:error, %Error{code: :conflict}} =
             ManifestStore.persist_event(second, second_deadline)

    assert {:ok, event_map} = AtomicJson.read(first.final_path)
    assert event_map["commit_token"] == first.commit_token
    refute event_map["commit_token"] == second.commit_token

    assert {:ok, %Server{id: "srv-after-reservation-reuse"}} =
             ManagementCore.register_server(%{id: "srv-after-reservation-reuse"})
  end

  test "stale stages are cleaned without deleting an immutable final" do
    assert {:ok, %Server{}} = ManagementCore.register_server(%{id: "srv-stale-stage"})
    [event] = ManagementCore.list_events()
    assert {:ok, final_path} = StoragePath.event(event.id)
    final_contents = File.read!(final_path)

    stale_path = Path.join(Path.dirname(final_path), ".#{Path.basename(final_path)}.stale.stage")
    assert :ok = File.write(stale_path, "stale")

    restart_child(ManifestStore)

    refute File.exists?(stale_path)
    assert File.read!(final_path) == final_contents
    assert [^event] = ManagementCore.list_events()
  end

  test "EventStore config snapshot disappears and reloads on restart" do
    Application.put_env(:yellow_dog_management_core, :event_write_timeout_ms, 100)
    restart_child(EventStore)
    assert EventStore.operation_timeout_ms() == 100

    assert :ok = Supervisor.terminate_child(YellowDog.ManagementCore.Supervisor, EventStore)
    assert :ets.whereis(YellowDog.Management.EventStore.ConfigSnapshot) == :undefined

    Application.put_env(:yellow_dog_management_core, :event_write_timeout_ms, 200)
    assert {:ok, _pid} = Supervisor.restart_child(YellowDog.ManagementCore.Supervisor, EventStore)
    assert EventStore.operation_timeout_ms() == 200
  end

  test "a suspended ManifestStore expires registration without later side effects", %{
    data_dir: data_dir
  } do
    Application.put_env(:yellow_dog_management_core, :event_write_timeout_ms, 100)
    restart_child(EventStore)

    manifest_store_pid = Process.whereis(ManifestStore)
    servers_pid = Process.whereis(Servers)
    owner = self()
    :ok = :sys.suspend(manifest_store_pid)

    {caller_pid, caller_ref} =
      spawn_monitor(fn ->
        result = ManagementCore.register_server(%{id: "srv-suspended-manifest"})
        send(owner, {:suspended_manifest_result, self(), result})
      end)

    try do
      assert_registration_commit_queued(manifest_store_pid)

      assert_receive {:suspended_manifest_result, ^caller_pid, {:error, %Error{code: :timeout}}},
                     500

      assert_receive {:DOWN, ^caller_ref, :process, ^caller_pid, :normal}
      assert Process.whereis(Servers) == servers_pid
      assert Process.alive?(servers_pid)
      assert {:error, :not_found} = ManagementCore.get_server("srv-suspended-manifest")
      assert [] = ManagementCore.list_servers()
    after
      :ok = :sys.resume(manifest_store_pid)
    end

    :sys.get_state(manifest_store_pid)
    assert event_files(data_dir) == []
    refute File.exists?(manifest_path_for("srv-suspended-manifest"))
  end

  test "an in-flight operation keeps its snapshotted storage root", %{data_dir: data_dir} do
    other_data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-management-other-root-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(other_data_dir) end)

    Application.put_env(:yellow_dog_management_core, :event_store_test_hook, fn
      :before_event_promote, _context ->
        Application.put_env(:yellow_dog_management_core, :data_dir, other_data_dir)

      _point, _context ->
        :ok
    end)

    restart_child(EventStore)

    assert {:ok, %Server{id: "srv-snapshotted-root"}} =
             ManagementCore.register_server(%{id: "srv-snapshotted-root"})

    assert File.exists?(
             Path.join([
               data_dir,
               "management",
               "servers",
               "srv-snapshotted-root",
               "manifest.json"
             ])
           )

    assert length(Path.wildcard(Path.join([data_dir, "management", "events", "*.json"]))) == 1
    refute File.exists?(Path.join(other_data_dir, "management"))

    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)
  end

  test "an expired queued manifest update is a no-op after resume" do
    Application.put_env(:yellow_dog_management_core, :event_write_timeout_ms, 100)
    restart_child(EventStore)

    assert {:ok, manifest_path} = StoragePath.server_manifest("srv-stale-manifest")
    manifest_store_pid = Process.whereis(ManifestStore)
    owner = self()
    :ok = :sys.suspend(manifest_store_pid)

    update =
      Task.async(fn ->
        ManifestStore.update_section(manifest_path, "config_lifecycle", fn _current ->
          send(owner, :stale_manifest_updater_called)
          %{"desired_version" => 1}
        end)
      end)

    try do
      assert_manifest_update_queued(manifest_path)
      assert {:error, %Error{code: :timeout}} = Task.await(update, 1_000)
      refute File.exists?(manifest_path)
    after
      :ok = :sys.resume(manifest_store_pid)
    end

    :sys.get_state(manifest_store_pid)
    refute_receive :stale_manifest_updater_called
    refute File.exists?(manifest_path)
  end

  test "a queued expired append cannot write after EventStore resumes", %{data_dir: data_dir} do
    Application.put_env(:yellow_dog_management_core, :event_write_timeout_ms, 100)
    restart_child(EventStore)

    event_store_pid = Process.whereis(EventStore)
    servers_pid = Process.whereis(Servers)
    manifest_store_pid = Process.whereis(ManifestStore)
    supervisor_pid = Process.whereis(YellowDog.ManagementCore.Supervisor)
    test_pid = self()

    :ok = :sys.suspend(event_store_pid)

    {caller_pid, caller_ref} =
      spawn_monitor(fn ->
        result = ManagementCore.register_server(%{id: "srv-expired-queued-event"})
        send(test_pid, {:queued_registration_result, self(), result})
      end)

    try do
      assert_event_append_queued(event_store_pid)

      assert_receive {:queued_registration_result, ^caller_pid, {:error, %Error{code: :timeout}}},
                     500

      assert_receive {:DOWN, ^caller_ref, :process, ^caller_pid, :normal}

      assert Process.whereis(Servers) == servers_pid
      assert Process.whereis(ManifestStore) == manifest_store_pid
      assert Process.whereis(YellowDog.ManagementCore.Supervisor) == supervisor_pid
      assert Process.alive?(servers_pid)
      assert Process.alive?(manifest_store_pid)
      assert Process.alive?(supervisor_pid)

      assert {:error, :not_found} =
               ManagementCore.get_server("srv-expired-queued-event")

      assert [] = ManagementCore.list_servers()

      assert {:ok, probe_path} = StoragePath.server_manifest("srv-timeout-probe")

      assert {:ok, %{"desired_version" => 1}} =
               ManifestStore.update_section(probe_path, "config_lifecycle", fn _current ->
                 %{"desired_version" => 1}
               end)

      assert {:ok, registration_path} =
               StoragePath.server_manifest("srv-expired-queued-event")

      refute File.exists?(registration_path)
      assert event_files(data_dir) == []
    after
      :ok = :sys.resume(event_store_pid)
    end

    :sys.get_state(event_store_pid)
    Process.sleep(250)

    assert [] = ManagementCore.list_events()
    assert event_files(data_dir) == []

    assert {:ok, registration_path} =
             StoragePath.server_manifest("srv-expired-queued-event")

    refute File.exists?(registration_path)
  end

  test "a started event write is killed and cleaned at its deadline", %{data_dir: data_dir} do
    Application.put_env(:yellow_dog_management_core, :event_write_timeout_ms, 100)
    Application.put_env(:yellow_dog_management_core, :event_write_test_delay_ms, 600)

    Application.put_env(
      :yellow_dog_management_core,
      :atomic_json_file_ops,
      __MODULE__.SlowEventFileOps
    )

    Application.put_env(:yellow_dog_management_core, :atomic_json_file_ops_owner, self())
    restart_child(EventStore)

    test_pid = self()
    servers_pid = Process.whereis(Servers)
    manifest_store_pid = Process.whereis(ManifestStore)
    started_at = System.monotonic_time(:millisecond)

    {caller_pid, caller_ref} =
      spawn_monitor(fn ->
        result = ManagementCore.register_server(%{id: "srv-slow-event"})
        elapsed = System.monotonic_time(:millisecond) - started_at
        send(test_pid, {:slow_registration_result, self(), result, elapsed})
      end)

    assert_receive {:event_write_started, worker_pid, event_path}
    assert Process.alive?(worker_pid)
    assert File.exists?(event_path)

    Application.put_env(:yellow_dog_management_core, :event_write_timeout_ms, 60_000)
    assert EventStore.operation_timeout_ms() == 100

    assert [] = ManagementCore.list_events()

    assert_receive {:slow_registration_result, ^caller_pid, {:error, %Error{code: :timeout}},
                    elapsed},
                   500

    assert elapsed < 500

    assert_receive {:DOWN, ^caller_ref, :process, ^caller_pid, :normal}
    refute Process.alive?(worker_pid)

    assert Process.whereis(Servers) == servers_pid
    assert Process.whereis(ManifestStore) == manifest_store_pid
    assert Process.alive?(servers_pid)
    assert Process.alive?(manifest_store_pid)
    assert {:error, :not_found} = ManagementCore.get_server("srv-slow-event")
    assert [] = ManagementCore.list_servers()
    assert [] = ManagementCore.list_events()
    refute File.exists?(event_path)

    assert {:ok, manifest_path} = StoragePath.server_manifest("srv-slow-event")
    refute File.exists?(manifest_path)

    Application.delete_env(:yellow_dog_management_core, :atomic_json_file_ops)
    Application.delete_env(:yellow_dog_management_core, :event_write_test_delay_ms)
    restart_child(EventStore)

    assert {:ok, %Server{id: "srv-after-event-timeout"}} =
             ManagementCore.register_server(%{id: "srv-after-event-timeout"})

    assert {:ok, %Server{id: "srv-after-event-timeout"}} =
             ManagementCore.get_server("srv-after-event-timeout")

    assert [%Server{id: "srv-after-event-timeout"}] = ManagementCore.list_servers()
    assert [%{source_id: "srv-after-event-timeout"}] = ManagementCore.list_events()

    Process.sleep(700)

    assert [%{source_id: "srv-after-event-timeout"}] = ManagementCore.list_events()
    assert length(event_files(data_dir)) == 1
  end

  test "a configured six-second write does not time out queued reads" do
    assert {:ok, %Server{id: "srv-existing"}} =
             ManagementCore.register_server(%{id: "srv-existing"})

    Application.put_env(:yellow_dog_management_core, :event_write_timeout_ms, 6_000)
    Application.put_env(:yellow_dog_management_core, :event_write_test_delay_ms, 5_200)

    Application.put_env(
      :yellow_dog_management_core,
      :atomic_json_file_ops,
      __MODULE__.SlowEventFileOps
    )

    Application.put_env(:yellow_dog_management_core, :atomic_json_file_ops_owner, self())
    restart_child(EventStore)

    started_at = System.monotonic_time(:millisecond)

    registration =
      Task.async(fn ->
        ManagementCore.register_server(%{id: "srv-six-second-write"})
      end)

    assert_receive {:event_write_started, _worker_pid, staging_path}
    assert String.ends_with?(staging_path, ".stage")

    assert [%{sequence: 1}] = ManagementCore.list_events()
    server_get = Task.async(fn -> ManagementCore.get_server("srv-existing") end)
    server_list = Task.async(fn -> ManagementCore.list_servers() end)

    assert_agent_call_queued(Process.whereis(Servers))

    assert {:ok, %Server{id: "srv-six-second-write"}} = Task.await(registration, 10_000)
    assert System.monotonic_time(:millisecond) - started_at >= 5_000

    assert [%{sequence: 1}, %{sequence: 2}] = ManagementCore.list_events()
    assert {:ok, %Server{id: "srv-existing"}} = Task.await(server_get, 10_000)

    assert [%Server{id: "srv-existing"}, %Server{id: "srv-six-second-write"}] =
             Task.await(server_list, 10_000)
  end

  test "an oversized event write timeout falls back to five seconds" do
    Application.put_env(:yellow_dog_management_core, :event_write_timeout_ms, 60_001)
    restart_child(EventStore)

    assert EventStore.operation_timeout_ms() == 5_000
    assert EventStore.read_call_timeout() == 8_000

    Application.put_env(:yellow_dog_management_core, :event_write_timeout_ms, 1_000)
    assert EventStore.operation_timeout_ms() == 5_000
    assert EventStore.read_call_timeout() == 8_000
  end

  test "event filename collisions are skipped without wedging future appends", %{
    data_dir: data_dir
  } do
    event_path = Path.join([data_dir, "management", "events", "evt-1.json"])
    File.mkdir_p!(Path.dirname(event_path))
    File.write!(event_path, "occupied")

    for id <- ["srv-event-conflict-1", "srv-event-conflict-2", "srv-event-conflict-3"] do
      assert {:ok, %Server{id: ^id}} = ManagementCore.register_server(%{id: id})
    end

    assert File.read!(event_path) == "occupied"
    assert Enum.map(ManagementCore.list_events(), & &1.sequence) == [2, 3, 4]

    restart_child(EventStore)
    assert Enum.map(ManagementCore.list_events(), & &1.sequence) == [2, 3, 4]
  end

  test "immutable events persist a bounded cryptographic commit token", %{data_dir: data_dir} do
    assert {:ok, %Server{id: "srv-tokenized-event"}} =
             ManagementCore.register_server(%{id: "srv-tokenized-event"})

    [event_path] = event_files(data_dir)
    assert {:ok, %{"commit_token" => token}} = AtomicJson.read(event_path)
    assert byte_size(token) == 43
    assert Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, token)
  end

  test "a huge malformed event filename does not poison restart allocation", %{
    data_dir: data_dir
  } do
    event_path =
      Path.join([
        data_dir,
        "management",
        "events",
        "evt-9223372036854775807.json"
      ])

    File.mkdir_p!(Path.dirname(event_path))
    File.write!(event_path, "malformed")

    restart_child(EventStore)

    assert {:ok, %Server{}} = ManagementCore.register_server(%{id: "srv-after-poison-1"})
    assert {:ok, %Server{}} = ManagementCore.register_server(%{id: "srv-after-poison-2"})

    assert Enum.map(ManagementCore.list_events(), & &1.sequence) == [1, 2]
  end

  test "an invalid event limit uses the documented default" do
    Application.put_env(:yellow_dog_management_core, :max_events, 0)

    assert {:ok, %Server{}} = ManagementCore.register_server(%{id: "srv-default-events"})
    assert [_event] = ManagementCore.list_events()
  end

  defp restart_child(child_id) do
    assert :ok = Supervisor.terminate_child(YellowDog.ManagementCore.Supervisor, child_id)
    assert {:ok, _pid} = Supervisor.restart_child(YellowDog.ManagementCore.Supervisor, child_id)
  end

  defp restart_management_children do
    Enum.each([Servers, Netmans, EventStore, ManifestStore], fn child_id ->
      assert :ok = Supervisor.terminate_child(YellowDog.ManagementCore.Supervisor, child_id)
    end)

    Enum.each([ManifestStore, EventStore, Servers, Netmans], fn child_id ->
      assert {:ok, _pid} =
               Supervisor.restart_child(YellowDog.ManagementCore.Supervisor, child_id)
    end)
  end

  defp write_file(data_dir, segments, contents) do
    path = Path.join([data_dir | segments])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp event_files(data_dir) do
    Path.wildcard(Path.join([data_dir, "management", "events", "*.json"]))
  end

  defp manifest_path_for(server_id) do
    config = EventStore.config()
    Path.join([config.root, "servers", server_id, "manifest.json"])
  end

  defp commit_token(seed) do
    :crypto.hash(:sha256, seed)
    |> Base.url_encode64(padding: false)
  end

  defp assert_event_append_queued(event_store_pid) do
    deadline = System.monotonic_time(:millisecond) + 1_000

    wait_until(deadline, fn ->
      {:messages, messages} = Process.info(event_store_pid, :messages)

      Enum.any?(messages, fn
        {:"$gen_call", _from, {:append, _attrs}} ->
          true

        {:"$gen_call", _from, {:append, _attrs, request_deadline}}
        when is_integer(request_deadline) ->
          true

        {:"$gen_call", _from, {:reserve, _attrs, request_deadline}}
        when is_integer(request_deadline) ->
          true

        {:"$gen_call", _from, {:reserve, _attrs, request_deadline, _config}}
        when is_integer(request_deadline) ->
          true

        _message ->
          false
      end)
    end)
  end

  defp assert_agent_call_queued(agent_pid) do
    deadline = System.monotonic_time(:millisecond) + 1_000

    wait_until(deadline, fn ->
      {:messages, messages} = Process.info(agent_pid, :messages)
      Enum.any?(messages, &match?({:"$gen_call", _from, _request}, &1))
    end)
  end

  defp assert_registration_commit_queued(manifest_store_pid) do
    deadline = System.monotonic_time(:millisecond) + 1_000

    wait_until(deadline, fn ->
      {:messages, messages} = Process.info(manifest_store_pid, :messages)

      Enum.any?(messages, fn
        {:"$gen_call", _from,
         {:commit_registration, _path, _registration, _reservation, request_deadline}}
        when is_integer(request_deadline) ->
          true

        _message ->
          false
      end)
    end)
  end

  defp assert_manifest_update_queued(path) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    manifest_store_pid = Process.whereis(ManifestStore)

    wait_until(deadline, fn ->
      {:messages, messages} = Process.info(manifest_store_pid, :messages)

      Enum.any?(messages, fn
        {:"$gen_call", _from, {:update_section, ^path, "config_lifecycle", updater}}
        when is_function(updater, 1) ->
          true

        {:"$gen_call", _from,
         {:update_section, ^path, "config_lifecycle", updater, request_deadline}}
        when is_function(updater, 1) and is_integer(request_deadline) ->
          true

        {:"$gen_call", _from,
         {:update_section, ^path, "config_lifecycle", updater, request_deadline, _config}}
        when is_function(updater, 1) and is_integer(request_deadline) ->
          true

        _message ->
          false
      end)
    end)
  end

  defp wait_for_replacement(module, old_pid) do
    deadline = System.monotonic_time(:millisecond) + 1_000

    wait_until(deadline, fn ->
      case Process.whereis(module) do
        pid when is_pid(pid) and pid != old_pid -> {:ok, pid}
        _other -> false
      end
    end)
  end

  defp wait_until(deadline, assertion) do
    case assertion.() do
      {:ok, value} ->
        value

      true ->
        :ok

      false ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1)
          wait_until(deadline, assertion)
        else
          flunk("timed out waiting for synchronized process state")
        end
    end
  end

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defmodule BlockingEventFailureFileOps do
    defdelegate read(path), to: YellowDog.Management.Storage.AtomicJson.FileOps

    def open(path) do
      if String.contains?(path, "/events/") do
        owner = Application.fetch_env!(:yellow_dog_management_core, :atomic_json_file_ops_owner)
        send(owner, {:event_write_blocked, self()})

        receive do
          :continue_event_write -> {:error, :eacces}
        end
      else
        YellowDog.Management.Storage.AtomicJson.FileOps.open(path)
      end
    end

    defdelegate write(device, contents), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate sync(device), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate close(device), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate rename(source, target), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate link(source, target), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate rm(path), to: YellowDog.Management.Storage.AtomicJson.FileOps
  end

  defmodule SlowEventFileOps do
    defdelegate read(path), to: YellowDog.Management.Storage.AtomicJson.FileOps

    def open(path) do
      if String.contains?(path, "/events/") do
        Process.put(:event_write_path, path)
        YellowDog.Management.Storage.AtomicJson.FileOps.open(path)
      else
        YellowDog.Management.Storage.AtomicJson.FileOps.open(path)
      end
    end

    defdelegate write(device, contents), to: YellowDog.Management.Storage.AtomicJson.FileOps

    def sync(device) do
      case Process.get(:event_write_path) do
        path when is_binary(path) ->
          owner = Application.fetch_env!(:yellow_dog_management_core, :atomic_json_file_ops_owner)
          delay = Application.fetch_env!(:yellow_dog_management_core, :event_write_test_delay_ms)
          send(owner, {:event_write_started, self(), path})
          Process.sleep(delay)
          YellowDog.Management.Storage.AtomicJson.FileOps.sync(device)

        _other ->
          YellowDog.Management.Storage.AtomicJson.FileOps.sync(device)
      end
    end

    defdelegate close(device), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate rename(source, target), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate link(source, target), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate rm(path), to: YellowDog.Management.Storage.AtomicJson.FileOps
  end

  defmodule BlockingStagingSyncFileOps do
    defdelegate read(path), to: YellowDog.Management.Storage.AtomicJson.FileOps

    def open(path) do
      Process.put(:event_staging_path, path)
      YellowDog.Management.Storage.AtomicJson.FileOps.open(path)
    end

    defdelegate write(device, contents), to: YellowDog.Management.Storage.AtomicJson.FileOps

    def sync(device) do
      path = Process.get(:event_staging_path)
      result = YellowDog.Management.Storage.AtomicJson.FileOps.sync(device)

      if is_binary(path) and String.contains?(path, "/events/") do
        owner = Application.fetch_env!(:yellow_dog_management_core, :atomic_json_file_ops_owner)
        send(owner, {:event_staging_synced, self(), path})

        receive do
          :continue_event_write -> result
        end
      else
        result
      end
    end

    defdelegate close(device), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate rename(source, target), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate link(source, target), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate rm(path), to: YellowDog.Management.Storage.AtomicJson.FileOps
  end

  defmodule PromoteThenFailFileOps do
    defdelegate read(path), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate open(path), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate write(device, contents), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate sync(device), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate close(device), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate rename(source, target), to: YellowDog.Management.Storage.AtomicJson.FileOps

    def link(source, target) do
      :ok = YellowDog.Management.Storage.AtomicJson.FileOps.link(source, target)

      case Application.fetch_env!(:yellow_dog_management_core, :atomic_json_link_result) do
        :eio -> {:error, :eio}
        :raise -> raise "injected post-link failure"
      end
    end

    defdelegate rm(path), to: YellowDog.Management.Storage.AtomicJson.FileOps
  end
end
