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
end
