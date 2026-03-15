defmodule YellowDog.Netman.Kernel.AddressManagerCoverageTest do
  @moduledoc """
  Tests targeting uncovered branches in Kernel.AddressManager:
  - flush/1 {:error, reason} path when Netlink commands fail
  - parse_family/1 catch-all for unknown family strings
  """
  use ExUnit.Case

  @moduletag :capture_log

  alias YellowDog.Netman.Kernel.{AddressManager, Netlink}
  alias YellowDog.Netman.Test.MockNetlink

  test "flush counts failed removals when Netlink is disconnected" do
    iface = "test_am_err_#{:rand.uniform(65535)}"

    MockNetlink.address_added(iface, "10.50.0.1/24")
    MockNetlink.address_added(iface, "10.51.0.1/24")
    Process.sleep(50)

    assert length(AddressManager.get_addresses(iface)) >= 2

    netlink_pid = Process.whereis(Netlink)
    original_state = :sys.get_state(netlink_pid)

    on_exit(fn ->
      :sys.replace_state(netlink_pid, fn _state -> original_state end)
    end)

    # Force Netlink to return {:error, :not_connected} for all commands
    :sys.replace_state(netlink_pid, fn state -> %{state | backend: :unavailable, port: nil} end)

    {removed, failed} = AddressManager.flush(iface)

    assert removed == 0
    assert failed >= 2
  end

  test "unknown address family defaults to :inet" do
    iface = "addr_family_unk_#{:rand.uniform(65535)}"

    send(
      Process.whereis(AddressManager),
      {:netlink_event,
       {:address_change,
        %{
          "action" => "add",
          "interface" => iface,
          "address" => "10.52.0.1/24",
          "family" => "packet"
        }}}
    )

    Process.sleep(50)
    addresses = AddressManager.get_addresses(iface)
    assert Enum.any?(addresses, &(&1.address == "10.52.0.1" and &1.family == :inet))
  end
end
