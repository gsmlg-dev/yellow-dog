defmodule YellowDog.Netman.Types.DiffPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias YellowDog.Netman.Types.Diff

  @actions [
    :add_address,
    :remove_address,
    :add_route,
    :remove_route,
    :activate_connection,
    :deactivate_connection,
    :update_dns,
    :set_mtu,
    :set_link_up,
    :set_link_down
  ]

  defp action_gen do
    member_of(@actions)
  end

  defp interface_gen do
    gen all(name <- string(:alphanumeric, min_length: 1, max_length: 15)) do
      name
    end
  end

  defp params_gen do
    gen all(
          keys <- list_of(atom(:alphanumeric), max_length: 5),
          values <- list_of(one_of([integer(), string(:alphanumeric)]), length: length(keys))
        ) do
      Enum.zip(keys, values) |> Map.new()
    end
  end

  property "new/3 preserves all fields" do
    check all(
            action <- action_gen(),
            interface <- interface_gen(),
            params <- params_gen()
          ) do
      diff = Diff.new(action, interface, params)
      assert diff.action == action
      assert diff.interface == interface
      assert diff.params == params
    end
  end

  property "new/1 with defaults creates valid diff" do
    check all(action <- action_gen()) do
      diff = Diff.new(action)
      assert diff.action == action
      assert diff.interface == nil
      assert diff.params == %{}
    end
  end

  property "all action types produce valid structs" do
    check all(action <- action_gen()) do
      diff = Diff.new(action, "eth0", %{test: true})
      assert %Diff{} = diff
      assert action in @actions
    end
  end

  property "add/remove pairs are inverses (same interface and params)" do
    check all(
            interface <- interface_gen(),
            address <- string(:alphanumeric, min_length: 1, max_length: 20),
            prefix <- integer(1..128)
          ) do
      add = Diff.new(:add_address, interface, %{address: address, prefix_len: prefix})
      remove = Diff.new(:remove_address, interface, %{address: address, prefix_len: prefix})

      # Same interface and params but opposite actions
      assert add.interface == remove.interface
      assert add.params == remove.params
      assert add.action != remove.action
    end
  end

  property "diffs with same action and interface are equal when params match" do
    check all(
            action <- action_gen(),
            interface <- interface_gen(),
            params <- params_gen()
          ) do
      d1 = Diff.new(action, interface, params)
      d2 = Diff.new(action, interface, params)
      assert d1 == d2
    end
  end

  property "diffs with different actions are never equal" do
    check all(
            action1 <- action_gen(),
            action2 <- action_gen(),
            action1 != action2,
            interface <- interface_gen()
          ) do
      d1 = Diff.new(action1, interface)
      d2 = Diff.new(action2, interface)
      assert d1 != d2
    end
  end

  property "invalid action atoms always raise FunctionClauseError" do
    invalid_action_gen =
      atom(:alphanumeric)
      |> filter(&(&1 not in @actions))

    check all(action <- invalid_action_gen) do
      assert_raise FunctionClauseError, fn ->
        Diff.new(action)
      end
    end
  end

  property "new/2 with explicit nil interface is equivalent to new/1 default" do
    check all(action <- action_gen()) do
      d1 = Diff.new(action)
      d2 = Diff.new(action, nil)
      assert d1 == d2
    end
  end

  property "Diff struct always has action, interface, params keys" do
    check all(
            action <- action_gen(),
            interface <- interface_gen(),
            params <- params_gen()
          ) do
      diff = Diff.new(action, interface, params)
      assert Map.has_key?(diff, :action), "Diff missing :action key"
      assert Map.has_key?(diff, :interface), "Diff missing :interface key"
      assert Map.has_key?(diff, :params), "Diff missing :params key"
    end
  end

  property "params is always a map (never nil)" do
    check all(action <- action_gen()) do
      diff = Diff.new(action)
      assert is_map(diff.params), "Expected params to be a map, got: #{inspect(diff.params)}"
    end
  end

  property "new/3 with non-empty params differs from new/3 with empty params" do
    check all(
            action <- action_gen(),
            interface <- interface_gen(),
            key <- atom(:alphanumeric),
            value <- integer()
          ) do
      d_empty = Diff.new(action, interface, %{})
      d_nonempty = Diff.new(action, interface, %{key => value})
      assert d_empty != d_nonempty,
             "Expected diffs to differ when params differ"
    end
  end

  property "action field in created Diff is always one of the known action atoms" do
    check all(action <- action_gen()) do
      diff = Diff.new(action)
      assert diff.action in @actions,
             "Unexpected action: #{inspect(diff.action)}"
    end
  end

  property "Diff with empty string interface stores it without modification" do
    check all(action <- action_gen()) do
      diff = Diff.new(action, "", %{})
      assert diff.interface == ""
    end
  end

  property "new/3 always returns a %Diff{} struct (not a plain map)" do
    check all(
            action <- action_gen(),
            interface <- interface_gen(),
            params <- params_gen()
          ) do
      diff = Diff.new(action, interface, params)
      assert is_struct(diff, Diff),
             "Expected %Diff{} struct, got: #{inspect(diff)}"
    end
  end

  property "new/3 with integer params values preserves them exactly" do
    check all(
            action <- action_gen(),
            interface <- interface_gen(),
            key <- atom(:alphanumeric),
            value <- integer()
          ) do
      params = %{key => value}
      diff = Diff.new(action, interface, params)
      assert diff.params[key] == value,
             "Expected params[#{key}] == #{value}, got: #{inspect(diff.params[key])}"
    end
  end

  property "new/1 is equivalent to new/3 with nil interface and empty params" do
    check all(action <- action_gen()) do
      d1 = Diff.new(action)
      d3 = Diff.new(action, nil, %{})
      assert d1 == d3,
             "Expected new/1 and new/3(nil, %{}) to be equivalent for action #{action}"
    end
  end

  property "diffs with same action but different non-nil interfaces are never equal" do
    check all(
            action <- action_gen(),
            i1 <- interface_gen(),
            i2 <- interface_gen(),
            i1 != i2
          ) do
      d1 = Diff.new(action, i1)
      d2 = Diff.new(action, i2)
      assert d1 != d2,
             "Expected diffs with different interfaces (#{i1}, #{i2}) to be unequal"
    end
  end

  property "new/2 is equivalent to new/3 with empty params" do
    check all(
            action <- action_gen(),
            iface <- interface_gen()
          ) do
      d2 = Diff.new(action, iface)
      d3 = Diff.new(action, iface, %{})
      assert d2 == d3,
             "Expected new/2 and new/3(iface, %{}) to be equivalent for action #{action}"
    end
  end

  property "diffs with different actions are never equal for same interface and empty params" do
    check all(
            a1 <- action_gen(),
            a2 <- action_gen(),
            a1 != a2,
            iface <- interface_gen()
          ) do
      d1 = Diff.new(a1, iface, %{})
      d2 = Diff.new(a2, iface, %{})

      assert d1 != d2,
             "Expected diffs with different actions (#{a1}, #{a2}) to be unequal"
    end
  end

  property "Diff struct always has exactly 3 fields: action, interface, params" do
    check all(
            action <- action_gen(),
            interface <- interface_gen(),
            params <- params_gen()
          ) do
      diff = Diff.new(action, interface, params)
      struct_keys = diff |> Map.from_struct() |> Map.keys() |> Enum.sort()

      assert struct_keys == [:action, :interface, :params],
             "Expected exactly [:action, :interface, :params], got: #{inspect(struct_keys)}"
    end
  end

  property "new/3 with string param values preserves them exactly" do
    check all(
            action <- action_gen(),
            interface <- interface_gen(),
            key <- atom(:alphanumeric),
            value <- string(:alphanumeric)
          ) do
      params = %{key => value}
      diff = Diff.new(action, interface, params)
      assert diff.params[key] == value,
             "Expected string param #{key}=#{inspect(value)} to be preserved, got: #{inspect(diff.params[key])}"
    end
  end

  property "two diffs created with same inputs are structurally equal and hash the same" do
    check all(
            action <- action_gen(),
            interface <- interface_gen(),
            params <- params_gen()
          ) do
      d1 = Diff.new(action, interface, params)
      d2 = Diff.new(action, interface, params)
      assert d1 == d2
      assert :erlang.phash2(d1) == :erlang.phash2(d2),
             "Expected identical hashes for equal diffs"
    end
  end

  property "new/3 with map params preserves all keys" do
    check all(
            action <- action_gen(),
            interface <- interface_gen(),
            params <- params_gen()
          ) do
      diff = Diff.new(action, interface, params)

      for {k, v} <- params do
        assert Map.has_key?(diff.params, k),
               "Expected key #{inspect(k)} in diff.params"
        assert diff.params[k] == v,
               "Expected diff.params[#{inspect(k)}] == #{inspect(v)}, got #{inspect(diff.params[k])}"
      end
    end
  end

  property "new/2 params field is always an empty map" do
    check all(
            action <- action_gen(),
            interface <- interface_gen()
          ) do
      diff = Diff.new(action, interface)
      assert diff.params == %{},
             "Expected empty params for new/2, got: #{inspect(diff.params)}"
    end
  end

  property "action field is always an atom" do
    check all(
            action <- action_gen(),
            interface <- interface_gen(),
            params <- params_gen()
          ) do
      diff = Diff.new(action, interface, params)
      assert is_atom(diff.action),
             "Expected atom action, got: #{inspect(diff.action)}"
    end
  end

  property "interface field is always a binary string" do
    check all(
            action <- action_gen(),
            interface <- interface_gen(),
            params <- params_gen()
          ) do
      diff = Diff.new(action, interface, params)
      assert is_binary(diff.interface),
             "Expected binary interface, got: #{inspect(diff.interface)}"
    end
  end

  property "params field is always a map" do
    check all(
            action <- action_gen(),
            interface <- interface_gen(),
            params <- params_gen()
          ) do
      diff = Diff.new(action, interface, params)
      assert is_map(diff.params),
             "Expected map params, got: #{inspect(diff.params)}"
    end
  end

  property "new/3 always stores interface as the exact binary given" do
    check all(
            action <- action_gen(),
            interface <- interface_gen(),
            params <- params_gen()
          ) do
      diff = Diff.new(action, interface, params)
      assert diff.interface == interface,
             "Expected interface #{inspect(interface)}, got: #{inspect(diff.interface)}"
    end
  end

  property "new/3 with atom keys in params always stores them as atoms" do
    check all(
            action <- action_gen(),
            interface <- interface_gen(),
            key <- StreamData.atom(:alphanumeric),
            val <- StreamData.integer()
          ) do
      params = %{key => val}
      diff = Diff.new(action, interface, params)
      assert Map.has_key?(diff.params, key),
             "Expected atom key #{inspect(key)} in params, got: #{inspect(diff.params)}"
    end
  end

  property "Diff.new always produces a struct with the correct action" do
    check all(action <- action_gen()) do
      diff = Diff.new(action)
      assert diff.action == action,
             "Expected action #{inspect(action)}, got: #{inspect(diff.action)}"
    end
  end

  property "two Diffs with same action always have equal action field" do
    check all(
            action <- action_gen(),
            iface1 <- interface_gen(),
            iface2 <- interface_gen()
          ) do
      diff1 = Diff.new(action, iface1, %{})
      diff2 = Diff.new(action, iface2, %{})
      assert diff1.action == diff2.action,
             "Expected same action in both diffs"
    end
  end

  property "Diff.new/1 with default interface is nil" do
    check all(action <- action_gen()) do
      diff = Diff.new(action)
      assert diff.interface == nil,
             "Expected nil interface from new/1, got: #{inspect(diff.interface)}"
    end
  end

  property "new/2 always stores empty map as params" do
    check all(
            action <- action_gen(),
            interface <- interface_gen()
          ) do
      diff = Diff.new(action, interface)
      assert diff.params == %{},
             "Expected empty params from new/2, got: #{inspect(diff.params)}"
    end
  end

  property "Diff.new/1 always creates a valid Diff struct" do
    check all(action <- action_gen()) do
      diff = Diff.new(action)
      assert is_struct(diff, Diff),
             "Expected Diff struct from Diff.new/1, got: #{inspect(diff)}"
      assert diff.action == action,
             "Expected action #{action}, got: #{inspect(diff.action)}"
    end
  end

  property "Diff with set_mtu action and integer param always creates valid struct" do
    check all(mtu <- StreamData.integer(68..65535)) do
      diff = Diff.new(:set_mtu, "eth0", %{mtu: mtu})
      assert is_struct(diff, Diff),
             "Expected Diff struct, got: \#{inspect(diff)}"
      assert diff.action == :set_mtu
      assert diff.params.mtu == mtu
    end
  end

  property "Diff with add_address action always creates a valid struct" do
    check all(
            iface <- interface_gen(),
            params <- params_gen()
          ) do
      diff = Diff.new(:add_address, iface, params)
      assert is_struct(diff, Diff)
      assert diff.action == :add_address
    end
  end

  property "Diff params field is always a map" do
    check all(
            action <- action_gen(),
            iface <- interface_gen(),
            params <- params_gen()
          ) do
      diff = Diff.new(action, iface, params)
      assert is_map(diff.params),
             "Expected map params in Diff, got: #{inspect(diff.params)}"
    end
  end

  property "Diff struct always has :action and :params keys" do
    check all(action <- action_gen()) do
      diff = Diff.new(action)
      assert Map.has_key?(diff, :action),
             "Expected :action key in Diff struct"
      assert Map.has_key?(diff, :params),
             "Expected :params key in Diff struct"
    end
  end

  property "Diff.new/1 action is always one of the valid actions" do
    check all(action <- action_gen()) do
      diff = Diff.new(action)
      assert diff.action in @actions,
             "Expected action in @actions, got: #{inspect(diff.action)}"
    end
  end

  property "Diff params is always an empty map for new/1" do
    check all(action <- action_gen()) do
      diff = Diff.new(action)
      assert is_map(diff.params),
             "Expected map for Diff.params, got: #{inspect(diff.params)}"
    end
  end

  property "Diff.new/1 always produces a struct with two keys" do
    check all(action <- action_gen()) do
      diff = Diff.new(action)
      keys = Map.keys(diff) |> Enum.reject(&(&1 == :__struct__))
      assert :action in keys,
             "Expected :action key in Diff, got: #{inspect(keys)}"
    end
  end

  property "Diff struct is never nil" do
    check all(action <- action_gen()) do
      diff = Diff.new(action)
      assert diff != nil,
             "Expected non-nil Diff struct"
    end
  end

  property "Diff.new/1 produces different structs for different actions" do
    check all(a1 <- action_gen(), a2 <- action_gen(), a1 != a2) do
      d1 = Diff.new(a1)
      d2 = Diff.new(a2)
      assert d1.action != d2.action,
             "Expected different actions in different Diffs"
    end
  end
  property "Diff struct action field is always a known action" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      assert diff.action == action,
             "Expected action \#{inspect(action)}, got: \#{inspect(diff.action)}"
    end
  end
  property "Diff new with valid action produces non-nil struct" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      refute is_nil(diff), "Expected non-nil struct from Diff.new"
    end
  end
  property "Diff struct is always a map with action key" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      assert is_map(diff) and Map.has_key?(diff, :action),
             "Expected map with :action key, got: #{inspect(diff)}"
    end
  end
  property "Diff new never produces nil" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      refute is_nil(diff), "Expected non-nil from Diff.new"
    end
  end
  property "Diff interface field is nil for actions not requiring interface" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      assert is_nil(diff.interface) or is_binary(diff.interface),
             "Expected nil or binary interface, got: #{inspect(diff.interface)}"
    end
  end
  property "Diff struct always has params map field" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      assert is_map(diff.params),
             "Expected map params, got: #{inspect(diff.params)}"
    end
  end
  property "Diff params field always has zero keys for basic new/1" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      assert map_size(diff.params) == 0,
             "Expected empty params map, got: #{inspect(diff.params)}"
    end
  end
  property "Diff interface field can be set to a string interface name" do
    check all(
            action <- action_gen(),
            iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 12)
          ) do
      diff = YellowDog.Netman.Types.Diff.new(action, iface, %{})
      assert diff.interface == iface,
             "Expected interface to be #{iface}, got: #{inspect(diff.interface)}"
    end
  end
  property "Diff action field matches the action passed to new/1" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      assert diff.action == action,
             "Expected action=#{action}, got: #{inspect(diff.action)}"
    end
  end
  property "Diff new with all actions never raises" do
    check all(action <- action_gen()) do
      result =
        try do
          YellowDog.Netman.Types.Diff.new(action)
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result == :ok,
             "Expected :ok from Diff.new with #{inspect(action)}"
    end
  end
  property "Diff action is one of the expected @actions" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      valid_actions = [:add_address, :remove_address, :add_route, :remove_route,
                       :activate_connection, :deactivate_connection, :update_dns,
                       :set_mtu, :set_link_up, :set_link_down]
      assert diff.action in valid_actions,
             "Expected valid action, got: #{inspect(diff.action)}"
    end
  end

end
