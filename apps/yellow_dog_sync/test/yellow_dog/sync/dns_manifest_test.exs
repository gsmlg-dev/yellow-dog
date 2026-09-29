defmodule YellowDog.Sync.DnsManifestTest do
  use ExUnit.Case, async: true

  alias YellowDog.Sync.DnsManifest
  alias YellowDog.Sync.Message
  alias YellowDog.Sync.Message.DnsManifestDelivery
  alias YellowDog.Sync.Message.DnsState

  test "two zones remain in the complete DNS manifest with independent generation" do
    zones = Enum.map(["example.test.", "other.test."], &zone/1)

    manifest = %{
      "schema_version" => 1,
      "server_id" => "server-1",
      "generation" => 7,
      "zones" => zones
    }

    assert {:ok, digest} = DnsManifest.validate(manifest, "server-1")
    assert {:ok, encoded} = Message.encode(%DnsManifestDelivery{manifest: manifest})
    assert {:ok, %DnsManifestDelivery{manifest: ^manifest}} = Message.decode(encoded)
    assert {:ok, ^digest} = DnsManifest.digest(manifest)
    assert {:error, :invalid_manifest} = DnsManifest.validate(manifest, "server-2")

    changed = put_in(manifest["generation"], 8)
    assert {:ok, changed_digest} = DnsManifest.digest(changed)
    refute changed_digest == digest
    assert Enum.map(changed["zones"], & &1["apex"]) == ["example.test.", "other.test."]
  end

  test "tampered zone content and unsupported records are rejected" do
    manifest = %{
      "schema_version" => 1,
      "server_id" => "server-1",
      "generation" => 1,
      "zones" => [zone("example.test.")]
    }

    assert {:ok, _} = DnsManifest.validate(manifest, "server-1")

    tampered =
      put_in(manifest, ["zones", Access.at(0), "rrsets", Access.at(0), "records"], ["192.0.2.99"])

    assert {:error, :invalid_manifest} = DnsManifest.validate(tampered, "server-1")

    unsupported = put_in(manifest, ["zones", Access.at(0), "rrsets", Access.at(0), "type"], "SRV")
    assert {:error, :invalid_manifest} = DnsManifest.validate(unsupported, "server-1")
  end

  test "validates supported records and zone semantics even with a recomputed digest" do
    base = zone("example.test.")

    extras = [
      %{
        "owner" => "ns.example.test.",
        "type" => "AAAA",
        "ttl" => 300,
        "records" => ["2001:db8::53"]
      },
      %{
        "owner" => "example.test.",
        "type" => "MX",
        "ttl" => 300,
        "records" => [%{"preference" => 10, "exchange" => "mail.example.test."}]
      },
      %{
        "owner" => "*.example.test.",
        "type" => "CNAME",
        "ttl" => 300,
        "records" => ["www.example.test."]
      },
      %{
        "owner" => "_dmarc.example.test.",
        "type" => "TXT",
        "ttl" => 300,
        "records" => [["v=DMARC1; ", "p=reject"]]
      }
    ]

    candidate = %{base | "rrsets" => base["rrsets"] ++ extras}
    assert {:ok, digest} = DnsManifest.zone_digest(Map.delete(candidate, "digest"))
    candidate = %{candidate | "digest" => digest}
    assert {:ok, _} = DnsManifest.validate(manifest(candidate), "server-1")

    for bad <- [
          %{
            candidate
            | "rrsets" =>
                candidate["rrsets"] ++
                  [
                    %{
                      "owner" => "child.example.test.",
                      "type" => "NS",
                      "ttl" => 300,
                      "records" => ["ns.example.test."]
                    }
                  ]
          },
          put_in(candidate, ["rrsets", Access.at(-1), "records"], [[String.duplicate("x", 256)]]),
          put_in(candidate, ["rrsets", Access.at(5), "records"], ["*.example.test."])
        ] do
      assert {:error, :invalid_manifest} = DnsManifest.zone_digest(Map.delete(bad, "digest"))
    end
  end

  test "DNS applied state is a separate wire message" do
    state = %DnsState{
      server_id: "server-1",
      generation: 2,
      digest: String.duplicate("a", 64),
      state: :applied,
      error: nil,
      observed_at: ~U[2026-09-28 00:00:00Z]
    }

    assert {:ok, encoded} = Message.encode(state)
    assert {:ok, ^state} = Message.decode(encoded)
  end

  test "rejects abbreviated IPv4 and oversized full-zone wire images" do
    apex = "example.test."
    base = zone(apex)

    for address <- ["1.2.3", "001.002.003.004", "0x7f.0.0.1"] do
      bad = put_in(base, ["rrsets", Access.at(0), "records"], [address])
      assert {:error, :invalid_manifest} = DnsManifest.zone_digest(Map.delete(bad, "digest"))
    end

    large =
      for owner <- 1..4 do
        records =
          for index <- 1..64 do
            [String.duplicate("x", 250) <> String.pad_leading(to_string(index), 3, "0")]
          end

        %{"owner" => "bulk#{owner}.#{apex}", "type" => "TXT", "ttl" => 300, "records" => records}
      end

    oversized = %{base | "rrsets" => base["rrsets"] ++ large}
    refute DnsManifest.within_wire_budget?(oversized["rrsets"])
    assert {:error, :invalid_manifest} = DnsManifest.zone_digest(oversized)
  end

  test "wire budget accounts for maximum wildcard owner expansion" do
    apex = "example.test."
    base = zone(apex)
    owner = "*.example.test."

    wildcard = [
      %{
        "owner" => owner,
        "type" => "TXT",
        "ttl" => 300,
        "records" => for(index <- 1..64, do: [String.duplicate("x", 247) <> to_string(index)])
      },
      %{
        "owner" => owner,
        "type" => "MX",
        "ttl" => 300,
        "records" =>
          for(index <- 1..64,
            do: %{"preference" => index, "exchange" => "mail#{index}.example.test."}
          )
      },
      %{
        "owner" => owner,
        "type" => "A",
        "ttl" => 300,
        "records" => for(index <- 1..64, do: "192.0.2.#{index}")
      }
    ]

    refute DnsManifest.within_wire_budget?(base["rrsets"] ++ wildcard)
    assert {:error, :invalid_manifest} =
             DnsManifest.zone_digest(%{base | "rrsets" => base["rrsets"] ++ wildcard})
  end

  defp zone(apex) do
    zone = %{
      "zone_id" => apex,
      "apex" => apex,
      "version" => 1,
      "rrsets" => [
        %{"owner" => apex, "type" => "A", "ttl" => 300, "records" => ["192.0.2.1"]},
        %{"owner" => apex, "type" => "NS", "ttl" => 300, "records" => ["ns." <> apex]},
        %{
          "owner" => apex,
          "type" => "SOA",
          "ttl" => 300,
          "records" => [
            %{
              "mname" => "ns." <> apex,
              "rname" => "hostmaster." <> apex,
              "serial" => 1,
              "refresh" => 3600,
              "retry" => 600,
              "expire" => 86_400,
              "minimum" => 300
            }
          ]
        }
      ]
    }

    {:ok, digest} = DnsManifest.zone_digest(zone)
    Map.put(zone, "digest", digest)
  end

  defp manifest(zone),
    do: %{
      "schema_version" => 1,
      "server_id" => "server-1",
      "generation" => 1,
      "zones" => [zone]
    }
end
