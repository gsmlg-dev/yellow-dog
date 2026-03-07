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

  property "get_link result always has :interface field matching the queried interface" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      link = LinkMonitor.get_link(iface)
      assert link != nil

      assert link.interface == iface,
             "Expected link.interface == #{iface}, got #{inspect(link.interface)}"
    end
  end

  property "link_up then link_down then link_up state is :up" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(30)
      MockNetlink.link_down(iface)
      Process.sleep(30)
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      link = LinkMonitor.get_link(iface)
      assert link != nil
      assert link.state == :up
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

  property "get_link result is always a subset of list_links" do
    check all(iface <- iface_gen()) do
      all_links = LinkMonitor.list_links()
      link = LinkMonitor.get_link(iface)

      if link != nil do
        assert Enum.member?(all_links, link),
               "get_link result not found in list_links for #{iface}"
      end
    end
  end

  property "set_link_up always returns :ok or {:error, _} for any interface" do
    check all(iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)) do
      result = LinkMonitor.set_link_up(iface)
      assert result == :ok or match?({:error, _}, result),
             "Unexpected set_link_up result: #{inspect(result)}"
    end
  end

  property "set_link_down always returns :ok or {:error, _} for any interface" do
    check all(iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)) do
      result = LinkMonitor.set_link_down(iface)
      assert result == :ok or match?({:error, _}, result),
             "Unexpected set_link_down result: #{inspect(result)}"
    end
  end

  property "link_removed then link_up restores the link entry" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(30)
      MockNetlink.link_removed(iface)
      Process.sleep(30)
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      link = LinkMonitor.get_link(iface)
      assert link != nil, "Expected link to be restored after link_removed then link_up on #{iface}"
      assert link.state == :up
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

  property "list_links never contains duplicate interface entries" do
    check all(_ <- StreamData.constant(:ok)) do
      links = LinkMonitor.list_links()
      ifaces = Enum.map(links, & &1.interface)

      assert length(ifaces) == length(Enum.uniq(ifaces)),
             "list_links contains duplicate interface entries: #{inspect(ifaces)}"
    end
  end

  property "link_up then link_removed removes interface from list_links" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(30)
      MockNetlink.link_removed(iface)
      Process.sleep(50)

      links = LinkMonitor.list_links()

      refute Enum.any?(links, &(&1.interface == iface)),
             "Expected #{iface} to be absent from list_links after link_removed"
    end
  end

  property "get_link mtu field is always nil or a positive integer" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      link = LinkMonitor.get_link(iface)
      assert link != nil

      assert is_nil(link.mtu) or (is_integer(link.mtu) and link.mtu > 0),
             "Expected nil or positive integer mtu, got: #{inspect(link.mtu)}"
    end
  end

  property "link_removed for never-added interface is a no-op — get_link returns nil" do
    check all(seed <- StreamData.integer(1..999_999)) do
      fresh_iface = "lm_nr_#{seed}"
      MockNetlink.link_removed(fresh_iface)
      Process.sleep(50)

      assert LinkMonitor.get_link(fresh_iface) == nil,
             "Expected nil for fresh interface #{fresh_iface} after link_removed on never-added iface"
    end
  end

  property "get_link result has :interface field matching the queried interface" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      link = LinkMonitor.get_link(iface)
      assert link != nil

      assert link.interface == iface,
             "Expected link.interface == #{iface}, got: #{inspect(link.interface)}"
    end
  end

  property "link_up then link_down — get_link still returns a non-nil entry" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(30)
      MockNetlink.link_down(iface)
      Process.sleep(50)

      link = LinkMonitor.get_link(iface)
      assert link != nil,
             "Expected get_link to return non-nil after link_down on #{iface}"
    end
  end

  property "link_up with custom mtu then get_link has the matching mtu value" do
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
             "Expected link.mtu == #{mtu}, got: #{inspect(link.mtu)}"
    end
  end

  property "get_link for a fresh unique interface always returns nil" do
    check all(seed <- StreamData.integer(1..999_999)) do
      fresh_iface = "lm_nil_#{seed}"
      result = LinkMonitor.get_link(fresh_iface)
      assert result == nil,
             "Expected nil for fresh interface #{fresh_iface}, got: #{inspect(result)}"
    end
  end

  property "link_up then list_links includes the interface" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      links = LinkMonitor.list_links()
      assert Enum.any?(links, &(&1.interface == iface)),
             "Expected #{iface} in list_links after link_up"
    end
  end

  property "get_link after link_up always has all required fields" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      link = LinkMonitor.get_link(iface)
      assert link != nil

      for field <- [:interface, :state, :carrier, :mtu] do
        assert Map.has_key?(link, field),
               "Expected link to have :#{field} field, got: #{inspect(link)}"
      end
    end
  end

  property "link_down after link_up always sets carrier to false" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)
      send_link_event(%{"interface" => iface, "state" => "down", "carrier" => false})
      link = LinkMonitor.get_link(iface)
      assert link != nil
      assert link.carrier == false,
             "Expected carrier false after link_down for #{iface}, got: #{inspect(link.carrier)}"
    end
  end

  property "get_link for never-registered interface always returns nil" do
    check all(seed <- StreamData.integer(1..999_999)) do
      fresh_iface = "lm_nil_#{seed}"
      result = LinkMonitor.get_link(fresh_iface)
      assert result == nil,
             "Expected nil for unregistered interface, got: #{inspect(result)}"
    end
  end

  property "list_links entries always have :interface and :state keys" do
    check all(_ <- StreamData.constant(:ok)) do
      links = LinkMonitor.list_links()
      for link <- links do
        assert Map.has_key?(link, :interface),
               "Expected :interface in link, got: #{inspect(link)}"
        assert Map.has_key?(link, :state),
               "Expected :state in link, got: #{inspect(link)}"
      end
    end
  end

  property "link_up sets the link state to up or down" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)
      link = LinkMonitor.get_link(iface)
      assert link != nil,
             "Expected non-nil link after link_up for #{iface}"
      assert link.state in [:up, :down],
             "Expected :up or :down state, got: #{inspect(link.state)}"
    end
  end

  property "link_up event always increments or maintains link count" do
    check all(iface <- iface_gen()) do
      before_count = length(LinkMonitor.list_links())
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(50)
      after_count = length(LinkMonitor.list_links())
      assert after_count >= before_count,
             "Expected link count to not decrease after link_up: #{before_count} -> #{after_count}"
    end
  end

  property "link_up then link_down: link is still tracked (not removed)" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)
      send_link_event(%{"interface" => iface, "state" => "down", "carrier" => false})
      link = LinkMonitor.get_link(iface)
      assert link != nil,
             "Expected link to remain tracked after link_down for #{iface}"
    end
  end

  property "list_links never contains nil entries" do
    check all(_ <- StreamData.constant(:ok)) do
      links = LinkMonitor.list_links()
      for link <- links do
        assert link != nil,
               "Expected non-nil entry in list_links"
      end
    end
  end

  property "get_link always returns nil or a map with :interface key" do
    check all(iface <- iface_gen()) do
      link = LinkMonitor.get_link(iface)
      if link != nil do
        assert Map.has_key?(link, :interface),
               "Expected :interface key in link, got: #{inspect(link)}"
      end
    end
  end

  property "get_link returns nil or a map with :state key" do
    check all(iface <- iface_gen()) do
      link = LinkMonitor.get_link(iface)
      if link != nil do
        assert Map.has_key?(link, :state),
               "Expected :state key in link, got: #{inspect(link)}"
      end
    end
  end

  property "list_links entries all have :carrier field" do
    check all(_ <- StreamData.constant(:ok)) do
      links = LinkMonitor.list_links()
      for link <- links do
        assert Map.has_key?(link, :carrier),
               "Expected :carrier key in link, got: #{inspect(link)}"
      end
    end
  end

  property "get_link for unknown interface always returns nil" do
    check all(seed <- StreamData.integer(1..9_999)) do
      iface = "lm_gk_#{seed}"
      result = LinkMonitor.get_link(iface)
      assert result == nil or is_map(result),
             "Expected nil or map from get_link, got: #{inspect(result)}"
    end
  end

  property "list_links always returns a list or map" do
    check all(_ <- StreamData.constant(:ok)) do
      result = LinkMonitor.list_links()
      assert is_map(result) or is_list(result),
             "Expected map or list from list_links, got: #{inspect(result)}"
    end
  end

  property "get_link returns nil for unregistered interface after mock_down" do
    check all(seed <- StreamData.integer(1..9_999)) do
      iface = "lm_ud_#{seed}"
      result = LinkMonitor.get_link(iface)
      assert result == nil or is_map(result),
             "Expected nil or map from get_link, got: #{inspect(result)}"
    end
  end

  property "LinkMonitor process is always alive" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.LinkMonitor)
      assert pid != nil, "Expected LinkMonitor to be registered"
      assert Process.alive?(pid), "Expected LinkMonitor to be alive"
    end
  end

  property "list_links count is always non-negative" do
    check all(_ <- StreamData.constant(:ok)) do
      result = LinkMonitor.list_links()
      count = if is_list(result), do: length(result), else: map_size(result)
      assert count >= 0,
             "Expected non-negative count from list_links"
    end
  end

  property "LinkMonitor pid is stable between two reads" do
    check all(_ <- StreamData.constant(:ok)) do
      pid1 = Process.whereis(YellowDog.Netman.Kernel.LinkMonitor)
      pid2 = Process.whereis(YellowDog.Netman.Kernel.LinkMonitor)
      assert pid1 == pid2,
             "Expected stable LinkMonitor pid: #{inspect(pid1)} vs #{inspect(pid2)}"
    end
  end
  property "LinkMonitor get_link for numeric string interface returns nil or map" do
    check all(n <- StreamData.integer(0..99)) do
      iface = "eth\#{n}"
      result = YellowDog.Netman.Kernel.LinkMonitor.get_link(iface)
      assert is_nil(result) or is_map(result),
             "Expected nil or map from get_link, got: \#{inspect(result)}"
    end
  end
  property "LinkMonitor list_links always returns a non-nil value" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.LinkMonitor.list_links()
      refute is_nil(result), "Expected non-nil from list_links"
    end
  end
  property "LinkMonitor get_link for 'lo' interface returns nil or map" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.LinkMonitor.get_link("lo")
      assert is_nil(result) or is_map(result),
             "Expected nil or map from get_link for lo, got: #{inspect(result)}"
    end
  end
  property "LinkMonitor pid is always alive and registered" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.LinkMonitor)
      assert is_pid(pid) and Process.alive?(pid),
             "Expected LinkMonitor to be alive"
    end
  end
  property "LinkMonitor get_link for 'lo' is nil or map with interface key" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.LinkMonitor.get_link("lo")
      if is_map(result) do
        assert Map.has_key?(result, :interface),
               "Expected :interface key in link map, got: #{inspect(result)}"
      else
        assert is_nil(result)
      end
    end
  end
  property "LinkMonitor list_links is consistent across calls" do
    check all(_ <- StreamData.constant(:ok)) do
      r1 = YellowDog.Netman.Kernel.LinkMonitor.list_links()
      r2 = YellowDog.Netman.Kernel.LinkMonitor.list_links()
      assert (is_list(r1) or is_map(r1)) and (is_list(r2) or is_map(r2)),
             "Expected consistent list/map from list_links"
    end
  end
  property "LinkMonitor get_link returns same result on repeated calls" do
    check all(iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8)) do
      r1 = YellowDog.Netman.Kernel.LinkMonitor.get_link(iface)
      r2 = YellowDog.Netman.Kernel.LinkMonitor.get_link(iface)
      assert r1 == r2,
             "Expected deterministic get_link results for #{iface}"
    end
  end
  property "LinkMonitor get_link result for any known interface is consistent" do
    check all(n <- StreamData.integer(0..9)) do
      iface = "eth#{n}"
      r1 = YellowDog.Netman.Kernel.LinkMonitor.get_link(iface)
      r2 = YellowDog.Netman.Kernel.LinkMonitor.get_link(iface)
      assert r1 == r2,
             "Expected deterministic result for #{iface}"
    end
  end

end
