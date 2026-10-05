defmodule YellowDog.Management.NetmanConfigTest do
  use ExUnit.Case, async: true

  alias YellowDog.Management.NetmanConfig

  test "default is a valid empty string-keyed document" do
    expected = %{"profiles" => [], "resolved" => %{"upstreams" => [], "search_domains" => []}}
    assert NetmanConfig.default() == expected
    assert NetmanConfig.validate(expected) == {:ok, expected}
  end

  test "optional profile fields normalize to explicit defaults" do
    assert {:ok, document} = NetmanConfig.validate(candidate())
    assert [profile] = document["profiles"]
    assert profile["profile_id"] == "wired-1"
    assert profile["zone"] == "trusted"
    assert profile["type"] == "ethernet"
    assert profile["interface"] == nil
    assert profile["autoconnect"] == true
    assert profile["autoconnect_priority"] == 0
    assert profile["ethernet"] == %{"mtu" => nil}

    for family <- ["ipv4", "ipv6"] do
      assert profile[family] == %{
               "method" => "auto",
               "address" => nil,
               "gateway" => nil,
               "dns" => [],
               "dns_search" => []
             }
    end

    assert NetmanConfig.validate(document) == {:ok, document}
  end

  test "normalizes dual-stack addresses and domains without changing host bits or identity" do
    document =
      candidate(%{
        "profile_id" => "Wired_1",
        "ipv4" => %{
          "method" => "manual",
          "address" => "192.0.2.9/24",
          "gateway" => "192.0.2.1",
          "dns" => ["192.0.2.53"],
          "dns_search" => ["EXAMPLE.Test."]
        },
        "ipv6" => %{
          "method" => "manual",
          "address" => "2001:0DB8:0000:0000:0000:0000:0000:0009/64",
          "gateway" => "2001:DB8::1",
          "dns" => ["2001:DB8::53"]
        }
      })
      |> Map.put("resolved", %{
        "upstreams" => ["192.0.2.53", "2001:0DB8::53"],
        "search_domains" => ["EXAMPLE.Test."]
      })

    assert {:ok, normalized} = NetmanConfig.validate(document)
    assert [profile] = normalized["profiles"]
    assert profile["profile_id"] == "Wired_1"
    assert profile["ipv4"]["address"] == "192.0.2.9/24"
    assert profile["ipv6"]["address"] == "2001:db8::9/64"
    assert profile["ipv6"]["gateway"] == "2001:db8::1"
    assert profile["ipv4"]["dns_search"] == ["example.test"]
    assert normalized["resolved"]["upstreams"] == ["192.0.2.53", "2001:db8::53"]
    assert normalized["resolved"]["search_domains"] == ["example.test"]
    assert NetmanConfig.validate(normalized) == {:ok, normalized}
  end

  test "requires both root keys and profile identity without accepting unknown keys" do
    for document <- [
          nil,
          [],
          %{},
          %{"profiles" => []},
          %{profiles: [], resolved: %{}},
          Map.put(NetmanConfig.default(), "extra", true)
        ] do
      invalid(document)
    end

    for profile <- [
          %{},
          %{"profile_id" => "wired-1"},
          %{"zone" => "trusted"},
          %{"profile_id" => "wired-1", "zone" => "trusted", "unknown" => 1}
        ] do
      invalid(%{"profiles" => [profile], "resolved" => %{}})
    end
  end

  test "rejects unknown nested keys even when the method would ignore them" do
    for attrs <- [
          %{"ethernet" => %{"speed" => 1000}},
          %{"ipv4" => %{"method" => "disabled", "secret" => "value"}},
          %{"ipv6" => %{"routes" => []}}
        ] do
      invalid(candidate(attrs))
    end

    invalid(Map.put(candidate(), "resolved", %{"servers" => []}))
  end

  test "rejects types without coercion" do
    for attrs <- [
          %{"type" => "wifi"},
          %{"type" => nil},
          %{"interface" => 1},
          %{"autoconnect" => "true"},
          %{"autoconnect_priority" => "0"},
          %{"autoconnect_priority" => 0.0},
          %{"ethernet" => nil},
          %{"ethernet" => %{"mtu" => "1500"}},
          %{"ipv4" => nil},
          %{"ipv6" => []},
          %{"ipv4" => %{"dns" => "192.0.2.1"}},
          %{"ipv6" => %{"dns_search" => nil}}
        ] do
      invalid(candidate(attrs))
    end

    invalid(%{"profiles" => %{}, "resolved" => %{}})
    invalid(%{"profiles" => [nil], "resolved" => %{}})
    invalid(Map.put(candidate(), "resolved", []))
    invalid(Map.put(candidate(), "resolved", %{"upstreams" => nil}))
  end

  test "identifier and interface bounds are enforced without trimming" do
    for value <- ["", ".", "..", "bad/id", "bad id", String.duplicate("a", 129), nil] do
      invalid(candidate(%{"profile_id" => value}))
    end

    for value <- ["", ".", "..", "bad:id", String.duplicate("a", 65), nil] do
      invalid(candidate(%{"zone" => value}))
    end

    for value <- [
          "",
          " eth0",
          "eth0\t",
          "eth0\n",
          "eth0\r",
          "eth/0",
          "eth:0",
          String.duplicate("a", 16)
        ] do
      invalid(candidate(%{"interface" => value}))
    end

    assert {:ok, _} =
             NetmanConfig.validate(candidate(%{"interface" => String.duplicate("a", 15)}))

    assert {:ok, _} =
             NetmanConfig.validate(
               candidate(%{
                 "profile_id" => String.duplicate("a", 128),
                 "zone" => String.duplicate("a", 64)
               })
             )
  end

  test "priority and MTU accept inclusive bounds and reject values outside them" do
    for priority <- [-1000, 10_000], mtu <- [nil, 68, 65_535] do
      assert {:ok, _} =
               NetmanConfig.validate(
                 candidate(%{"autoconnect_priority" => priority, "ethernet" => %{"mtu" => mtu}})
               )
    end

    for priority <- [-1001, 10_001], do: invalid(candidate(%{"autoconnect_priority" => priority}))
    for mtu <- [0, 67, 65_536, 1500.0], do: invalid(candidate(%{"ethernet" => %{"mtu" => mtu}}))
  end

  test "manual requires an address and methods remain family-specific" do
    for family <- ["ipv4", "ipv6"] do
      invalid(candidate(%{family => %{"method" => "manual"}}))
      invalid(candidate(%{family => %{"method" => "unknown"}}))
    end

    invalid(candidate(%{"ipv4" => %{"method" => "link-local"}}))
    assert {:ok, _} = NetmanConfig.validate(candidate(%{"ipv6" => %{"method" => "link-local"}}))
  end

  test "disabled families reject every nonempty setting instead of silently dropping it" do
    for {family, address, gateway} <- [
          {"ipv4", "192.0.2.9/24", "192.0.2.1"},
          {"ipv6", "2001:db8::9/64", "2001:db8::1"}
        ] do
      assert {:ok, _} = NetmanConfig.validate(candidate(%{family => %{"method" => "disabled"}}))

      for settings <- [
            %{"address" => address},
            %{"gateway" => gateway},
            %{"dns" => [gateway]},
            %{"dns_search" => ["example.test"]}
          ] do
        invalid(candidate(%{family => Map.put(settings, "method", "disabled")}))
      end
    end
  end

  test "link-local rejects ignored static address and gateway" do
    invalid(candidate(%{"ipv6" => %{"method" => "link-local", "address" => "fe80::1/64"}}))
    invalid(candidate(%{"ipv6" => %{"method" => "link-local", "gateway" => "fe80::2"}}))
  end

  test "CIDR prefix boundaries preserve family and host address" do
    for {family, address, prefixes} <- [
          {"ipv4", "192.0.2.9", [0, 32]},
          {"ipv6", "2001:db8::9", [0, 128]}
        ],
        prefix <- prefixes do
      assert {:ok, _} =
               NetmanConfig.validate(
                 candidate(%{
                   family => %{"method" => "manual", "address" => "#{address}/#{prefix}"}
                 })
               )
    end

    for {family, address} <- [
          {"ipv4", "192.0.2.9/33"},
          {"ipv4", "192.0.2.9/-1"},
          {"ipv4", "192.0.2.9/24extra"},
          {"ipv4", "192.0.2.9"},
          {"ipv4", "2001:db8::9/24"},
          {"ipv6", "2001:db8::9/129"},
          {"ipv6", "192.0.2.9/24"},
          {"ipv6", "fe80::1%eth0/64"}
        ] do
      invalid(candidate(%{family => %{"address" => address}}))
    end
  end

  test "gateway and profile DNS must use the configured family but resolved allows both" do
    for {family, wrong_ip} <- [{"ipv4", "2001:db8::1"}, {"ipv6", "192.0.2.1"}] do
      invalid(candidate(%{family => %{"gateway" => wrong_ip}}))
      invalid(candidate(%{family => %{"dns" => [wrong_ip]}}))
    end

    for value <- ["localhost", "127.1", "0x7f000001", "192.0.2.1/24", "fe80::1%eth0", 123, nil] do
      invalid(Map.put(candidate(), "resolved", %{"upstreams" => [value]}))
    end
  end

  test "domain validation checks every label and normalizes optional trailing dots" do
    for value <- [
          "",
          ".",
          "bad..test",
          "example.test..",
          "-bad.test",
          "bad-.test",
          "_bad.test",
          "bad test",
          "http://example.test",
          String.duplicate("a", 64) <> ".test",
          42,
          nil
        ] do
      invalid(Map.put(candidate(), "resolved", %{"search_domains" => [value]}))
    end

    name = Enum.join(List.duplicate(String.duplicate("a", 63), 4), ".")
    invalid(candidate(%{"ipv4" => %{"dns_search" => [name]}}))
  end

  test "profile count and unique identity are enforced without reordering" do
    profiles = Enum.map(1..128, &%{"profile_id" => "wired-#{&1}", "zone" => "trusted"})
    assert {:ok, document} = NetmanConfig.validate(%{"profiles" => profiles, "resolved" => %{}})

    assert Enum.map(document["profiles"], & &1["profile_id"]) ==
             Enum.map(profiles, & &1["profile_id"])

    invalid(%{
      "profiles" => profiles ++ [%{"profile_id" => "extra", "zone" => "trusted"}],
      "resolved" => %{}
    })

    invalid(%{"profiles" => [hd(profiles), hd(profiles)], "resolved" => %{}})
  end

  test "all resolver lists enforce the 32 item limit" do
    for field <- ["upstreams", "search_domains"] do
      value = if field == "upstreams", do: "192.0.2.53", else: "example.test"

      assert {:ok, _} =
               NetmanConfig.validate(
                 Map.put(candidate(), "resolved", %{field => List.duplicate(value, 32)})
               )

      invalid(Map.put(candidate(), "resolved", %{field => List.duplicate(value, 33)}))
    end

    for {family, ip} <- [{"ipv4", "192.0.2.53"}, {"ipv6", "2001:db8::53"}],
        field <- ["dns", "dns_search"] do
      value = if field == "dns", do: ip, else: "example.test"
      invalid(candidate(%{family => %{field => List.duplicate(value, 33)}}))
    end
  end

  test "candidate JSON byte bound and non-JSON values return structured errors" do
    profiles =
      Enum.map(1..128, fn index ->
        %{
          "profile_id" => "wired-#{index}",
          "zone" => "trusted",
          "ipv4" => %{"dns_search" => List.duplicate(String.duplicate("a", 63) <> ".test", 32)}
        }
      end)

    document = %{"profiles" => profiles, "resolved" => %{}}
    assert byte_size(Jason.encode!(document)) > 256 * 1024
    invalid(document)
    invalid(Map.put(candidate(), "extra", self()))
    invalid(candidate(%{"interface" => <<255>>}))
  end

  test "error details identify the field" do
    assert {:error, %{details: %{path: "profiles[0].ipv4.address"}}} =
             NetmanConfig.validate(candidate(%{"ipv4" => %{"method" => "manual"}}))
  end

  test "normalization cannot expand a valid input beyond the JSON byte bound" do
    profiles =
      Enum.map(1..128, fn index ->
        %{
          "profile_id" => "wired-#{index}",
          "zone" => "trusted",
          "ipv4" => %{"dns_search" => List.duplicate(String.duplicate("a", 52) <> ".test", 32)}
        }
      end)

    document = %{"profiles" => profiles, "resolved" => %{}}
    assert byte_size(Jason.encode!(document)) <= 256 * 1024
    invalid(document)
  end

  defp candidate(attrs \\ %{}) do
    %{
      "profiles" => [Map.merge(%{"profile_id" => "wired-1", "zone" => "trusted"}, attrs)],
      "resolved" => %{}
    }
  end

  defp invalid(document) do
    assert {:error, %{code: "invalid_request", message: message, details: details}} =
             NetmanConfig.validate(document)

    assert is_binary(message) and message != ""
    assert is_map(details)
  end
end
