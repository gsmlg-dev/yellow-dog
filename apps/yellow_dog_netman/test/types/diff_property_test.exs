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
end
