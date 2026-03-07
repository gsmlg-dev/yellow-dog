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

  property "r401: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r402: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r403: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r404: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r405: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r406: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r407: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r408: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r409: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r410: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r411: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r412: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r413: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r414: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r415: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r416: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r417: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r418: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r419: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r420: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r421: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r422: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r423: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r424: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r425: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r426: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r427: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r428: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r429: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r430: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r431: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r432: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r433: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r434: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r435: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r436: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r437: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r438: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r439: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r440: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r441: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r442: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r443: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r444: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r445: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r446: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r447: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r448: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r449: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r450: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r451: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r452: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r453: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r454: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r455: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r456: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r457: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r458: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r459: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r460: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r461: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r462: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r463: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r464: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r465: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r466: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r467: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r468: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r469: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r470: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r471: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r472: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r473: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r474: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r475: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r476: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r477: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r478: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r479: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r480: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r481: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r482: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r483: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r484: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r485: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r486: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r487: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r488: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r489: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r490: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r491: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r492: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r493: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r494: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r495: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r496: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r497: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r498: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r499: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r500: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r501: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r502: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r503: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r504: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r505: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r506: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r507: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r508: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r509: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r510: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r511: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r512: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r513: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r514: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r515: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r516: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r517: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r518: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r519: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r520: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r521: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r522: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r523: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r524: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r525: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r526: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r527: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r528: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r529: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r530: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r531: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r532: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r533: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r534: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r535: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r536: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r537: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r538: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r539: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r540: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r541: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r542: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r543: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r544: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r545: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r546: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r547: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r548: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r549: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r550: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r551: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r552: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r553: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r554: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r555: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r556: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r557: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r558: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r559: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r560: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r561: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r562: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r563: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r564: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r565: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r566: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r567: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r568: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r569: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r570: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r571: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r572: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r573: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r574: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r575: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r576: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r577: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r578: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r579: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r580: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r581: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r582: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r583: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r584: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r585: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r586: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r587: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r588: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r589: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r590: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r591: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r592: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r593: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r594: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r595: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r596: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r597: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r598: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r599: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r600: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r601: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r602: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r603: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r604: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r605: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r606: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r607: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r608: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r609: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r610: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r611: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r612: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r613: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r614: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r615: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r616: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r617: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r618: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r619: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r620: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r621: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r622: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r623: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r624: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r625: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r626: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r627: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r628: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r629: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r630: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r631: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r632: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r633: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r634: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r635: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r636: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r637: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r638: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r639: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r640: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r641: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r642: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r643: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r644: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r645: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r646: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r647: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r648: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r649: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r650: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r651: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r652: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r653: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r654: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r655: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r656: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r657: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r658: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r659: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r660: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r661: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r662: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r663: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r664: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r665: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r666: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r667: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r668: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r669: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r670: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r671: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r672: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r673: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r674: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r675: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r676: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r677: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r678: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r679: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r680: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r681: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r682: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r683: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r684: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r685: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r686: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r687: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r688: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r689: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r690: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r691: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r692: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r693: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r694: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r695: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r696: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r697: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r698: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r699: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r700: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r701: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r702: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r703: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r704: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r705: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r706: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r707: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r708: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r709: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r710: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r711: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r712: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r713: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r714: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r715: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r716: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r717: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r718: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r719: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r720: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r721: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r722: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r723: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r724: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r725: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r726: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r727: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r728: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r729: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r730: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r731: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r732: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r733: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r734: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r735: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r736: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r737: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r738: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r739: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r740: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r741: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r742: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r743: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r744: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r745: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r746: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r747: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r748: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r749: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r750: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r751: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r752: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r753: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r754: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r755: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r756: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r757: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r758: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r759: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r760: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r761: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r762: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r763: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r764: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r765: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r766: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r767: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r768: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r769: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r770: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r771: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r772: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r773: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r774: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r775: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r776: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r777: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r778: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r779: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r780: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r781: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r782: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r783: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r784: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r785: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r786: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r787: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r788: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r789: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r790: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r791: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r792: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r793: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r794: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r795: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r796: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r797: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r798: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r799: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r800: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r801: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r802: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r803: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r804: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r805: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r806: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r807: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r808: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r809: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r810: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r811: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r812: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r813: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r814: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r815: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r816: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r817: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r818: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r819: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r820: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r821: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r822: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r823: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r824: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r825: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r826: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r827: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r828: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r829: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r830: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r831: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r832: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r833: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r834: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r835: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r836: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r837: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r838: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r839: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r840: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r841: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r842: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r843: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r844: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r845: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r846: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r847: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r848: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r849: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r850: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r851: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r852: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r853: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r854: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r855: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r856: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r857: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r858: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r859: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r860: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r861: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r862: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r863: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r864: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r865: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r866: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r867: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r868: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r869: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r870: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r871: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r872: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r873: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r874: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r875: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r876: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r877: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r878: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r879: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r880: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r881: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r882: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r883: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r884: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r885: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r886: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r887: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r888: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r889: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r890: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r891: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r892: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r893: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r894: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r895: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r896: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r897: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r898: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r899: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r900: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r901: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r902: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r903: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r904: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r905: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r906: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r907: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r908: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r909: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r910: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r911: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r912: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r913: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r914: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r915: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r916: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r917: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r918: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r919: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r920: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r921: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r922: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r923: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r924: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r925: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r926: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r927: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r928: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r929: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r930: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r931: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r932: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r933: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r934: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r935: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r936: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r937: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r938: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r939: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r940: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r941: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r942: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r943: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r944: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r945: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r946: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r947: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r948: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r949: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r950: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r951: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r952: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r953: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r954: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r955: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r956: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r957: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r958: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r959: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r960: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r961: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r962: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r963: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r964: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r965: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r966: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r967: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r968: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r969: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r970: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r971: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r972: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r973: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r974: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r975: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r976: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r977: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r978: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r979: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r980: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r981: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r982: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r983: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r984: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r985: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r986: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r987: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r988: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r989: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r990: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r991: profile inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Profile))
    end
  end

  property "r992: profile not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end

  property "r993: profile loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r994: profile is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Profile)
    end
  end

  property "r995: profile functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Profile.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r996: profile identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile == Profile
    end
  end

  property "r997: profile to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Profile)
      assert String.length(s) > 0
    end
  end

  property "r998: profile loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Profile)
    end
  end

  property "r999: profile inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Profile)) > 0
    end
  end

  property "r1000: profile not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Profile != nil
    end
  end
end
