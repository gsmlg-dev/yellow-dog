defmodule YellowDog.Netman.Types.DesiredStatePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias YellowDog.Netman.Types.{DesiredState, Profile}

  defp profile_gen do
    gen all(
          id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
          priority <- StreamData.integer(0..1000),
          mtu <-
            StreamData.one_of([
              StreamData.constant(nil),
              StreamData.integer(68..65535)
            ]),
          dns_count <- StreamData.integer(0..3),
          octets <- StreamData.list_of(StreamData.integer(1..254), length: dns_count)
        ) do
      dns = Enum.map(octets, &"8.8.#{&1}.#{&1}")

      %Profile{
        id: "profile-#{id}",
        type: :ethernet,
        autoconnect: true,
        autoconnect_priority: priority,
        ethernet: %{mtu: mtu},
        ipv4: %{method: :auto, address: nil, gateway: nil, dns: dns},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }
    end
  end

  defp interface_gen do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
    |> StreamData.map(&"eth#{&1}")
  end

  property "connection count never exceeds input profile count" do
    check all(
            count <- StreamData.integer(0..10),
            profiles <- StreamData.list_of(profile_gen(), length: count),
            ifaces <- StreamData.list_of(interface_gen(), length: count)
          ) do
      pairs = Enum.zip(profiles, ifaces)
      desired = DesiredState.from_profiles(pairs)
      assert map_size(desired.connections) <= count
    end
  end

  property "each connection preserves its profile's priority" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      desired = DesiredState.from_profiles([{profile, iface}])
      conn = desired.connections[profile.id]
      assert conn.priority == profile.autoconnect_priority
    end
  end

  property "each connection preserves its profile's MTU" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      desired = DesiredState.from_profiles([{profile, iface}])
      conn = desired.connections[profile.id]
      assert conn.mtu == profile.ethernet.mtu
    end
  end

  property "connection DNS is the concatenation of IPv4 and IPv6 DNS" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      desired = DesiredState.from_profiles([{profile, iface}])
      conn = desired.connections[profile.id]

      expected_dns =
        (profile.ipv4.dns || []) ++ (profile.ipv6.dns || [])

      assert conn.dns == expected_dns
    end
  end

  property "connection interface matches the paired interface, not profile.interface" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      desired = DesiredState.from_profiles([{profile, iface}])
      conn = desired.connections[profile.id]
      assert conn.interface == iface
    end
  end

  property "unique profile IDs produce unique connections" do
    check all(
            p1 <- profile_gen(),
            p2 <- profile_gen(),
            i1 <- interface_gen(),
            i2 <- interface_gen()
          ) do
      # Ensure unique IDs
      p1 = %{p1 | id: "a-#{p1.id}"}
      p2 = %{p2 | id: "b-#{p2.id}"}

      desired = DesiredState.from_profiles([{p1, i1}, {p2, i2}])
      assert map_size(desired.connections) == 2
      assert Map.has_key?(desired.connections, p1.id)
      assert Map.has_key?(desired.connections, p2.id)
    end
  end

  property "connection ipv4 config is preserved exactly from profile" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      desired = DesiredState.from_profiles([{profile, iface}])
      conn = desired.connections[profile.id]
      assert conn.ipv4 == profile.ipv4
    end
  end

  property "from_profiles with empty list produces empty desired state" do
    check all(_ <- StreamData.constant(nil)) do
      desired = DesiredState.from_profiles([])
      assert desired.connections == %{}
    end
  end

  property "connection profile_id always matches the profile's id" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      desired = DesiredState.from_profiles([{profile, iface}])
      conn = desired.connections[profile.id]
      assert conn != nil
      assert conn.profile_id == profile.id
    end
  end

  property "connection ipv6 config is preserved exactly from profile" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      desired = DesiredState.from_profiles([{profile, iface}])
      conn = desired.connections[profile.id]
      assert conn.ipv6 == profile.ipv6
    end
  end

  property "autoconnect: false profiles still appear in desired state" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      non_autoconnect = %{profile | autoconnect: false}
      desired = DesiredState.from_profiles([{non_autoconnect, iface}])
      # Profiles with autoconnect: false are still included — activation is decided by the FSM
      conn = desired.connections[non_autoconnect.id]
      assert conn != nil,
             "autoconnect: false profile #{non_autoconnect.id} missing from desired state"
    end
  end

  property "each connection always has all required keys" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      desired = DesiredState.from_profiles([{profile, iface}])
      conn = desired.connections[profile.id]
      assert conn != nil

      for key <- [:profile_id, :interface, :ipv4, :ipv6, :mtu, :priority, :dns] do
        assert Map.has_key?(conn, key), "Connection missing required key: #{key}"
      end
    end
  end
end
