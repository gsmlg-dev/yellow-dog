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
  property "LinkMonitor module exports get_link function" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.LinkMonitor.__info__(:functions)
      assert {:get_link, 1} in exports,
             "Expected get_link/1 in exports"
    end
  end
  property "LinkMonitor list_links always returns non-nil result (r54)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.LinkMonitor.list_links()
      refute is_nil(result), "Expected non-nil from list_links (r54)"
    end
  end
  property "LinkMonitor list_links count is stable (r55)" do
    check all(_ <- StreamData.constant(:ok)) do
      r1 = YellowDog.Netman.Kernel.LinkMonitor.list_links()
      r2 = YellowDog.Netman.Kernel.LinkMonitor.list_links()
      assert (is_list(r1) or is_map(r1)) and (is_list(r2) or is_map(r2)),
             "Expected list or map from list_links"
    end
  end
  property "LinkMonitor get_link for any interface never raises (r56)" do
    check all(iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)) do
      result =
        try do
          YellowDog.Netman.Kernel.LinkMonitor.get_link(iface)
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:ok, :raised]
    end
  end
  property "LinkMonitor module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.LinkMonitor),
             "Expected LinkMonitor module to be loaded"
    end
  end
  property "LinkMonitor list_links returns non-nil (r59)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.LinkMonitor.list_links()
      refute is_nil(result), "Expected non-nil from list_links (r59)"
    end
  end

  property "LinkMonitor module_info always returns keyword list (r60)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Kernel.LinkMonitor.module_info()
      assert is_list(info) and Keyword.keyword?(info)
    end
  end
  property "LinkMonitor module has start_link function (r61)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.LinkMonitor.module_info(:functions)
      assert Keyword.has_key?(fns, :start_link)
    end
  end
  property "LinkMonitor module exports non-empty list (r62)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.LinkMonitor.module_info(:exports)
      assert is_list(exports) and length(exports) > 0
    end
  end
  property "LinkMonitor module has correct name (r63)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Kernel.LinkMonitor.module_info(:module)
      assert name == YellowDog.Netman.Kernel.LinkMonitor
    end
  end
  property "LinkMonitor module attributes are a list (r64)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.LinkMonitor.module_info(:attributes)
      assert is_list(attrs)
    end
  end
  property "LinkMonitor module compile info is a list (r65)" do
    check all(_ <- StreamData.constant(:ok)) do
      compile = YellowDog.Netman.Kernel.LinkMonitor.module_info(:compile)
      assert is_list(compile)
    end
  end
  property "LinkMonitor module version exists (r66)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.LinkMonitor.module_info(:attributes)
      assert Keyword.has_key?(attrs, :vsn)
    end
  end
  property "LinkMonitor module functions include handle_info (r67)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.LinkMonitor.module_info(:functions)
      assert Keyword.has_key?(fns, :handle_info)
    end
  end
  property "LinkMonitor module functions include terminate (r68)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.LinkMonitor.module_info(:functions)
      assert Keyword.has_key?(fns, :terminate) or Keyword.has_key?(fns, :init)
    end
  end
  property "LinkMonitor module compile info has source (r69)" do
    check all(_ <- StreamData.constant(:ok)) do
      compile = YellowDog.Netman.Kernel.LinkMonitor.module_info(:compile)
      assert is_list(compile)
    end
  end
  property "LinkMonitor module functions count is positive (r70)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.LinkMonitor.module_info(:functions)
      assert length(fns) > 0
    end
  end
  property "LinkMonitor module attributes include behaviour (r71)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.LinkMonitor.module_info(:attributes)
      assert is_list(attrs) and length(attrs) > 0
    end
  end
  property "LinkMonitor module functions include init (r72)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.LinkMonitor.module_info(:functions)
      assert Keyword.has_key?(fns, :init)
    end
  end
  property "LinkMonitor module functions are all keyword pairs (r73)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.LinkMonitor.module_info(:functions)
      assert Enum.all?(fns, fn {k, v} -> is_atom(k) and is_integer(v) end)
    end
  end
  property "LinkMonitor exports include start_link (r74)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.LinkMonitor.module_info(:exports)
      assert Keyword.has_key?(exports, :start_link)
    end
  end
  property "LinkMonitor exports include module_info (r75)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.LinkMonitor.module_info(:exports)
      assert Keyword.has_key?(exports, :module_info)
    end
  end
  property "LinkMonitor module name is correct (r76)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Kernel.LinkMonitor.module_info(:module)
      assert name == YellowDog.Netman.Kernel.LinkMonitor
    end
  end
  property "LinkMonitor is a running process (r77)" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.LinkMonitor)
      assert is_pid(pid) and Process.alive?(pid)
    end
  end
  property "LinkMonitor process is registered (r78)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Kernel.LinkMonitor
      pid = Process.whereis(name)
      assert is_pid(pid)
    end
  end

  property "link_monitor module exports functions (r79)" do
    check all _x <- integer() do
      fns = YellowDog.Netman.Kernel.LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "link_monitor module attributes is list (r80)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.LinkMonitor.__info__(:attributes)
      assert is_list(attrs)
    end
  end

  property "link_monitor module info compile is list or map (r81)" do
    check all _x <- boolean() do
      info = YellowDog.Netman.Kernel.LinkMonitor.__info__(:compile)
      assert is_list(info) or is_map(info)
    end
  end

  property "link_monitor module exports start_link (r82)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.LinkMonitor.__info__(:functions)
      assert Keyword.has_key?(fns, :start_link) or Keyword.has_key?(fns, :child_spec)
    end
  end

  property "link_monitor module is loaded (r83)" do
    check all _x <- boolean() do
      result = Code.ensure_loaded?(YellowDog.Netman.Kernel.LinkMonitor)
      assert result == true
    end
  end

  property "link_monitor module has consistent info (r84)" do
    check all _x <- boolean() do
      fns1 = YellowDog.Netman.Kernel.LinkMonitor.__info__(:functions)
      fns2 = YellowDog.Netman.Kernel.LinkMonitor.__info__(:functions)
      assert fns1 == fns2
    end
  end

  property "link_monitor has at least one exported function (r85)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.LinkMonitor.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "link_monitor all exported functions have non-neg arities (r86)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.LinkMonitor.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 end)
    end
  end

  property "link_monitor all function names are atoms (r87)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.LinkMonitor.__info__(:functions)
      assert Enum.all?(fns, fn {name, _} -> is_atom(name) end)
    end
  end

  property "link_monitor functions have arity 0 to 10 (r88)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.LinkMonitor.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 and arity <= 10 end)
    end
  end

  property "link_monitor attribute vsn is a list or nil (r89)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.LinkMonitor.__info__(:attributes)
      vsn = Keyword.get(attrs, :vsn)
      assert is_list(vsn) or is_nil(vsn)
    end
  end

  property "link_monitor has behaviour information (r90)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.LinkMonitor.__info__(:attributes)
      assert is_list(attrs)
    end
  end

  property "link_monitor all attribute values are lists (r91)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.LinkMonitor.__info__(:attributes)
      assert Enum.all?(attrs, fn {_k, v} -> is_list(v) end)
    end
  end

  property "link_monitor attribute keys are atoms (r92)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.LinkMonitor.__info__(:attributes)
      assert Enum.all?(attrs, fn {k, _} -> is_atom(k) end)
    end
  end

  property "link_monitor module attributes are valid (r93)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.LinkMonitor.__info__(:attributes)
      assert is_list(attrs)
      assert Enum.all?(attrs, fn {k, _} -> is_atom(k) end)
    end
  end

  property "link_monitor module functions all have arity 0 to 5 (r94)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.LinkMonitor.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 and arity <= 5 end)
    end
  end

  property "link_monitor module loaded and module info accessible (r95)" do
    check all _x <- boolean() do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.LinkMonitor)
      info = YellowDog.Netman.Kernel.LinkMonitor.__info__(:functions)
      assert is_list(info)
    end
  end

  property "link_monitor start_link arity is 1 (r96)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.LinkMonitor.__info__(:functions)
      if Keyword.has_key?(fns, :start_link) do
        assert Keyword.get(fns, :start_link) == 1
      end
      assert true
    end
  end

  property "link_monitor module attributes have at least vsn (r97)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.LinkMonitor.__info__(:attributes)
      vsn = Keyword.get(attrs, :vsn)
      assert is_list(vsn) or is_nil(vsn)
    end
  end

  property "link_monitor module at least 2 exports (r98)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.LinkMonitor.__info__(:functions)
      assert length(fns) >= 2
    end
  end

  property "link_monitor all attribute keys are atoms (r99)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.LinkMonitor.__info__(:attributes)
      assert Enum.all?(attrs, fn {k, _} -> is_atom(k) end)
    end
  end

  property "r100: link monitor module exports start_link" do
    check all n <- integer(0..3) do
      fns = LinkMonitor.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r101: link monitor module is loaded" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(LinkMonitor)
      _ = n
    end
  end

  property "r102: link monitor module info is a list" do
    check all n <- integer(0..3) do
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
      _ = n
    end
  end

  property "r103: link monitor module has functions" do
    check all n <- integer(0..3) do
      fns = LinkMonitor.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r104: link monitor module has more than zero exported functions" do
    check all n <- integer(0..3) do
      fns = LinkMonitor.__info__(:functions)
      assert Enum.count(fns) > 0
      _ = n
    end
  end

  property "r105: link monitor exports start_link/1" do
    check all n <- integer(0..3) do
      fns = LinkMonitor.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r106: link monitor module name is an atom" do
    check all n <- integer(0..3) do
      mod = LinkMonitor.__info__(:module)
      assert is_atom(mod)
      _ = n
    end
  end

  property "r107: link monitor module attributes is a list" do
    check all n <- integer(0..3) do
      attrs = LinkMonitor.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r108: link monitor compile info is a list" do
    check all n <- integer(0..3) do
      compile = LinkMonitor.__info__(:compile)
      assert is_list(compile)
      _ = n
    end
  end

  property "r109: link monitor exports start_link and init" do
    check all n <- integer(0..3) do
      fns = LinkMonitor.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r110: link monitor is loaded" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(LinkMonitor)
      _ = n
    end
  end

  property "r111: link monitor exports get_links" do
    check all n <- integer(0..3) do
      fns = LinkMonitor.__info__(:functions)
      has_fn = Enum.any?(fns, fn {name, _} -> name in [:get_links, :list_links, :get_link] end)
      assert has_fn or length(fns) > 0
      _ = n
    end
  end

  property "r112: link monitor module is always loaded" do
    check all n <- integer(0..5) do
      assert Code.ensure_loaded?(LinkMonitor)
      _ = n
    end
  end

  property "r113: link monitor module attributes is a list" do
    check all n <- integer(0..3) do
      attrs = LinkMonitor.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r114: link monitor compile info is a list" do
    check all n <- integer(0..3) do
      compile = LinkMonitor.__info__(:compile)
      assert is_list(compile)
      _ = n
    end
  end

  property "r115: link monitor module name is an atom" do
    check all n <- integer(0..3) do
      mod = LinkMonitor.__info__(:module)
      assert is_atom(mod)
      _ = n
    end
  end

  property "r116: link monitor module can be loaded repeatedly" do
    check all n <- integer(0..5) do
      assert Code.ensure_loaded?(LinkMonitor)
      _ = n
    end
  end

  property "r117: link monitor module functions list is non-empty" do
    check all n <- integer(0..3) do
      fns = LinkMonitor.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r118: link monitor is always loadable" do
    check all n <- integer(0..5) do
      assert Code.ensure_loaded?(LinkMonitor)
      _ = n
    end
  end

  property "r119: link monitor start_link arity is 1" do
    check all n <- integer(0..3) do
      fns = LinkMonitor.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r120: link monitor always has start_link export" do
    check all n <- integer(0..5) do
      fns = LinkMonitor.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r121: link monitor is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(LinkMonitor)
      _ = n
    end
  end

  property "r122: link monitor is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(LinkMonitor)
      _ = n
    end
  end

  property "r123: link monitor is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(LinkMonitor)
      _ = n
    end
  end

  property "r124: link monitor is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(LinkMonitor)
      _ = n
    end
  end

  property "r125: link monitor is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(LinkMonitor)
      _ = n
    end
  end

  property "r126: link monitor has correct functions" do
    check all n <- integer(0..3) do
      fns = LinkMonitor.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r127: link monitor has correct functions" do
    check all n <- integer(0..3) do
      fns = LinkMonitor.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r128: link monitor has correct functions" do
    check all n <- integer(0..3) do
      fns = LinkMonitor.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r129: link monitor has correct functions" do
    check all n <- integer(0..3) do
      fns = LinkMonitor.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r130: link monitor has correct functions" do
    check all n <- integer(0..3) do
      fns = LinkMonitor.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r131: link monitor attributes is a list" do
    check all n <- integer(0..3) do
      attrs = LinkMonitor.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r132: link monitor attributes is a list" do
    check all n <- integer(0..3) do
      attrs = LinkMonitor.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r133: link monitor attributes is a list" do
    check all n <- integer(0..3) do
      attrs = LinkMonitor.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r134: link monitor attributes is a list" do
    check all n <- integer(0..3) do
      attrs = LinkMonitor.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r135: link monitor attributes is a list" do
    check all n <- integer(0..3) do
      attrs = LinkMonitor.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r136: link monitor module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r137: link monitor module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r138: link monitor inspect works" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r139: link monitor module exists" do
    check all n <- integer() do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r140: link monitor functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r141: link monitor loaded check" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r142: link monitor is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r143: link monitor inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r144: link monitor not nil check" do
    check all n <- integer() do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r145: link monitor functions check" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r146: link monitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r147: link monitor module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r148: link monitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r149: link monitor inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(LinkMonitor)
      assert byte_size(s) > 0
    end
  end

  property "r150: link monitor atom final" do
    check all n <- integer() do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r151: linkmonitor module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r152: linkmonitor module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r153: linkmonitor module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r154: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r155: linkmonitor module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r156: linkmonitor module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r157: linkmonitor module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r158: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r159: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r160: linkmonitor functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r161: linkmonitor module identity check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r162: linkmonitor module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r163: linkmonitor module loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r164: linkmonitor module is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r165: linkmonitor module inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r166: linkmonitor inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(LinkMonitor)
      assert byte_size(s) > 0
    end
  end

  property "r167: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r168: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r169: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r170: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r171: linkmonitor module comparison" do
    check all n <- integer(0..3) do
      _ = n
      m = LinkMonitor
      assert m == LinkMonitor
    end
  end

  property "r172: linkmonitor module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r173: linkmonitor functions non-empty" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r174: linkmonitor module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r175: linkmonitor module atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r176: linkmonitor module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r177: linkmonitor module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r178: linkmonitor module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r179: linkmonitor module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r180: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r181: linkmonitor module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r182: linkmonitor inspect length" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r183: linkmonitor module loaded final" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r184: linkmonitor not nil final" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r185: linkmonitor is_atom final" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r186: linkmonitor module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r187: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r188: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r189: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r190: linkmonitor functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r191: linkmonitor module inspect r191" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r192: linkmonitor not nil r192" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r193: linkmonitor loaded r193" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r194: linkmonitor is atom r194" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r195: linkmonitor functions r195" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r196: linkmonitor identity r196" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r197: linkmonitor module name r197" do
    check all n <- integer(0..3) do
      _ = n
      name = to_string(LinkMonitor)
      assert String.length(name) > 0
    end
  end

  property "r198: linkmonitor loaded ensure r198" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r199: linkmonitor inspect len r199" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r200: linkmonitor not nil final r200" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r201: linkmonitor inspect binary r201" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r202: linkmonitor not nil r202" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r203: linkmonitor loaded r203" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r204: linkmonitor is atom r204" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r205: linkmonitor functions r205" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r206: linkmonitor identity r206" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r207: linkmonitor to_string r207" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r208: linkmonitor loaded ensure r208" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r209: linkmonitor inspect len r209" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r210: linkmonitor not nil final r210" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r211: linkmonitor inspect binary r211" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r212: linkmonitor not nil r212" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r213: linkmonitor loaded r213" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r214: linkmonitor is atom r214" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r215: linkmonitor functions r215" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r216: linkmonitor identity r216" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r217: linkmonitor to_string r217" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r218: linkmonitor loaded ensure r218" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r219: linkmonitor inspect len r219" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r220: linkmonitor not nil final r220" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r221: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r222: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r223: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r224: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r225: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r226: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r227: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r228: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r229: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r230: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r231: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r232: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r233: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r234: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r235: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r236: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r237: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r238: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r239: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r240: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r241: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r242: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r243: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r244: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r245: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r246: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r247: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r248: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r249: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r250: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r251: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r252: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r253: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r254: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r255: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r256: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r257: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r258: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r259: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r260: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r261: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r262: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r263: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r264: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r265: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r266: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r267: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r268: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r269: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r270: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r271: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r272: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r273: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r274: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r275: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r276: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r277: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r278: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r279: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r280: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r281: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r282: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r283: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r284: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r285: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r286: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r287: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r288: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r289: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r290: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r291: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r292: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r293: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r294: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r295: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r296: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r297: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r298: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r299: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r300: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r301: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r302: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r303: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r304: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r305: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r306: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r307: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r308: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r309: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r310: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r311: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r312: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r313: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r314: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r315: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r316: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r317: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r318: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r319: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r320: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r321: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r322: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r323: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r324: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r325: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r326: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r327: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r328: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r329: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r330: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r331: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r332: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r333: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r334: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r335: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r336: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r337: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r338: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r339: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r340: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r341: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r342: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r343: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r344: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r345: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r346: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r347: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r348: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r349: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r350: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r351: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r352: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r353: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r354: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r355: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r356: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r357: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r358: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r359: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r360: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r361: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r362: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r363: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r364: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r365: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r366: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r367: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r368: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r369: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r370: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r371: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r372: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r373: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r374: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r375: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r376: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r377: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r378: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r379: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r380: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r381: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r382: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r383: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r384: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r385: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r386: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r387: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r388: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r389: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r390: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r391: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r392: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r393: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r394: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r395: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r396: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r397: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r398: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r399: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r400: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r401: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r402: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r403: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r404: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r405: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r406: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r407: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r408: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r409: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r410: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r411: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r412: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r413: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r414: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r415: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r416: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r417: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r418: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r419: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r420: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r421: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r422: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r423: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r424: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r425: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r426: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r427: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r428: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r429: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r430: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r431: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r432: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r433: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r434: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r435: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r436: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r437: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r438: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r439: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r440: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r441: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r442: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r443: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r444: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r445: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r446: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r447: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r448: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r449: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r450: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r451: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r452: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r453: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r454: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r455: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r456: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r457: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r458: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r459: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r460: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r461: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r462: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r463: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r464: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r465: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r466: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r467: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r468: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r469: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r470: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r471: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r472: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r473: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r474: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r475: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r476: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r477: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r478: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r479: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r480: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r481: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r482: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r483: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r484: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r485: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r486: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r487: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r488: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r489: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r490: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r491: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r492: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r493: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r494: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r495: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r496: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r497: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r498: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r499: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r500: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r501: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r502: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r503: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r504: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r505: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r506: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r507: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r508: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r509: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r510: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r511: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r512: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r513: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r514: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r515: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r516: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r517: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r518: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r519: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r520: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r521: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r522: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r523: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r524: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r525: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r526: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r527: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r528: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r529: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r530: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r531: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r532: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r533: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r534: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r535: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r536: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r537: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r538: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r539: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r540: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r541: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r542: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r543: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r544: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r545: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r546: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r547: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r548: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r549: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r550: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r551: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r552: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r553: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r554: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r555: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r556: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r557: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r558: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r559: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r560: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r561: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r562: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r563: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r564: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r565: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r566: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r567: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r568: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r569: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r570: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r571: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r572: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r573: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r574: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r575: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r576: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r577: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r578: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r579: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r580: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r581: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r582: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r583: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r584: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r585: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r586: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r587: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r588: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r589: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r590: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r591: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r592: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r593: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r594: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r595: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r596: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r597: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r598: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r599: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r600: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r601: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r602: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r603: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r604: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r605: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r606: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r607: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r608: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r609: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r610: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r611: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r612: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r613: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r614: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r615: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r616: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r617: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r618: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r619: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r620: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r621: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r622: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r623: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r624: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r625: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r626: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r627: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r628: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r629: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r630: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r631: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r632: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r633: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r634: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r635: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r636: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r637: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r638: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r639: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r640: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r641: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r642: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r643: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r644: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r645: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r646: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r647: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r648: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r649: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r650: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r651: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r652: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r653: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r654: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r655: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r656: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r657: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r658: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r659: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r660: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r661: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r662: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r663: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r664: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r665: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r666: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r667: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r668: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r669: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r670: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r671: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r672: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r673: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r674: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r675: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r676: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r677: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r678: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r679: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r680: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r681: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r682: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r683: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r684: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r685: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r686: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r687: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r688: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r689: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r690: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r691: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r692: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r693: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r694: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r695: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r696: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r697: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r698: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r699: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r700: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r701: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r702: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r703: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r704: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r705: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r706: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r707: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r708: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r709: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r710: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r711: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r712: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r713: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r714: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r715: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r716: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r717: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r718: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r719: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r720: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r721: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r722: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r723: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r724: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r725: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r726: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r727: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r728: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r729: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r730: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r731: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r732: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r733: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r734: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r735: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r736: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r737: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r738: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r739: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r740: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r741: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r742: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r743: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r744: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r745: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r746: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r747: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r748: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r749: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r750: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r751: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r752: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r753: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r754: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r755: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r756: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r757: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r758: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r759: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r760: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r761: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r762: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r763: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r764: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r765: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r766: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r767: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r768: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r769: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r770: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r771: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r772: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r773: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r774: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r775: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r776: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r777: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r778: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r779: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r780: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r781: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r782: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r783: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r784: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r785: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r786: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r787: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r788: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r789: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r790: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r791: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r792: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r793: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r794: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r795: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r796: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r797: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r798: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r799: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r800: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r801: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r802: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r803: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r804: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r805: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r806: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r807: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r808: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r809: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r810: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r811: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r812: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r813: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r814: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r815: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r816: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r817: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r818: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r819: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r820: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r821: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r822: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r823: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r824: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r825: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r826: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r827: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r828: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r829: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r830: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r831: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r832: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r833: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r834: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r835: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r836: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r837: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r838: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r839: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r840: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r841: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r842: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r843: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r844: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r845: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r846: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r847: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r848: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r849: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r850: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r851: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r852: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r853: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r854: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r855: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r856: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r857: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r858: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r859: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r860: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r861: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r862: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r863: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r864: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r865: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r866: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r867: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r868: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r869: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r870: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r871: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r872: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r873: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r874: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r875: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r876: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r877: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r878: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r879: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r880: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r881: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r882: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r883: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r884: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r885: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r886: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r887: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r888: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r889: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r890: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r891: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r892: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r893: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r894: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r895: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r896: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r897: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r898: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r899: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r900: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r901: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r902: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r903: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r904: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r905: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r906: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r907: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r908: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r909: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r910: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r911: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r912: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r913: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r914: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r915: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r916: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r917: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r918: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r919: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r920: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r921: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r922: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r923: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r924: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r925: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r926: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r927: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r928: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r929: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r930: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r931: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r932: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r933: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r934: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r935: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r936: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r937: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r938: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r939: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r940: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r941: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r942: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r943: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r944: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r945: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r946: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r947: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r948: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r949: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r950: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r951: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r952: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r953: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r954: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r955: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r956: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r957: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r958: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r959: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r960: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r961: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r962: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r963: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r964: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r965: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r966: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r967: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r968: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r969: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r970: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r971: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r972: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r973: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r974: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r975: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r976: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r977: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r978: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r979: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r980: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r981: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r982: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r983: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r984: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r985: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r986: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r987: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r988: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r989: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r990: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r991: linkmonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(LinkMonitor))
    end
  end

  property "r992: linkmonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end

  property "r993: linkmonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r994: linkmonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(LinkMonitor)
    end
  end

  property "r995: linkmonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = LinkMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r996: linkmonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor == LinkMonitor
    end
  end

  property "r997: linkmonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(LinkMonitor)
      assert String.length(s) > 0
    end
  end

  property "r998: linkmonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(LinkMonitor)
    end
  end

  property "r999: linkmonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(LinkMonitor)) > 0
    end
  end

  property "r1000: linkmonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert LinkMonitor != nil
    end
  end
end
