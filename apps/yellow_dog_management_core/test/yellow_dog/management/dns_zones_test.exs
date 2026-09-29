defmodule YellowDog.Management.DnsZonesTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.DnsZones
  alias YellowDog.Management.DnsZone
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
                 %{"owner" => "example.test.", "type" => "SRV", "ttl" => 300, "records" => ["no"]}
               ]
             })
  end

  test "publishes AAAA, MX, ordered TXT segments, wildcard and underscore owners" do
    extra = [
      %{
        "owner" => "ns1.example.test.",
        "type" => "AAAA",
        "ttl" => 300,
        "records" => ["2001:DB8::53"]
      },
      %{
        "owner" => "example.test.",
        "type" => "MX",
        "ttl" => 300,
        "records" => [%{"preference" => 10, "exchange" => "Mail.Example.Test"}]
      },
      %{"owner" => "*.example.test.", "type" => "A", "ttl" => 300, "records" => ["192.0.2.10"]},
      %{
        "owner" => "_dmarc.example.test.",
        "type" => "TXT",
        "ttl" => 300,
        "records" => [["v=DMARC1; ", "p=reject"]]
      }
    ]

    assert {:ok, zone} =
             DnsZones.create(%{
               "apex" => "example.test.",
               "targets" => ["srv-one"],
               "rrsets" => rrsets("example.test.") ++ extra
             })

    assert {:ok, _} = DnsZones.publish(zone["id"], 1, "operator", "new-types")
    assert {:ok, %{"zones" => [snapshot]}} = DnsZones.manifest("srv-one")
    assert {:ok, _} = YellowDog.Sync.DnsManifest.zone_digest(Map.delete(snapshot, "digest"))
    assert Enum.find(snapshot["rrsets"], &(&1["type"] == "AAAA"))["records"] == ["2001:db8::53"]

    assert Enum.find(snapshot["rrsets"], &(&1["type"] == "MX"))["records"] ==
             [%{"preference" => 10, "exchange" => "mail.example.test."}]

    assert Enum.find(snapshot["rrsets"], &(&1["type"] == "TXT"))["records"] ==
             [["v=DMARC1; ", "p=reject"]]
  end

  test "CNAME replacements are atomic and conflicting aliases are rejected" do
    {:ok, zone} =
      DnsZones.create(%{
        "apex" => "example.test.",
        "targets" => ["srv-one"],
        "rrsets" =>
          rrsets("example.test.") ++
            [
              %{
                "owner" => "www.example.test.",
                "type" => "A",
                "ttl" => 300,
                "records" => ["192.0.2.2"]
              }
            ]
      })

    cname = %{
      "owner" => "www.example.test.",
      "type" => "CNAME",
      "ttl" => 300,
      "records" => ["ns1.example.test."]
    }

    deletion = %{"owner" => "www.example.test.", "type" => "A", "delete" => true}
    assert {:error, :cname_conflict} = DnsZones.edit(zone["id"], 1, [cname])
    assert {:ok, updated} = DnsZones.edit(zone["id"], 1, [cname, deletion])
    assert updated["revision"] == 2

    assert {:error, :cname_loop} =
             DnsZones.edit(zone["id"], 2, [
               %{cname | "owner" => "alias.example.test.", "records" => ["www.example.test."]},
               %{cname | "records" => ["alias.example.test."]}
             ])

    assert {:error, :invalid_owner} =
             DnsZones.edit(zone["id"], 2, [
               %{cname | "owner" => "child.example.test.", "type" => "NS"}
             ])
  end

  test "managed RRset validation enforces owner, type and content bounds" do
    apex = "example.test."

    assert {:ok, normalized} =
             DnsZone.normalize_rrsets(
               apex,
               rrsets(apex) ++
                 [
                   %{
                     "owner" => "www.deep.example.test.",
                     "type" => "A",
                     "ttl" => 300,
                     "records" => ["192.0.2.4"]
                   }
                 ]
             )

    assert Enum.any?(normalized, &(&1["owner"] == "www.deep.example.test."))

    bad = [
      {%{
         "owner" => "child.example.test.",
         "type" => "NS",
         "ttl" => 300,
         "records" => ["ns1.example.test."]
       }, :invalid_owner},
      {%{"owner" => "*.example.test.", "type" => "A", "ttl" => 0, "records" => ["192.0.2.1"]},
       :invalid_rrset},
      {%{"owner" => "bad.example.test.", "type" => "A", "ttl" => 300, "records" => ["1.2.3"]},
       :invalid_a_record},
      {%{
         "owner" => "bad.example.test.",
         "type" => "A",
         "ttl" => 300,
         "records" => ["001.002.003.004"]
       }, :invalid_a_record},
      {%{
         "owner" => "bad.example.test.",
         "type" => "A",
         "ttl" => 300,
         "records" => ["192.0.2.1"],
         "priority" => 10
       }, :invalid_rrset},
      {%{
         "owner" => "*.example.test.",
         "type" => "A",
         "ttl" => 2_147_483_648,
         "records" => ["192.0.2.1"]
       }, :invalid_rrset},
      {%{
         "owner" => "bad.example.test.",
         "type" => "AAAA",
         "ttl" => 300,
         "records" => ["2001:db8::not-ip"]
       }, :invalid_aaaa_record},
      {%{
         "owner" => "bad.example.test.",
         "type" => "MX",
         "ttl" => 300,
         "records" => [%{"preference" => 10, "exchange" => "mail.example.test.", "extra" => 1}]
       }, :invalid_record},
      {%{
         "owner" => "_dmarc.example.test.",
         "type" => "TXT",
         "ttl" => 300,
         "records" => [[String.duplicate("x", 256)]]
       }, :invalid_txt_record},
      {%{
         "owner" => "_dmarc.example.test.",
         "type" => "TXT",
         "ttl" => 300,
         "records" => [String.duplicate("x", 256)]
       }, :invalid_record}
    ]

    for {rrset, reason} <- bad do
      assert {:error, ^reason} = DnsZone.normalize_rrsets(apex, rrsets(apex) ++ [rrset])
    end
  end

  test "edit rejects unknown fields rather than silently discarding them" do
    {:ok, zone} = DnsZones.create(%{"apex" => "example.test.", "targets" => ["srv-one"]})

    assert {:error, :invalid_edits} =
             DnsZones.edit(zone["id"], 1, [
               %{
                 "owner" => "www.example.test.",
                 "type" => "A",
                 "ttl" => 300,
                 "records" => ["192.0.2.1"],
                 "priority" => 10
               }
             ])

    assert {:ok, %{"revision" => 1}} = DnsZones.get(zone["id"])
  end

  test "SOA serial wraps by RFC 1982 and invalid stored serial fails safely" do
    assert {:ok, 0} = DnsZone.next_serial(4_294_967_295)
    assert {:error, :invalid_soa_serial} = DnsZone.next_serial(4_294_967_296)

    {:ok, zone} =
      DnsZones.create(%{
        "apex" => "example.test.",
        "targets" => ["srv-one"],
        "rrsets" => rrsets("example.test.")
      })

    {:ok, root} = YellowDog.Management.Storage.Path.root()
    path = Path.join([root, "dns", "state.json"])

    {:ok, state} = YellowDog.Management.Storage.AtomicJson.read(path)
    state = put_in(state, ["zones", zone["id"], "soa_serial"], 4_294_967_295)
    {:ok, _} = YellowDog.Management.Storage.AtomicJson.replace(path, state)
    restart(DnsZones)

    assert {:ok, deployment} = DnsZones.publish(zone["id"], 1, "operator", "wrapped")
    assert deployment["soa_serial"] == 0
    assert {:ok, %{"zones" => [snapshot]}} = DnsZones.manifest("srv-one")
    assert hd(Enum.find(snapshot["rrsets"], &(&1["type"] == "SOA"))["records"])["serial"] == 0

    {:ok, state} = YellowDog.Management.Storage.AtomicJson.read(path)
    state = put_in(state, ["zones", zone["id"], "soa_serial"], 4_294_967_296)
    {:ok, _} = YellowDog.Management.Storage.AtomicJson.replace(path, state)
    restart(DnsZones)

    assert {:error, :invalid_soa_serial} =
             DnsZones.publish(zone["id"], 1, "operator", "bad-serial")

    assert Process.alive?(Process.whereis(DnsZones))
  end

  test "oversized DNS wire image is rejected before saving a draft" do
    apex = "example.test."
    txt_rrsets = oversized_txt_rrsets(apex)
    assert {:error, :too_large} = DnsZone.normalize_rrsets(apex, rrsets(apex) ++ txt_rrsets)

    assert {:error, :too_large} =
             DnsZones.create(%{
               "apex" => apex,
               "targets" => ["srv-one"],
               "rrsets" => rrsets(apex) ++ txt_rrsets
             })

    assert DnsZones.list() == []
  end

  test "CNAME targets cannot be loops or NS and MX targets" do
    apex = "example.test."
    base = rrsets(apex)

    alias_rrset = %{
      "owner" => "mail.example.test.",
      "type" => "CNAME",
      "ttl" => 300,
      "records" => ["ns1.example.test."]
    }

    mx = %{
      "owner" => apex,
      "type" => "MX",
      "ttl" => 300,
      "records" => [%{"preference" => 10, "exchange" => "mail.example.test."}]
    }

    assert {:error, :cname_target} = DnsZone.normalize_rrsets(apex, base ++ [alias_rrset, mx])

    ns_alias = %{alias_rrset | "owner" => "ns1.example.test."}
    assert {:error, :cname_conflict} = DnsZone.normalize_rrsets(apex, base ++ [ns_alias])

    loop = %{alias_rrset | "records" => ["mail.example.test."]}
    assert {:error, :cname_loop} = DnsZone.normalize_rrsets(apex, base ++ [loop])
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
    # Escaped control bytes keep each zone inside the DNS wire budget while
    # making four zones exceed the 1 MiB serialized manifest bound.
    records =
      Enum.map(1..64, fn index ->
        [String.duplicate(<<0>>, 247) <> String.pad_leading(to_string(index), 3, "0")]
      end)

    zones =
      Enum.map(1..4, fn number ->
        apex = "bulk#{number}.test."

        large_rrsets =
          Enum.map(1..3, fn owner ->
            %{"owner" => "n#{owner}.#{apex}", "type" => "TXT", "ttl" => 300, "records" => records}
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

  defp oversized_txt_rrsets(apex) do
    for owner <- 1..4 do
      records =
        for index <- 1..64,
            do: [String.duplicate("x", 250) <> String.pad_leading(to_string(index), 3, "0")]

      %{"owner" => "bulk#{owner}.#{apex}", "type" => "TXT", "ttl" => 300, "records" => records}
    end
  end

  defp restart(module) do
    pid = Process.whereis(module)
    if pid, do: Supervisor.terminate_child(YellowDog.ManagementCore.Supervisor, module)
    if pid, do: Supervisor.restart_child(YellowDog.ManagementCore.Supervisor, module)
  end
end
