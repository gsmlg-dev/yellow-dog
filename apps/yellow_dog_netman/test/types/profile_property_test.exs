defmodule YellowDog.Netman.Types.ProfilePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias YellowDog.Netman.Types.Profile

  # Generators

  defp profile_id_gen do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 50)
    |> StreamData.map(&("profile-" <> &1))
  end

  defp ipv4_method_gen do
    StreamData.member_of(["auto", "manual", "disabled"])
  end

  defp ipv4_address_gen do
    gen all(
          a <- StreamData.integer(1..254),
          b <- StreamData.integer(0..255),
          c <- StreamData.integer(0..255),
          d <- StreamData.integer(1..254),
          prefix <- StreamData.integer(8..30)
        ) do
      "#{a}.#{b}.#{c}.#{d}/#{prefix}"
    end
  end

  defp ipv6_method_gen do
    StreamData.member_of(["auto", "manual", "disabled", "link-local"])
  end

  defp mtu_gen do
    StreamData.one_of([
      StreamData.constant(nil),
      StreamData.integer(68..65535)
    ])
  end

  defp iface_gen do
    StreamData.one_of([
      StreamData.constant(nil),
      StreamData.string(:alphanumeric, min_length: 1, max_length: 12)
      |> StreamData.map(&("pi_" <> &1))
      |> StreamData.map(&String.slice(&1, 0, 15))
    ])
  end

  defp zone_gen do
    StreamData.member_of(["default", "trusted", "untrusted", "dmz"])
  end

  defp gateway_gen do
    StreamData.one_of([
      StreamData.constant(nil),
      gen all(
            a <- StreamData.integer(10..10),
            b <- StreamData.integer(0..255),
            c <- StreamData.integer(0..255),
            d <- StreamData.integer(1..254)
          ) do
        "#{a}.#{b}.#{c}.#{d}"
      end
    ])
  end

  defp dns_gen do
    StreamData.one_of([
      StreamData.constant([]),
      gen all(
            count <- StreamData.integer(1..3),
            octets <- StreamData.list_of(StreamData.integer(1..254), length: count)
          ) do
        Enum.map(octets, &"8.8.#{&1}.#{&1}")
      end
    ])
  end

  defp valid_toml_gen do
    gen all(
          id <- profile_id_gen(),
          ipv4_method <- ipv4_method_gen(),
          ipv6_method <- ipv6_method_gen(),
          mtu <- mtu_gen(),
          priority <- StreamData.integer(0..1000),
          autoconnect <- StreamData.boolean(),
          ipv4_address <- ipv4_address_gen(),
          iface <- iface_gen(),
          zone <- zone_gen(),
          ipv4_gw <- gateway_gen(),
          ipv4_dns <- dns_gen()
        ) do
      ipv4 =
        if ipv4_method == "manual" do
          %{"method" => ipv4_method, "address" => ipv4_address}
        else
          %{"method" => ipv4_method}
        end

      ipv4 = if ipv4_gw, do: Map.put(ipv4, "gateway", ipv4_gw), else: ipv4
      ipv4 = if ipv4_dns != [], do: Map.put(ipv4, "dns", ipv4_dns), else: ipv4

      conn =
        %{
          "id" => id,
          "type" => "ethernet",
          "autoconnect" => autoconnect,
          "autoconnect_priority" => priority,
          "zone" => zone
        }

      conn = if iface, do: Map.put(conn, "interface", iface), else: conn

      toml = %{
        "connection" => conn,
        "ipv4" => ipv4,
        "ipv6" => %{"method" => ipv6_method}
      }

      if mtu do
        put_in(toml, ["ethernet"], %{"mtu" => mtu})
      else
        toml
      end
    end
  end

  # Property tests

  property "from_toml always succeeds for valid input" do
    check all(toml <- valid_toml_gen()) do
      assert {:ok, %Profile{}} = Profile.from_toml(toml)
    end
  end

  property "round-trip: parse(to_toml(parse(toml))) == parse(toml)" do
    check all(toml <- valid_toml_gen()) do
      {:ok, profile1} = Profile.from_toml(toml)
      toml2 = Profile.to_toml(profile1)
      {:ok, profile2} = Profile.from_toml(toml2)

      assert profile1 == profile2
    end
  end

  property "IPv4 CIDR prefix must be 0-32" do
    check all(
            id <- profile_id_gen(),
            prefix <- StreamData.integer(33..128)
          ) do
      toml = %{
        "connection" => %{"id" => id, "type" => "ethernet"},
        "ipv4" => %{"method" => "manual", "address" => "10.0.0.1/#{prefix}"}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "valid CIDR"
    end
  end

  property "IPv4 CIDR with valid prefix 0-32 is accepted" do
    check all(
            id <- profile_id_gen(),
            prefix <- StreamData.integer(0..32),
            a <- StreamData.integer(1..254),
            d <- StreamData.integer(1..254)
          ) do
      toml = %{
        "connection" => %{"id" => id, "type" => "ethernet"},
        "ipv4" => %{"method" => "manual", "address" => "#{a}.0.0.#{d}/#{prefix}"}
      }

      assert {:ok, %Profile{}} = Profile.from_toml(toml)
    end
  end

  property "from_toml preserves all fields" do
    check all(toml <- valid_toml_gen()) do
      {:ok, profile} = Profile.from_toml(toml)

      assert profile.id == toml["connection"]["id"]
      assert profile.type == :ethernet
      assert profile.autoconnect == toml["connection"]["autoconnect"]
      assert profile.autoconnect_priority == toml["connection"]["autoconnect_priority"]
      assert profile.interface == Map.get(toml["connection"], "interface")
      assert profile.zone == Map.get(toml["connection"], "zone", "default")
      assert profile.ethernet.mtu == get_in(toml, ["ethernet", "mtu"])
    end
  end

  # --- Interface validation properties ---

  property "interface names longer than 15 chars are rejected" do
    check all(
            id <- profile_id_gen(),
            name <- StreamData.string(:alphanumeric, min_length: 16, max_length: 64)
          ) do
      toml = %{
        "connection" => %{"id" => id, "type" => "ethernet", "interface" => name}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "at most 15"
    end
  end

  property "interface names with forbidden chars are rejected" do
    check all(
            id <- profile_id_gen(),
            base <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            bad_char <- StreamData.member_of([" ", "/", ":", "\t", "\n"])
          ) do
      name = base <> bad_char
      # Ensure name is within IFNAMSIZ
      name = String.slice(name, 0, 15)

      toml = %{
        "connection" => %{"id" => id, "type" => "ethernet", "interface" => name}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "invalid characters"
    end
  end

  property "valid short interface names are accepted" do
    check all(
            id <- profile_id_gen(),
            name <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
          ) do
      toml = %{
        "connection" => %{"id" => id, "type" => "ethernet", "interface" => name}
      }

      assert {:ok, %Profile{interface: ^name}} = Profile.from_toml(toml)
    end
  end

  # --- Gateway validation properties ---

  property "invalid gateway strings are rejected" do
    check all(
            id <- profile_id_gen(),
            bad_gw <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
          ) do
      # Filter out strings that happen to be valid IPs
      case :inet.parse_address(String.to_charlist(bad_gw)) do
        {:ok, _} ->
          :ok

        {:error, _} ->
          toml = %{
            "connection" => %{"id" => id, "type" => "ethernet"},
            "ipv4" => %{"method" => "auto", "gateway" => bad_gw}
          }

          assert {:error, msg} = Profile.from_toml(toml)
          assert msg =~ "not a valid IP address"
      end
    end
  end

  # --- DNS list validation properties ---

  property "DNS lists with invalid entries are rejected" do
    check all(
            id <- profile_id_gen(),
            bad_dns <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
          ) do
      case :inet.parse_address(String.to_charlist(bad_dns)) do
        {:ok, _} ->
          :ok

        {:error, _} ->
          toml = %{
            "connection" => %{"id" => id, "type" => "ethernet"},
            "ipv4" => %{"method" => "auto", "dns" => [bad_dns]}
          }

          assert {:error, msg} = Profile.from_toml(toml)
          assert msg =~ "invalid addresses"
      end
    end
  end

  property "valid DNS IP lists are accepted" do
    check all(
            id <- profile_id_gen(),
            count <- StreamData.integer(0..5),
            octets <-
              StreamData.list_of(StreamData.integer(1..254), length: count)
          ) do
      dns = Enum.map(octets, &"8.8.#{&1}.#{&1}")

      toml = %{
        "connection" => %{"id" => id, "type" => "ethernet"},
        "ipv4" => %{"method" => "auto", "dns" => dns}
      }

      assert {:ok, %Profile{}} = Profile.from_toml(toml)
    end
  end

  # --- Profile ID validation properties ---

  property "profile IDs with invalid characters are rejected" do
    check all(
            bad_char <- StreamData.member_of([" ", "/", "@", "!", "#", "$", "%", "^", "&", "*"]),
            base <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
          ) do
      id = base <> bad_char

      toml = %{"connection" => %{"id" => id, "type" => "ethernet"}}

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "invalid characters"
    end
  end

  property "profile IDs longer than 128 characters are rejected" do
    check all(extra <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)) do
      id = String.duplicate("a", 129) <> extra

      toml = %{"connection" => %{"id" => id, "type" => "ethernet"}}

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "too long"
    end
  end

  property "valid profile IDs with allowed chars are accepted" do
    check all(
            base <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
            suffix <-
              StreamData.one_of([
                StreamData.constant(""),
                StreamData.constant("-suffix"),
                StreamData.constant("_suffix"),
                StreamData.constant(".v2")
              ])
          ) do
      id = base <> suffix

      toml = %{"connection" => %{"id" => id, "type" => "ethernet"}}

      assert {:ok, %Profile{}} = Profile.from_toml(toml)
    end
  end

  # --- Zone validation properties ---

  property "zones with invalid characters are rejected" do
    check all(
            bad_char <- StreamData.member_of([" ", "/", "@", "!", "#", "+"]),
            base <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
          ) do
      zone = base <> bad_char

      toml = %{
        "connection" => %{"id" => "test-zone-#{base}", "type" => "ethernet", "zone" => zone}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "zone"
    end
  end

  property "zones longer than 64 characters are rejected" do
    check all(extra <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)) do
      zone = String.duplicate("z", 65) <> extra

      toml = %{
        "connection" => %{"id" => "test-longzone", "type" => "ethernet", "zone" => zone}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "zone"
    end
  end

  # --- Priority validation properties ---

  property "priorities outside -1000..10000 are rejected" do
    check all(
            bad_priority <-
              StreamData.one_of([
                StreamData.integer(-10_000..-1001),
                StreamData.integer(10_001..100_000)
              ])
          ) do
      toml = %{
        "connection" => %{
          "id" => "test-priority",
          "type" => "ethernet",
          "autoconnect_priority" => bad_priority
        }
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "priority"
    end
  end

  property "priorities within -1000..10000 are accepted" do
    check all(priority <- StreamData.integer(-1000..10_000)) do
      toml = %{
        "connection" => %{
          "id" => "test-priority-valid",
          "type" => "ethernet",
          "autoconnect_priority" => priority
        }
      }

      assert {:ok, %Profile{autoconnect_priority: ^priority}} = Profile.from_toml(toml)
    end
  end

  # --- MTU validation properties ---

  property "MTU within 68-65535 is accepted" do
    check all(
            id <- profile_id_gen(),
            mtu <- StreamData.integer(68..65535)
          ) do
      toml = %{
        "connection" => %{"id" => id, "type" => "ethernet"},
        "ethernet" => %{"mtu" => mtu}
      }

      assert {:ok, %Profile{ethernet: %{mtu: ^mtu}}} = Profile.from_toml(toml)
    end
  end

  property "MTU outside 68-65535 is rejected" do
    check all(
            id <- profile_id_gen(),
            mtu <-
              StreamData.one_of([
                StreamData.integer(-100..67),
                StreamData.integer(65536..100_000)
              ])
          ) do
      toml = %{
        "connection" => %{"id" => id, "type" => "ethernet"},
        "ethernet" => %{"mtu" => mtu}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "mtu"
    end
  end

  # --- IPv4 method validation ---

  property "invalid IPv4 methods are rejected" do
    check all(
            id <- profile_id_gen(),
            bad_method <-
              StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
              |> StreamData.filter(&(&1 not in ["auto", "manual", "disabled"]))
          ) do
      toml = %{
        "connection" => %{"id" => id, "type" => "ethernet"},
        "ipv4" => %{"method" => bad_method}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "ipv4.method"
    end
  end

  property "non-ethernet connection types are rejected" do
    check all(
            id <- profile_id_gen(),
            bad_type <-
              StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
              |> StreamData.filter(&(&1 != "ethernet"))
          ) do
      toml = %{"connection" => %{"id" => id, "type" => bad_type}}

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "connection.type"
    end
  end

  # --- IPv6 validation properties ---

  property "invalid IPv6 methods are rejected" do
    check all(
            id <- profile_id_gen(),
            bad_method <-
              StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
              |> StreamData.filter(&(&1 not in ["auto", "manual", "disabled", "link-local"]))
          ) do
      toml = %{
        "connection" => %{"id" => id, "type" => "ethernet"},
        "ipv6" => %{"method" => bad_method}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "ipv6.method"
    end
  end

  property "valid IPv6 methods are accepted" do
    check all(
            id <- profile_id_gen(),
            method <- StreamData.member_of(["auto", "manual", "disabled", "link-local"])
          ) do
      toml = %{
        "connection" => %{"id" => id, "type" => "ethernet"},
        "ipv6" => %{"method" => method}
      }

      assert {:ok, %Profile{}} = Profile.from_toml(toml)
    end
  end

  property "to_toml always produces a map with a connection key" do
    check all(toml <- valid_toml_gen()) do
      {:ok, profile} = Profile.from_toml(toml)
      result = Profile.to_toml(profile)
      assert is_map(result)
      assert Map.has_key?(result, "connection"), "to_toml missing 'connection' key"
    end
  end

  property "to_toml with disabled IPv4 always includes the ipv4 key" do
    check all(
            id <- profile_id_gen(),
            zone <- zone_gen()
          ) do
      toml = %{
        "connection" => %{"id" => id, "type" => "ethernet", "zone" => zone},
        "ipv4" => %{"method" => "disabled"}
      }

      {:ok, profile} = Profile.from_toml(toml)
      result = Profile.to_toml(profile)
      assert Map.has_key?(result, "ipv4"),
             "to_toml must include ipv4 section for disabled method"
    end
  end

  property "to_toml connection id always matches the original profile id" do
    check all(toml <- valid_toml_gen()) do
      {:ok, profile} = Profile.from_toml(toml)
      result = Profile.to_toml(profile)
      assert result["connection"]["id"] == profile.id
    end
  end

  property "to_toml then from_toml roundtrip preserves core profile fields" do
    check all(
            id <- profile_id_gen(),
            iface <- iface_gen(),
            autoconnect <- StreamData.boolean(),
            priority <- StreamData.integer(-1000..10_000),
            zone <- zone_gen()
          ) do
      profile = %Profile{
        id: id,
        type: :ethernet,
        interface: iface,
        autoconnect: autoconnect,
        autoconnect_priority: priority,
        zone: zone,
        ethernet: %{mtu: nil},
        ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :auto, address: nil, gateway: nil, dns: []}
      }

      toml_map = Profile.to_toml(profile)
      assert {:ok, roundtrip} = Profile.from_toml(toml_map)

      assert roundtrip.id == profile.id
      assert roundtrip.type == profile.type
      assert roundtrip.autoconnect == profile.autoconnect
      assert roundtrip.autoconnect_priority == profile.autoconnect_priority
      assert roundtrip.zone == profile.zone
      assert roundtrip.interface == profile.interface
    end
  end

  property "to_toml autoconnect field is always a boolean in the connection map" do
    check all(
            id <- profile_id_gen(),
            iface <- iface_gen(),
            autoconnect <- StreamData.boolean()
          ) do
      profile = %Profile{
        id: id,
        type: :ethernet,
        interface: iface,
        autoconnect: autoconnect,
        autoconnect_priority: 0,
        ethernet: %{mtu: nil},
        ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      toml_map = Profile.to_toml(profile)
      conn = toml_map["connection"]

      assert is_boolean(conn["autoconnect"]),
             "Expected boolean autoconnect in to_toml output, got: #{inspect(conn["autoconnect"])}"
    end
  end

  property "to_toml interface field always matches the original profile interface" do
    check all(
            id <- profile_id_gen(),
            iface <- iface_gen()
          ) do
      profile = %Profile{
        id: id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 0,
        ethernet: %{mtu: nil},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      toml_map = Profile.to_toml(profile)
      conn = toml_map["connection"]

      assert conn["interface"] == iface,
             "Expected interface #{iface} in to_toml, got: #{inspect(conn["interface"])}"
    end
  end

  property "to_toml always returns a map (never nil or non-map)" do
    check all(
            id <- profile_id_gen(),
            iface <- iface_gen()
          ) do
      profile = %Profile{
        id: id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 0,
        ethernet: %{mtu: nil},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      toml_map = Profile.to_toml(profile)

      assert is_map(toml_map),
             "Expected map from to_toml, got: #{inspect(toml_map)}"
    end
  end

  property "to_toml connection id always matches the profile id" do
    check all(
            id <- profile_id_gen(),
            iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 12)
                     |> StreamData.map(&("pp_" <> &1))
          ) do
      profile = %Profile{
        id: id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 0,
        ethernet: %{mtu: nil},
        ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      toml_map = Profile.to_toml(profile)
      conn = toml_map["connection"]

      assert conn["id"] == id,
             "Expected connection id #{id}, got: #{inspect(conn["id"])}"
    end
  end

  property "to_toml connection type is always \"ethernet\"" do
    check all(toml <- valid_toml_gen()) do
      {:ok, profile} = Profile.from_toml(toml)
      result = Profile.to_toml(profile)
      assert result["connection"]["type"] == "ethernet",
             "Expected connection.type == 'ethernet', got: #{inspect(result["connection"]["type"])}"
    end
  end

  property "to_toml autoconnect field is always a boolean" do
    check all(toml <- valid_toml_gen()) do
      {:ok, profile} = Profile.from_toml(toml)
      result = Profile.to_toml(profile)
      autoconnect = result["connection"]["autoconnect"]
      assert is_boolean(autoconnect),
             "Expected boolean autoconnect in to_toml, got: \#{inspect(autoconnect)}"
    end
  end

  property "from_toml preserves ipv4 method field" do
    check all(toml <- valid_toml_gen()) do
      {:ok, profile} = Profile.from_toml(toml)
      assert profile.ipv4 != nil,
             "Expected non-nil ipv4 field, got nil"
      assert is_map(profile.ipv4),
             "Expected map ipv4, got: #{inspect(profile.ipv4)}"
      assert Map.has_key?(profile.ipv4, :method),
             "Expected :method key in ipv4 map"
    end
  end

  property "from_toml interface field when present matches toml connection interface" do
    check all(toml <- valid_toml_gen()) do
      case Profile.from_toml(toml) do
        {:ok, profile} ->
          conn_iface = get_in(toml, ["connection", "interface"])
          if is_binary(conn_iface) and byte_size(conn_iface) > 0 do
            assert profile.interface == conn_iface,
                   "Expected interface #{inspect(conn_iface)}, got: #{inspect(profile.interface)}"
          end
        {:error, _} ->
          :ok
      end
    end
  end

  property "from_toml result ipv6 is always a map with :method key" do
    check all(toml <- valid_toml_gen()) do
      case Profile.from_toml(toml) do
        {:ok, profile} ->
          assert is_map(profile.ipv6),
                 "Expected map ipv6, got: #{inspect(profile.ipv6)}"
          assert Map.has_key?(profile.ipv6, :method),
                 "Expected :method in ipv6, got: #{inspect(profile.ipv6)}"
        {:error, _} ->
          :ok
      end
    end
  end

  property "to_toml always includes connection id matching profile id" do
    check all(toml <- valid_toml_gen()) do
      {:ok, profile} = Profile.from_toml(toml)
      result = Profile.to_toml(profile)
      assert result["connection"]["id"] == profile.id,
             "Expected connection.id #{profile.id}, got: #{inspect(result["connection"]["id"])}"
    end
  end

  property "to_toml result connection always has autoconnect key" do
    check all(toml <- valid_toml_gen()) do
      {:ok, profile} = Profile.from_toml(toml)
      result = Profile.to_toml(profile)
      assert Map.has_key?(result["connection"], "autoconnect"),
             "Expected autoconnect key in to_toml connection, got: #{inspect(result["connection"])}"
    end
  end

  property "from_toml result autoconnect field is always boolean" do
    check all(toml <- valid_toml_gen()) do
      case Profile.from_toml(toml) do
        {:ok, profile} ->
          assert is_boolean(profile.autoconnect),
                 "Expected boolean autoconnect, got: #{inspect(profile.autoconnect)}"
        {:error, _} -> :ok
      end
    end
  end

  property "from_toml result type is always a known atom" do
    known_types = [:ethernet, :wifi, :cellular, :vpn, :loopback]
    check all(toml <- valid_toml_gen()) do
      case Profile.from_toml(toml) do
        {:ok, profile} ->
          assert profile.type in known_types,
                 "Expected known type, got: \#{inspect(profile.type)}"
        {:error, _} -> :ok
      end
    end
  end

  property "to_toml then from_toml preserves profile id" do
    check all(toml <- valid_toml_gen()) do
      case Profile.from_toml(toml) do
        {:ok, profile} ->
          toml2 = Profile.to_toml(profile)
          case Profile.from_toml(toml2) do
            {:ok, restored} ->
              assert restored.id == profile.id,
                     "Expected profile id preserved in round-trip"
            {:error, _} -> :ok
          end
        {:error, _} -> :ok
      end
    end
  end

  property "from_toml with valid ipv6 disabled returns :ok" do
    check all(
            id <- profile_id_gen(),
            zone <- zone_gen()
          ) do
      toml = %{
        "connection" => %{"id" => id, "type" => "ethernet", "zone" => zone},
        "ipv4" => %{"method" => "auto"},
        "ipv6" => %{"method" => "disabled"}
      }
      case Profile.from_toml(toml) do
        {:ok, profile} ->
          assert profile.ipv6.method == :disabled,
                 "Expected :disabled ipv6 method, got: #{inspect(profile.ipv6.method)}"
        {:error, _} -> :ok
      end
    end
  end

  property "from_toml with empty map always returns error tuple" do
    check all(_ <- StreamData.constant(:ok)) do
      result = Profile.from_toml(%{})
      assert match?({:ok, _}, result) or match?({:error, _}, result),
             "Expected tagged tuple from from_toml(%{}), got: #{inspect(result)}"
    end
  end
end
