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

    unsupported_record =
      put_in(
        base,
        ["resources", Access.at(0), "content", "records", Access.at(2), "type"],
        "HINFO"
      )

    assert error_code(ConfigSpec.normalize_plan(unsupported_record)) == :unsupported_value

    extra =
      put_in(
        base,
        ["resources", Access.at(0), "content", "records", Access.at(2), "data", "extra"],
        "x"
      )

    assert error_code(ConfigSpec.normalize_plan(extra)) == :unsupported_field
  end

  test "zones without A records round-trip AAAA, CNAME, MX, TXT and PTR" do
    fixtures = [
      {"*.example.com.", "AAAA", %{"address" => "2001:0DB8:0:0:0:0:0:42"}},
      {"_Check.example.com.", "CNAME", %{"target" => "_validation.external.TEST"}},
      {"example.com.", "MX", %{"preference" => 0, "exchange" => "."}},
      {"_policy.example.com.", "TXT", %{"strings" => ["", "quoted \"text\"", "多行\n内容", <<127>>]}},
      {"reverse.example.com.", "PTR", %{"target" => "PTR.EXAMPLE.COM"}}
    ]

    records =
      Enum.map(fixtures, fn {name, type, data} ->
        %{"name" => name, "type" => type, "ttl" => 600, "data" => data}
      end)

    candidate =
      update_in(plan(), ["resources", Access.at(0), "content", "records"], fn required ->
        Enum.take(required, 2) ++ records
      end)

    assert {:ok, normalized} = ConfigSpec.normalize_plan(candidate)
    assert {:ok, toml} = ConfigSpec.encode(normalized)
    assert {:ok, ^normalized} = ConfigSpec.decode(toml)

    normalized_records = get_in(normalized, ["resources", Access.at(0), "content", "records"])
    by_type = Map.new(normalized_records, &{&1["type"], &1})
    assert by_type["AAAA"]["data"]["address"] == "2001:db8::42"
    assert by_type["CNAME"]["name"] == "_check.example.com."
    assert by_type["CNAME"]["data"]["target"] == "_validation.external.test."
    assert by_type["TXT"]["data"] == Enum.at(records, 3)["data"]

    invalid =
      update_in(candidate, ["resources", Access.at(0), "content", "records"], fn records ->
        [%{by_type["AAAA"] | "name" => by_type["CNAME"]["name"]} | records]
      end)

    assert error_code(ConfigSpec.normalize_plan(invalid)) == :invalid_zone

    for {index, field, value, error} <- [
          {2, "address", "192.0.2.1", :invalid_address},
          {4, "preference", 65_536, :invalid_integer},
          {5, "strings", [], :invalid_record},
          {5, "strings", [String.duplicate("é", 128)], :invalid_record}
        ] do
      path = ["resources", Access.at(0), "content", "records", Access.at(index), "data", field]
      assert error_code(ConfigSpec.normalize_plan(put_in(candidate, path, value))) == error
    end
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

  test "the legacy listener format cannot create a second DNS service" do
    base = plan()
    [first] = base["services"]
    second = %{first | "id" => "dns-secondary", "resources" => []}
    second = put_in(second, ["config", "listen_address"], "0.0.0.0")

    for state <- ~w(running stopped) do
      assert error_code(
               ConfigSpec.normalize_plan(%{
                 base
                 | "services" => [first, %{second | "desired_state" => state}]
               })
             ) ==
               :duplicate_service_type
    end
  end

  test "DNS listeners inherit addresses and have independent protocol settings" do
    config = %{
      "listen" => %{"mode" => "all_ipv4"},
      "transports" => %{
        "tcp" => %{"enabled" => false},
        "doh" => %{
          "enabled" => true,
          "listen" => %{"mode" => "specific", "addresses" => ["2001:0db8::1", "192.0.2.1"]},
          "certificate_id" => "internal"
        }
      }
    }

    target = put_in(plan(), ["services", Access.at(0), "config"], config)
    assert {:ok, normalized} = ConfigSpec.normalize_plan(target)
    [service] = normalized["services"]
    assert service["config"]["listen"] == %{"mode" => "all_ipv4"}
    assert service["config"]["transports"]["udp"] == %{"enabled" => true, "port" => 53}
    assert service["config"]["transports"]["tcp"] == %{"enabled" => false, "port" => 53}
    assert service["config"]["transports"]["doq"] == %{"enabled" => false, "port" => 853}

    assert service["config"]["transports"]["doh"] == %{
             "enabled" => true,
             "port" => 443,
             "listen" => %{"mode" => "specific", "addresses" => ["192.0.2.1", "2001:db8::1"]},
             "certificate_id" => "internal"
           }

    assert {:ok, toml} = ConfigSpec.encode(target)
    assert {:ok, ^normalized} = ConfigSpec.decode(toml)

    missing_cert =
      update_in(
        target,
        ["services", Access.at(0), "config", "transports", "doh"],
        &Map.delete(&1, "certificate_id")
      )

    assert error_code(ConfigSpec.normalize_plan(missing_cert)) == :missing_field
  end

  test "Worker DNS configuration has one service and explicit wildcard modes" do
    target =
      put_in(plan(), ["services", Access.at(0), "config"], %{"listen" => %{"mode" => "all"}})

    assert {:ok, normalized} = ConfigSpec.normalize_plan(target)
    [service] = normalized["services"]
    assert service["config"]["transports"]["tcp"] == %{"enabled" => true, "port" => 53}

    for mode <- ["all_ipv4", "all_ipv6"] do
      assert {:ok, _} =
               ConfigSpec.normalize_plan(
                 put_in(target, ["services", Access.at(0), "config", "listen", "mode"], mode)
               )
    end

    second = %{service | "id" => "dns-secondary", "resources" => []}

    assert error_code(ConfigSpec.normalize_plan(%{target | "services" => [service, second]})) ==
             :duplicate_service_type

    for address <- ["0.0.0.0", "::", "192.0.2.1/24"] do
      invalid =
        put_in(target, ["services", Access.at(0), "config", "listen"], %{
          "mode" => "specific",
          "addresses" => [address]
        })

      assert error_code(ConfigSpec.normalize_plan(invalid)) == :invalid_address
    end
  end

  test "malformed TOML and semantically equivalent formatting" do
    assert error_code(ConfigSpec.decode("broken = [")) == :invalid_toml
    {:ok, encoded} = ConfigSpec.encode(plan())
    {:ok, first} = ConfigSpec.decode(encoded)

    reformatted =
      "# operator note\n\n" <> String.replace(encoded, "revision = 1", "revision=1 # same plan")

    assert {:ok, ^first} = ConfigSpec.decode(reformatted)
  end

  describe "dns policy config" do
    defp with_dns(extra) do
      base = plan()
      update_in(base, ["services", Access.at(0), "config"], &Map.merge(&1, extra))
    end

    defp dns_of({:ok, plan}), do: hd(plan["services"])["config"]

    test "defaults when new keys are omitted" do
      config = dns_of(ConfigSpec.normalize_plan(plan()))

      assert config == %{
               "listen_address" => "127.0.0.1",
               "port" => 1053,
               "recursion" => false,
               "allow_query" => [],
               "forward_zones" => []
             }
    end

    test "allow_query is masked, sorted and deduplicated" do
      config =
        dns_of(
          ConfigSpec.normalize_plan(
            with_dns(%{"allow_query" => ["10.10.10.7/24", "::1/128", "10.10.10.0/24"]})
          )
        )

      assert config["allow_query"] == ["10.10.10.0/24", "::1/128"]
    end

    test "IPv4-mapped CIDRs are stored as IPv4 CIDRs" do
      config =
        dns_of(
          ConfigSpec.normalize_plan(
            with_dns(%{"allow_query" => ["::ffff:10.0.0.1/128", "::FFFF:192.168.7.9/120"]})
          )
        )

      assert config["allow_query"] == ["10.0.0.1/32", "192.168.7.0/24"]
    end

    test "allow_query rejects bad CIDRs and over-limit lists" do
      for bad <- [
            "10.0.0.0",
            "10.0.0.0/33",
            "::/129",
            "x/8",
            "10.0.0.0/-1",
            5,
            "::ffff:10.0.0.1/95",
            "::ffff:10.0.0.1/129"
          ] do
        assert error_code(ConfigSpec.normalize_plan(with_dns(%{"allow_query" => [bad]}))) in [
                 :invalid_cidr
               ]
      end

      many = for i <- 0..128, do: "10.0.#{div(i, 256)}.#{rem(i, 256)}/32"

      assert error_code(ConfigSpec.normalize_plan(with_dns(%{"allow_query" => many}))) ==
               :too_many
    end

    test "forward zones are normalized and sorted" do
      zones = [
        %{"name" => "Corp.Example", "forwarders" => [%{"address" => "10.0.0.2", "port" => 53}]},
        %{
          "name" => ".",
          "forwarders" => [%{"address" => "2001:DB8::53"}, %{"address" => "9.9.9.9"}]
        }
      ]

      config = dns_of(ConfigSpec.normalize_plan(with_dns(%{"forward_zones" => zones})))

      assert config["forward_zones"] == [
               %{
                 "name" => ".",
                 "forwarders" => [
                   %{"address" => "2001:db8::53", "port" => 53},
                   %{"address" => "9.9.9.9", "port" => 53}
                 ]
               },
               %{
                 "name" => "corp.example.",
                 "forwarders" => [%{"address" => "10.0.0.2", "port" => 53}]
               }
             ]
    end

    test "forward zone validation" do
      fwd = [%{"address" => "10.0.0.2"}]
      check = fn zones -> ConfigSpec.normalize_plan(with_dns(%{"forward_zones" => zones})) end

      assert error_code(
               check.([
                 %{"name" => "a.example", "forwarders" => fwd},
                 %{"name" => "A.example.", "forwarders" => fwd}
               ])
             ) == :duplicate_forward_zone

      assert error_code(check.([%{"name" => "a.example", "forwarders" => []}])) == :invalid_value

      assert error_code(
               check.([
                 %{
                   "name" => "a.example",
                   "forwarders" => List.duplicate(%{"address" => "10.0.0.2"}, 9)
                 }
               ])
             ) == :too_many

      for port <- [0, 65_536, "53"] do
        assert error_code(
                 check.([
                   %{
                     "name" => "a.example",
                     "forwarders" => [%{"address" => "10.0.0.2", "port" => port}]
                   }
                 ])
               ) == :invalid_integer
      end

      assert error_code(
               check.([%{"name" => "a.example", "forwarders" => [%{"address" => "nope"}]}])
             ) == :invalid_address

      assert error_code(check.([%{"name" => "a.example", "forwarders" => fwd, "x" => 1}])) ==
               :unsupported_field

      too_many =
        for i <- 1..65, do: %{"name" => "z#{i}.example", "forwarders" => fwd}

      assert error_code(check.(too_many)) == :too_many
    end

    test "unknown keys still fail" do
      assert error_code(ConfigSpec.normalize_plan(with_dns(%{"cache" => true}))) ==
               :unsupported_field

      assert error_code(ConfigSpec.normalize_plan(with_dns(%{"recursion" => "yes"}))) ==
               :invalid_type
    end

    test "recursion participates in plan_digest" do
      assert {:ok, a} = ConfigSpec.plan_digest(with_dns(%{"recursion" => false}))
      assert {:ok, b} = ConfigSpec.plan_digest(with_dns(%{"recursion" => true}))
      refute a == b
    end

    test "views preserve rule ordering and have stable priority and ID ordering in TOML" do
      rules = [
        %{"action" => "deny", "kind" => "networks", "networks" => ["192.0.2.13/24", "::1/128"]},
        %{"action" => "allow", "kind" => "any"}
      ]

      default = %{"id" => "default", "recursion_enabled" => false, "client_rules" => rules}
      top = Map.merge(default, %{"id" => "top", "priority" => 0, "recursion_enabled" => true})
      high = Map.merge(default, %{"id" => "z", "priority" => 9_223_372_036_854_775_807})
      tied = %{high | "id" => "a"}

      raw = with_dns(%{"views" => [default, high, tied, top]})
      assert {:ok, normalized} = ConfigSpec.normalize_plan(raw)
      assert {:ok, toml} = ConfigSpec.encode(normalized)
      assert {:ok, ^normalized} = ConfigSpec.decode(toml)

      views = hd(normalized["services"])["config"]["views"]
      assert Enum.map(views, & &1["id"]) == ~w(top a z default)
      assert List.last(views)["priority"] == nil
      assert List.first(views)["recursion_enabled"]

      assert [
               %{"action" => "deny", "networks" => ["192.0.2.0/24", "::1/128"]},
               %{"action" => "allow", "kind" => "any"}
             ] = hd(views)["client_rules"]

      assert {:ok, digest} = ConfigSpec.plan_digest(raw)

      assert {:ok, ^digest} =
               ConfigSpec.plan_digest(with_dns(%{"views" => [top, tied, high, default]}))

      bad_rule =
        put_in(top, ["client_rules"], [
          %{"action" => "allow", "kind" => "countries", "countries" => ["US"]}
        ])

      assert {:error, [%{code: :unsupported_value, path: path}]} =
               ConfigSpec.normalize_plan(with_dns(%{"views" => [bad_rule]}))

      assert path == ["services", 0, "config", "views", 0, "client_rules", 0, "kind"]

      assert {:ok, legacy} = ConfigSpec.normalize_plan(with_dns(%{}))
      refute Map.has_key?(hd(legacy["services"])["config"], "views")
      assert {:ok, empty} = ConfigSpec.normalize_plan(with_dns(%{"views" => []}))
      assert hd(empty["services"])["config"]["views"] == []
    end

    test "recursive_forward.toml round-trips" do
      assert {:ok, plan} = ConfigSpec.decode(fixture("recursive_forward.toml"))
      config = hd(plan["services"])["config"]
      assert config["recursion"] == true
      assert config["allow_query"] == ["10.10.10.0/24", "::1/128"]
      assert [%{"name" => "."}, %{"name" => "corp.example."}] = config["forward_zones"]
      assert {:ok, encoded} = ConfigSpec.encode(plan)
      assert {:ok, ^plan} = ConfigSpec.decode(encoded)
    end
  end
end
