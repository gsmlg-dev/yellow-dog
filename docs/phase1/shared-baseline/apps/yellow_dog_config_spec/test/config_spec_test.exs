defmodule YellowDog.ConfigSpecTest do
  use ExUnit.Case, async: true

  alias YellowDog.ConfigSpec

  defp zone(id, name, address) do
    %{
      "id" => id,
      "type" => "dns_zone",
      "schema_version" => 1,
      "version" => 1,
      "content" => %{
        "name" => name,
        "records" => [
          %{
            "name" => name,
            "type" => "SOA",
            "ttl" => 3600,
            "data" => %{
              "mname" => "ns1.#{name}",
              "rname" => "hostmaster.#{name}",
              "serial" => 2_026_093_001,
              "refresh" => 3600,
              "retry" => 600,
              "expire" => 86_400,
              "minimum" => 300
            }
          },
          %{"name" => name, "type" => "NS", "ttl" => 3600, "data" => %{"host" => "ns1.#{name}"}},
          %{
            "name" => "ns1.#{name}",
            "type" => "A",
            "ttl" => 300,
            "data" => %{"address" => address}
          }
        ]
      }
    }
  end

  defp plan do
    %{
      "schema_version" => 1,
      "worker_id" => "edge-01",
      "revision" => 1,
      "services" => [
        %{
          "id" => "dns-primary",
          "type" => "dns",
          "desired_state" => "running",
          "config" => %{"listen_address" => "127.0.0.1", "port" => 1053},
          "resources" => ["zone-example"]
        }
      ],
      "resources" => [zone("zone-example", "Example.COM", "192.0.2.53")]
    }
  end

  defp error_code({:error, [%{code: code} | _]}), do: code

  defp fixture(name), do: File.read!(Path.join([__DIR__, "fixtures", name]))

  test "fixed hand-authored TOML fixtures" do
    assert {:ok, complete} = ConfigSpec.decode(fixture("complete_zone.toml"))
    assert complete["resources"] |> hd() |> get_in(["content", "records"]) |> length() == 3
    assert {:ok, multiple} = ConfigSpec.decode(fixture("multiple_zones.toml"))
    assert Enum.map(multiple["resources"], & &1["id"]) == ["zone-example", "zone-other"]
    assert hd(multiple["services"])["desired_state"] == "stopped"
    assert {:ok, empty} = ConfigSpec.decode(fixture("empty_resources.toml"))
    assert {:ok, ^empty} = ConfigSpec.decode(fixture("equivalent_empty.toml"))
    assert empty["resources"] == []
    assert hd(empty["services"])["desired_state"] == "stopped"
    assert error_code(ConfigSpec.decode(fixture("missing_reference.toml"))) == :missing_reference
    assert error_code(ConfigSpec.decode(fixture("duplicate_instances.toml"))) == :duplicate
    assert error_code(ConfigSpec.decode(fixture("duplicate_resources.toml"))) == :duplicate
    assert error_code(ConfigSpec.decode(fixture("incorrect_digest.toml"))) == :digest_mismatch

    assert error_code(ConfigSpec.decode(fixture("unsupported_service.toml"))) ==
             :unsupported_value

    assert error_code(ConfigSpec.decode(fixture("malformed.toml"))) == :invalid_toml
    assert {:ok, generated} = ConfigSpec.encode(complete)
    assert {:ok, ^complete} = ConfigSpec.decode(generated)
  end

  test "complete SOA/NS/A zone normalizes and survives a TOML round trip" do
    {:ok, normalized} = ConfigSpec.normalize_plan(plan())
    {:ok, toml} = ConfigSpec.encode(plan())
    assert {:ok, ^normalized} = ConfigSpec.decode(toml)
    assert normalized["resources"] |> hd() |> get_in(["content", "name"]) == "example.com."
    assert normalized["resources"] |> hd() |> Map.fetch!("digest") =~ ~r/\A[0-9a-f]{64}\z/
    assert {:ok, digest} = ConfigSpec.plan_digest(plan())
    assert {:ok, ^digest} = ConfigSpec.plan_digest(%{plan() | "revision" => 2})
  end

  test "resource digest ignores record order, map key order and domain case" do
    original = zone("zone-example", "Example.COM", "192.0.2.53")
    {:ok, first} = ConfigSpec.normalize_resource(original)

    reversed =
      put_in(original, ["content", "records"], Enum.reverse(original["content"]["records"]))

    {:ok, second} = ConfigSpec.normalize_resource(reversed)
    assert first == second

    rekeyed = %{
      "content" => %{"records" => reversed["content"]["records"], "name" => "example.com."},
      "version" => 1,
      "schema_version" => 1,
      "type" => "dns_zone",
      "id" => "zone-example"
    }

    assert {:ok, ^first} = ConfigSpec.normalize_resource(rekeyed)
  end

  test "SOA rname preserves mailbox local-part case" do
    resource = zone("zone-example", "Example.COM", "192.0.2.53")

    resource =
      put_in(
        resource,
        ["content", "records", Access.at(0), "data", "rname"],
        "HostMaster.Example.COM"
      )

    assert {:ok, normalized} = ConfigSpec.normalize_resource(resource)
    soa = Enum.find(normalized["content"]["records"], &(&1["type"] == "SOA"))
    assert soa["data"]["rname"] == "HostMaster.example.com."
  end

  test "declared digest is recomputed and checked" do
    {:ok, resource} = ConfigSpec.normalize_resource(zone("z", "example.com", "192.0.2.53"))
    assert {:ok, ^resource} = ConfigSpec.normalize_resource(resource)

    assert error_code(
             ConfigSpec.normalize_resource(%{resource | "digest" => String.duplicate("0", 64)})
           ) ==
             :digest_mismatch

    assert error_code(ConfigSpec.normalize_resource(%{resource | "digest" => nil})) ==
             :invalid_type
  end

  test "explicitly empty resource sets are valid and missing arrays are not" do
    empty = put_in(plan(), ["services", Access.at(0), "resources"], [])
    empty = %{empty | "resources" => []}
    assert {:ok, _} = ConfigSpec.normalize_plan(empty)
    assert error_code(ConfigSpec.normalize_plan(Map.delete(empty, "resources"))) == :missing_field
    assert error_code(ConfigSpec.normalize_plan(Map.delete(empty, "services"))) == :missing_field

    assert error_code(
             ConfigSpec.normalize_plan(
               put_in(plan(), ["services", Access.at(0), "resources"], [])
             )
           ) ==
             :unreferenced_resource
  end

  test "multiple zones and independent assignments have structured removals and lifecycle" do
    second = zone("zone-other", "other.example", "192.0.2.54")
    old = %{plan() | "resources" => plan()["resources"] ++ [second]}
    old = put_in(old, ["services", Access.at(0), "resources"], ["zone-example", "zone-other"])
    new = put_in(old, ["services", Access.at(0), "resources"], ["zone-other"])
    new = put_in(new, ["services", Access.at(0), "desired_state"], "stopped")
    new = %{new | "resources" => [second], "revision" => 2}

    assert {:ok, diff} = ConfigSpec.diff(old, new)
    assert diff["resources"]["removed"] == ["zone-example"]
    assert diff["resources"]["added"] == []
    assert diff["services"]["replaced"] == ["dns-primary"]

    assert diff["services"]["lifecycle"] ==
             [%{"id" => "dns-primary", "from" => "running", "to" => "stopped"}]

    assert {:ok, normalized} = ConfigSpec.normalize_plan(new)
    assert Enum.map(normalized["resources"], & &1["id"]) == ["zone-other"]
  end

  test "duplicate instances, resources, and references fail" do
    base = plan()

    assert error_code(
             ConfigSpec.normalize_plan(%{
               base
               | "services" => base["services"] ++ base["services"]
             })
           ) ==
             :duplicate

    assert error_code(
             ConfigSpec.normalize_plan(%{
               base
               | "resources" => base["resources"] ++ base["resources"]
             })
           ) ==
             :duplicate

    twice =
      put_in(base, ["services", Access.at(0), "resources"], ["zone-example", "zone-example"])

    assert error_code(ConfigSpec.normalize_plan(twice)) == :duplicate
  end

  test "missing references and unsupported service/record data fail explicitly" do
    base = plan()
    missing = put_in(base, ["services", Access.at(0), "resources"], ["zone-unknown"])
    assert error_code(ConfigSpec.normalize_plan(missing)) == :missing_reference
    unsupported = put_in(base, ["services", Access.at(0), "type"], "dhcpv4")
    assert error_code(ConfigSpec.normalize_plan(unsupported)) == :unsupported_value

    txt =
      put_in(base, ["resources", Access.at(0), "content", "records", Access.at(2), "type"], "TXT")

    assert error_code(ConfigSpec.normalize_plan(txt)) == :unsupported_value

    extra =
      put_in(
        base,
        ["resources", Access.at(0), "content", "records", Access.at(2), "data", "extra"],
        "x"
      )

    assert error_code(ConfigSpec.normalize_plan(extra)) == :unsupported_field
  end

  test "incomplete zones and bad bounds fail" do
    no_soa = update_in(plan(), ["resources", Access.at(0), "content", "records"], &tl/1)
    assert error_code(ConfigSpec.normalize_plan(no_soa)) == :invalid_zone

    assert error_code(
             ConfigSpec.normalize_plan(%{plan() | "worker_id" => String.duplicate("a", 65)})
           ) ==
             :invalid_identity

    assert error_code(ConfigSpec.normalize_plan(%{plan() | "revision" => 0})) == :invalid_integer

    assert error_code(
             ConfigSpec.normalize_plan(%{
               plan()
               | "services" => List.duplicate(hd(plan()["services"]), 65)
             })
           ) ==
             :too_many

    assert error_code(ConfigSpec.decode(String.duplicate("#", 1_048_577))) == :too_large
  end

  test "a normalized plan cannot confirm more data than its TOML export limit" do
    long_labels = Enum.join(List.duplicate(String.duplicate("a", 60), 3), ".")

    resources =
      Enum.map(1..5, fn i ->
        base = zone("zone-#{i}", "z#{i}.example", "192.0.2.53")

        extra =
          Enum.map(1..1021, fn j ->
            %{
              "name" => "h#{j}.#{long_labels}.z#{i}.example.",
              "type" => "A",
              "ttl" => 300,
              "data" => %{"address" => "192.0.2.53"}
            }
          end)

        update_in(base, ["content", "records"], &(&1 ++ extra))
      end)

    oversized = %{plan() | "resources" => resources}

    oversized =
      put_in(oversized, ["services", Access.at(0), "resources"], Enum.map(resources, & &1["id"]))

    assert error_code(ConfigSpec.normalize_plan(oversized)) == :too_large
  end

  test "one RRset cannot have conflicting TTLs" do
    base = plan()
    a = base["resources"] |> hd() |> get_in(["content", "records"]) |> List.last()
    other_a = %{a | "ttl" => 400, "data" => %{"address" => "192.0.2.54"}}
    mixed = update_in(base, ["resources", Access.at(0), "content", "records"], &(&1 ++ [other_a]))
    assert error_code(ConfigSpec.normalize_plan(mixed)) == :inconsistent_ttl
  end

  test "one service cannot select two resource IDs for one zone name" do
    base = plan()
    other_id = zone("zone-alias", "example.com", "192.0.2.54")
    duplicated_zone = %{base | "resources" => base["resources"] ++ [other_id]}

    duplicated_zone =
      put_in(duplicated_zone, ["services", Access.at(0), "resources"], [
        "zone-example",
        "zone-alias"
      ])

    assert error_code(ConfigSpec.normalize_plan(duplicated_zone)) == :duplicate_zone
  end

  test "running DNS services cannot bind overlapping listeners" do
    base = plan()
    second = %{hd(base["services"]) | "id" => "dns-secondary", "resources" => []}

    assert error_code(
             ConfigSpec.normalize_plan(%{base | "services" => base["services"] ++ [second]})
           ) ==
             :listener_conflict

    stopped = %{second | "desired_state" => "stopped"}

    assert {:ok, _} =
             ConfigSpec.normalize_plan(%{base | "services" => base["services"] ++ [stopped]})

    wildcard = put_in(second, ["config", "listen_address"], "0.0.0.0")

    assert error_code(
             ConfigSpec.normalize_plan(%{base | "services" => base["services"] ++ [wildcard]})
           ) ==
             :listener_conflict
  end

  test "malformed TOML and semantically equivalent formatting" do
    assert error_code(ConfigSpec.decode("broken = [")) == :invalid_toml
    {:ok, encoded} = ConfigSpec.encode(plan())
    {:ok, first} = ConfigSpec.decode(encoded)

    reformatted =
      "# operator note\n\n" <> String.replace(encoded, "revision = 1", "revision=1 # same plan")

    assert {:ok, ^first} = ConfigSpec.decode(reformatted)
  end
end
