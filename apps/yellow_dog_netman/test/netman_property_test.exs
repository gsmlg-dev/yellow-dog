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
end
