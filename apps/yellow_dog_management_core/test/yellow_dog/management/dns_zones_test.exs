defmodule YellowDog.Management.DnsZonesTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.DnsZones
  alias YellowDog.Management.Servers

  setup do
    old_dir = Application.get_env(:yellow_dog_management_core, :data_dir)
    dir = Path.join(System.tmp_dir!(), "dns-zones-#{System.unique_integer([:positive])}")
    Application.put_env(:yellow_dog_management_core, :data_dir, dir)
    restart(DnsZones)
    restart(Servers)
    {:ok, _} = Servers.register(%{id: "srv-one", profile: :cloud_dns})

    on_exit(fn ->
      if old_dir,
        do: Application.put_env(:yellow_dog_management_core, :data_dir, old_dir),
        else: Application.delete_env(:yellow_dog_management_core, :data_dir)

      restart(DnsZones)
      restart(Servers)
      File.rm_rf(dir)
    end)

    :ok
  end

  test "draft edits and publication survive restart with independent generations" do
    {:ok, zone} =
      DnsZones.create(%{
        "apex" => "Example.Test",
        "targets" => ["srv-one"],
        "rrsets" => rrsets("example.test.")
      })

    assert zone["revision"] == 1

    assert {:error, :conflict} =
             DnsZones.edit(zone["id"], 0, [
               %{
                 "owner" => "www.example.test.",
                 "type" => "A",
                 "ttl" => 300,
                 "records" => ["192.0.2.2"]
               }
             ])

    assert {:ok, deployment} = DnsZones.publish(zone["id"], 1, "operator", "request-one")
    assert deployment["soa_serial"] == 1
    assert {:ok, ^deployment} = DnsZones.publish(zone["id"], 1, "operator", "request-one")
    assert {:error, :conflict} = DnsZones.publish(zone["id"], 2, "operator", "request-one")
    restart(DnsZones)
    assert {:ok, ^deployment} = DnsZones.publish(zone["id"], 1, "operator", "request-one")
    assert {:ok, manifest} = DnsZones.manifest("srv-one")
    assert manifest["generation"] == 1
    assert [snapshot] = manifest["zones"]
    assert snapshot["digest"] == deployment["zone_digest"]

    {:ok, manifest_digest} = YellowDog.Sync.DnsManifest.digest(manifest)
    assert :ok = DnsZones.report_applied("srv-one", 1, manifest_digest)
    assert {:ok, ^deployment} = DnsZones.publish(zone["id"], 1, "operator", "request-one")

    assert {:ok, %{"state" => "applied", "targets" => %{"srv-one" => target}}} =
             DnsZones.deployment(deployment["id"])

    assert target["verification"] == nil
    assert target["observed"]["zone_version"] == deployment["zone_version"]
    assert target["observed"]["zone_digest"] == deployment["zone_digest"]
    assert target["observed"]["digest"] == manifest_digest
    assert hd(Enum.find(snapshot["rrsets"], &(&1["type"] == "SOA"))["records"])["serial"] == 1
  end

  test "rejects unsupported records and missing enrolled placement" do
    assert {:error, :unknown_target} =
             DnsZones.create(%{"apex" => "example.test.", "targets" => ["offline-unknown"]})

    assert {:error, :invalid_rrset} =
             DnsZones.create(%{
               "apex" => "example.test.",
               "targets" => ["srv-one"],
               "rrsets" => [
                 %{"owner" => "example.test.", "type" => "TXT", "ttl" => 300, "records" => ["no"]}
               ]
             })
  end

  test "publishing two zones retains both independent manifest entries" do
    {:ok, first} =
      DnsZones.create(%{
        "apex" => "example.test.",
        "targets" => ["srv-one"],
        "rrsets" => rrsets("example.test.")
      })

    {:ok, second} =
      DnsZones.create(%{
        "apex" => "other.test.",
        "targets" => ["srv-one"],
        "rrsets" => rrsets("other.test.")
      })

    {:ok, first_deployment} = DnsZones.publish(first["id"], 1, "operator", "first")
    {:ok, second_deployment} = DnsZones.publish(second["id"], 1, "operator", "second")
    {:ok, manifest} = DnsZones.manifest("srv-one")
    assert manifest["generation"] == 2
    assert Enum.map(manifest["zones"], & &1["apex"]) == ["example.test.", "other.test."]
    assert first_deployment["zone_digest"] != second_deployment["zone_digest"]
  end

  test "create and edit idempotency survive restart while stale edits conflict" do
    attrs = %{
      "apex" => "example.test.",
      "targets" => ["srv-one"],
      "rrsets" => rrsets("example.test.")
    }

    {:ok, zone} = DnsZones.create(attrs, "operator", "create-key")
    restart(DnsZones)
    assert {:ok, ^zone} = DnsZones.create(attrs, "operator", "create-key")

    assert {:error, :conflict} =
             DnsZones.create(%{attrs | "apex" => "changed.test."}, "operator", "create-key")

    edits = [
      %{"owner" => "www.example.test.", "type" => "A", "ttl" => 300, "records" => ["192.0.2.9"]}
    ]

    {:ok, updated} = DnsZones.edit(zone["id"], 1, edits, "operator", "edit-key")
    assert updated["revision"] == 2
    assert {:error, :conflict} = DnsZones.edit(zone["id"], 1, edits, "operator", "other-edit")
    restart(DnsZones)
    assert {:ok, ^updated} = DnsZones.edit(zone["id"], 1, edits, "operator", "edit-key")
  end

  test "out-of-zone deletion is rejected without advancing draft revision" do
    {:ok, zone} = DnsZones.create(%{"apex" => "example.test.", "targets" => ["srv-one"]})

    assert {:error, :invalid_edits} =
             DnsZones.edit(zone["id"], 1, [
               %{"owner" => "outside.test.", "type" => "A", "delete" => true}
             ])

    assert {:ok, %{"revision" => 1, "rrsets" => []}} = DnsZones.get(zone["id"])
  end

  test "oversized aggregate manifest rejects publication without crashing or committing" do
    records = Enum.map(1..64, &"255.255.255.#{&1}")

    zones =
      Enum.map(1..4, fn number ->
        apex = "bulk#{number}.test."

        large_rrsets =
          Enum.map(1..253, fn owner ->
            %{"owner" => "n#{owner}.#{apex}", "type" => "A", "ttl" => 300, "records" => records}
          end)

        {:ok, zone} =
          DnsZones.create(%{
            "apex" => apex,
            "targets" => ["srv-one"],
            "rrsets" => rrsets(apex) ++ large_rrsets
          })

        zone
      end)

    Enum.each(Enum.take(zones, 3), fn zone ->
      assert {:ok, _} = DnsZones.publish(zone["id"], 1, "operator", "publish-#{zone["id"]}")
    end)

    fourth = List.last(zones)
    assert {:error, :too_large} = DnsZones.publish(fourth["id"], 1, "operator", "too-large")
    assert Process.alive?(Process.whereis(DnsZones))
    assert {:ok, %{"published_version" => nil}} = DnsZones.get(fourth["id"])
    assert {:ok, %{"generation" => 3, "zones" => installed}} = DnsZones.manifest("srv-one")
    assert length(installed) == 3
  end

  defp rrsets(apex) do
    ns = "ns1.#{apex}"
    rname = "hostmaster.#{apex}"

    [
      %{
        "owner" => apex,
        "type" => "SOA",
        "ttl" => 300,
        "records" => [
          %{
            "mname" => ns,
            "rname" => rname,
            "refresh" => 3600,
            "retry" => 600,
            "expire" => 86400,
            "minimum" => 300
          }
        ]
      },
      %{"owner" => apex, "type" => "NS", "ttl" => 300, "records" => [ns]},
      %{"owner" => ns, "type" => "A", "ttl" => 300, "records" => ["192.0.2.53"]}
    ]
  end

  defp restart(module) do
    pid = Process.whereis(module)
    if pid, do: Supervisor.terminate_child(YellowDog.ManagementCore.Supervisor, module)
    if pid, do: Supervisor.restart_child(YellowDog.ManagementCore.Supervisor, module)
  end
end
