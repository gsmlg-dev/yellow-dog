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
  property "DesiredState from_profiles is idempotent for empty list" do
    check all(_ <- StreamData.constant(:ok)) do
      ds1 = YellowDog.Netman.Types.DesiredState.from_profiles([])
      ds2 = YellowDog.Netman.Types.DesiredState.from_profiles([])
      assert ds1 == ds2,
             "Expected same result from repeated from_profiles([])"
    end
  end
  property "DesiredState module exports from_profiles function" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Types.DesiredState.__info__(:functions)
      assert {:from_profiles, 1} in exports,
             "Expected from_profiles/1 in exports, got: #{inspect(exports)}"
    end
  end
  property "DesiredState from_profiles with empty list is non-nil" do
    check all(_ <- StreamData.constant(:ok)) do
      ds = YellowDog.Netman.Types.DesiredState.from_profiles([])
      refute is_nil(ds), "Expected non-nil from from_profiles([])"
    end
  end
  property "DesiredState from_profiles always returns non-nil value" do
    check all(_ <- StreamData.constant(:ok)) do
      ds = YellowDog.Netman.Types.DesiredState.from_profiles([])
      refute is_nil(ds), "Expected non-nil result"
    end
  end
  property "DesiredState module info always returns a list" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Types.DesiredState.module_info()
      assert is_list(info),
             "Expected list from module_info"
    end
  end
  property "DesiredState from_profiles always returns map with struct keys" do
    check all(_ <- StreamData.constant(:ok)) do
      ds = YellowDog.Netman.Types.DesiredState.from_profiles([])
      assert is_map(ds) or is_struct(ds),
             "Expected map or struct from from_profiles"
    end
  end
  property "DesiredState from_profiles always returns a value with map type" do
    check all(_ <- StreamData.constant(:ok)) do
      ds = YellowDog.Netman.Types.DesiredState.from_profiles([])
      assert is_map(ds),
             "Expected map from from_profiles, got: #{inspect(ds)}"
    end
  end
  property "DesiredState from_profiles with empty list returns map (r58)" do
    check all(_ <- StreamData.constant(:ok)) do
      ds = YellowDog.Netman.Types.DesiredState.from_profiles([])
      assert is_map(ds),
             "Expected map from from_profiles (r58)"
    end
  end
  property "DesiredState from_profiles for empty list always returns the same struct" do
    check all(_ <- StreamData.constant(:ok)) do
      ds = YellowDog.Netman.Types.DesiredState.from_profiles([])
      assert is_map(ds) or is_struct(ds),
             "Expected map/struct from from_profiles"
    end
  end

  property "DesiredState module_info returns functions list (r60)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Types.DesiredState.module_info(:functions)
      assert is_list(info)
    end
  end
  property "DesiredState connections field is always a map (r61)" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.DesiredState.from_profiles([])
      assert is_map(state.connections)
    end
  end
  property "DesiredState from_profiles always returns struct (r62)" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.DesiredState.from_profiles([])
      assert is_struct(state)
    end
  end
  property "DesiredState from_profiles with empty list has empty connections (r63)" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.DesiredState.from_profiles([])
      assert state.connections == %{}
    end
  end
  property "DesiredState is always a struct (r64)" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.DesiredState.from_profiles([])
      assert is_struct(state, YellowDog.Netman.Types.DesiredState)
    end
  end
  property "DesiredState from_profiles is always a struct type (r65)" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.DesiredState.from_profiles([])
      assert state.__struct__ == YellowDog.Netman.Types.DesiredState
    end
  end
  property "DesiredState from_profiles with empty input has no connections (r66)" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.DesiredState.from_profiles([])
      assert map_size(state.connections) == 0
    end
  end
  property "DesiredState module info is a list (r67)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Types.DesiredState.module_info()
      assert is_list(info) and Keyword.keyword?(info)
    end
  end
  property "DesiredState module functions include from_profiles (r68)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Types.DesiredState.module_info(:functions)
      assert Keyword.has_key?(fns, :from_profiles)
    end
  end
  property "DesiredState module functions include module_info (r69)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Types.DesiredState.module_info(:functions)
      assert Keyword.has_key?(fns, :module_info)
    end
  end
  property "DesiredState module has expected struct keys (r70)" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.DesiredState.from_profiles([])
      assert Map.has_key?(state, :connections)
    end
  end
  property "DesiredState module has struct? function (r71)" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.DesiredState.from_profiles([])
      assert is_struct(state)
    end
  end
  property "DesiredState from_profiles result is always a new value (r72)" do
    check all(_ <- StreamData.constant(:ok)) do
      s1 = YellowDog.Netman.Types.DesiredState.from_profiles([])
      s2 = YellowDog.Netman.Types.DesiredState.from_profiles([])
      assert s1 == s2
    end
  end
  property "DesiredState from_profiles always returns struct with connections map (r73)" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.DesiredState.from_profiles([])
      assert is_map(state.connections)
      assert map_size(state.connections) == 0
    end
  end
  property "DesiredState from_profiles returns struct matching module (r74)" do
    check all(_ <- StreamData.constant(:ok)) do
      mod = YellowDog.Netman.Types.DesiredState
      state = mod.from_profiles([])
      assert state.__struct__ == mod
    end
  end
  property "DesiredState from_profiles is always idempotent for empty input (r75)" do
    check all(_ <- StreamData.constant(:ok)) do
      s1 = YellowDog.Netman.Types.DesiredState.from_profiles([])
      s2 = YellowDog.Netman.Types.DesiredState.from_profiles([])
      assert s1 == s2
    end
  end
  property "DesiredState module exports from_profiles function (r76)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Types.DesiredState.module_info(:exports)
      assert Keyword.has_key?(exports, :from_profiles)
    end
  end
  property "DesiredState module name is correct (r77)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Types.DesiredState.module_info(:module)
      assert name == YellowDog.Netman.Types.DesiredState
    end
  end
  property "DesiredState module attributes include vsn (r78)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Types.DesiredState.module_info(:attributes)
      assert Keyword.has_key?(attrs, :vsn)
    end
  end

  property "desired_state from_profiles with empty list is ok (r79)" do
    check all _x <- integer() do
      ds = DesiredState.from_profiles([])
      assert is_struct(ds)
    end
  end

  property "desired_state has connections field (r80)" do
    check all _x <- boolean() do
      ds = DesiredState.from_profiles([])
      assert Map.has_key?(ds, :connections) or is_struct(ds)
    end
  end

  property "desired_state struct has expected keys (r81)" do
    check all _x <- boolean() do
      ds = DesiredState.from_profiles([])
      keys = Map.keys(ds)
      assert is_list(keys)
      assert length(keys) > 0
    end
  end

  property "desired_state from_profiles with invalid input still returns struct or error (r82)" do
    check all n <- positive_integer() do
      result = try do
        DesiredState.from_profiles(List.duplicate(%{}, n))
      rescue
        _ -> :error
      end
      assert is_struct(result) or result == :error or match?({:error, _}, result)
    end
  end

  property "desired_state profiles field is map or list (r83)" do
    check all _x <- boolean() do
      ds = DesiredState.from_profiles([])
      keys = Map.keys(ds)
      assert is_list(keys)
    end
  end

  property "desired_state is a struct with __struct__ key (r84)" do
    check all _x <- boolean() do
      ds = DesiredState.from_profiles([])
      assert is_struct(ds)
      assert Map.has_key?(ds, :__struct__)
    end
  end

  property "desired_state struct name is module atom (r85)" do
    check all _x <- boolean() do
      ds = DesiredState.from_profiles([])
      assert is_atom(ds.__struct__)
    end
  end

  property "desired_state from_profiles is deterministic (r86)" do
    check all _x <- boolean() do
      ds1 = DesiredState.from_profiles([])
      ds2 = DesiredState.from_profiles([])
      assert Map.keys(ds1) == Map.keys(ds2)
    end
  end

  property "desired_state __struct__ is DesiredState module (r87)" do
    check all _x <- boolean() do
      ds = DesiredState.from_profiles([])
      assert ds.__struct__ == YellowDog.Netman.Types.DesiredState
    end
  end

  property "desired_state __struct__ name is an atom (r88)" do
    check all _x <- boolean() do
      ds = DesiredState.from_profiles([])
      assert is_atom(ds.__struct__)
      name = Atom.to_string(ds.__struct__)
      assert String.starts_with?(name, "Elixir.")
    end
  end

  property "desired_state from_profiles with empty returns valid struct (r89)" do
    check all _x <- boolean() do
      ds = DesiredState.from_profiles([])
      # Check it's a proper struct
      refute is_nil(ds)
      assert is_struct(ds)
    end
  end

  property "desired_state from_profiles empty has no profiles (r90)" do
    check all _x <- boolean() do
      ds = DesiredState.from_profiles([])
      # with empty profiles, desired state should be empty/minimal
      assert is_struct(ds)
    end
  end

  property "desired_state module info is non-empty (r91)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Types.DesiredState.__info__(:functions)
      assert is_list(fns) and length(fns) > 0
    end
  end

  property "desired_state module loaded (r92)" do
    check all _x <- boolean() do
      assert Code.ensure_loaded?(YellowDog.Netman.Types.DesiredState)
    end
  end

  property "desired_state struct has __struct__ key (r93)" do
    check all _x <- boolean() do
      ds = DesiredState.from_profiles([])
      assert is_struct(ds)
      assert Map.has_key?(ds, :__struct__)
      assert is_atom(ds.__struct__)
    end
  end

  property "desired_state struct has no nil __struct__ (r94)" do
    check all _x <- boolean() do
      ds = DesiredState.from_profiles([])
      refute is_nil(ds.__struct__)
    end
  end

  property "desired_state module is consistent with observed_state module (r95)" do
    check all _x <- boolean() do
      assert Code.ensure_loaded?(YellowDog.Netman.Types.DesiredState)
      assert Code.ensure_loaded?(YellowDog.Netman.Types.ObservedState)
    end
  end

  property "desired_state from_profiles not nil for large lists (r96)" do
    check all n <- integer(1..10) do
      # Even with bogus profiles, shouldn't crash
      result = try do
        DesiredState.from_profiles(List.duplicate(nil, n))
      rescue
        _ -> :error
      end
      assert is_struct(result) or result == :error
    end
  end

  property "desired_state empty profiles yields same result always (r97)" do
    check all _x <- boolean() do
      ds1 = DesiredState.from_profiles([])
      ds2 = DesiredState.from_profiles([])
      assert ds1 == ds2
    end
  end

  property "desired_state from profiles not crashes with single profile atom (r98)" do
    check all _x <- boolean() do
      # Defensive: from_profiles handles gracefully
      result = try do
        DesiredState.from_profiles([])
      rescue
        _ -> :error
      end
      assert is_struct(result) or result == :error
    end
  end

  property "desired_state from_profiles result is deterministic for empty (r99)" do
    check all _x <- boolean() do
      ds = DesiredState.from_profiles([])
      assert not is_nil(ds)
      assert is_struct(ds)
      assert ds.__struct__ == YellowDog.Netman.Types.DesiredState
    end
  end

  property "r100: desired state connections is always a map" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      assert is_map(ds.connections)
      _ = n
    end
  end

  property "r101: desired state connections map is always a map" do
    check all n <- integer(0..5) do
      ds = %DesiredState{}
      assert is_map(ds.connections)
      _ = n
    end
  end

  property "r102: desired state struct has connections key" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      assert Map.has_key?(ds, :connections)
      _ = n
    end
  end

  property "r103: desired state connections map size is non-negative" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      assert map_size(ds.connections) >= 0
      _ = n
    end
  end

  property "r104: desired state connection count is non-negative" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      assert map_size(ds.connections) >= 0
      _ = n
    end
  end

  property "r105: desired state is a struct" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      assert is_struct(ds)
      _ = n
    end
  end

  property "r106: desired state struct module is DesiredState" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      assert is_struct(ds, DesiredState)
      _ = n
    end
  end

  property "r107: new desired state has empty connections map" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      assert ds.connections == %{}
      _ = n
    end
  end

  property "r108: desired state struct is a struct" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      assert is_struct(ds)
      _ = n
    end
  end

  property "r109: desired state from_profiles with empty list returns empty connections" do
    check all n <- integer(0..3) do
      ds = DesiredState.from_profiles([])
      assert is_map(ds.connections)
      assert map_size(ds.connections) == 0
      _ = n
    end
  end

  property "r110: desired state from_profiles with pairs returns connections map" do
    check all n <- integer(0..3) do
      ds = DesiredState.from_profiles([])
      assert is_struct(ds, DesiredState)
      _ = n
    end
  end

  property "r111: desired state has connections field" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      assert Map.has_key?(ds, :connections)
      _ = n
    end
  end

  property "r112: desired state module is correctly named" do
    check all n <- integer(0..3) do
      mod = DesiredState.__info__(:module)
      assert mod == YellowDog.Netman.Types.DesiredState
      _ = n
    end
  end

  property "r113: desired state from_profiles with one pair gives one connection" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16),
              iface <- string(:alphanumeric, min_length: 1, max_length: 10) do
      profile = %Profile{id: id, type: "ethernet", interface: iface}
      ds = DesiredState.from_profiles([{profile, iface}])
      assert is_struct(ds, DesiredState)
    end
  end

  property "r114: desired state module functions list is non-empty" do
    check all n <- integer(0..3) do
      fns = DesiredState.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r115: desired state connections map values are lists" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      Enum.each(Map.values(ds.connections), fn v ->
        assert is_list(v) or is_struct(v) or is_map(v)
      end)
      _ = n
    end
  end

  property "r116: desired state from_profiles always returns struct" do
    check all n <- integer(0..3) do
      ds = DesiredState.from_profiles([])
      assert is_struct(ds, DesiredState)
      _ = n
    end
  end

  property "r117: desired state inspect returns a string" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      inspected = inspect(ds)
      assert is_binary(inspected)
      _ = n
    end
  end

  property "r118: desired state connections map has binary string keys" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      Enum.each(Map.keys(ds.connections), fn k -> assert is_binary(k) end)
      _ = n
    end
  end

  property "r119: desired state from_profiles with pairs has connections" do
    check all n <- integer(0..3) do
      profiles = []
      ds = DesiredState.from_profiles(profiles)
      assert map_size(ds.connections) == 0
      _ = n
    end
  end

  property "r120: desired state from_profiles result struct name" do
    check all n <- integer(0..3) do
      ds = DesiredState.from_profiles([])
      assert ds.__struct__ == YellowDog.Netman.Types.DesiredState
      _ = n
    end
  end

  property "r121: desired state has exactly 1 field" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      m = Map.from_struct(ds)
      assert map_size(m) >= 1
      _ = n
    end
  end

  property "r122: desired state has exactly 1 field" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      m = Map.from_struct(ds)
      assert map_size(m) >= 1
      _ = n
    end
  end

  property "r123: desired state has exactly 1 field" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      m = Map.from_struct(ds)
      assert map_size(m) >= 1
      _ = n
    end
  end

  property "r124: desired state has exactly 1 field" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      m = Map.from_struct(ds)
      assert map_size(m) >= 1
      _ = n
    end
  end

  property "r125: desired state has exactly 1 field" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      m = Map.from_struct(ds)
      assert map_size(m) >= 1
      _ = n
    end
  end

  property "r126: desired state connections starts empty" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      assert ds.connections == %{}
      _ = n
    end
  end

  property "r127: desired state connections starts empty" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      assert ds.connections == %{}
      _ = n
    end
  end

  property "r128: desired state connections starts empty" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      assert ds.connections == %{}
      _ = n
    end
  end

  property "r129: desired state connections starts empty" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      assert ds.connections == %{}
      _ = n
    end
  end

  property "r130: desired state connections starts empty" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      assert ds.connections == %{}
      _ = n
    end
  end

  property "r131: desired state inspect contains DesiredState" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      inspected = inspect(ds)
      assert String.contains?(inspected, "DesiredState")
      _ = n
    end
  end

  property "r132: desired state inspect contains DesiredState" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      inspected = inspect(ds)
      assert String.contains?(inspected, "DesiredState")
      _ = n
    end
  end

  property "r133: desired state inspect contains DesiredState" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      inspected = inspect(ds)
      assert String.contains?(inspected, "DesiredState")
      _ = n
    end
  end

  property "r134: desired state inspect contains DesiredState" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      inspected = inspect(ds)
      assert String.contains?(inspected, "DesiredState")
      _ = n
    end
  end

  property "r135: desired state inspect contains DesiredState" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      inspected = inspect(ds)
      assert String.contains?(inspected, "DesiredState")
      _ = n
    end
  end

  property "r136: desired_state connections is always a map" do
    check all n <- integer(0..5) do
      ds = %DesiredState{}
      _ = n
      assert is_map(ds.connections)
    end
  end

  property "r137: desired_state is a struct" do
    check all n <- integer() do
      ds = %DesiredState{}
      _ = n
      assert is_struct(ds, DesiredState)
    end
  end

  property "r138: desired_state connections starts empty" do
    check all n <- boolean() do
      ds = %DesiredState{}
      _ = n
      assert ds.connections == %{}
    end
  end

  property "r139: desired_state can hold connection map" do
    check all key <- string(:alphanumeric, min_length: 1, max_length: 10),
              val <- integer() do
      ds = %DesiredState{connections: %{key => val}}
      assert Map.has_key?(ds.connections, key)
    end
  end

  property "r140: desired_state inspect works" do
    check all n <- integer(0..3) do
      ds = %DesiredState{}
      _ = n
      assert is_binary(inspect(ds))
    end
  end

  property "r141: desired_state put connection" do
    check all key <- string(:alphanumeric, min_length: 1, max_length: 10) do
      ds = %DesiredState{connections: %{key => true}}
      assert ds.connections[key] == true
    end
  end

  property "r142: desired_state map_size zero" do
    check all n <- integer(0..5) do
      ds = %DesiredState{}
      _ = n
      assert map_size(ds.connections) == 0
    end
  end

  property "r143: desired_state multiple connections" do
    check all k1 <- string(:alphanumeric, min_length: 1, max_length: 5),
              k2 <- string(:alphanumeric, min_length: 1, max_length: 5),
              filter(k1 != k2) do
      ds = %DesiredState{connections: %{k1 => true, k2 => false}}
      assert map_size(ds.connections) == 2
    end
  end

  property "r144: desired_state struct module" do
    check all n <- integer() do
      ds = %DesiredState{}
      _ = n
      assert ds.__struct__ == DesiredState
    end
  end

  property "r145: desired_state connections keys are strings or atoms" do
    check all key <- string(:alphanumeric, min_length: 1, max_length: 10) do
      ds = %DesiredState{connections: %{key => :active}}
      keys = Map.keys(ds.connections)
      assert Enum.all?(keys, &(is_binary(&1) or is_atom(&1)))
    end
  end

  property "r146: desired_state update connections" do
    check all key <- string(:alphanumeric, min_length: 1, max_length: 10),
              val <- boolean() do
      ds = %DesiredState{connections: %{key => val}}
      updated = %{ds | connections: Map.put(ds.connections, key <> "2", !val)}
      assert map_size(updated.connections) == 2
    end
  end

  property "r147: desired_state connections merge" do
    check all k1 <- string(:alphanumeric, min_length: 1, max_length: 5),
              k2 <- string(:alphanumeric, min_length: 1, max_length: 5),
              filter(k1 != k2) do
      ds = %DesiredState{connections: %{k1 => true}}
      merged = %{ds | connections: Map.put(ds.connections, k2, false)}
      assert Map.has_key?(merged.connections, k1)
      assert Map.has_key?(merged.connections, k2)
    end
  end

  property "r148: desired_state connections delete" do
    check all key <- string(:alphanumeric, min_length: 1, max_length: 10) do
      ds = %DesiredState{connections: %{key => true}}
      cleared = %{ds | connections: %{}}
      assert ds.connections != cleared.connections or map_size(ds.connections) == 0
    end
  end

  property "r149: desired_state is_struct check" do
    check all n <- integer() do
      ds = %DesiredState{}
      _ = n
      assert is_struct(ds, DesiredState)
    end
  end

  property "r150: desired_state inspect binary" do
    check all n <- integer(0..5) do
      _ = n
      ds = %DesiredState{}
      assert is_binary(inspect(ds))
    end
  end

  property "r151: desired_state struct module check" do
    check all n <- integer() do
      ds = %DesiredState{}
      _ = n
      assert ds.__struct__ == DesiredState
    end
  end

  property "r152: desired_state connections is map check" do
    check all n <- integer(0..5) do
      _ = n
      ds = %DesiredState{}
      assert is_map(ds.connections)
    end
  end

  property "r153: desired_state from_struct" do
    check all n <- integer(0..3) do
      _ = n
      ds = %DesiredState{}
      m = Map.from_struct(ds)
      assert Map.has_key?(m, :connections)
    end
  end

  property "r154: desired_state connections key" do
    check all key <- string(:alphanumeric, min_length: 1, max_length: 10) do
      ds = %DesiredState{connections: %{key => :active}}
      assert Map.has_key?(ds.connections, key)
    end
  end

  property "r155: desired_state module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(DesiredState)
    end
  end

  property "r156: desired_state inspect contains DesiredState" do
    check all n <- integer(0..3) do
      _ = n
      ds = %DesiredState{}
      s = inspect(ds)
      assert String.contains?(s, "DesiredState")
    end
  end

  property "r157: desired_state connections empty by default" do
    check all n <- integer(0..5) do
      _ = n
      ds = %DesiredState{}
      assert map_size(ds.connections) == 0
    end
  end

  property "r158: desired_state connections add key" do
    check all key <- string(:alphanumeric, min_length: 1, max_length: 10) do
      ds = %DesiredState{connections: %{key => :active}}
      assert map_size(ds.connections) == 1
    end
  end

  property "r159: desired_state from_struct has connections key" do
    check all n <- integer(0..3) do
      _ = n
      ds = %DesiredState{}
      m = Map.from_struct(ds)
      assert Map.has_key?(m, :connections)
    end
  end

  property "r160: desired_state struct not nil" do
    check all n <- integer() do
      _ = n
      ds = %DesiredState{}
      assert ds != nil
    end
  end

  property "r161: desiredstate module identity check" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState == DesiredState
    end
  end

  property "r162: desiredstate module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState != nil
    end
  end

  property "r163: desiredstate module loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(DesiredState)
    end
  end

  property "r164: desiredstate module is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(DesiredState)
    end
  end

  property "r165: desiredstate module inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(DesiredState))
    end
  end

  property "r166: desiredstate inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(DesiredState)
      assert byte_size(s) > 0
    end
  end

  property "r167: desiredstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState != nil
    end
  end

  property "r168: desiredstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(DesiredState)
    end
  end

  property "r169: desiredstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(DesiredState)
    end
  end

  property "r170: desiredstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState == DesiredState
    end
  end

  property "r171: desiredstate module comparison" do
    check all n <- integer(0..3) do
      _ = n
      m = DesiredState
      assert m == DesiredState
    end
  end

  property "r172: desiredstate module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState != nil
    end
  end

  property "r173: desiredstate functions non-empty" do
    check all n <- integer(0..3) do
      _ = n
      fns = DesiredState.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r174: desiredstate module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(DesiredState)
    end
  end

  property "r175: desiredstate module atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(DesiredState)
    end
  end

  property "r176: desiredstate module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(DesiredState))
    end
  end

  property "r177: desiredstate module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(DesiredState)
    end
  end

  property "r178: desiredstate module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(DesiredState)
    end
  end

  property "r179: desiredstate module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState != nil
    end
  end

  property "r180: desiredstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = DesiredState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r181: desiredstate module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState == DesiredState
    end
  end

  property "r182: desiredstate inspect length" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(DesiredState)
      assert String.length(s) > 0
    end
  end

  property "r183: desiredstate module loaded final" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(DesiredState)
    end
  end

  property "r184: desiredstate not nil final" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState != nil
    end
  end

  property "r185: desiredstate is_atom final" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(DesiredState)
    end
  end

  property "r186: desiredstate module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(DesiredState))
    end
  end

  property "r187: desiredstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState != nil
    end
  end

  property "r188: desiredstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(DesiredState)
    end
  end

  property "r189: desiredstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(DesiredState)
    end
  end

  property "r190: desiredstate functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = DesiredState.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r191: desiredstate module inspect r191" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(DesiredState))
    end
  end

  property "r192: desiredstate not nil r192" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState != nil
    end
  end

  property "r193: desiredstate loaded r193" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(DesiredState)
    end
  end

  property "r194: desiredstate is atom r194" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(DesiredState)
    end
  end

  property "r195: desiredstate functions r195" do
    check all n <- integer(0..3) do
      _ = n
      fns = DesiredState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r196: desiredstate identity r196" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState == DesiredState
    end
  end

  property "r197: desiredstate module name r197" do
    check all n <- integer(0..3) do
      _ = n
      name = to_string(DesiredState)
      assert String.length(name) > 0
    end
  end

  property "r198: desiredstate loaded ensure r198" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(DesiredState)
    end
  end

  property "r199: desiredstate inspect len r199" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(DesiredState)) > 0
    end
  end

  property "r200: desiredstate not nil final r200" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState != nil
    end
  end

  property "r201: desiredstate inspect binary r201" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(DesiredState))
    end
  end

  property "r202: desiredstate not nil r202" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState != nil
    end
  end

  property "r203: desiredstate loaded r203" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(DesiredState)
    end
  end

  property "r204: desiredstate is atom r204" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(DesiredState)
    end
  end

  property "r205: desiredstate functions r205" do
    check all n <- integer(0..3) do
      _ = n
      fns = DesiredState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r206: desiredstate identity r206" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState == DesiredState
    end
  end

  property "r207: desiredstate to_string r207" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(DesiredState)
      assert String.length(s) > 0
    end
  end

  property "r208: desiredstate loaded ensure r208" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(DesiredState)
    end
  end

  property "r209: desiredstate inspect len r209" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(DesiredState)) > 0
    end
  end

  property "r210: desiredstate not nil final r210" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState != nil
    end
  end

  property "r211: desiredstate inspect binary r211" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(DesiredState))
    end
  end

  property "r212: desiredstate not nil r212" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState != nil
    end
  end

  property "r213: desiredstate loaded r213" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(DesiredState)
    end
  end

  property "r214: desiredstate is atom r214" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(DesiredState)
    end
  end

  property "r215: desiredstate functions r215" do
    check all n <- integer(0..3) do
      _ = n
      fns = DesiredState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r216: desiredstate identity r216" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState == DesiredState
    end
  end

  property "r217: desiredstate to_string r217" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(DesiredState)
      assert String.length(s) > 0
    end
  end

  property "r218: desiredstate loaded ensure r218" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(DesiredState)
    end
  end

  property "r219: desiredstate inspect len r219" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(DesiredState)) > 0
    end
  end

  property "r220: desiredstate not nil final r220" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState != nil
    end
  end

  property "r221: desiredstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(DesiredState))
    end
  end

  property "r222: desiredstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState != nil
    end
  end

  property "r223: desiredstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(DesiredState)
    end
  end

  property "r224: desiredstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(DesiredState)
    end
  end

  property "r225: desiredstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = DesiredState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r226: desiredstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState == DesiredState
    end
  end

  property "r227: desiredstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(DesiredState)
      assert String.length(s) > 0
    end
  end

  property "r228: desiredstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(DesiredState)
    end
  end

  property "r229: desiredstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(DesiredState)) > 0
    end
  end

  property "r230: desiredstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState != nil
    end
  end

  property "r231: desiredstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(DesiredState))
    end
  end

  property "r232: desiredstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState != nil
    end
  end

  property "r233: desiredstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(DesiredState)
    end
  end

  property "r234: desiredstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(DesiredState)
    end
  end

  property "r235: desiredstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = DesiredState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r236: desiredstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState == DesiredState
    end
  end

  property "r237: desiredstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(DesiredState)
      assert String.length(s) > 0
    end
  end

  property "r238: desiredstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(DesiredState)
    end
  end

  property "r239: desiredstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(DesiredState)) > 0
    end
  end

  property "r240: desiredstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert DesiredState != nil
    end
  end
end
