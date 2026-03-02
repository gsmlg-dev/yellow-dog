defmodule YellowDog.Netman.Kernel.RouteManagerCoverageTest do
  @moduledoc """
  Tests targeting uncovered branches in Kernel.RouteManager:
  - flush/1 {:error, reason} path when Netlink commands fail
  """
  use ExUnit.Case

  @moduletag :capture_log

  alias YellowDog.Netman.Kernel.{Netlink, RouteManager}
  alias YellowDog.Netman.Test.MockNetlink

  test "flush counts failed removals when Netlink is disconnected" do
    iface = "test_fl_err_#{:rand.uniform(65535)}"

    MockNetlink.route_added(destination: "10.40.0.0/24", gateway: "10.40.0.1", interface: iface)
    MockNetlink.route_added(destination: "10.41.0.0/24", gateway: "10.40.0.1", interface: iface)
    Process.sleep(50)

    assert length(RouteManager.get_routes(iface)) >= 2

    netlink_pid = Process.whereis(Netlink)
    original_state = :sys.get_state(netlink_pid)

    on_exit(fn ->
      :sys.replace_state(netlink_pid, fn _state -> original_state end)
    end)

    # Force Netlink to return {:error, :not_connected} for all commands
    :sys.replace_state(netlink_pid, fn state -> %{state | backend: :unavailable, port: nil} end)

    {removed, failed} = RouteManager.flush(iface)

    assert removed == 0
    assert failed >= 2
  end
end
