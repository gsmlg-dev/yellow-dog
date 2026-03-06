defmodule YellowDog.Netman.Kernel.LinkMonitorPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias YellowDog.Netman.Kernel.{Netlink, LinkMonitor}
  alias YellowDog.Netman.Test.MockNetlink

  @moduletag :capture_log

  defp iface_gen do
    StreamData.string(:alphanumeric, min_length: 3, max_length: 10)
    |> StreamData.map(&("prop_lm_" <> &1))
    |> StreamData.map(&String.slice(&1, 0, 15))
  end

  defp send_link_event(event) do
    send(Netlink, {:mock_event, Map.put(event, "type", "link_change")})
    Process.sleep(50)
  end

  # Properties

  property "link_up then get_link returns link with :up state" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      link = LinkMonitor.get_link(iface)
      assert link != nil, "Expected link entry for #{iface}"
      assert link.state == :up
    end
  end

  property "link_down then get_link returns link with :down state" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(30)
      MockNetlink.link_down(iface)
      Process.sleep(50)

      link = LinkMonitor.get_link(iface)
      assert link != nil
      assert link.state == :down
    end
  end

  property "link_removed then get_link returns nil" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface)
      Process.sleep(30)
      MockNetlink.link_removed(iface)
      Process.sleep(50)

      assert LinkMonitor.get_link(iface) == nil
    end
  end

  property "get_link never crashes for any interface name" do
    check all(iface <- StreamData.string(:printable, min_length: 0, max_length: 64)) do
      result = LinkMonitor.get_link(iface)
      assert is_nil(result) or is_map(result)
    end
  end

  property "link state is always normalized to :up, :down, or :unknown" do
    check all(
            iface <- iface_gen(),
            state <-
              StreamData.one_of([
                StreamData.member_of(["up", "down"]),
                StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
              ])
          ) do
      send_link_event(%{"action" => "update", "interface" => iface, "state" => state})

      link = LinkMonitor.get_link(iface)
      assert link != nil

      assert link.state in [:up, :down, :unknown],
             "Unexpected state atom: #{link.state} (from string: #{state})"
    end
  end

  property "carrier is always coerced to boolean" do
    check all(
            iface <- iface_gen(),
            carrier <-
              StreamData.one_of([
                StreamData.boolean(),
                StreamData.constant("true"),
                StreamData.constant("false"),
                StreamData.integer(),
                StreamData.constant(nil)
              ])
          ) do
      send_link_event(%{
        "action" => "update",
        "interface" => iface,
        "state" => "up",
        "carrier" => carrier
      })

      link = LinkMonitor.get_link(iface)
      assert link != nil

      assert is_boolean(link.carrier),
             "Expected boolean carrier, got: #{inspect(link.carrier)}"
    end
  end

  property "invalid MTU is coerced to 1500 default" do
    check all(
            iface <- iface_gen(),
            bad_mtu <-
              StreamData.one_of([
                StreamData.constant(0),
                StreamData.constant(-1),
                StreamData.constant("not_an_int"),
                StreamData.constant(nil)
              ])
          ) do
      send_link_event(%{
        "action" => "update",
        "interface" => iface,
        "state" => "up",
        "mtu" => bad_mtu
      })

      link = LinkMonitor.get_link(iface)
      assert link != nil

      assert link.mtu == 1500,
             "Expected MTU=1500 default for #{inspect(bad_mtu)}, got #{link.mtu}"
    end
  end

  property "valid positive MTU is preserved" do
    check all(
            iface <- iface_gen(),
            mtu <- StreamData.integer(68..65535)
          ) do
      send_link_event(%{
        "action" => "update",
        "interface" => iface,
        "state" => "up",
        "mtu" => mtu
      })

      link = LinkMonitor.get_link(iface)
      assert link != nil

      assert link.mtu == mtu,
             "Expected MTU=#{mtu} to be preserved, got #{link.mtu}"
    end
  end

  property "list_links always returns a list" do
    check all(_ <- StreamData.constant(:ok)) do
      assert is_list(LinkMonitor.list_links())
    end
  end

  property "list_links includes recently added links" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      links = LinkMonitor.list_links()

      assert Enum.any?(links, &(&1.interface == iface)),
             "list_links missing recently added link #{iface}"
    end
  end

  property "set_link_down always returns :ok or {:error, _} for any interface" do
    check all(iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)) do
      result = LinkMonitor.set_link_down(iface)
      assert result == :ok or match?({:error, _}, result),
             "Unexpected set_link_down result: #{inspect(result)}"
    end
  end

  property "set_mtu always returns :ok or {:error, _} for valid positive MTU" do
    check all(
            iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15),
            mtu <- StreamData.integer(68..65535)
          ) do
      result = LinkMonitor.set_mtu(iface, mtu)
      assert result == :ok or match?({:error, _}, result),
             "Unexpected set_mtu result: #{inspect(result)}"
    end
  end
end
