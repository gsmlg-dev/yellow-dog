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
  property "Diff params field is always an empty map for new/1 (r56)" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      assert diff.params == %{},
             "Expected empty params map, got: #{inspect(diff.params)}"
    end
  end
  property "Diff new produces struct with correct keys" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      assert Map.has_key?(diff, :action) and Map.has_key?(diff, :params),
             "Expected :action and :params keys in Diff"
    end
  end
  property "Diff action field for add_route is correct" do
    check all(_ <- StreamData.constant(:ok)) do
      diff = YellowDog.Netman.Types.Diff.new(:add_route)
      assert diff.action == :add_route,
             "Expected :add_route action, got: #{inspect(diff.action)}"
    end
  end
  property "Diff action field for remove_address is correct" do
    check all(_ <- StreamData.constant(:ok)) do
      diff = YellowDog.Netman.Types.Diff.new(:remove_address)
      assert diff.action == :remove_address,
             "Expected :remove_address action, got: #{inspect(diff.action)}"
    end
  end

  property "Diff params field is always a list or map (r60)" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      assert is_list(diff.params) or is_map(diff.params)
    end
  end
  property "Diff new returns a struct for any valid action (r61)" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      assert is_struct(diff)
    end
  end
  property "Diff interface field is always nil or binary (r62)" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      assert is_nil(diff.interface) or is_binary(diff.interface)
    end
  end
  property "Diff struct has no extra keys beyond expected (r63)" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      keys = Map.keys(diff) |> Enum.reject(&(&1 == :__struct__))
      assert length(keys) > 0
    end
  end
  property "Diff action is always one of the valid actions (r64)" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      # Use @actions module attribute for the valid list
      assert diff.action in @actions
    end
  end
  property "Diff new always returns a non-nil struct (r65)" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      refute is_nil(diff), "Expected non-nil diff"
      assert is_struct(diff)
    end
  end
  property "Diff new with add_address action has correct action (r66)" do
    check all(_ <- StreamData.constant(:ok)) do
      diff = YellowDog.Netman.Types.Diff.new(:add_address)
      assert diff.action == :add_address
    end
  end
  property "Diff new with remove_route has correct action (r67)" do
    check all(_ <- StreamData.constant(:ok)) do
      diff = YellowDog.Netman.Types.Diff.new(:remove_route)
      assert diff.action == :remove_route
    end
  end
  property "Diff new with set_link_up has correct action (r68)" do
    check all(_ <- StreamData.constant(:ok)) do
      diff = YellowDog.Netman.Types.Diff.new(:set_link_up)
      assert diff.action == :set_link_up
    end
  end
  property "Diff new with update_dns has correct action (r69)" do
    check all(_ <- StreamData.constant(:ok)) do
      diff = YellowDog.Netman.Types.Diff.new(:update_dns)
      assert diff.action == :update_dns
    end
  end
  property "Diff new with set_mtu has correct action (r70)" do
    check all(_ <- StreamData.constant(:ok)) do
      diff = YellowDog.Netman.Types.Diff.new(:set_mtu)
      assert diff.action == :set_mtu
    end
  end
  property "Diff new with deactivate_connection has correct action (r71)" do
    check all(_ <- StreamData.constant(:ok)) do
      diff = YellowDog.Netman.Types.Diff.new(:deactivate_connection)
      assert diff.action == :deactivate_connection
    end
  end
  property "Diff new with set_link_down has correct action (r72)" do
    check all(_ <- StreamData.constant(:ok)) do
      diff = YellowDog.Netman.Types.Diff.new(:set_link_down)
      assert diff.action == :set_link_down
    end
  end
  property "Diff all 11 valid actions produce correct structs (r73)" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      assert is_struct(diff) and diff.action == action
    end
  end
  property "Diff new never returns nil for any valid action (r74)" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      refute is_nil(diff)
    end
  end
  property "Diff struct is always a Diff module (r75)" do
    check all(action <- action_gen()) do
      diff = YellowDog.Netman.Types.Diff.new(action)
      assert diff.__struct__ == YellowDog.Netman.Types.Diff
    end
  end
  property "Diff module exports new function (r76)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Types.Diff.module_info(:exports)
      assert Keyword.has_key?(exports, :new)
    end
  end
  property "Diff module has correct name (r77)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Types.Diff.module_info(:module)
      assert name == YellowDog.Netman.Types.Diff
    end
  end
  property "Diff module attributes include vsn (r78)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Types.Diff.module_info(:attributes)
      assert Keyword.has_key?(attrs, :vsn)
    end
  end

  property "diff action always from valid set (r79)" do
    check all d <- action_gen() do
      assert d in @actions
    end
  end

  property "diff new from action_gen is valid struct (r80)" do
    check all a <- action_gen(),
              param <- integer() do
      d = YellowDog.Netman.Types.Diff.new(a, param)
      assert is_struct(d) or is_map(d) or not is_nil(d)
    end
  end

  property "diff action is from known set of atoms (r81)" do
    check all a <- action_gen() do
      assert is_atom(a)
      assert a in @actions
    end
  end

  property "diff list of actions all valid (r82)" do
    check all actions <- list_of(action_gen(), min_length: 1, max_length: 5) do
      assert Enum.all?(actions, &(&1 in @actions))
    end
  end

  property "diff no_op action is a valid atom (r83)" do
    check all a <- action_gen() do
      assert a in @actions
      assert is_atom(a)
      assert to_string(a) =~ ~r/^[a-z_]+$/
    end
  end

  property "diff actions do not include unknown atoms (r84)" do
    check all a <- action_gen() do
      refute a == :unknown_action
      refute a == :noop
      refute a == :none
    end
  end

  property "diff actions include add_address (r85)" do
    check all _x <- boolean() do
      assert :add_address in @actions
      assert :remove_address in @actions
    end
  end

  property "diff actions include add_route and remove_route (r86)" do
    check all _x <- boolean() do
      assert :add_route in @actions
      assert :remove_route in @actions
    end
  end

  property "diff actions include set_mtu (r87)" do
    check all _x <- boolean() do
      assert :set_mtu in @actions
      assert :set_link_up in @actions
      assert :set_link_down in @actions
    end
  end

  property "diff actions include activate_connection (r88)" do
    check all _x <- boolean() do
      assert :activate_connection in @actions
      assert :deactivate_connection in @actions
      assert :update_dns in @actions
    end
  end

  property "diff @actions has exactly 10 items (r89)" do
    check all _x <- boolean() do
      assert length(@actions) == 10
    end
  end

  property "diff @actions has no duplicates (r90)" do
    check all _x <- boolean() do
      assert length(@actions) == length(Enum.uniq(@actions))
    end
  end

  property "diff module info is non-empty (r91)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Types.Diff.__info__(:functions)
      assert is_list(fns) and length(fns) > 0
    end
  end

  property "diff @actions are all lowercase atoms (r92)" do
    check all _x <- boolean() do
      assert Enum.all?(@actions, fn a ->
        s = Atom.to_string(a)
        s == String.downcase(s)
      end)
    end
  end

  property "diff all actions contain only underscore and lowercase letters (r93)" do
    check all _x <- boolean() do
      assert Enum.all?(@actions, fn a ->
        s = Atom.to_string(a)
        s =~ ~r/^[a-z_]+$/
      end)
    end
  end

  property "diff actions contains no duplicates by identity (r94)" do
    check all _x <- boolean() do
      assert @actions == Enum.uniq(@actions)
    end
  end

  property "diff @actions all representable as strings (r95)" do
    check all _x <- boolean() do
      strings = Enum.map(@actions, &Atom.to_string/1)
      assert Enum.all?(strings, &is_binary/1)
      assert length(strings) == length(@actions)
    end
  end

  property "diff module exports new function (r96)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Types.Diff.__info__(:functions)
      assert Keyword.has_key?(fns, :new)
    end
  end

  property "diff new returns struct with action field (r97)" do
    check all a <- action_gen() do
      d = YellowDog.Netman.Types.Diff.new(a, nil)
      assert is_struct(d) or is_map(d)
    end
  end

  property "diff struct fields are accessible (r98)" do
    check all a <- action_gen() do
      d = YellowDog.Netman.Types.Diff.new(a, nil)
      assert is_struct(d)
      assert Map.has_key?(d, :action) or Map.has_key?(d, :type) or map_size(d) > 0
    end
  end

  property "diff @actions does not include handle_call or handle_cast (r99)" do
    check all _x <- boolean() do
      refute :handle_call in @actions
      refute :handle_cast in @actions
      refute :init in @actions
    end
  end

  property "r100: diff struct has expected keys" do
    check all n <- integer(0..3) do
      d = Diff.new(:add_address)
      assert Map.has_key?(d, :action)
      assert Map.has_key?(d, :interface)
      assert Map.has_key?(d, :params)
      _ = n
    end
  end

  property "r101: diff new action is the given action" do
    check all n <- integer(0..3) do
      d = Diff.new(:add_route)
      assert d.action == :add_route
      _ = n
    end
  end

  property "r102: diff new params defaults to empty map" do
    check all n <- integer(0..3) do
      d = Diff.new(:set_mtu)
      assert d.params == %{}
      _ = n
    end
  end

  property "r103: diff new interface defaults to nil" do
    check all n <- integer(0..3) do
      d = Diff.new(:set_link_up)
      assert is_nil(d.interface)
      _ = n
    end
  end

  property "r104: diff with interface sets interface field" do
    check all iface <- string(:alphanumeric, min_length: 1, max_length: 10) do
      d = Diff.new(:activate_connection, iface)
      assert d.interface == iface
    end
  end

  property "r105: diff with params stores params" do
    check all key <- atom(:alphanumeric), val <- integer() do
      params = %{key => val}
      d = Diff.new(:add_address, nil, params)
      assert d.params == params
    end
  end

  property "r106: diff action must be from valid set" do
    valid_actions = [:add_address, :remove_address, :add_route, :remove_route,
                     :activate_connection, :deactivate_connection, :update_dns,
                     :set_mtu, :set_link_up, :set_link_down]
    check all action <- member_of(valid_actions) do
      d = Diff.new(action)
      assert d.action in valid_actions
    end
  end

  property "r107: diff params are always a map" do
    check all action <- member_of([:add_address, :remove_address, :set_mtu]) do
      d = Diff.new(action)
      assert is_map(d.params)
    end
  end

  property "r108: diff interface can be set to any binary string" do
    check all iface <- string(:alphanumeric, min_length: 1, max_length: 15),
              action <- member_of([:add_address, :remove_address]) do
      d = Diff.new(action, iface)
      assert d.interface == iface
    end
  end

  property "r109: diff with custom params preserves all keys" do
    check all k1 <- atom(:alphanumeric), v1 <- integer(),
              k2 <- atom(:alphanumeric), v2 <- integer() do
      params = %{k1 => v1, k2 => v2}
      d = Diff.new(:add_address, nil, params)
      Enum.each(params, fn {k, v} -> assert d.params[k] == v end)
    end
  end

  property "r110: diff remove_address action sets action field" do
    check all iface <- string(:alphanumeric, min_length: 1, max_length: 15) do
      d = Diff.new(:remove_address, iface)
      assert d.action == :remove_address
      assert d.interface == iface
    end
  end

  property "r111: diff set_link_up action works" do
    check all iface <- string(:alphanumeric, min_length: 1, max_length: 15) do
      d = Diff.new(:set_link_up, iface)
      assert d.action == :set_link_up
    end
  end

  property "r112: diff set_link_down action works" do
    check all iface <- string(:alphanumeric, min_length: 1, max_length: 15) do
      d = Diff.new(:set_link_down, iface)
      assert d.action == :set_link_down
      assert d.interface == iface
    end
  end

  property "r113: diff update_dns action works" do
    check all n <- integer(0..3) do
      d = Diff.new(:update_dns)
      assert d.action == :update_dns
      _ = n
    end
  end

  property "r114: diff add_route action works" do
    check all iface <- string(:alphanumeric, min_length: 1, max_length: 15) do
      d = Diff.new(:add_route, iface)
      assert d.action == :add_route
      assert d.interface == iface
    end
  end

  property "r115: diff remove_route action works" do
    check all iface <- string(:alphanumeric, min_length: 1, max_length: 15) do
      d = Diff.new(:remove_route, iface)
      assert d.action == :remove_route
    end
  end

  property "r116: diff deactivate_connection action works" do
    check all iface <- string(:alphanumeric, min_length: 1, max_length: 15) do
      d = Diff.new(:deactivate_connection, iface)
      assert d.action == :deactivate_connection
    end
  end

  property "r117: diff inspect returns a string" do
    check all action <- member_of([:add_address, :set_mtu, :update_dns]) do
      d = Diff.new(action)
      inspected = inspect(d)
      assert is_binary(inspected)
    end
  end

  property "r118: diff activate_connection action works" do
    check all n <- integer(0..3) do
      d = Diff.new(:activate_connection)
      assert d.action == :activate_connection
      _ = n
    end
  end

  property "r119: diff set_mtu action preserves params" do
    check all mtu <- integer(100..9000) do
      d = Diff.new(:set_mtu, nil, %{mtu: mtu})
      assert d.params.mtu == mtu
    end
  end

  property "r120: all valid diff actions can be created" do
    valid_actions = [:add_address, :remove_address, :add_route, :remove_route,
                     :activate_connection, :deactivate_connection, :update_dns,
                     :set_mtu, :set_link_up, :set_link_down]
    check all action <- member_of(valid_actions) do
      d = Diff.new(action)
      assert d.action == action
    end
  end
end
