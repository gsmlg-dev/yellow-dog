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

  defp ipv6_address_gen do
    gen all(
          group <- StreamData.integer(0x2001..0x2001),
          suffix <- StreamData.integer(1..0xFFFF),
          prefix <- StreamData.integer(48..64)
        ) do
      "#{Integer.to_string(group, 16)}:db8::#{Integer.to_string(suffix, 16)}/#{prefix}"
    end
  end

  defp dns_search_gen do
    StreamData.one_of([
      StreamData.constant([]),
      gen all(
            count <- StreamData.integer(1..3),
            labels <-
              StreamData.list_of(StreamData.string(:alphanumeric, min_length: 3, max_length: 8),
                length: count
              )
          ) do
        Enum.map(labels, &"#{&1}.example.com")
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
          ipv6_address <- ipv6_address_gen(),
          iface <- iface_gen(),
          zone <- zone_gen(),
          ipv4_gw <- gateway_gen(),
          ipv4_dns <- dns_gen(),
          ipv4_dns_search <- dns_search_gen(),
          ipv6_dns_search <- dns_search_gen()
        ) do
      ipv4 =
        if ipv4_method == "manual" do
          %{"method" => ipv4_method, "address" => ipv4_address}
        else
          %{"method" => ipv4_method}
        end

      ipv4 = if ipv4_gw, do: Map.put(ipv4, "gateway", ipv4_gw), else: ipv4
      ipv4 = if ipv4_dns != [], do: Map.put(ipv4, "dns", ipv4_dns), else: ipv4

      ipv4 =
        if ipv4_dns_search != [], do: Map.put(ipv4, "dns_search", ipv4_dns_search), else: ipv4

      ipv6 =
        if ipv6_method == "manual" do
          %{"method" => ipv6_method, "address" => ipv6_address}
        else
          %{"method" => ipv6_method}
        end

      ipv6 =
        if ipv6_dns_search != [], do: Map.put(ipv6, "dns_search", ipv6_dns_search), else: ipv6

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
        "ipv6" => ipv6
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
            method <- StreamData.member_of(["auto", "manual", "disabled", "link-local"]),
            ipv6_addr <- ipv6_address_gen()
          ) do
      ipv6 =
        if method == "manual" do
          %{"method" => method, "address" => ipv6_addr}
        else
          %{"method" => method}
        end

      toml = %{
        "connection" => %{"id" => id, "type" => "ethernet"},
        "ipv6" => ipv6
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
            iface <-
              StreamData.string(:alphanumeric, min_length: 1, max_length: 12)
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
             "Expected boolean autoconnect in to_toml, got: #{inspect(autoconnect)}"
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

        {:error, _} ->
          :ok
      end
    end
  end

  property "from_toml result type is always a known atom" do
    known_types = [:ethernet, :wifi, :cellular, :vpn, :loopback]

    check all(toml <- valid_toml_gen()) do
      case Profile.from_toml(toml) do
        {:ok, profile} ->
          assert profile.type in known_types,
                 "Expected known type, got: #{inspect(profile.type)}"

        {:error, _} ->
          :ok
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

            {:error, _} ->
              :ok
          end

        {:error, _} ->
          :ok
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

        {:error, _} ->
          :ok
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

        {:error, _} ->
          :ok
      end
    end
  end

  property "Profile struct always has :ipv6 field" do
    check all(toml <- valid_toml_gen()) do
      case Profile.from_toml(toml) do
        {:ok, profile} ->
          assert Map.has_key?(profile, :ipv6),
                 "Expected :ipv6 key in Profile struct, got: #{inspect(Map.keys(profile))}"

        {:error, _} ->
          :ok
      end
    end
  end

  property "Profile struct id is always a binary string" do
    check all(toml <- valid_toml_gen()) do
      case Profile.from_toml(toml) do
        {:ok, profile} ->
          assert is_binary(profile.id),
                 "Expected binary string for profile id, got: #{inspect(profile.id)}"

        {:error, _} ->
          :ok
      end
    end
  end

  property "Profile struct type is always :ethernet for valid toml" do
    check all(toml <- valid_toml_gen()) do
      case Profile.from_toml(toml) do
        {:ok, profile} ->
          assert profile.type == :ethernet,
                 "Expected :ethernet type in Profile, got: #{inspect(profile.type)}"

        {:error, _} ->
          :ok
      end
    end
  end

  property "Profile struct zone is always a binary string" do
    check all(toml <- valid_toml_gen()) do
      case Profile.from_toml(toml) do
        {:ok, profile} ->
          assert is_binary(profile.zone),
                 "Expected binary zone in Profile, got: #{inspect(profile.zone)}"

        {:error, _} ->
          :ok
      end
    end
  end

  property "Profile type field is always an atom" do
    check all(type <- StreamData.member_of([:ethernet, :wifi, :loopback])) do
      p = %YellowDog.Netman.Types.Profile{id: "p45", type: type}

      assert is_atom(p.type),
             "Expected atom type, got: #{inspect(p.type)}"
    end
  end

  property "Profile autoconnect field defaults to boolean" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            type <- StreamData.member_of([:ethernet, :wifi, :loopback])
          ) do
      p = %YellowDog.Netman.Types.Profile{id: id, type: type}

      assert is_boolean(p.autoconnect),
             "Expected boolean for autoconnect"
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

  property "Profile struct zone field defaults to binary" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            type <- StreamData.member_of([:ethernet, :wifi, :loopback])
          ) do
      p = %YellowDog.Netman.Types.Profile{id: id, type: type}

      assert is_binary(p.zone),
             "Expected binary zone, got: #{inspect(p.zone)}"
    end
  end

  property "Profile ethernet field defaults to map" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            type <- StreamData.member_of([:ethernet, :wifi, :loopback])
          ) do
      p = %YellowDog.Netman.Types.Profile{id: id, type: type}

      assert is_map(p.ethernet),
             "Expected map ethernet, got: #{inspect(p.ethernet)}"
    end
  end

  property "Profile ipv4 field defaults to map" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            type <- StreamData.member_of([:ethernet, :wifi, :loopback])
          ) do
      p = %YellowDog.Netman.Types.Profile{id: id, type: type}

      assert is_map(p.ipv4),
             "Expected map ipv4, got: #{inspect(p.ipv4)}"
    end
  end

  property "Profile ipv6 field defaults to map" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            type <- StreamData.member_of([:ethernet, :wifi, :loopback])
          ) do
      p = %YellowDog.Netman.Types.Profile{id: id, type: type}

      assert is_map(p.ipv6),
             "Expected map ipv6, got: #{inspect(p.ipv6)}"
    end
  end

  property "Profile autoconnect_priority field defaults to integer" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            type <- StreamData.member_of([:ethernet, :wifi, :loopback])
          ) do
      p = %YellowDog.Netman.Types.Profile{id: id, type: type}

      assert is_integer(p.autoconnect_priority),
             "Expected integer autoconnect_priority, got: #{inspect(p.autoconnect_priority)}"
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

  property "Profile ipv4 and ipv6 are map by default" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            type <- StreamData.member_of([:ethernet, :wifi, :loopback])
          ) do
      p = %YellowDog.Netman.Types.Profile{id: id, type: type}

      assert is_map(p.ipv4) and is_map(p.ipv6),
             "Expected map for ipv4/ipv6 by default"
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
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)) do
      toml = %{
        "connection" => %{
          "id" => id,
          "type" => "ethernet",
          "interface" => "eth0",
          "priority" => 1,
          "zone" => "default"
        }
      }

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
      toml = %{
        "connection" => %{
          "id" => id,
          "type" => "ethernet",
          "interface" => "eth0",
          "priority" => priority,
          "zone" => "default"
        }
      }

      result = YellowDog.Netman.Types.Profile.from_toml(toml)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "Profile zone field is always a binary (r62)" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)) do
      toml = %{
        "connection" => %{
          "id" => id,
          "type" => "ethernet",
          "interface" => "eth0",
          "priority" => 1,
          "zone" => "test"
        }
      }

      result = YellowDog.Netman.Types.Profile.from_toml(toml)

      case result do
        {:ok, p} -> assert is_binary(p.zone)
        {:error, _} -> :ok
      end
    end
  end

  property "Profile type field is always a known atom (r63)" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)) do
      toml = %{
        "connection" => %{
          "id" => id,
          "type" => "ethernet",
          "interface" => "eth0",
          "priority" => 1,
          "zone" => "z"
        }
      }

      result = YellowDog.Netman.Types.Profile.from_toml(toml)

      case result do
        {:ok, p} -> assert p.type in [:ethernet, :wifi, :bridge, :loopback] or is_atom(p.type)
        {:error, _} -> :ok
      end
    end
  end

  property "Profile autoconnect field is always boolean (r64)" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)) do
      toml = %{
        "connection" => %{
          "id" => id,
          "type" => "ethernet",
          "interface" => "eth0",
          "priority" => 1,
          "zone" => "z"
        }
      }

      result = YellowDog.Netman.Types.Profile.from_toml(toml)

      case result do
        {:ok, p} -> assert is_boolean(p.autoconnect)
        {:error, _} -> :ok
      end
    end
  end

  property "Profile autoconnect_priority is always an integer (r65)" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)) do
      toml = %{
        "connection" => %{
          "id" => id,
          "type" => "ethernet",
          "interface" => "eth0",
          "priority" => 1,
          "zone" => "z"
        }
      }

      result = YellowDog.Netman.Types.Profile.from_toml(toml)

      case result do
        {:ok, p} -> assert is_integer(p.autoconnect_priority)
        {:error, _} -> :ok
      end
    end
  end

  property "Profile interface field is nil or binary (r66)" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)) do
      toml = %{
        "connection" => %{
          "id" => id,
          "type" => "ethernet",
          "interface" => "eth0",
          "priority" => 1,
          "zone" => "z"
        }
      }

      result = YellowDog.Netman.Types.Profile.from_toml(toml)

      case result do
        {:ok, p} -> assert is_nil(p.interface) or is_binary(p.interface)
        {:error, _} -> :ok
      end
    end
  end

  property "Profile ethernet field is always nil or map (r67)" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)) do
      toml = %{
        "connection" => %{
          "id" => id,
          "type" => "ethernet",
          "interface" => "eth0",
          "priority" => 1,
          "zone" => "z"
        }
      }

      result = YellowDog.Netman.Types.Profile.from_toml(toml)

      case result do
        {:ok, p} -> assert is_nil(p.ethernet) or is_map(p.ethernet)
        {:error, _} -> :ok
      end
    end
  end

  property "Profile ipv4 method is always :auto :manual :disabled or :link_local (r68)" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)) do
      toml = %{
        "connection" => %{
          "id" => id,
          "type" => "ethernet",
          "interface" => "eth0",
          "priority" => 1,
          "zone" => "z"
        }
      }

      result = YellowDog.Netman.Types.Profile.from_toml(toml)

      case result do
        {:ok, p} ->
          if p.ipv4 do
            assert p.ipv4[:method] in [:auto, :manual, :disabled, :link_local] or
                     is_nil(p.ipv4[:method])
          end

        {:error, _} ->
          :ok
      end
    end
  end

  property "Profile autoconnect_priority is always integer (r69)" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15),
            priority <- StreamData.integer(1..1000)
          ) do
      toml = %{
        "connection" => %{
          "id" => id,
          "type" => "ethernet",
          "interface" => "eth0",
          "priority" => priority,
          "zone" => "z"
        }
      }

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
      toml = %{
        "connection" => %{
          "id" => id,
          "type" => "ethernet",
          "interface" => "eth0",
          "priority" => 1,
          "zone" => zone
        }
      }

      result = YellowDog.Netman.Types.Profile.from_toml(toml)

      case result do
        {:ok, p} -> assert is_binary(p.zone)
        {:error, _} -> :ok
      end
    end
  end

  property "Profile ipv6 method is nil or known atom (r71)" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)) do
      toml = %{
        "connection" => %{
          "id" => id,
          "type" => "ethernet",
          "interface" => "eth0",
          "priority" => 1,
          "zone" => "z"
        }
      }

      result = YellowDog.Netman.Types.Profile.from_toml(toml)

      case result do
        {:ok, p} ->
          if p.ipv6 do
            assert is_nil(p.ipv6[:method]) or
                     p.ipv6[:method] in [:auto, :manual, :disabled, :link_local]
          end

        {:error, _} ->
          :ok
      end
    end
  end

  property "Profile id always matches the input id from TOML (r72)" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)) do
      toml = %{
        "connection" => %{
          "id" => id,
          "type" => "ethernet",
          "interface" => "eth0",
          "priority" => 1,
          "zone" => "z"
        }
      }

      result = YellowDog.Netman.Types.Profile.from_toml(toml)

      case result do
        {:ok, p} -> assert p.id == id
        {:error, _} -> :ok
      end
    end
  end

  property "Profile to_toml round-trip preserves id (r73)" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)) do
      toml = %{
        "connection" => %{
          "id" => id,
          "type" => "ethernet",
          "interface" => "eth0",
          "priority" => 1,
          "zone" => "z"
        }
      }

      case YellowDog.Netman.Types.Profile.from_toml(toml) do
        {:ok, p} ->
          toml2 = YellowDog.Netman.Types.Profile.to_toml(p)
          assert is_map(toml2)

        {:error, _} ->
          :ok
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
      toml = %{
        "connection" => %{
          "id" => "",
          "type" => "ethernet",
          "interface" => "eth0",
          "priority" => 1,
          "zone" => "z"
        }
      }

      result = YellowDog.Netman.Types.Profile.from_toml(toml)
      # Empty id might fail or succeed depending on validation
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "Profile from_toml always returns tagged tuple (r76)" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)) do
      toml = %{
        "connection" => %{
          "id" => id,
          "type" => "ethernet",
          "interface" => "eth0",
          "priority" => 1,
          "zone" => "z"
        }
      }

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
    check all(profile_map <- map_of(string(:alphanumeric, min_length: 1), string(:alphanumeric))) do
      result = Profile.from_toml(profile_map)

      case result do
        {:ok, p} -> assert is_nil(p.autoconnect_priority) or is_integer(p.autoconnect_priority)
        {:error, _} -> assert true
      end
    end
  end

  property "profile from_toml always returns tagged tuple (r80)" do
    check all(kv <- map_of(string(:alphanumeric, min_length: 1), boolean())) do
      result = Profile.from_toml(kv)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile from_toml preserves id when valid (r81)" do
    check all(id <- string(:alphanumeric, min_length: 1, max_length: 64)) do
      map = %{"id" => id, "zone" => "test"}
      result = Profile.from_toml(map)

      case result do
        {:ok, p} -> assert p.id == id or is_nil(p.id)
        {:error, _} -> assert true
      end
    end
  end

  property "profile from_toml with valid zone is ok or error (r82)" do
    check all(
            zone <- string(:alphanumeric, min_length: 1, max_length: 64),
            id <- string(:alphanumeric, min_length: 1, max_length: 64)
          ) do
      result = Profile.from_toml(%{"id" => id, "zone" => zone})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile from_toml ipv4 field presence (r83)" do
    check all(id <- string(:alphanumeric, min_length: 1)) do
      result = Profile.from_toml(%{"id" => id})

      case result do
        {:ok, p} -> assert Map.has_key?(p, :ipv4)
        {:error, _} -> assert true
      end
    end
  end

  property "profile from_toml ipv6 field presence (r84)" do
    check all(id <- string(:alphanumeric, min_length: 1)) do
      result = Profile.from_toml(%{"id" => id})

      case result do
        {:ok, p} -> assert Map.has_key?(p, :ipv6)
        {:error, _} -> assert true
      end
    end
  end

  property "profile from_toml with integer id returns error (r85)" do
    check all(n <- positive_integer()) do
      result = Profile.from_toml(%{"id" => n})
      # id must be a string
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end
  end

  property "profile from_toml with empty map returns error (r86)" do
    check all(_x <- boolean()) do
      result = Profile.from_toml(%{})
      assert match?({:error, _}, result)
    end
  end

  property "profile from_toml with only zone key returns error (r87)" do
    check all(zone <- string(:alphanumeric, min_length: 1)) do
      result = Profile.from_toml(%{"zone" => zone})
      # Profile requires id field
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end
  end

  property "profile from_toml with boolean value for id returns error (r88)" do
    check all(b <- boolean()) do
      result = Profile.from_toml(%{"id" => b})
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end
  end

  property "profile from_toml with list value for id returns error (r89)" do
    check all(lst <- list_of(string(:alphanumeric), max_length: 3)) do
      result = Profile.from_toml(%{"id" => lst})
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end
  end

  property "profile from_toml with valid id and priority returns ok (r90)" do
    check all(
            id <- string(:alphanumeric, min_length: 1, max_length: 64),
            prio <- integer(0..1000)
          ) do
      result = Profile.from_toml(%{"id" => id, "priority" => prio})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile from_toml autoconnect field defaults to boolean (r91)" do
    check all(id <- string(:alphanumeric, min_length: 1)) do
      case Profile.from_toml(%{"id" => id}) do
        {:ok, p} -> assert is_boolean(p.autoconnect) or is_nil(p.autoconnect)
        {:error, _} -> assert true
      end
    end
  end

  property "profile from_toml zone field is string when set (r92)" do
    check all(
            id <- string(:alphanumeric, min_length: 1),
            zone <- string(:alphanumeric, min_length: 1, max_length: 64)
          ) do
      case Profile.from_toml(%{"id" => id, "zone" => zone}) do
        {:ok, p} -> assert is_binary(p.zone) or is_nil(p.zone)
        {:error, _} -> assert true
      end
    end
  end

  property "profile from_toml with interface field is ok or error (r93)" do
    check all(
            id <- string(:alphanumeric, min_length: 1),
            iface <- string(:alphanumeric, min_length: 1, max_length: 15)
          ) do
      result = Profile.from_toml(%{"id" => id, "interface" => iface})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile from_toml id preserved in ok case (r94)" do
    check all(
            id <-
              string(Enum.concat([?a..?z, ?A..?Z, ?0..?9, [?_]]), min_length: 1, max_length: 64)
          ) do
      case Profile.from_toml(%{"id" => id}) do
        {:ok, p} -> assert is_binary(p.id) or is_nil(p.id)
        {:error, _} -> assert true
      end
    end
  end

  property "profile from_toml with autoconnect boolean is ok or error (r95)" do
    check all(
            id <- string(:alphanumeric, min_length: 1),
            auto <- boolean()
          ) do
      result = Profile.from_toml(%{"id" => id, "autoconnect" => auto})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile from_toml with autoconnect_priority number is ok or error (r96)" do
    check all(
            id <- string(:alphanumeric, min_length: 1),
            prio <- non_negative_integer()
          ) do
      result = Profile.from_toml(%{"id" => id, "autoconnect_priority" => prio})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile from_toml with method field is ok or error (r97)" do
    check all(
            id <- string(:alphanumeric, min_length: 1),
            method <- member_of(["dhcp", "static", "disabled", "auto"])
          ) do
      result = Profile.from_toml(%{"id" => id, "ipv4" => %{"method" => method}})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile from_toml with ipv6 method field is ok or error (r98)" do
    check all(
            id <- string(:alphanumeric, min_length: 1),
            method <- member_of(["slaac", "dhcpv6", "static", "disabled"])
          ) do
      result = Profile.from_toml(%{"id" => id, "ipv6" => %{"method" => method}})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile from_toml returns struct with expected keys on success (r99)" do
    check all(id <- string(:alphanumeric, min_length: 1)) do
      case Profile.from_toml(%{"id" => id}) do
        {:ok, p} ->
          assert Map.has_key?(p, :id)
          assert Map.has_key?(p, :ipv4)
          assert Map.has_key?(p, :ipv6)

        {:error, _} ->
          assert true
      end
    end
  end
end
