defmodule YellowDog.Netman.Types.DiffTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netman.Types.Diff

  test "new/1 creates diff with action only" do
    diff = Diff.new(:activate_connection)
    assert diff.action == :activate_connection
    assert diff.interface == nil
    assert diff.params == %{}
  end

  test "new/2 creates diff with action and interface" do
    diff = Diff.new(:set_link_up, "eth0")
    assert diff.action == :set_link_up
    assert diff.interface == "eth0"
    assert diff.params == %{}
  end

  test "new/3 creates diff with action, interface, and params" do
    diff = Diff.new(:add_address, "eth0", %{address: "10.0.0.1", prefix_len: 24})
    assert diff.action == :add_address
    assert diff.interface == "eth0"
    assert diff.params == %{address: "10.0.0.1", prefix_len: 24}
  end

  test "struct enforces action key" do
    assert_raise ArgumentError, fn ->
      struct!(Diff, %{})
    end
  end

  test "new/1 rejects invalid action atoms" do
    assert_raise FunctionClauseError, fn ->
      Diff.new(:invalid_action)
    end
  end

  test "all action types can be created" do
    actions = [
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

    for action <- actions do
      diff = Diff.new(action, "eth0")
      assert diff.action == action
    end
  end
end
