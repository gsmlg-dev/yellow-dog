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

  # --- MTU validation properties ---

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
end
