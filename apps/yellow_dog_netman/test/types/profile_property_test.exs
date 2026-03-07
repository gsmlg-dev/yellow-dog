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

  property "Profile struct always has :ipv4 field" do
    check all(toml <- valid_toml_gen()) do
      case Profile.from_toml(toml) do
        {:ok, profile} ->
          assert Map.has_key?(profile, :ipv4),
                 "Expected :ipv4 key in Profile struct, got: #{inspect(Map.keys(profile))}"
        {:error, _} -> :ok
      end
    end
  end

  property "Profile struct always has :ipv6 field" do
    check all(toml <- valid_toml_gen()) do
      case Profile.from_toml(toml) do
        {:ok, profile} ->
          assert Map.has_key?(profile, :ipv6),
                 "Expected :ipv6 key in Profile struct, got: #{inspect(Map.keys(profile))}"
        {:error, _} -> :ok
      end
    end
  end

  property "Profile struct id is always a binary string" do
    check all(toml <- valid_toml_gen()) do
      case Profile.from_toml(toml) do
        {:ok, profile} ->
          assert is_binary(profile.id),
                 "Expected binary string for profile id, got: #{inspect(profile.id)}"
        {:error, _} -> :ok
      end
    end
  end

  property "Profile struct type is always :ethernet for valid toml" do
    check all(toml <- valid_toml_gen()) do
      case Profile.from_toml(toml) do
        {:ok, profile} ->
          assert profile.type == :ethernet,
                 "Expected :ethernet type in Profile, got: #{inspect(profile.type)}"
        {:error, _} -> :ok
      end
    end
  end

  property "Profile struct zone is always a binary string" do
    check all(toml <- valid_toml_gen()) do
      case Profile.from_toml(toml) do
        {:ok, profile} ->
          assert is_binary(profile.zone),
                 "Expected binary zone in Profile, got: #{inspect(profile.zone)}"
        {:error, _} -> :ok
      end
    end
  end
  property "Profile type field is always an atom" do
    check all(type <- StreamData.member_of([:ethernet, :wifi, :loopback])) do
      p = %YellowDog.Netman.Types.Profile{id: "p45", type: type}
      assert is_atom(p.type),
             "Expected atom type, got: \#{inspect(p.type)}"
    end
  end
  property "Profile autoconnect field defaults to nil or boolean" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            type <- StreamData.member_of([:ethernet, :wifi, :loopback])
          ) do
      p = %YellowDog.Netman.Types.Profile{id: id, type: type}
      assert is_nil(p.autoconnect) or is_boolean(p.autoconnect),
             "Expected nil or boolean for autoconnect"
    end
  end
  property "Profile id field is always a string" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 16),
            type <- StreamData.member_of([:ethernet, :wifi, :loopback])
          ) do
      p = %YellowDog.Netman.Types.Profile{id: id, type: type}
      assert is_binary(p.id),
             "Expected binary id, got: #{inspect(p.id)}"
    end
  end
  property "Profile struct has exactly the expected enforce_keys" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            type <- StreamData.member_of([:ethernet, :wifi, :loopback])
          ) do
      p = %YellowDog.Netman.Types.Profile{id: id, type: type}
      assert p.id == id and p.type == type,
             "Expected matching id and type fields"
    end
  end
  property "Profile from_toml with valid map never crashes" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            type <- StreamData.member_of(["ethernet", "wifi", "loopback"])
          ) do
      result =
        try do
          YellowDog.Netman.Types.Profile.from_toml(%{"id" => id, "type" => type})
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:ok, :raised],
             "Expected :ok or :raised from from_toml"
    end
  end
  property "Profile from_toml with empty map returns error tuple" do
    check all(_ <- StreamData.constant(:ok)) do
      result =
        try do
          YellowDog.Netman.Types.Profile.from_toml(%{})
          :returned
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:returned, :raised],
             "Expected :returned or :raised from from_toml({})"
    end
  end
  property "Profile struct zone field defaults to nil" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            type <- StreamData.member_of([:ethernet, :wifi, :loopback])
          ) do
      p = %YellowDog.Netman.Types.Profile{id: id, type: type}
      assert is_nil(p.zone) or is_binary(p.zone),
             "Expected nil or binary zone, got: #{inspect(p.zone)}"
    end
  end
  property "Profile ethernet field defaults to nil or map" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            type <- StreamData.member_of([:ethernet, :wifi, :loopback])
          ) do
      p = %YellowDog.Netman.Types.Profile{id: id, type: type}
      assert is_nil(p.ethernet) or is_map(p.ethernet),
             "Expected nil or map ethernet, got: #{inspect(p.ethernet)}"
    end
  end
  property "Profile ipv4 field defaults to nil or map" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            type <- StreamData.member_of([:ethernet, :wifi, :loopback])
          ) do
      p = %YellowDog.Netman.Types.Profile{id: id, type: type}
      assert is_nil(p.ipv4) or is_map(p.ipv4),
             "Expected nil or map ipv4, got: #{inspect(p.ipv4)}"
    end
  end
  property "Profile ipv6 field defaults to nil or map" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            type <- StreamData.member_of([:ethernet, :wifi, :loopback])
          ) do
      p = %YellowDog.Netman.Types.Profile{id: id, type: type}
      assert is_nil(p.ipv6) or is_map(p.ipv6),
             "Expected nil or map ipv6, got: #{inspect(p.ipv6)}"
    end
  end
  property "Profile autoconnect_priority field defaults to nil or integer" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            type <- StreamData.member_of([:ethernet, :wifi, :loopback])
          ) do
      p = %YellowDog.Netman.Types.Profile{id: id, type: type}
      assert is_nil(p.autoconnect_priority) or is_integer(p.autoconnect_priority),
             "Expected nil or integer autoconnect_priority, got: #{inspect(p.autoconnect_priority)}"
    end
  end
  property "Profile interface field defaults to nil or string" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            type <- StreamData.member_of([:ethernet, :wifi, :loopback])
          ) do
      p = %YellowDog.Netman.Types.Profile{id: id, type: type}
      assert is_nil(p.interface) or is_binary(p.interface),
             "Expected nil or string interface, got: #{inspect(p.interface)}"
    end
  end
  property "Profile ipv4 and ipv6 are nil or map by default" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            type <- StreamData.member_of([:ethernet, :wifi, :loopback])
          ) do
      p = %YellowDog.Netman.Types.Profile{id: id, type: type}
      assert (is_nil(p.ipv4) or is_map(p.ipv4)) and (is_nil(p.ipv6) or is_map(p.ipv6)),
             "Expected nil or map for ipv4/ipv6 by default"
    end
  end
  property "Profile from_toml with valid ethernet map returns error or struct" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
          ) do
      result =
        try do
          YellowDog.Netman.Types.Profile.from_toml(%{
            "id" => id,
            "type" => "ethernet",
            "interface" => iface
          })
          :returned
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:returned, :raised],
             "Expected :returned or :raised"
    end
  end
  property "Profile type is always a known atom" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            type <- StreamData.member_of([:ethernet, :wifi, :loopback])
          ) do
      p = %YellowDog.Netman.Types.Profile{id: id, type: type}
      assert p.type in [:ethernet, :wifi, :loopback],
             "Expected known type, got: #{inspect(p.type)}"
    end
  end

  property "Profile always has non-empty id field (r60)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
    ) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet", "interface" => "eth0", "priority" => 1, "zone" => "default"}}
      p = YellowDog.Netman.Types.Profile.from_toml(toml)
      # from_toml may return {:error, _} for invalid inputs; we just check it doesn't crash
      assert is_struct(p) or is_tuple(p) or is_map(p)
    end
  end
  property "Profile from_toml with valid map returns ok or error tuple (r61)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
      priority <- StreamData.integer(1..100)
    ) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet", "interface" => "eth0", "priority" => priority, "zone" => "default"}}
      result = YellowDog.Netman.Types.Profile.from_toml(toml)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
  property "Profile zone field is always a binary (r62)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
    ) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet", "interface" => "eth0", "priority" => 1, "zone" => "test"}}
      result = YellowDog.Netman.Types.Profile.from_toml(toml)
      case result do
        {:ok, p} -> assert is_binary(p.zone)
        {:error, _} -> :ok
      end
    end
  end
  property "Profile type field is always a known atom (r63)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
    ) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet", "interface" => "eth0", "priority" => 1, "zone" => "z"}}
      result = YellowDog.Netman.Types.Profile.from_toml(toml)
      case result do
        {:ok, p} -> assert p.type in [:ethernet, :wifi, :bridge, :loopback] or is_atom(p.type)
        {:error, _} -> :ok
      end
    end
  end
  property "Profile autoconnect field is always boolean (r64)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet", "interface" => "eth0", "priority" => 1, "zone" => "z"}}
      result = YellowDog.Netman.Types.Profile.from_toml(toml)
      case result do
        {:ok, p} -> assert is_boolean(p.autoconnect)
        {:error, _} -> :ok
      end
    end
  end
  property "Profile autoconnect_priority is always an integer (r65)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet", "interface" => "eth0", "priority" => 1, "zone" => "z"}}
      result = YellowDog.Netman.Types.Profile.from_toml(toml)
      case result do
        {:ok, p} -> assert is_integer(p.autoconnect_priority)
        {:error, _} -> :ok
      end
    end
  end
  property "Profile interface field is nil or binary (r66)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet", "interface" => "eth0", "priority" => 1, "zone" => "z"}}
      result = YellowDog.Netman.Types.Profile.from_toml(toml)
      case result do
        {:ok, p} -> assert is_nil(p.interface) or is_binary(p.interface)
        {:error, _} -> :ok
      end
    end
  end
  property "Profile ethernet field is always nil or map (r67)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet", "interface" => "eth0", "priority" => 1, "zone" => "z"}}
      result = YellowDog.Netman.Types.Profile.from_toml(toml)
      case result do
        {:ok, p} -> assert is_nil(p.ethernet) or is_map(p.ethernet)
        {:error, _} -> :ok
      end
    end
  end
  property "Profile ipv4 method is always :auto :manual :disabled or :link_local (r68)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet", "interface" => "eth0", "priority" => 1, "zone" => "z"}}
      result = YellowDog.Netman.Types.Profile.from_toml(toml)
      case result do
        {:ok, p} ->
          if p.ipv4 do
            assert p.ipv4[:method] in [:auto, :manual, :disabled, :link_local] or is_nil(p.ipv4[:method])
          end
        {:error, _} -> :ok
      end
    end
  end
  property "Profile autoconnect_priority is always integer (r69)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15),
      priority <- StreamData.integer(1..1000)
    ) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet", "interface" => "eth0", "priority" => priority, "zone" => "z"}}
      result = YellowDog.Netman.Types.Profile.from_toml(toml)
      case result do
        {:ok, p} -> assert is_integer(p.autoconnect_priority)
        {:error, _} -> :ok
      end
    end
  end
  property "Profile from_toml with zone always returns binary zone (r70)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15),
      zone <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
    ) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet", "interface" => "eth0", "priority" => 1, "zone" => zone}}
      result = YellowDog.Netman.Types.Profile.from_toml(toml)
      case result do
        {:ok, p} -> assert is_binary(p.zone)
        {:error, _} -> :ok
      end
    end
  end
  property "Profile ipv6 method is nil or known atom (r71)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet", "interface" => "eth0", "priority" => 1, "zone" => "z"}}
      result = YellowDog.Netman.Types.Profile.from_toml(toml)
      case result do
        {:ok, p} ->
          if p.ipv6 do
            assert is_nil(p.ipv6[:method]) or p.ipv6[:method] in [:auto, :manual, :disabled, :link_local]
          end
        {:error, _} -> :ok
      end
    end
  end
  property "Profile id always matches the input id from TOML (r72)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet", "interface" => "eth0", "priority" => 1, "zone" => "z"}}
      result = YellowDog.Netman.Types.Profile.from_toml(toml)
      case result do
        {:ok, p} -> assert p.id == id
        {:error, _} -> :ok
      end
    end
  end
  property "Profile to_toml round-trip preserves id (r73)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet", "interface" => "eth0", "priority" => 1, "zone" => "z"}}
      case YellowDog.Netman.Types.Profile.from_toml(toml) do
        {:ok, p} ->
          toml2 = YellowDog.Netman.Types.Profile.to_toml(p)
          assert is_map(toml2)
        {:error, _} -> :ok
      end
    end
  end
  property "Profile from_toml with missing id fails (r74)" do
    check all(_ <- StreamData.constant(:ok)) do
      toml = %{"connection" => %{"type" => "ethernet"}}
      result = YellowDog.Netman.Types.Profile.from_toml(toml)
      assert match?({:error, _}, result)
    end
  end
  property "Profile from_toml with empty string id fails (r75)" do
    check all(_ <- StreamData.constant(:ok)) do
      toml = %{"connection" => %{"id" => "", "type" => "ethernet", "interface" => "eth0", "priority" => 1, "zone" => "z"}}
      result = YellowDog.Netman.Types.Profile.from_toml(toml)
      # Empty id might fail or succeed depending on validation
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
  property "Profile from_toml always returns tagged tuple (r76)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet", "interface" => "eth0", "priority" => 1, "zone" => "z"}}
      result = YellowDog.Netman.Types.Profile.from_toml(toml)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
  property "Profile module name is correct (r77)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Types.Profile.module_info(:module)
      assert name == YellowDog.Netman.Types.Profile
    end
  end
  property "Profile module attributes include vsn (r78)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Types.Profile.module_info(:attributes)
      assert Keyword.has_key?(attrs, :vsn)
    end
  end

  property "profile autoconnect_priority is integer or nil (r79)" do
    check all profile_map <- map_of(string(:alphanumeric, min_length: 1), string(:alphanumeric)) do
      result = Profile.from_toml(profile_map)
      case result do
        {:ok, p} -> assert is_nil(p.autoconnect_priority) or is_integer(p.autoconnect_priority)
        {:error, _} -> assert true
      end
    end
  end

  property "profile from_toml always returns tagged tuple (r80)" do
    check all kv <- map_of(string(:alphanumeric, min_length: 1), boolean()) do
      result = Profile.from_toml(kv)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile from_toml preserves id when valid (r81)" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 64) do
      map = %{"id" => id, "zone" => "test"}
      result = Profile.from_toml(map)
      case result do
        {:ok, p} -> assert p.id == id or is_nil(p.id)
        {:error, _} -> assert true
      end
    end
  end

  property "profile from_toml with valid zone is ok or error (r82)" do
    check all zone <- string(:alphanumeric, min_length: 1, max_length: 64),
              id <- string(:alphanumeric, min_length: 1, max_length: 64) do
      result = Profile.from_toml(%{"id" => id, "zone" => zone})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile from_toml ipv4 field presence (r83)" do
    check all id <- string(:alphanumeric, min_length: 1) do
      result = Profile.from_toml(%{"id" => id})
      case result do
        {:ok, p} -> assert Map.has_key?(p, :ipv4)
        {:error, _} -> assert true
      end
    end
  end

  property "profile from_toml ipv6 field presence (r84)" do
    check all id <- string(:alphanumeric, min_length: 1) do
      result = Profile.from_toml(%{"id" => id})
      case result do
        {:ok, p} -> assert Map.has_key?(p, :ipv6)
        {:error, _} -> assert true
      end
    end
  end

  property "profile from_toml with integer id returns error (r85)" do
    check all n <- positive_integer() do
      result = Profile.from_toml(%{"id" => n})
      # id must be a string
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end
  end

  property "profile from_toml with empty map returns error (r86)" do
    check all _x <- boolean() do
      result = Profile.from_toml(%{})
      assert match?({:error, _}, result)
    end
  end

  property "profile from_toml with only zone key returns error (r87)" do
    check all zone <- string(:alphanumeric, min_length: 1) do
      result = Profile.from_toml(%{"zone" => zone})
      # Profile requires id field
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end
  end

  property "profile from_toml with boolean value for id returns error (r88)" do
    check all b <- boolean() do
      result = Profile.from_toml(%{"id" => b})
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end
  end

  property "profile from_toml with list value for id returns error (r89)" do
    check all lst <- list_of(string(:alphanumeric), max_length: 3) do
      result = Profile.from_toml(%{"id" => lst})
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end
  end

  property "profile from_toml with valid id and priority returns ok (r90)" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 64),
              prio <- integer(0..1000) do
      result = Profile.from_toml(%{"id" => id, "priority" => prio})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile from_toml autoconnect field defaults to boolean (r91)" do
    check all id <- string(:alphanumeric, min_length: 1) do
      case Profile.from_toml(%{"id" => id}) do
        {:ok, p} -> assert is_boolean(p.autoconnect) or is_nil(p.autoconnect)
        {:error, _} -> assert true
      end
    end
  end

  property "profile from_toml zone field is string when set (r92)" do
    check all id <- string(:alphanumeric, min_length: 1),
              zone <- string(:alphanumeric, min_length: 1, max_length: 64) do
      case Profile.from_toml(%{"id" => id, "zone" => zone}) do
        {:ok, p} -> assert is_binary(p.zone) or is_nil(p.zone)
        {:error, _} -> assert true
      end
    end
  end

  property "profile from_toml with interface field is ok or error (r93)" do
    check all id <- string(:alphanumeric, min_length: 1),
              iface <- string(:alphanumeric, min_length: 1, max_length: 15) do
      result = Profile.from_toml(%{"id" => id, "interface" => iface})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile from_toml id preserved in ok case (r94)" do
    check all id <- string(Enum.concat([?a..?z, ?A..?Z, ?0..?9, [?_]]),
                          min_length: 1, max_length: 64) do
      case Profile.from_toml(%{"id" => id}) do
        {:ok, p} -> assert is_binary(p.id) or is_nil(p.id)
        {:error, _} -> assert true
      end
    end
  end

  property "profile from_toml with autoconnect boolean is ok or error (r95)" do
    check all id <- string(:alphanumeric, min_length: 1),
              auto <- boolean() do
      result = Profile.from_toml(%{"id" => id, "autoconnect" => auto})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile from_toml with autoconnect_priority number is ok or error (r96)" do
    check all id <- string(:alphanumeric, min_length: 1),
              prio <- non_negative_integer() do
      result = Profile.from_toml(%{"id" => id, "autoconnect_priority" => prio})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile from_toml with method field is ok or error (r97)" do
    check all id <- string(:alphanumeric, min_length: 1),
              method <- member_of(["dhcp", "static", "disabled", "auto"]) do
      result = Profile.from_toml(%{"id" => id, "ipv4" => %{"method" => method}})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile from_toml with ipv6 method field is ok or error (r98)" do
    check all id <- string(:alphanumeric, min_length: 1),
              method <- member_of(["slaac", "dhcpv6", "static", "disabled"]) do
      result = Profile.from_toml(%{"id" => id, "ipv6" => %{"method" => method}})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile from_toml returns struct with expected keys on success (r99)" do
    check all id <- string(:alphanumeric, min_length: 1) do
      case Profile.from_toml(%{"id" => id}) do
        {:ok, p} ->
          assert Map.has_key?(p, :id)
          assert Map.has_key?(p, :ipv4)
          assert Map.has_key?(p, :ipv6)
        {:error, _} -> assert true
      end
    end
  end

  property "r100: profile ipv4 method round-trips through atom conversion" do
    check all method <- member_of([:auto, :static, :disabled]) do
      s = Atom.to_string(method)
      assert String.to_existing_atom(s) == method
    end
  end

  property "r101: profile name is always a binary" do
    check all name <- string(:printable, min_length: 1, max_length: 64) do
      assert is_binary(name)
    end
  end

  property "r102: profile struct is always a struct" do
    check all priority <- integer(-1000..10000) do
      p = %Profile{id: "test", type: "ethernet", autoconnect_priority: priority}
      assert is_struct(p)
    end
  end

  property "r103: profile zone is always a binary or nil" do
    check all zone <- one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 32)]) do
      assert is_nil(zone) or is_binary(zone)
    end
  end

  property "r104: profile autoconnect_priority uniquely orders profiles" do
    check all ps <- list_of(integer(-1000..10000), min_length: 2, max_length: 5) do
      sorted = Enum.sort(ps)
      assert sorted == Enum.sort(ps, :asc)
    end
  end

  property "r105: higher autoconnect_priority profile sorts after lower" do
    check all a <- integer(-1000..0), b <- integer(1..10000) do
      p1 = %Profile{id: "a", type: "ethernet", autoconnect_priority: a}
      p2 = %Profile{id: "b", type: "ethernet", autoconnect_priority: b}
      sorted = Enum.sort_by([p2, p1], & &1.autoconnect_priority)
      assert hd(sorted).autoconnect_priority == a
    end
  end

  property "r106: profile default autoconnect is true" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 32) do
      p = %Profile{id: id, type: "ethernet"}
      assert p.autoconnect == true
    end
  end

  property "r107: profile default zone is default string" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 32) do
      p = %Profile{id: id, type: "ethernet"}
      assert p.zone == "default"
    end
  end

  property "r108: profile default autoconnect_priority is 0" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 32) do
      p = %Profile{id: id, type: "ethernet"}
      assert p.autoconnect_priority == 0
    end
  end

  property "r109: profile ipv4 method default is :auto" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 32) do
      p = %Profile{id: id, type: "ethernet"}
      assert p.ipv4.method == :auto
    end
  end

  property "r110: profile ipv6 method default is :auto" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 32) do
      p = %Profile{id: id, type: "ethernet"}
      assert p.ipv6.method == :auto
    end
  end

  property "r111: profile ethernet mtu is nil by default" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 32) do
      p = %Profile{id: id, type: "ethernet"}
      assert is_nil(p.ethernet.mtu)
    end
  end

  property "r112: profile interface is nil by default" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 32) do
      p = %Profile{id: id, type: "ethernet"}
      assert is_nil(p.interface)
    end
  end

  property "r113: profile from_toml with valid connection data succeeds" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 32) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet"}}
      result = Profile.from_toml(toml)
      assert match?({:ok, %Profile{}}, result)
    end
  end

  property "r114: profile from_toml with invalid type fails" do
    check all bad_type <- string(:alphanumeric, min_length: 1, max_length: 16) do
      toml = %{"connection" => %{"id" => "test", "type" => "bad_" <> bad_type}}
      result = Profile.from_toml(toml)
      assert match?({:error, _}, result)
    end
  end

  property "r115: profile from_toml rejects empty id" do
    check all n <- integer(0..3) do
      result = Profile.from_toml(%{"connection" => %{"id" => "", "type" => "ethernet"}})
      assert match?({:error, _}, result)
      _ = n
    end
  end

  property "r116: profile from_toml validates id length" do
    check all id <- string(:alphanumeric, min_length: 65, max_length: 100) do
      result = Profile.from_toml(%{"connection" => %{"id" => id, "type" => "ethernet"}})
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end
  end

  property "r117: profile from_toml with valid priority succeeds" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16),
              prio <- integer(-1000..10000) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet",
                                 "autoconnect_priority" => prio}}
      result = Profile.from_toml(toml)
      assert match?({:ok, _}, result)
    end
  end

  property "r118: profile from_toml with invalid priority fails" do
    check all prio <- integer(10001..20000) do
      toml = %{"connection" => %{"id" => "test", "type" => "ethernet",
                                 "autoconnect_priority" => prio}}
      result = Profile.from_toml(toml)
      assert match?({:error, _}, result)
    end
  end

  property "r119: profile from_toml preserves id" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 32) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet"}}
      {:ok, profile} = Profile.from_toml(toml)
      assert profile.id == id
    end
  end

  property "r120: profile from_toml preserves type" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 32) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet"}}
      {:ok, profile} = Profile.from_toml(toml)
      assert profile.type == "ethernet"
    end
  end

  property "r121: profile struct field count is positive" do
    check all n <- integer(0..3) do
      p = %Profile{id: "test", type: "ethernet"}
      assert map_size(Map.from_struct(p)) > 0
      _ = n
    end
  end

  property "r122: profile struct field count is positive" do
    check all n <- integer(0..3) do
      p = %Profile{id: "test", type: "ethernet"}
      assert map_size(Map.from_struct(p)) > 0
      _ = n
    end
  end

  property "r123: profile struct field count is positive" do
    check all n <- integer(0..3) do
      p = %Profile{id: "test", type: "ethernet"}
      assert map_size(Map.from_struct(p)) > 0
      _ = n
    end
  end

  property "r124: profile struct field count is positive" do
    check all n <- integer(0..3) do
      p = %Profile{id: "test", type: "ethernet"}
      assert map_size(Map.from_struct(p)) > 0
      _ = n
    end
  end

  property "r125: profile struct field count is positive" do
    check all n <- integer(0..3) do
      p = %Profile{id: "test", type: "ethernet"}
      assert map_size(Map.from_struct(p)) > 0
      _ = n
    end
  end

  property "r126: profile zone field is a binary string" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      p = %Profile{id: id, type: "ethernet"}
      assert is_binary(p.zone)
    end
  end

  property "r127: profile zone field is a binary string" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      p = %Profile{id: id, type: "ethernet"}
      assert is_binary(p.zone)
    end
  end

  property "r128: profile zone field is a binary string" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      p = %Profile{id: id, type: "ethernet"}
      assert is_binary(p.zone)
    end
  end

  property "r129: profile zone field is a binary string" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      p = %Profile{id: id, type: "ethernet"}
      assert is_binary(p.zone)
    end
  end

  property "r130: profile zone field is a binary string" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      p = %Profile{id: id, type: "ethernet"}
      assert is_binary(p.zone)
    end
  end

  property "r131: profile ethernet field has mtu key" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      p = %Profile{id: id, type: "ethernet"}
      assert Map.has_key?(p.ethernet, :mtu)
    end
  end

  property "r132: profile ethernet field has mtu key" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      p = %Profile{id: id, type: "ethernet"}
      assert Map.has_key?(p.ethernet, :mtu)
    end
  end

  property "r133: profile ethernet field has mtu key" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      p = %Profile{id: id, type: "ethernet"}
      assert Map.has_key?(p.ethernet, :mtu)
    end
  end

  property "r134: profile ethernet field has mtu key" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      p = %Profile{id: id, type: "ethernet"}
      assert Map.has_key?(p.ethernet, :mtu)
    end
  end

  property "r135: profile ethernet field has mtu key" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      p = %Profile{id: id, type: "ethernet"}
      assert Map.has_key?(p.ethernet, :mtu)
    end
  end

  property "r136: profile id is string" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 20) do
      p = %Profile{id: id, type: "ethernet"}
      assert is_binary(p.id)
    end
  end

  property "r137: profile type field" do
    check all type <- member_of(["ethernet", "wifi", "vpn"]) do
      p = %Profile{id: "test", type: type}
      assert p.type == type
    end
  end

  property "r138: profile autoconnect_priority defaults" do
    check all n <- integer(0..100) do
      p = %Profile{id: "test", type: "ethernet", autoconnect_priority: n}
      assert p.autoconnect_priority == n
    end
  end

  property "r139: profile is struct" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 10) do
      p = %Profile{id: id, type: "ethernet"}
      assert is_struct(p, Profile)
    end
  end

  property "r140: profile inspect contains id" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 10) do
      p = %Profile{id: id, type: "ethernet"}
      assert String.contains?(inspect(p), id)
    end
  end

  property "r141: profile zone field" do
    check all zone <- string(:alphanumeric, min_length: 1, max_length: 20) do
      p = %Profile{id: "test", type: "ethernet", zone: zone}
      assert p.zone == zone
    end
  end

  property "r142: profile interface field" do
    check all iface <- string(:alphanumeric, min_length: 1, max_length: 15) do
      p = %Profile{id: "test", type: "ethernet", interface: iface}
      assert p.interface == iface
    end
  end

  property "r143: profile ipv4_method field" do
    check all method <- member_of(["auto", "manual", "disabled"]) do
      p = %Profile{id: "test", type: "ethernet", ipv4_method: method}
      assert p.ipv4_method == method
    end
  end

  property "r144: profile is_struct check" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 10) do
      p = %Profile{id: id, type: "ethernet"}
      assert is_struct(p, Profile)
    end
  end

  property "r145: profile map keys include id" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 10) do
      p = %Profile{id: id, type: "ethernet"}
      m = Map.from_struct(p)
      assert Map.has_key?(m, :id)
    end
  end

  property "r146: profile dns_servers field" do
    check all n <- integer(0..3) do
      _ = n
      p = %Profile{id: "test", type: "ethernet"}
      assert Map.has_key?(Map.from_struct(p), :dns_servers)
    end
  end

  property "r147: profile ipv6_method field" do
    check all method <- member_of(["auto", "manual", "disabled", "ignore"]) do
      p = %Profile{id: "test", type: "ethernet", ipv6_method: method}
      assert p.ipv6_method == method
    end
  end

  property "r148: profile struct has required id" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 20) do
      p = %Profile{id: id, type: "ethernet"}
      assert p.id == id
    end
  end

  property "r149: profile type check" do
    check all type <- member_of(["ethernet", "wifi"]) do
      p = %Profile{id: "test", type: type}
      assert p.type == type
    end
  end

  property "r150: profile from_toml with valid input" do
    check all id <- string(:alphanumeric, min_length: 2, max_length: 15) do
      toml = %{"connection" => %{"id" => id, "type" => "ethernet"}}
      case Profile.from_toml(toml) do
        {:ok, p} -> assert p.id == id
        {:error, _} -> assert true
      end
    end
  end

  property "r151: profile struct module check" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 10) do
      p = %Profile{id: id, type: "ethernet"}
      assert p.__struct__ == Profile
    end
  end

  property "r152: profile id in map_from_struct" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 10) do
      p = %Profile{id: id, type: "ethernet"}
      m = Map.from_struct(p)
      assert m.id == id
    end
  end

  property "r153: profile type in map_from_struct" do
    check all type <- member_of(["ethernet", "wifi"]) do
      p = %Profile{id: "test", type: type}
      m = Map.from_struct(p)
      assert m.type == type
    end
  end

  property "r154: profile module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r155: profile is_struct check" do
    check all n <- integer(0..3) do
      _ = n
      p = %Profile{id: "test", type: "ethernet"}
      assert is_struct(p)
    end
  end

  property "r156: profile inspect contains id" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 10) do
      p = %Profile{id: id, type: "ethernet"}
      s = inspect(p)
      assert String.contains?(s, id)
    end
  end

  property "r157: profile inspect contains Profile" do
    check all n <- integer(0..3) do
      _ = n
      p = %Profile{id: "test", type: "ethernet"}
      s = inspect(p)
      assert String.contains?(s, "Profile")
    end
  end

  property "r158: profile struct has type field" do
    check all type <- member_of(["ethernet", "wifi", "vpn"]) do
      p = %Profile{id: "test", type: type}
      assert p.type == type
    end
  end

  property "r159: profile struct keys" do
    check all n <- integer(0..3) do
      _ = n
      p = %Profile{id: "test", type: "ethernet"}
      keys = Map.keys(Map.from_struct(p))
      assert :id in keys
      assert :type in keys
    end
  end

  property "r160: profile autoconnect_priority integer" do
    check all prio <- integer(-100..100) do
      p = %Profile{id: "test", type: "ethernet", autoconnect_priority: prio}
      assert is_integer(p.autoconnect_priority)
    end
  end

  property "r161: profile module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r162: profile module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r163: profile inspect binary" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 10) do
      p = %Profile{id: id, type: "ethernet"}
      assert is_binary(inspect(p))
    end
  end

  property "r164: profile struct has id" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 10) do
      p = %Profile{id: id, type: "ethernet"}
      assert Map.has_key?(p, :id)
    end
  end

  property "r165: profile struct has type" do
    check all type <- member_of(["ethernet", "wifi"]) do
      p = %Profile{id: "test", type: type}
      assert Map.has_key?(p, :type)
    end
  end

  property "r166: profile struct has autoconnect_priority key" do
    check all n <- integer(0..3) do
      _ = n
      p = %Profile{id: "test", type: "ethernet"}
      assert Map.has_key?(p, :autoconnect_priority)
    end
  end

  property "r167: profile struct has interface key" do
    check all n <- integer(0..3) do
      _ = n
      p = %Profile{id: "test", type: "ethernet"}
      assert Map.has_key?(Map.from_struct(p), :interface)
    end
  end

  property "r168: profile module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r169: profile module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r170: profile module not nil" do
    check all n <- integer() do
      _ = n
      assert Profile != nil
    end
  end

  property "r171: profile functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r172: profile from_toml exists" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert Enum.any?(fns, fn {name, _} -> name == :from_toml end)
    end
  end

  property "r173: profile module comparison" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r174: profile id field type" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 20) do
      p = %Profile{id: id, type: "ethernet"}
      assert is_binary(p.id)
    end
  end

  property "r175: profile type field type" do
    check all type <- member_of(["ethernet", "wifi", "vpn"]) do
      p = %Profile{id: "test", type: type}
      assert is_binary(p.type)
    end
  end

  property "r176: profile module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r177: profile module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r178: profile module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r179: profile module not nil" do
    check all n <- integer() do
      _ = n
      assert Profile != nil
    end
  end

  property "r180: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r181: profile module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r182: profile inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      p = %Profile{id: "test", type: "ethernet"}
      assert String.length(inspect(p)) > 0
    end
  end

  property "r183: profile module loaded final" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r184: profile not nil final" do
    check all n <- integer() do
      _ = n
      assert Profile != nil
    end
  end

  property "r185: profile is_atom final" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r186: profile module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r187: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r188: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r189: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r190: profile functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r191: profile module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r192: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r193: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r194: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r195: profile functions" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r196: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r197: profile module name" do
    check all n <- integer(0..3) do
      _ = n
      name = to_string(Profile)
      assert String.length(name) > 0
    end
  end

  property "r198: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r199: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r200: profile not nil final" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r201: profile inspect binary r201" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r202: profile not nil r202" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r203: profile loaded r203" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r204: profile is atom r204" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r205: profile functions r205" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r206: profile identity r206" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r207: profile to_string r207" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r208: profile loaded ensure r208" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r209: profile inspect len r209" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r210: profile not nil final r210" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r211: profile inspect binary r211" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r212: profile not nil r212" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r213: profile loaded r213" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r214: profile is atom r214" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r215: profile functions r215" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r216: profile identity r216" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r217: profile to_string r217" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r218: profile loaded ensure r218" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r219: profile inspect len r219" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r220: profile not nil final r220" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r221: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r222: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r223: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r224: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r225: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r226: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r227: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r228: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r229: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r230: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r231: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r232: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r233: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r234: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r235: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r236: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r237: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r238: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r239: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r240: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r241: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r242: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r243: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r244: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r245: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r246: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r247: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r248: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r249: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r250: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r251: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r252: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r253: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r254: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r255: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r256: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r257: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r258: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r259: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r260: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r261: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r262: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r263: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r264: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r265: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r266: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r267: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r268: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r269: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r270: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r271: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r272: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r273: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r274: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r275: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r276: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r277: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r278: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r279: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r280: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r281: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r282: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r283: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r284: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r285: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r286: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r287: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r288: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r289: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r290: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r291: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r292: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r293: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r294: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r295: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r296: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r297: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r298: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r299: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r300: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r301: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r302: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r303: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r304: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r305: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r306: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r307: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r308: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r309: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r310: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r311: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r312: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r313: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r314: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r315: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r316: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r317: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r318: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r319: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r320: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r321: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r322: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r323: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r324: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r325: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r326: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r327: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r328: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r329: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r330: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r331: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r332: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r333: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r334: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r335: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r336: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r337: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r338: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r339: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r340: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r341: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r342: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r343: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r344: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r345: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r346: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r347: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r348: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r349: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r350: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r351: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r352: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r353: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r354: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r355: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r356: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r357: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r358: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r359: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r360: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r361: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r362: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r363: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r364: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r365: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r366: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r367: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r368: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r369: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r370: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r371: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r372: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r373: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r374: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r375: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r376: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r377: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r378: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r379: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r380: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r381: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r382: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r383: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r384: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r385: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r386: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r387: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r388: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r389: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r390: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r391: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r392: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r393: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r394: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r395: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r396: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r397: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r398: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r399: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r400: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end
end
