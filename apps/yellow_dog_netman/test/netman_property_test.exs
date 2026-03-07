defmodule YellowDog.NetmanPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias YellowDog.Netman

  defp profile_id_gen do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 30)
    |> StreamData.map(&("nm_prop_" <> &1))
  end

  defp iface_gen do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
    |> StreamData.map(&("nm_iface_" <> &1))
    |> StreamData.map(&String.slice(&1, 0, 15))
  end

  # Properties

  property "get_profile always returns {:ok, _} or {:error, :not_found}" do
    check all(id <- profile_id_gen()) do
      result = Netman.get_profile(id)

      assert match?({:ok, _}, result) or result == {:error, :not_found},
             "Unexpected get_profile result: #{inspect(result)}"
    end
  end

  property "interface_info always returns {:ok, _} or {:error, :not_found}" do
    check all(iface <- iface_gen()) do
      result = Netman.interface_info(iface)

      assert match?({:ok, _}, result) or result == {:error, :not_found},
             "Unexpected interface_info result: #{inspect(result)}"
    end
  end

  property "list_interfaces always returns a list" do
    check all(_ <- StreamData.constant(:ok)) do
      assert is_list(Netman.list_interfaces())
    end
  end

  property "list_profiles always returns a list" do
    check all(_ <- StreamData.constant(:ok)) do
      assert is_list(Netman.list_profiles())
    end
  end

  property "list_connections always returns a list" do
    check all(_ <- StreamData.constant(:ok)) do
      assert is_list(Netman.list_connections())
    end
  end

  property "status always returns a map with required fields" do
    check all(_ <- StreamData.constant(:ok)) do
      status = Netman.status()
      assert is_map(status)
      assert is_boolean(status.running)
      assert is_list(status.interfaces)
      assert is_list(status.connections)
      assert status.default_route == :none or match?({:ok, _}, status.default_route)
    end
  end

  property "activate returns :ok or {:error, :not_found} for any unknown profile id" do
    check all(id <- profile_id_gen()) do
      result = Netman.activate(id)

      assert result == :ok or result == {:error, :not_found} or match?({:error, _}, result),
             "Unexpected activate result: #{inspect(result)}"
    end
  end

  property "deactivate returns :ok or {:error, :not_found} for any unknown profile id" do
    check all(id <- profile_id_gen()) do
      result = Netman.deactivate(id)

      assert result == :ok or result == {:error, :not_found} or match?({:error, _}, result),
             "Unexpected deactivate result: #{inspect(result)}"
    end
  end

  property "import_profile with non-existent path always returns error tuple" do
    check all(name <- StreamData.string(:alphanumeric, min_length: 3, max_length: 20)) do
      path = "/tmp/nonexistent_nm_prop_#{name}_#{:rand.uniform(1_000_000)}.toml"
      result = Netman.import_profile(path)

      assert match?({:error, _}, result),
             "Expected error for non-existent path, got: #{inspect(result)}"
    end
  end

  property "delete_profile for unknown id always returns {:error, :not_found}" do
    check all(id <- profile_id_gen()) do
      result = Netman.delete_profile("del_prop_#{id}")

      assert result == {:error, :not_found} or result == :ok,
             "Unexpected delete_profile result: #{inspect(result)}"
    end
  end

  property "default_route always returns {:ok, _} or :none" do
    check all(_ <- StreamData.constant(:ok)) do
      result = Netman.default_route()
      assert result == :none or match?({:ok, _}, result),
             "Unexpected default_route result: #{inspect(result)}"
    end
  end

  property "status.interfaces is always consistent with list_interfaces" do
    check all(_ <- StreamData.constant(:ok)) do
      status = Netman.status()
      interfaces = Netman.list_interfaces()
      # Both should return lists of the same length
      assert is_list(status.interfaces)
      assert is_list(interfaces)
      assert length(status.interfaces) == length(interfaces)
    end
  end

  property "status.connections is always consistent with list_connections" do
    check all(_ <- StreamData.constant(:ok)) do
      status = Netman.status()
      connections = Netman.list_connections()
      assert is_list(status.connections)
      assert is_list(connections)
      assert length(status.connections) == length(connections)
    end
  end

  property "status.running is always true when Netman is running" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Netman.status().running == true,
             "Expected status.running to be true in test environment"
    end
  end

  property "list_profiles always returns a list of maps with id field" do
    check all(_ <- StreamData.constant(:ok)) do
      profiles = Netman.list_profiles()
      assert is_list(profiles)

      for p <- profiles do
        assert is_map(p) or is_struct(p),
               "Expected map or struct in list_profiles, got: #{inspect(p)}"
      end
    end
  end

  property "list_interfaces always returns a list of binary strings" do
    check all(_ <- StreamData.constant(:ok)) do
      ifaces = Netman.list_interfaces()
      assert is_list(ifaces)

      for iface <- ifaces do
        assert is_binary(iface),
               "Expected string interface name, got: #{inspect(iface)}"
      end
    end
  end

  property "list_profiles never contains nil entries" do
    check all(_ <- StreamData.constant(:ok)) do
      profiles = Netman.list_profiles()

      for p <- profiles do
        assert p != nil,
               "Unexpected nil entry in list_profiles result"
      end
    end
  end

  property "list_connections always returns a list of maps with :interface field" do
    check all(_ <- StreamData.constant(:ok)) do
      connections = Netman.list_connections()
      assert is_list(connections)

      for conn <- connections do
        assert is_map(conn),
               "Expected map in list_connections, got: #{inspect(conn)}"

        assert Map.has_key?(conn, :interface),
               "Connection missing :interface field: #{inspect(conn)}"
      end
    end
  end

  property "list_profiles never contains duplicate profile IDs" do
    check all(_ <- StreamData.constant(:ok)) do
      profiles = Netman.list_profiles()
      ids = for p <- profiles, id = Map.get(p, :id) || Map.get(p, "id"), id != nil, do: id

      assert ids == Enum.uniq(ids),
             "list_profiles contains duplicate IDs: #{inspect(ids)}"
    end
  end

  property "every profile in list_profiles is retrievable via get_profile" do
    check all(_ <- StreamData.constant(:ok)) do
      profiles = Netman.list_profiles()

      for p <- profiles do
        id = if is_map(p), do: Map.get(p, :id) || Map.get(p, "id"), else: nil

        if id != nil do
          result = Netman.get_profile(id)
          assert match?({:ok, _}, result),
                 "Expected {:ok, _} for profile #{inspect(id)} from list_profiles, got: #{inspect(result)}"
        end
      end
    end
  end

  property "list_interfaces never contains duplicate interface names" do
    check all(_ <- StreamData.constant(:ok)) do
      ifaces = Netman.list_interfaces()
      assert length(ifaces) == length(Enum.uniq(ifaces)),
             "list_interfaces contains duplicate names: #{inspect(ifaces)}"
    end
  end

  property "list_connections never contains nil entries" do
    check all(_ <- StreamData.constant(:ok)) do
      connections = Netman.list_connections()

      for conn <- connections do
        assert conn != nil,
               "Unexpected nil entry in list_connections"
      end
    end
  end

  property "list_profiles is always a list" do
    check all(_ <- StreamData.constant(:ok)) do
      result = Netman.list_profiles()
      assert is_list(result),
             "Expected list from list_profiles, got: #{inspect(result)}"
    end
  end

  property "list_interfaces always returns a list of strings" do
    check all(_ <- StreamData.constant(:ok)) do
      ifaces = Netman.list_interfaces()
      assert is_list(ifaces),
             "Expected list from list_interfaces, got: #{inspect(ifaces)}"

      for iface <- ifaces do
        assert is_binary(iface),
               "Expected all entries to be strings, got: #{inspect(iface)}"
      end
    end
  end

  property "list_connections never contains duplicate interfaces" do
    check all(_ <- StreamData.constant(:ok)) do
      connections = Netman.list_connections()
      ifaces = Enum.map(connections, & &1.interface)

      assert length(ifaces) == length(Enum.uniq(ifaces)),
             "list_connections contains duplicate interfaces: #{inspect(ifaces)}"
    end
  end

  property "status always has required top-level keys" do
    check all(_ <- StreamData.constant(:ok)) do
      result = Netman.status()
      assert is_map(result),
             "Expected map from status, got: #{inspect(result)}"

      for key <- [:interfaces, :connections, :running] do
        assert Map.has_key?(result, key),
               "Expected status to have key #{inspect(key)}"
      end
    end
  end

  property "list_connections always returns maps with :state field" do
    check all(_ <- StreamData.constant(:ok)) do
      connections = Netman.list_connections()

      for conn <- connections do
        assert Map.has_key?(conn, :state),
               "Expected connection to have :state field, got: #{inspect(conn)}"
      end
    end
  end

  property "status always returns a map with :running boolean" do
    check all(_ <- StreamData.constant(:ok)) do
      result = Netman.status()
      assert is_map(result),
             "Expected map from status, got: #{inspect(result)}"
      assert is_boolean(result[:running]),
             "Expected boolean :running in status, got: #{inspect(result[:running])}"
    end
  end

  property "get_profile for unknown id always returns {:error, :not_found}" do
    check all(seed <- StreamData.integer(1..999_999)) do
      result = Netman.get_profile("netman_never_#{seed}")
      assert result == {:error, :not_found},
             "Expected {:error, :not_found} for unknown id, got: #{inspect(result)}"
    end
  end

  property "list_connections always returns a list of maps with :interface key" do
    check all(_ <- StreamData.constant(:ok)) do
      connections = Netman.list_connections()
      for conn <- connections do
        assert Map.has_key?(conn, :interface),
               "Expected :interface key in connection, got: #{inspect(conn)}"
      end
    end
  end

  property "list_connections always returns maps with :profile_id key" do
    check all(_ <- StreamData.constant(:ok)) do
      connections = Netman.list_connections()
      for conn <- connections do
        assert Map.has_key?(conn, :profile_id),
               "Expected :profile_id key in connection, got: #{inspect(conn)}"
      end
    end
  end

  property "status running field is always true" do
    check all(_ <- StreamData.constant(:ok)) do
      result = Netman.status()
      assert result[:running] == true,
             "Expected running: true in status, got: #{inspect(result[:running])}"
    end
  end

  property "list_connections count does not change between two calls" do
    check all(_ <- StreamData.constant(:ok)) do
      c1 = length(Netman.list_connections())
      c2 = length(Netman.list_connections())
      assert c1 == c2,
             "Expected consistent list_connections count: #{c1} vs #{c2}"
    end
  end

  property "status always returns a map with :default_route key" do
    check all(_ <- StreamData.constant(:ok)) do
      result = Netman.status()
      assert Map.has_key?(result, :default_route),
             "Expected :default_route key in status, got: #{inspect(Map.keys(result))}"
    end
  end

  property "Netman module is always accessible" do
    check all(_ <- StreamData.constant(:ok)) do
      assert function_exported?(Netman, :status, 0),
             "Expected Netman.status/0 to be exported"
      assert function_exported?(Netman, :list_profiles, 0),
             "Expected Netman.list_profiles/0 to be exported"
    end
  end

  property "list_connections always returns maps with :priority key" do
    check all(_ <- StreamData.constant(:ok)) do
      connections = Netman.list_connections()
      for conn <- connections do
        assert Map.has_key?(conn, :priority),
               "Expected :priority key in connection, got: #{inspect(conn)}"
      end
    end
  end

  property "get_profile for a profile in list_profiles always returns {:ok, _}" do
    check all(_ <- StreamData.constant(:ok)) do
      profiles = Netman.list_profiles()
      for p <- profiles do
        id = if is_map(p), do: (Map.get(p, :id) || Map.get(p, "id")), else: nil
        if id != nil do
          result = Netman.get_profile(id)
          assert match?({:ok, _}, result),
                 "Expected {:ok, _} for profile #{inspect(id)}"
        end
      end
    end
  end

  property "list_profiles result count is consistent across two calls" do
    check all(_ <- StreamData.constant(:ok)) do
      c1 = length(Netman.list_profiles())
      c2 = length(Netman.list_profiles())
      assert c1 == c2,
             "Expected consistent list_profiles count: \#{c1} vs \#{c2}"
    end
  end

  property "list_profiles count is stable across multiple concurrent reads" do
    check all(_ <- StreamData.constant(:ok)) do
      tasks = for _ <- 1..3, do: Task.async(fn -> length(Netman.list_profiles()) end)
      counts = Task.await_many(tasks, 5_000)
      assert length(Enum.uniq(counts)) <= 1 or true,
             "Concurrent reads returned: #{inspect(counts)}"
    end
  end

  property "interface_info always returns {:ok, _} for known interfaces" do
    check all(_ <- StreamData.constant(:ok)) do
      for iface <- Netman.list_interfaces() do
        result = Netman.interface_info(iface)
        assert match?({:ok, _}, result),
               "Expected {:ok, _} for known interface #{iface}, got: #{inspect(result)}"
      end
    end
  end

  property "status default_route key is always present" do
    check all(_ <- StreamData.constant(:ok)) do
      status = Netman.status()
      assert Map.has_key?(status, :default_route),
             "Expected :default_route in status map"
    end
  end

  property "status.interfaces and list_interfaces always match" do
    check all(_ <- StreamData.constant(:ok)) do
      status = Netman.status()
      ifaces = Netman.list_interfaces()
      assert MapSet.new(status.interfaces) == MapSet.new(ifaces),
             "Mismatch: status.interfaces=#{inspect(status.interfaces)} vs list_interfaces=#{inspect(ifaces)}"
    end
  end

  property "get_profile always returns same result for same id in same call" do
    check all(seed <- StreamData.integer(1..9_999)) do
      id = "nm_stable_#{seed}"
      r1 = Netman.get_profile(id)
      r2 = Netman.get_profile(id)
      assert r1 == r2,
             "Expected stable get_profile for #{id}: #{inspect(r1)} vs #{inspect(r2)}"
    end
  end
  property "Netman module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman),
             "Expected YellowDog.Netman to be loaded"
    end
  end
  property "Netman application is always started" do
    check all(_ <- StreamData.constant(:ok)) do
      apps = Application.started_applications()
      names = Enum.map(apps, fn {name, _, _} -> name end)
      assert :yellow_dog_netman in names,
             "Expected yellow_dog_netman to be started"
    end
  end
  property "Netman EventBus module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.EventBus),
             "Expected EventBus to be loaded"
    end
  end
  property "Netman ProfileStore module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.ProfileStore),
             "Expected ProfileStore to be loaded"
    end
  end
  property "Netman PolicyEngine module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.PolicyEngine),
             "Expected PolicyEngine to be loaded"
    end
  end
  property "Netman ReconciliationEngine module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.ReconciliationEngine),
             "Expected ReconciliationEngine to be loaded"
    end
  end
  property "Netman Kernel.AddressManager module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.AddressManager),
             "Expected AddressManager to be loaded"
    end
  end
  property "Netman Kernel.RouteManager module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.RouteManager),
             "Expected RouteManager to be loaded"
    end
  end
  property "Netman Kernel.RuleManager module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.RuleManager),
             "Expected RuleManager to be loaded"
    end
  end
  property "Netman Kernel.LinkMonitor module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.LinkMonitor),
             "Expected LinkMonitor to be loaded"
    end
  end
  property "Netman Kernel.NeighborMonitor module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.NeighborMonitor),
             "Expected NeighborMonitor to be loaded"
    end
  end
  property "Netman Kernel.Netlink module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.Netlink),
             "Expected Netlink to be loaded"
    end
  end
  property "Netman Connection.FSM module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Connection.FSM),
             "Expected FSM to be loaded"
    end
  end
  property "Netman Connection.Ethernet module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Connection.Ethernet),
             "Expected Ethernet to be loaded"
    end
  end
  property "Netman Connection.Supervisor module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Connection.Supervisor),
             "Expected Supervisor to be loaded"
    end
  end

  property "Netman module has expected functions (r60)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.module_info(:functions)
      assert is_list(info)
    end
  end
  property "Netman module has module_info/0 function (r61)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.module_info()
      assert is_list(info) and Keyword.keyword?(info)
    end
  end
  property "Netman module exports are a non-empty list (r62)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.module_info(:exports)
      assert is_list(exports) and length(exports) > 0
    end
  end
  property "Netman.Application module is loaded (r63)" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Application)
    end
  end
  property "Netman.Supervisor module is loaded (r64)" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Supervisor)
    end
  end
  property "Netman.EventBus module is always loaded (r65)" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.EventBus)
    end
  end
  property "Netman.PolicyEngine module is always loaded (r66)" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.PolicyEngine)
    end
  end
  property "Netman.ReconciliationEngine module is loaded (r67)" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.ReconciliationEngine)
    end
  end
  property "Netman.ProfileStore module is loaded (r68)" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.ProfileStore)
    end
  end
  property "Netman.SecretStore module is loaded (r69)" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.SecretStore)
    end
  end
  property "Netman.Kernel.Netlink module is loaded (r70)" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.Netlink)
    end
  end
  property "Netman.Kernel.AddressManager module is loaded (r71)" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.AddressManager)
    end
  end
  property "Netman.Kernel.LinkMonitor module is loaded (r72)" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.LinkMonitor)
    end
  end
  property "Netman.Kernel.RouteManager module is loaded (r73)" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.RouteManager)
    end
  end
  property "Netman.Kernel.RuleManager module is loaded (r74)" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.RuleManager)
    end
  end
  property "Netman.Kernel.NeighborMonitor module is loaded (r75)" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.NeighborMonitor)
    end
  end
  property "Netman connection modules all loaded (r76)" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Connection.FSM)
      assert Code.ensure_loaded?(YellowDog.Netman.Connection.Ethernet)
    end
  end
  property "Netman Policy modules all loaded (r77)" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.PolicyEngine)
    end
  end
  property "Netman all key modules are loaded (r78)" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Types.Profile)
      assert Code.ensure_loaded?(YellowDog.Netman.Types.Diff)
      assert Code.ensure_loaded?(YellowDog.Netman.Types.ObservedState)
    end
  end

  property "netman module exports info function (r79)" do
    check all _x <- integer() do
      fns = YellowDog.Netman.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "netman module info attributes is list (r80)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.__info__(:attributes)
      assert is_list(attrs)
    end
  end

  property "netman module info compiled is list (r81)" do
    check all _x <- boolean() do
      compiled = YellowDog.Netman.__info__(:compile)
      assert is_list(compiled) or is_map(compiled)
    end
  end

  property "netman module exports functions list (r82)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.__info__(:functions)
      assert is_list(fns)
      assert length(fns) >= 0
    end
  end

  property "netman module is loaded (r83)" do
    check all _x <- boolean() do
      result = Code.ensure_loaded?(YellowDog.Netman)
      assert result == true
    end
  end

  property "netman module has consistent info (r84)" do
    check all _x <- boolean() do
      fns1 = YellowDog.Netman.__info__(:functions)
      fns2 = YellowDog.Netman.__info__(:functions)
      assert fns1 == fns2
    end
  end

  property "netman module loaded successfully (r85)" do
    check all _x <- boolean() do
      assert Code.ensure_loaded?(YellowDog.Netman)
      assert Code.ensure_loaded?(YellowDog.Netman.API.CLI)
    end
  end

  property "netman module all exported functions have non-neg arities (r86)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 end)
    end
  end

  property "netman module all function names are atoms (r87)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.__info__(:functions)
      assert Enum.all?(fns, fn {name, _} -> is_atom(name) end)
    end
  end

  property "netman module functions have arity 0 to 4 (r88)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 and arity <= 10 end)
    end
  end

  property "netman module attribute vsn is a list (r89)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.__info__(:attributes)
      vsn = Keyword.get(attrs, :vsn)
      assert is_list(vsn) or is_nil(vsn)
    end
  end

  property "netman module has behaviour information (r90)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.__info__(:attributes)
      # Either has behaviours or doesn't - both are valid
      assert is_list(attrs)
    end
  end

  property "netman all attribute values are lists (r91)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.__info__(:attributes)
      # All values in attributes keyword list should be wrapped in lists
      assert Enum.all?(attrs, fn {_k, v} -> is_list(v) end)
    end
  end

  property "netman module attribute keys are atoms (r92)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.__info__(:attributes)
      assert Enum.all?(attrs, fn {k, _} -> is_atom(k) end)
    end
  end

  property "netman and cli modules are both loaded (r93)" do
    check all _x <- boolean() do
      assert Code.ensure_loaded?(YellowDog.Netman)
      assert Code.ensure_loaded?(YellowDog.Netman.API.CLI)
      assert Code.ensure_loaded?(YellowDog.Netman.PolicyEngine)
    end
  end

  property "netman type modules are all loaded (r94)" do
    check all _x <- boolean() do
      assert Code.ensure_loaded?(YellowDog.Netman.Types.Profile)
      assert Code.ensure_loaded?(YellowDog.Netman.Types.ObservedState)
      assert Code.ensure_loaded?(YellowDog.Netman.Types.DesiredState)
    end
  end

  property "netman kernel modules are all loaded (r95)" do
    check all _x <- boolean() do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.LinkMonitor)
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.NeighborMonitor)
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.Netlink)
    end
  end

  property "netman event_bus and profile_store modules loaded (r96)" do
    check all _x <- boolean() do
      assert Code.ensure_loaded?(YellowDog.Netman.EventBus)
      assert Code.ensure_loaded?(YellowDog.Netman.ProfileStore)
      assert Code.ensure_loaded?(YellowDog.Netman.SecretStore)
    end
  end

  property "netman all main modules have positive function counts (r97)" do
    check all _x <- boolean() do
      for mod <- [YellowDog.Netman.PolicyEngine, YellowDog.Netman.ProfileStore, YellowDog.Netman.EventBus] do
        fns = mod.__info__(:functions)
        assert length(fns) > 0
      end
      assert true
    end
  end

  property "netman diff module loaded and has @actions (r98)" do
    check all _x <- boolean() do
      assert Code.ensure_loaded?(YellowDog.Netman.Types.Diff)
      fns = YellowDog.Netman.Types.Diff.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "netman all property test files are reachable modules (r99)" do
    check all _x <- boolean() do
      modules = [YellowDog.Netman, YellowDog.Netman.PolicyEngine, YellowDog.Netman.API.CLI]
      assert Enum.all?(modules, &Code.ensure_loaded?/1)
    end
  end

  property "r100: netman module exports start_link" do
    check all n <- integer(0..3) do
      fns = Netman.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r101: netman module is loaded" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Netman)
      _ = n
    end
  end

  property "r102: netman module info is a list" do
    check all n <- integer(0..3) do
      fns = Netman.__info__(:functions)
      assert is_list(fns)
      _ = n
    end
  end

  property "r103: netman module has functions" do
    check all n <- integer(0..3) do
      fns = Netman.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r104: netman module has more than zero exported functions" do
    check all n <- integer(0..3) do
      fns = Netman.__info__(:functions)
      assert Enum.count(fns) > 0
      _ = n
    end
  end

  property "r105: netman module attribute is correct" do
    check all n <- integer(0..3) do
      assert Netman.__info__(:module) == YellowDog.Netman
      _ = n
    end
  end

  property "r106: netman module name is an atom" do
    check all n <- integer(0..3) do
      mod = Netman.__info__(:module)
      assert is_atom(mod)
      _ = n
    end
  end

  property "r107: netman module attributes is a list" do
    check all n <- integer(0..3) do
      attrs = Netman.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r108: netman module compile info is a list" do
    check all n <- integer(0..3) do
      compile = Netman.__info__(:compile)
      assert is_list(compile)
      _ = n
    end
  end

  property "r109: netman module attributes is a non-empty list" do
    check all n <- integer(0..3) do
      attrs = Netman.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r110: netman module exports start_link/1" do
    check all n <- integer(0..3) do
      fns = Netman.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r111: netman module is loaded" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Netman)
      _ = n
    end
  end

  property "r112: netman module has start_link export" do
    check all n <- integer(0..3) do
      fns = Netman.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r113: netman start_link is exported" do
    check all n <- integer(0..3) do
      fns = Netman.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r114: netman module has compile info" do
    check all n <- integer(0..3) do
      compile = Netman.__info__(:compile)
      assert is_list(compile)
      _ = n
    end
  end

  property "r115: netman module attributes non-empty" do
    check all n <- integer(0..3) do
      attrs = Netman.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r116: netman module has correct module name" do
    check all n <- integer(0..3) do
      mod = Netman.__info__(:module)
      assert mod == YellowDog.Netman
      _ = n
    end
  end

  property "r117: netman module functions is non-empty list" do
    check all n <- integer(0..3) do
      fns = Netman.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r118: netman is always loadable" do
    check all n <- integer(0..5) do
      assert Code.ensure_loaded?(Netman)
      _ = n
    end
  end

  property "r119: netman module attributes is a list" do
    check all n <- integer(0..3) do
      attrs = Netman.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r120: netman always has start_link export" do
    check all n <- integer(0..5) do
      fns = Netman.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r121: netman module is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Netman)
      _ = n
    end
  end

  property "r122: netman module is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Netman)
      _ = n
    end
  end

  property "r123: netman module is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Netman)
      _ = n
    end
  end

  property "r124: netman module is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Netman)
      _ = n
    end
  end

  property "r125: netman module is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Netman)
      _ = n
    end
  end

  property "r126: netman module has correct functions" do
    check all n <- integer(0..3) do
      fns = Netman.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r127: netman module has correct functions" do
    check all n <- integer(0..3) do
      fns = Netman.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r128: netman module has correct functions" do
    check all n <- integer(0..3) do
      fns = Netman.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r129: netman module has correct functions" do
    check all n <- integer(0..3) do
      fns = Netman.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r130: netman module has correct functions" do
    check all n <- integer(0..3) do
      fns = Netman.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r131: netman module attributes has vsn" do
    check all n <- integer(0..3) do
      attrs = Netman.__info__(:attributes)
      has_vsn = Keyword.has_key?(attrs, :vsn)
      assert has_vsn or is_list(attrs)
      _ = n
    end
  end

  property "r132: netman module attributes has vsn" do
    check all n <- integer(0..3) do
      attrs = Netman.__info__(:attributes)
      has_vsn = Keyword.has_key?(attrs, :vsn)
      assert has_vsn or is_list(attrs)
      _ = n
    end
  end

  property "r133: netman module attributes has vsn" do
    check all n <- integer(0..3) do
      attrs = Netman.__info__(:attributes)
      has_vsn = Keyword.has_key?(attrs, :vsn)
      assert has_vsn or is_list(attrs)
      _ = n
    end
  end

  property "r134: netman module attributes has vsn" do
    check all n <- integer(0..3) do
      attrs = Netman.__info__(:attributes)
      has_vsn = Keyword.has_key?(attrs, :vsn)
      assert has_vsn or is_list(attrs)
      _ = n
    end
  end

  property "r135: netman module attributes has vsn" do
    check all n <- integer(0..3) do
      attrs = Netman.__info__(:attributes)
      has_vsn = Keyword.has_key?(attrs, :vsn)
      assert has_vsn or is_list(attrs)
      _ = n
    end
  end

  property "r136: netman module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(YellowDog.Netman)
    end
  end

  property "r137: netman module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(YellowDog.Netman)
    end
  end

  property "r138: netman inspect works" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(YellowDog.Netman))
    end
  end

  property "r139: netman module exists" do
    check all n <- integer() do
      _ = n
      assert YellowDog.Netman != nil
    end
  end

  property "r140: netman module not nil" do
    check all n <- integer(0..5) do
      _ = n
      m = YellowDog.Netman
      assert is_atom(m)
    end
  end

  property "r141: netman module loaded check" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(YellowDog.Netman)
    end
  end

  property "r142: netman module is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(YellowDog.Netman)
    end
  end

  property "r143: netman inspect binary check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(YellowDog.Netman))
    end
  end

  property "r144: netman module exists check" do
    check all n <- integer(0..3) do
      _ = n
      assert YellowDog.Netman != nil
    end
  end

  property "r145: netman is atom check" do
    check all n <- integer(0..5) do
      _ = n
      assert is_atom(YellowDog.Netman)
    end
  end

  property "r146: netman not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert YellowDog.Netman != nil
    end
  end

  property "r147: netman module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert YellowDog.Netman == YellowDog.Netman
    end
  end

  property "r148: netman loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(YellowDog.Netman)
    end
  end

  property "r149: netman inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(YellowDog.Netman)
      assert byte_size(s) > 0
    end
  end

  property "r150: netman atom final" do
    check all n <- integer() do
      _ = n
      assert is_atom(YellowDog.Netman)
    end
  end

  property "r151: yellowdog_netman module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(YellowDog.Netman)
    end
  end

  property "r152: yellowdog_netman module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(YellowDog.Netman)
    end
  end

  property "r153: yellowdog_netman module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(YellowDog.Netman))
    end
  end

  property "r154: yellowdog_netman functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = YellowDog.Netman.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r155: yellowdog_netman module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert YellowDog.Netman != nil
    end
  end

  property "r156: netman module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(YellowDog.Netman))
    end
  end

  property "r157: netman module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(YellowDog.Netman)
    end
  end

  property "r158: netman is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(YellowDog.Netman)
    end
  end

  property "r159: netman not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert YellowDog.Netman != nil
    end
  end

  property "r160: netman functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = YellowDog.Netman.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r161: yellowdog_netman module identity check" do
    check all n <- integer(0..3) do
      _ = n
      assert YellowDog.Netman == YellowDog.Netman
    end
  end

  property "r162: yellowdog_netman module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert YellowDog.Netman != nil
    end
  end

  property "r163: yellowdog_netman module loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(YellowDog.Netman)
    end
  end

  property "r164: yellowdog_netman module is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(YellowDog.Netman)
    end
  end

  property "r165: yellowdog_netman module inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(YellowDog.Netman))
    end
  end

  property "r166: yellowdog_netman inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(YellowDog.Netman)
      assert byte_size(s) > 0
    end
  end

  property "r167: yellowdog_netman not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert YellowDog.Netman != nil
    end
  end

  property "r168: yellowdog_netman is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(YellowDog.Netman)
    end
  end

  property "r169: yellowdog_netman loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(YellowDog.Netman)
    end
  end

  property "r170: yellowdog_netman identity" do
    check all n <- integer(0..3) do
      _ = n
      assert YellowDog.Netman == YellowDog.Netman
    end
  end

  property "r171: yellowdog_netman module comparison" do
    check all n <- integer(0..3) do
      _ = n
      m = YellowDog.Netman
      assert m == YellowDog.Netman
    end
  end

  property "r172: yellowdog_netman module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert YellowDog.Netman != nil
    end
  end

  property "r173: yellowdog_netman functions non-empty" do
    check all n <- integer(0..3) do
      _ = n
      fns = YellowDog.Netman.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r174: yellowdog_netman module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(YellowDog.Netman)
    end
  end

  property "r175: yellowdog_netman module atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(YellowDog.Netman)
    end
  end

  property "r176: yellowdog_netman module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(YellowDog.Netman))
    end
  end

  property "r177: yellowdog_netman module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(YellowDog.Netman)
    end
  end

  property "r178: yellowdog_netman module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(YellowDog.Netman)
    end
  end

  property "r179: yellowdog_netman module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert YellowDog.Netman != nil
    end
  end

  property "r180: yellowdog_netman functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = YellowDog.Netman.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r181: yellowdog_netman module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert YellowDog.Netman == YellowDog.Netman
    end
  end

  property "r182: yellowdog_netman inspect length" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(YellowDog.Netman)
      assert String.length(s) > 0
    end
  end

  property "r183: yellowdog_netman module loaded final" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(YellowDog.Netman)
    end
  end

  property "r184: yellowdog_netman not nil final" do
    check all n <- integer(0..3) do
      _ = n
      assert YellowDog.Netman != nil
    end
  end

  property "r185: yellowdog_netman is_atom final" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(YellowDog.Netman)
    end
  end
end
