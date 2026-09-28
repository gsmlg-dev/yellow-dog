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

    unsupported = put_in(manifest, ["zones", Access.at(0), "rrsets", Access.at(0), "type"], "TXT")
    assert {:error, :invalid_manifest} = DnsManifest.validate(unsupported, "server-1")
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
end
