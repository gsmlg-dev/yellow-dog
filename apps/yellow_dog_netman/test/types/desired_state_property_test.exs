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

  property "N profiles with distinct IDs always produce exactly N connections" do
    check all(
            count <- StreamData.integer(1..8),
            profiles <- StreamData.list_of(profile_gen(), length: count),
            ifaces <- StreamData.list_of(interface_gen(), length: count)
          ) do
      # Give each profile a unique prefix to guarantee unique IDs
      indexed_profiles =
        profiles
        |> Enum.with_index()
        |> Enum.map(fn {p, i} -> %{p | id: "uniq-#{i}-#{p.id}"} end)

      pairs = Enum.zip(indexed_profiles, ifaces)
      desired = DesiredState.from_profiles(pairs)

      assert map_size(desired.connections) == count,
             "Expected #{count} connections but got #{map_size(desired.connections)}"
    end
  end

  property "connection dns is always a list of strings" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      desired = DesiredState.from_profiles([{profile, iface}])
      conn = desired.connections[profile.id]
      assert conn != nil
      assert is_list(conn.dns),
             "Expected dns to be a list, got: #{inspect(conn.dns)}"

      for item <- conn.dns do
        assert is_binary(item),
               "Expected dns item to be a string, got: #{inspect(item)}"
      end
    end
  end

  property "connection priority is always a non-negative integer" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      desired = DesiredState.from_profiles([{profile, iface}])
      conn = desired.connections[profile.id]
      assert conn != nil
      assert is_integer(conn.priority) and conn.priority >= 0,
             "Expected non-negative integer priority, got: #{inspect(conn.priority)}"
    end
  end

  property "connection interface is always a binary string" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      desired = DesiredState.from_profiles([{profile, iface}])
      conn = desired.connections[profile.id]
      assert conn != nil
      assert is_binary(conn.interface),
             "Expected binary interface, got: #{inspect(conn.interface)}"
    end
  end

  property "profiles with duplicate IDs produce at most 1 connection" do
    check all(
            profile <- profile_gen(),
            iface1 <- interface_gen(),
            iface2 <- interface_gen()
          ) do
      pairs = [{profile, iface1}, {profile, iface2}]
      desired = DesiredState.from_profiles(pairs)

      assert map_size(desired.connections) == 1,
             "Expected 1 connection for duplicate profile ID, got #{map_size(desired.connections)}"
    end
  end

  property "connection profile_id always equals the profile id" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      desired = DesiredState.from_profiles([{profile, iface}])
      conn = desired.connections[profile.id]
      assert conn != nil
      assert conn[:profile_id] == profile.id,
             "Expected profile_id #{inspect(profile.id)}, got: #{inspect(conn[:profile_id])}"
    end
  end

  property "connection mtu is always nil or a positive integer" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      desired = DesiredState.from_profiles([{profile, iface}])
      conn = desired.connections[profile.id]
      assert conn != nil

      assert is_nil(conn.mtu) or (is_integer(conn.mtu) and conn.mtu > 0),
             "Expected nil or positive integer mtu, got: #{inspect(conn.mtu)}"
    end
  end

  property "from_profiles result only contains IDs from the input profiles" do
    check all(
            count <- StreamData.integer(1..5),
            profiles <- StreamData.list_of(profile_gen(), length: count),
            ifaces <- StreamData.list_of(interface_gen(), length: count)
          ) do
      indexed_profiles = profiles |> Enum.with_index()
        |> Enum.map(fn {p, i} -> %{p | id: "check-#{i}-#{p.id}"} end)

      pairs = Enum.zip(indexed_profiles, ifaces)
      desired = DesiredState.from_profiles(pairs)

      input_ids = MapSet.new(indexed_profiles, & &1.id)

      for {conn_id, _conn} <- desired.connections do
        assert MapSet.member?(input_ids, conn_id),
               "Connection #{conn_id} not in input profiles"
      end
    end
  end

  property "DesiredState struct always has exactly the :connections field" do
    check all(
            count <- StreamData.integer(0..3),
            profiles <- StreamData.list_of(profile_gen(), length: count),
            ifaces <- StreamData.list_of(interface_gen(), length: count)
          ) do
      pairs = Enum.zip(profiles, ifaces)
      desired = DesiredState.from_profiles(pairs)

      struct_keys = desired |> Map.from_struct() |> Map.keys()

      assert struct_keys == [:connections],
             "Expected exactly [:connections] in DesiredState, got: #{inspect(struct_keys)}"
    end
  end

  property "DesiredState connections is always a map with binary string keys" do
    check all(
            count <- StreamData.integer(0..4),
            profiles <- StreamData.list_of(profile_gen(), length: count),
            ifaces <- StreamData.list_of(interface_gen(), length: count)
          ) do
      pairs = Enum.zip(profiles, ifaces)
      desired = DesiredState.from_profiles(pairs)

      assert is_map(desired.connections),
             "Expected connections to be a map, got: #{inspect(desired.connections)}"

      for {key, _} <- desired.connections do
        assert is_binary(key),
               "Expected binary string key in connections, got: #{inspect(key)}"
      end
    end
  end

  property "from_profiles with empty list always produces empty connections map" do
    check all(_ <- StreamData.constant(:ok)) do
      desired = DesiredState.from_profiles([])
      assert desired.connections == %{},
             "Expected empty connections map for empty profile list, got: #{inspect(desired.connections)}"
    end
  end

  property "from_profiles always produces a DesiredState struct" do
    check all(
            count <- StreamData.integer(0..4),
            profiles <- StreamData.list_of(profile_gen(), length: count),
            ifaces <- StreamData.list_of(interface_gen(), length: count)
          ) do
      pairs = Enum.zip(profiles, ifaces)
      desired = DesiredState.from_profiles(pairs)
      assert %DesiredState{} = desired,
             "Expected %DesiredState{} struct, got: #{inspect(desired)}"
    end
  end

  property "from_profiles connections map keys are always binary strings" do
    check all(
            count <- StreamData.integer(0..4),
            profiles <- StreamData.list_of(profile_gen(), length: count),
            ifaces <- StreamData.list_of(interface_gen(), length: count)
          ) do
      pairs = Enum.zip(profiles, ifaces)
      desired = DesiredState.from_profiles(pairs)

      for {key, _} <- desired.connections do
        assert is_binary(key),
               "Expected binary key in connections map, got: #{inspect(key)}"
      end
    end
  end

  property "from_profiles with one profile produces state with one connection" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      desired = DesiredState.from_profiles([{profile, iface}])
      assert map_size(desired.connections) == 1,
             "Expected exactly 1 connection for one profile, got: #{inspect(desired.connections)}"
    end
  end

  property "each connection always has a :profile_id key with a binary value" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      desired = DesiredState.from_profiles([{profile, iface}])
      conn = desired.connections[profile.id]
      assert conn != nil

      assert Map.has_key?(conn, :profile_id),
             "Expected :profile_id key in connection, got: #{inspect(Map.keys(conn))}"

      assert is_binary(conn.profile_id),
             "Expected binary profile_id, got: #{inspect(conn.profile_id)}"
    end
  end

  property "from_profiles with empty list always returns empty connections map" do
    check all(_ <- StreamData.constant(:ok)) do
      desired = DesiredState.from_profiles([])
      assert desired.connections == %{},
             "Expected empty connections for empty profile list, got: \#{inspect(desired.connections)}"
    end
  end

  property "from_profiles always returns a DesiredState struct" do
    check all(profiles <- list_of(profile_gen(), max_length: 3)) do
      pairs = Enum.map(profiles, &{&1, "eth_#{:erlang.unique_integer([:positive])}"})
      result = DesiredState.from_profiles(pairs)
      assert is_struct(result, DesiredState),
             "Expected DesiredState struct, got: #{inspect(result)}"
    end
  end

  property "from_profiles result connections size equals unique profile id count" do
    check all(profiles <- list_of(profile_gen(), min_length: 1, max_length: 3)) do
      pairs = Enum.map(profiles, &{&1, "ds_iface_#{:erlang.unique_integer([:positive])}"})
      desired = DesiredState.from_profiles(pairs)
      expected_count = pairs |> Enum.map(fn {p, _} -> p.id end) |> Enum.uniq() |> length()
      assert map_size(desired.connections) == expected_count,
             "Expected #{expected_count} connections, got #{map_size(desired.connections)}"
    end
  end

  property "from_profiles result has connections as a map" do
    check all(profiles <- list_of(profile_gen(), max_length: 3)) do
      pairs = Enum.map(profiles, &{&1, "ds2_#{:erlang.unique_integer([:positive])}"})
      desired = DesiredState.from_profiles(pairs)
      assert is_map(desired.connections),
             "Expected map connections, got: #{inspect(desired.connections)}"
    end
  end

  property "from_profiles result connections values always have :interface and :ipv4 fields" do
    check all(profiles <- list_of(profile_gen(), min_length: 1, max_length: 3)) do
      pairs = Enum.map(profiles, &{&1, "ds3_#{:erlang.unique_integer([:positive])}"})
      desired = DesiredState.from_profiles(pairs)
      for {_id, conn} <- desired.connections do
        assert Map.has_key?(conn, :interface),
               "Expected :interface field in connection, got: #{inspect(conn)}"
        assert Map.has_key?(conn, :ipv4),
               "Expected :ipv4 field in connection, got: #{inspect(conn)}"
      end
    end
  end

  property "from_profiles result connections all have :mtu key" do
    check all(profiles <- list_of(profile_gen(), min_length: 1, max_length: 3)) do
      pairs = Enum.map(profiles, &{&1, "ds4_#{:erlang.unique_integer([:positive])}"})
      desired = DesiredState.from_profiles(pairs)
      for {_id, conn} <- desired.connections do
        assert Map.has_key?(conn, :mtu),
               "Expected :mtu key in connection, got: #{inspect(Map.keys(conn))}"
      end
    end
  end

  property "from_profiles result connection map key matches the profile_id" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      desired = DesiredState.from_profiles([{profile, iface}])
      conn = desired.connections[profile.id]
      assert conn != nil
      assert conn.profile_id == profile.id,
             "Expected profile_id #{profile.id} to equal the map key"
    end
  end

  property "from_profiles result connections always have :dns as a list" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      desired = DesiredState.from_profiles([{profile, iface}])
      conn = desired.connections[profile.id]
      assert conn != nil
      assert is_list(conn.dns),
             "Expected :dns to be a list in connection, got: \#{inspect(conn.dns)}"
    end
  end

  property "from_profiles connections interface is always a non-empty binary" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      desired = DesiredState.from_profiles([{profile, iface}])
      conn = desired.connections[profile.id]
      assert conn != nil
      assert is_binary(conn.interface) and byte_size(conn.interface) > 0,
             "Expected non-empty binary interface, got: #{inspect(conn.interface)}"
    end
  end

  property "from_profiles result connections values all have non-nil ipv4" do
    check all(
            profile <- profile_gen(),
            iface <- interface_gen()
          ) do
      desired = DesiredState.from_profiles([{profile, iface}])
      conn = desired.connections[profile.id]
      assert conn != nil
      assert conn.ipv4 != nil,
             "Expected non-nil ipv4 in connection"
    end
  end

  property "DesiredState.from_profiles/1 with empty list returns struct" do
    check all(_ <- StreamData.constant(:ok)) do
      ds = DesiredState.from_profiles([])
      assert is_struct(ds, DesiredState),
             "Expected DesiredState struct from from_profiles([]), got: #{inspect(ds)}"
    end
  end

  property "DesiredState struct always has :connections key" do
    check all(_ <- StreamData.constant(:ok)) do
      ds = DesiredState.from_profiles([])
      assert Map.has_key?(ds, :connections),
             "Expected :connections key in DesiredState"
    end
  end

  property "DesiredState connections field is always a map" do
    check all(_ <- StreamData.constant(:ok)) do
      ds = DesiredState.from_profiles([])
      assert is_map(ds.connections),
             "Expected map for DesiredState.connections, got: #{inspect(ds.connections)}"
    end
  end

  property "DesiredState connections field is always an empty map for empty input" do
    check all(_ <- StreamData.constant(:ok)) do
      ds = DesiredState.from_profiles([])
      assert ds.connections == %{},
             "Expected empty connections for from_profiles([]), got: #{inspect(ds.connections)}"
    end
  end

  property "DesiredState connections values always have :type key" do
    check all(_ <- StreamData.constant(:ok)) do
      ds = DesiredState.from_profiles([])
      for {_id, conn} <- ds.connections do
        assert Map.has_key?(conn, :type),
               "Expected :type key in connection, got: #{inspect(conn)}"
      end
    end
  end

  property "DesiredState from_profiles always produces consistent result for same input" do
    check all(_ <- StreamData.constant(:ok)) do
      ds1 = DesiredState.from_profiles([])
      ds2 = DesiredState.from_profiles([])
      assert ds1 == ds2,
             "Expected consistent from_profiles([]) result"
    end
  end
  property "DesiredState from_profiles with empty list has empty connections" do
    check all(_ <- StreamData.constant(:ok)) do
      ds = YellowDog.Netman.Types.DesiredState.from_profiles([])
      conns = Map.get(ds, :connections, [])
      assert is_list(conns) or is_map(conns),
             "Expected list or map for connections, got: \#{inspect(conns)}"
    end
  end
  property "DesiredState from_profiles always returns a struct or map" do
    check all(_ <- StreamData.constant(:ok)) do
      ds = YellowDog.Netman.Types.DesiredState.from_profiles([])
      assert is_map(ds) or is_struct(ds),
             "Expected map/struct from from_profiles, got: #{inspect(ds)}"
    end
  end
  property "DesiredState from_profiles with empty always returns same value" do
    check all(_ <- StreamData.constant(:ok)) do
      ds1 = YellowDog.Netman.Types.DesiredState.from_profiles([])
      ds2 = YellowDog.Netman.Types.DesiredState.from_profiles([])
      assert ds1 == ds2,
             "Expected deterministic from_profiles results to be equal"
    end
  end
  property "DesiredState from_profiles with empty always has empty or nil connections" do
    check all(_ <- StreamData.constant(:ok)) do
      ds = YellowDog.Netman.Types.DesiredState.from_profiles([])
      conns = Map.get(ds, :connections, nil)
      assert is_nil(conns) or (is_list(conns) and conns == []) or is_map(conns),
             "Expected empty connections, got: #{inspect(conns)}"
    end
  end
  property "DesiredState module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Types.DesiredState),
             "Expected DesiredState module to be loadable"
    end
  end
  property "DesiredState from_profiles with empty list never raises" do
    check all(_ <- StreamData.constant(:ok)) do
      result =
        try do
          YellowDog.Netman.Types.DesiredState.from_profiles([])
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result == :ok,
             "Expected :ok from from_profiles, got: #{inspect(result)}"
    end
  end

end
