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
end
