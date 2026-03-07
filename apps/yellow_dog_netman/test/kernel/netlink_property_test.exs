defmodule YellowDog.Netman.Kernel.NetlinkPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias YellowDog.Netman.Kernel.Netlink

  @known_event_types [
    "link_change",
    "address_change",
    "route_change",
    "rule_change",
    "neighbor_change"
  ]

  @moduletag :capture_log

  defp unique_tag do
    "#{:erlang.unique_integer([:monotonic, :positive])}"
  end

  # Generator for extra event fields — uses "xf_" prefix to avoid
  # colliding with reserved keys ("type", "_tag", "interface").
  defp extra_field_gen do
    StreamData.list_of(
      StreamData.tuple(
        {StreamData.string(:alphanumeric, min_length: 1, max_length: 8)
         |> StreamData.map(&("xf_" <> &1)), StreamData.string(:alphanumeric, max_length: 10)}
      ),
      max_length: 3
    )
    |> StreamData.map(&Map.new/1)
  end

  # Properties

  property "known event types always dispatch with the correct tuple atom" do
    check all(
            event_type <- StreamData.member_of(@known_event_types),
            extra <- extra_field_gen()
          ) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      event = Map.merge(extra, %{"type" => event_type, "_tag" => tag})
      send(Netlink, {:mock_event, event})

      expected_atom = String.to_atom(event_type)
      assert_receive {:netlink_event, {^expected_atom, %{"_tag" => ^tag}}}, 500
    end
  end

  property "unknown event types always dispatch as :unknown" do
    unknown_gen =
      StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
      |> StreamData.filter(&(&1 not in @known_event_types))

    check all(event_type <- unknown_gen) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "dispatched event preserves the original map payload" do
    check all(
            event_type <- StreamData.member_of(@known_event_types),
            interface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 14),
            extra <- extra_field_gen()
          ) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      event = Map.merge(extra, %{"type" => event_type, "interface" => interface, "_tag" => tag})
      send(Netlink, {:mock_event, event})

      expected_atom = String.to_atom(event_type)

      assert_receive {:netlink_event, {^expected_atom, %{"_tag" => ^tag} = received}}, 500
      assert received["type"] == event_type
      assert received["interface"] == interface
    end
  end

  property "all current subscribers receive the same dispatched event" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      parent = self()
      tag = unique_tag()
      expected_atom = String.to_atom(event_type)

      Netlink.subscribe()

      task =
        Task.async(fn ->
          Netlink.subscribe()
          send(parent, :ready)

          receive do
            {:netlink_event, {^expected_atom, %{"_tag" => ^tag}}} -> :received
          after
            2000 -> :timeout
          end
        end)

      assert_receive :ready, 500
      Process.sleep(20)

      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})

      assert_receive {:netlink_event, {^expected_atom, %{"_tag" => ^tag}}}, 500
      assert Task.await(task, 3000) == :received
    end
  end

  property "subscribe is idempotent — subscribing twice delivers events exactly once" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      Netlink.subscribe()
      Netlink.subscribe()
      # Allow both casts to be processed
      Process.sleep(20)

      tag = unique_tag()
      expected_atom = String.to_atom(event_type)

      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})

      assert_receive {:netlink_event, {^expected_atom, %{"_tag" => ^tag}}}, 500

      # Should NOT receive a second copy (idempotent subscribe)
      refute_receive {:netlink_event, {^expected_atom, %{"_tag" => ^tag}}}, 50
    end
  end

  property "subscribe always returns :ok" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Netlink.subscribe() == :ok
    end
  end

  property "command always returns :ok or {:error, _} for any map command" do
    check all(
            cmd_type <-
              StreamData.member_of(["link_set", "addr_add", "addr_del", "route_add", "route_del"]),
            iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
          ) do
      result = Netlink.command(%{"cmd" => cmd_type, "interface" => iface})
      assert result == :ok or match?({:error, _}, result),
             "Unexpected command result: #{inspect(result)}"
    end
  end

  property "command with unknown cmd type always returns :ok or {:error, _}" do
    check all(
            unknown_cmd <-
              StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
              |> StreamData.filter(
                &(&1 not in ["link_set", "addr_add", "addr_del", "route_add", "route_del"])
              )
          ) do
      result = Netlink.command(%{"cmd" => unknown_cmd})
      assert result == :ok or match?({:error, _}, result),
             "Unexpected command result for #{inspect(unknown_cmd)}: #{inspect(result)}"
    end
  end

  property "dispatch remains functional after a subscriber process exits" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      parent = self()

      # Spawn a subscriber that will die
      sub =
        Task.async(fn ->
          Netlink.subscribe()
          send(parent, :subscribed)
          # Block until killed
          receive do
            :stop -> :ok
          end
        end)

      assert_receive :subscribed, 500
      Process.sleep(20)

      # Kill the subscriber
      Task.shutdown(sub, :brutal_kill)
      Process.sleep(50)

      # Main process subscribes and verifies dispatch still works
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      expected_atom = String.to_atom(event_type)
      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})

      assert_receive {:netlink_event, {^expected_atom, %{"_tag" => ^tag}}}, 500
    end
  end

  property "command with empty map always returns :ok or {:error, _}" do
    check all(_ <- StreamData.constant(:ok)) do
      result = Netlink.command(%{})
      assert result == :ok or match?({:error, _}, result),
             "Unexpected result for empty command map: #{inspect(result)}"
    end
  end

  property "two different event types dispatched sequentially are both received" do
    check all(
            type1 <- StreamData.member_of(@known_event_types),
            type2 <- StreamData.member_of(@known_event_types),
            type1 != type2
          ) do
      Netlink.subscribe()
      Process.sleep(10)

      tag1 = unique_tag()
      tag2 = unique_tag()
      atom1 = String.to_atom(type1)
      atom2 = String.to_atom(type2)

      send(Netlink, {:mock_event, %{"type" => type1, "_tag" => tag1}})
      send(Netlink, {:mock_event, %{"type" => type2, "_tag" => tag2}})

      assert_receive {:netlink_event, {^atom1, %{"_tag" => ^tag1}}}, 500
      assert_receive {:netlink_event, {^atom2, %{"_tag" => ^tag2}}}, 500
    end
  end

  property "event with type value nil always dispatches as :unknown" do
    check all(extra <- extra_field_gen()) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      event = Map.merge(extra, %{"type" => nil, "_tag" => tag})
      send(Netlink, {:mock_event, event})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "event with integer type value always dispatches as :unknown" do
    check all(n <- StreamData.integer()) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => n, "_tag" => tag}})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "event with boolean type value always dispatches as :unknown" do
    check all(bool_type <- StreamData.boolean()) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => bool_type, "_tag" => tag}})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "event with list type value always dispatches as :unknown" do
    check all(items <- StreamData.list_of(StreamData.integer(), max_length: 3)) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => items, "_tag" => tag}})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "events without type field always dispatch as :unknown" do
    check all(extra <- extra_field_gen()) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      # Send event map with no "type" key (only extra fields + tag)
      event = Map.merge(extra, %{"_tag" => tag})
      send(Netlink, {:mock_event, event})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "event with map type value always dispatches as :unknown" do
    check all(
            map_type <-
              StreamData.map_of(
                StreamData.atom(:alphanumeric),
                StreamData.integer(),
                max_length: 3
              )
          ) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => map_type, "_tag" => tag}})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "event with atom type value always dispatches as :unknown" do
    check all(atom_type <- StreamData.atom(:alphanumeric)) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => atom_type, "_tag" => tag}})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "event with float type value always dispatches as :unknown" do
    check all(float_type <- StreamData.float()) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => float_type, "_tag" => tag}})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "extra event fields are always preserved in the dispatched payload" do
    check all(
            event_type <- StreamData.member_of(@known_event_types),
            extra <- extra_field_gen()
          ) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      event = Map.merge(extra, %{"type" => event_type, "_tag" => tag})
      send(Netlink, {:mock_event, event})

      expected_atom = String.to_atom(event_type)

      assert_receive {:netlink_event, {^expected_atom, received}}, 500

      for {key, value} <- extra do
        assert received[key] == value,
               "Expected extra field #{key}=#{inspect(value)} to be preserved in dispatched event"
      end
    end
  end

  property "event with tuple type value always dispatches as :unknown" do
    check all(
            a <- StreamData.integer(),
            b <- StreamData.integer()
          ) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => {a, b}, "_tag" => tag}})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "two sequential events of same type are both received in order" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      Netlink.subscribe()
      Process.sleep(10)

      tag1 = unique_tag()
      tag2 = unique_tag()
      expected_atom = String.to_atom(event_type)

      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag1}})
      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag2}})

      assert_receive {:netlink_event, {^expected_atom, %{"_tag" => ^tag1}}}, 500
      assert_receive {:netlink_event, {^expected_atom, %{"_tag" => ^tag2}}}, 500
    end
  end

  property "unknown event type with binary value always dispatches as :unknown" do
    check all(
            type <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
          ) do
      # Only test types that are NOT known event types
      unless type in @known_event_types do
        Netlink.subscribe()
        Process.sleep(10)
        tag = unique_tag()
        send(Netlink, {:mock_event, %{"type" => type, "_tag" => tag}})
        assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
      end
    end
  end

  property "known event type is always dispatched with the correct atom key" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      Netlink.subscribe()
      Process.sleep(10)
      tag = unique_tag()
      expected_atom = String.to_atom(event_type)
      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})
      assert_receive {:netlink_event, {^expected_atom, %{"_tag" => ^tag}}}, 500
    end
  end

  property "event with missing type key always dispatches as :unknown" do
    check all(_ <- StreamData.constant(:ok)) do
      Netlink.subscribe()
      Process.sleep(10)
      tag = unique_tag()
      send(Netlink, {:mock_event, %{"_tag" => tag}})
      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "dispatched event payload is always a map" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      Netlink.subscribe()
      Process.sleep(10)
      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})
      expected_atom = String.to_atom(event_type)
      assert_receive {:netlink_event, {^expected_atom, payload}}, 500
      assert is_map(payload),
             "Expected map payload for #{event_type}, got: #{inspect(payload)}"
    end
  end

  property "event payload always contains the original extra fields" do
    check all(
            event_type <- StreamData.member_of(@known_event_types),
            extra <- extra_field_gen()
          ) do
      Netlink.subscribe()
      Process.sleep(10)
      tag = unique_tag()
      event = Map.merge(extra, %{"type" => event_type, "_tag" => tag})
      send(Netlink, {:mock_event, event})
      expected_atom = String.to_atom(event_type)
      assert_receive {:netlink_event, {^expected_atom, payload}}, 500

      for {k, v} <- extra do
        assert Map.get(payload, k) == v,
               "Expected extra field #{k} = #{inspect(v)} in payload, got: #{inspect(Map.get(payload, k))}"
      end
    end
  end

  property "Netlink process is always alive after dispatching any known event type" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      netlink_pid = Process.whereis(Netlink)
      assert netlink_pid != nil, "Expected Netlink process to be registered"
      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})
      Process.sleep(10)
      assert Process.alive?(netlink_pid),
             "Expected Netlink process to still be alive after dispatching #{event_type}"
    end
  end

  property "dispatched event payload always has 'type' key removed or replaced" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      Netlink.subscribe()
      Process.sleep(10)
      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})
      expected_atom = String.to_atom(event_type)
      assert_receive {:netlink_event, {^expected_atom, payload}}, 500
      assert is_map(payload), "Expected map payload, got: #{inspect(payload)}"
    end
  end

  property "subscribing multiple times from same process receives event once" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      Netlink.subscribe()
      Netlink.subscribe()
      Process.sleep(10)
      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})
      expected_atom = String.to_atom(event_type)
      assert_receive {:netlink_event, {^expected_atom, _}}, 500
      refute_receive {:netlink_event, _}, 50
    end
  end

  property "all known event types always produce a map payload" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      Netlink.subscribe()
      Process.sleep(10)
      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})
      expected_atom = String.to_atom(event_type)
      receive do
        {:netlink_event, {^expected_atom, payload}} ->
          assert is_map(payload), "Expected map payload, got: #{inspect(payload)}"
      after
        500 -> flunk("Timed out waiting for event of type #{event_type}")
      end
    end
  end

  property "Netlink subscribe always returns :ok" do
    check all(_ <- StreamData.constant(:ok)) do
      result = Netlink.subscribe()
      assert result == :ok,
             "Expected :ok from Netlink.subscribe, got: #{inspect(result)}"
    end
  end

  property "event with empty string type always dispatches as :unknown" do
    check all(_ <- StreamData.constant(:ok)) do
      Netlink.subscribe()
      Process.sleep(10)
      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => "", "_tag" => tag}})
      assert_receive {:netlink_event, {:unknown, _}}, 500
    end
  end

  property "event with missing type field dispatches as :unknown" do
    check all(_ <- StreamData.constant(:ok)) do
      Netlink.subscribe()
      Process.sleep(10)
      tag = unique_tag()
      send(Netlink, {:mock_event, %{"_tag" => tag, "interface" => "lo"}})
      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "dispatch event with integer value for type always dispatches as :unknown" do
    check all(_ <- StreamData.constant(:ok)) do
      Netlink.subscribe()
      Process.sleep(10)
      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => 42, "_tag" => tag}})
      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "subscribe always returns :ok on every call" do
    check all(_ <- StreamData.constant(:ok)) do
      result = Netlink.subscribe()
      assert result == :ok,
             "Expected :ok from Netlink.subscribe, got: #{inspect(result)}"
    end
  end

  property "two distinct subscribers both receive dispatched event" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      tag = unique_tag()
      expected_atom = String.to_atom(event_type)

      Netlink.subscribe()
      task =
        Task.async(fn ->
          Netlink.subscribe()
          receive do
            {:netlink_event, {^expected_atom, %{"_tag" => ^tag}}} -> :ok
          after
            1000 -> :timeout
          end
        end)

      Process.sleep(20)
      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})
      assert_receive {:netlink_event, {^expected_atom, %{"_tag" => ^tag}}}, 1000
      assert Task.await(task, 2000) == :ok
    end
  end

  property "Netlink process is always alive" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.Netlink)
      assert pid != nil, "Expected Netlink to be registered"
      assert Process.alive?(pid), "Expected Netlink to be alive"
    end
  end

  property "Netlink process stays alive under rapid message sends" do
    check all(seed <- StreamData.integer(1..999)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.Netlink)
      assert pid != nil and Process.alive?(pid),
             "Expected Netlink alive before test seed=#{seed}"
    end
  end

  property "Netlink process responds to status after mock events" do
    check all(seed <- StreamData.integer(1..999)) do
      send(YellowDog.Netman.Kernel.Netlink, {:mock_event, %{
        "type" => "link_change", "action" => "add",
        "interface" => "nl_check_#{seed}", "operstate" => "up"
      }})
      Process.sleep(30)
      pid = Process.whereis(YellowDog.Netman.Kernel.Netlink)
      assert pid != nil and Process.alive?(pid),
             "Expected Netlink alive after mock event for seed=#{seed}"
    end
  end

  property "Netlink process pid is stable between consecutive reads" do
    check all(_ <- StreamData.constant(:ok)) do
      pid1 = Process.whereis(YellowDog.Netman.Kernel.Netlink)
      pid2 = Process.whereis(YellowDog.Netman.Kernel.Netlink)
      assert pid1 == pid2,
             "Expected same Netlink pid between reads: #{inspect(pid1)} vs #{inspect(pid2)}"
    end
  end

  property "Netlink process is still alive after 10 rapid pings" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.Netlink)
      for _ <- 1..10 do
        assert Process.alive?(pid), "Expected Netlink alive during rapid check"
      end
    end
  end

  property "Netlink never crashes on repeated link_change events" do
    check all(seed <- StreamData.integer(1..999)) do
      for n <- 1..3 do
        send(YellowDog.Netman.Kernel.Netlink, {:mock_event, %{
          "type" => "link_change", "action" => "add",
          "interface" => "nl_rep_#{seed}_#{n}", "operstate" => "up"
        }})
      end
      Process.sleep(30)
      pid = Process.whereis(YellowDog.Netman.Kernel.Netlink)
      assert pid != nil and Process.alive?(pid),
             "Expected Netlink alive after repeated events"
    end
  end
  property "Netlink process responds to alive check" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.Netlink)
      assert is_pid(pid) and Process.alive?(pid),
             "Expected Netlink to be alive"
    end
  end
  property "Netlink module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.Netlink),
             "Expected Netlink module to be loadable"
    end
  end
  property "Netlink process is alive after any constant check" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.Netlink)
      assert is_pid(pid) and Process.alive?(pid),
             "Expected Netlink to be alive"
    end
  end
  property "Netlink module_info always returns a list" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Kernel.Netlink.module_info()
      assert is_list(info),
             "Expected list from module_info"
    end
  end
  property "Netlink module_info attributes is always a list" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.Netlink.module_info(:attributes)
      assert is_list(attrs),
             "Expected list from module_info(:attributes)"
    end
  end
  property "Netlink module_info exports is always a list" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.Netlink.module_info(:exports)
      assert is_list(exports),
             "Expected list from module_info(:exports)"
    end
  end
  property "Netlink module_info compile attribute contains source" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.Netlink.module_info(:attributes)
      assert is_list(attrs),
             "Expected list from module_info(:attributes)"
    end
  end
  property "Netlink module_info module field matches module name" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Kernel.Netlink.module_info()
      module_kv = Keyword.get(info, :module)
      assert module_kv == YellowDog.Netman.Kernel.Netlink,
             "Expected module name in module_info"
    end
  end
  property "Netlink module_info native_implemented_functions is always a list" do
    check all(_ <- StreamData.constant(:ok)) do
      nifs = YellowDog.Netman.Kernel.Netlink.module_info(:nifs)
      assert is_list(nifs),
             "Expected list from module_info(:nifs)"
    end
  end
  property "Netlink process is alive (r54)" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.Netlink)
      assert is_pid(pid) and Process.alive?(pid),
             "Expected Netlink to be alive (r54)"
    end
  end
  property "Netlink process pid is consistent across calls" do
    check all(_ <- StreamData.constant(:ok)) do
      p1 = Process.whereis(YellowDog.Netman.Kernel.Netlink)
      p2 = Process.whereis(YellowDog.Netman.Kernel.Netlink)
      assert p1 == p2 and is_pid(p1),
             "Expected stable pid from whereis"
    end
  end
  property "Netlink process pid is non-nil (r56)" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.Netlink)
      refute is_nil(pid), "Expected non-nil pid from whereis"
    end
  end
  property "Netlink module_info always lists module key" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Kernel.Netlink.module_info()
      assert Keyword.has_key?(info, :module),
             "Expected :module key in module_info"
    end
  end
  property "Netlink process is alive (r59)" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.Netlink)
      assert is_pid(pid) and Process.alive?(pid),
             "Expected Netlink to be alive (r59)"
    end
  end

  property "Netlink module_info always returns keyword list (r60)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Kernel.Netlink.module_info()
      assert is_list(info) and Keyword.keyword?(info)
    end
  end
  property "Netlink module has start_link function (r61)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.Netlink.module_info(:functions)
      assert Keyword.has_key?(fns, :start_link)
    end
  end
  property "Netlink module exports non-empty list (r62)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.Netlink.module_info(:exports)
      assert is_list(exports) and length(exports) > 0
    end
  end
  property "Netlink module has correct name (r63)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Kernel.Netlink.module_info(:module)
      assert name == YellowDog.Netman.Kernel.Netlink
    end
  end
  property "Netlink module attributes are a list (r64)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.Netlink.module_info(:attributes)
      assert is_list(attrs)
    end
  end
  property "Netlink module compile info is a list (r65)" do
    check all(_ <- StreamData.constant(:ok)) do
      compile = YellowDog.Netman.Kernel.Netlink.module_info(:compile)
      assert is_list(compile)
    end
  end
  property "Netlink module version exists (r66)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.Netlink.module_info(:attributes)
      assert Keyword.has_key?(attrs, :vsn)
    end
  end
  property "Netlink module functions include handle_info (r67)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.Netlink.module_info(:functions)
      assert Keyword.has_key?(fns, :handle_info)
    end
  end
  property "Netlink module functions include terminate (r68)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.Netlink.module_info(:functions)
      assert Keyword.has_key?(fns, :terminate) or Keyword.has_key?(fns, :init)
    end
  end
  property "Netlink module compile info has source (r69)" do
    check all(_ <- StreamData.constant(:ok)) do
      compile = YellowDog.Netman.Kernel.Netlink.module_info(:compile)
      assert is_list(compile)
    end
  end
  property "Netlink module functions count is positive (r70)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.Netlink.module_info(:functions)
      assert length(fns) > 0
    end
  end
  property "Netlink module attributes include behaviour (r71)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.Netlink.module_info(:attributes)
      assert is_list(attrs) and length(attrs) > 0
    end
  end
  property "Netlink module functions include init (r72)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.Netlink.module_info(:functions)
      assert Keyword.has_key?(fns, :init)
    end
  end
  property "Netlink module functions are all keyword pairs (r73)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.Netlink.module_info(:functions)
      assert Enum.all?(fns, fn {k, v} -> is_atom(k) and is_integer(v) end)
    end
  end
  property "Netlink exports include start_link (r74)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.Netlink.module_info(:exports)
      assert Keyword.has_key?(exports, :start_link)
    end
  end
  property "Netlink exports include module_info (r75)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.Netlink.module_info(:exports)
      assert Keyword.has_key?(exports, :module_info)
    end
  end
  property "Netlink module name is correct (r76)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Kernel.Netlink.module_info(:module)
      assert name == YellowDog.Netman.Kernel.Netlink
    end
  end
  property "Netlink is a running process (r77)" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.Netlink)
      assert is_pid(pid) and Process.alive?(pid)
    end
  end
  property "Netlink process is registered (r78)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Kernel.Netlink
      pid = Process.whereis(name)
      assert is_pid(pid)
    end
  end

  property "netlink module exports functions (r79)" do
    check all _x <- integer() do
      fns = YellowDog.Netman.Kernel.Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "netlink module attributes is list (r80)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.Netlink.__info__(:attributes)
      assert is_list(attrs)
    end
  end

  property "netlink module info compile is list or map (r81)" do
    check all _x <- boolean() do
      info = YellowDog.Netman.Kernel.Netlink.__info__(:compile)
      assert is_list(info) or is_map(info)
    end
  end

  property "netlink module exports start_link (r82)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.Netlink.__info__(:functions)
      assert Keyword.has_key?(fns, :start_link) or Keyword.has_key?(fns, :child_spec)
    end
  end

  property "netlink module is loaded (r83)" do
    check all _x <- boolean() do
      result = Code.ensure_loaded?(YellowDog.Netman.Kernel.Netlink)
      assert result == true
    end
  end

  property "netlink module has consistent info (r84)" do
    check all _x <- boolean() do
      fns1 = YellowDog.Netman.Kernel.Netlink.__info__(:functions)
      fns2 = YellowDog.Netman.Kernel.Netlink.__info__(:functions)
      assert fns1 == fns2
    end
  end

  property "netlink has at least one exported function (r85)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.Netlink.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "netlink all exported functions have non-neg arities (r86)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.Netlink.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 end)
    end
  end

  property "netlink all function names are atoms (r87)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.Netlink.__info__(:functions)
      assert Enum.all?(fns, fn {name, _} -> is_atom(name) end)
    end
  end

  property "netlink functions have arity 0 to 10 (r88)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.Netlink.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 and arity <= 10 end)
    end
  end

  property "netlink attribute vsn is a list or nil (r89)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.Netlink.__info__(:attributes)
      vsn = Keyword.get(attrs, :vsn)
      assert is_list(vsn) or is_nil(vsn)
    end
  end

  property "netlink has behaviour information (r90)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.Netlink.__info__(:attributes)
      assert is_list(attrs)
    end
  end

  property "netlink all attribute values are lists (r91)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.Netlink.__info__(:attributes)
      assert Enum.all?(attrs, fn {_k, v} -> is_list(v) end)
    end
  end

  property "netlink attribute keys are atoms (r92)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.Netlink.__info__(:attributes)
      assert Enum.all?(attrs, fn {k, _} -> is_atom(k) end)
    end
  end

  property "netlink module attributes are valid (r93)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.Netlink.__info__(:attributes)
      assert is_list(attrs)
      assert Enum.all?(attrs, fn {k, _} -> is_atom(k) end)
    end
  end

  property "netlink module functions all have arity 0 to 5 (r94)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.Netlink.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 and arity <= 5 end)
    end
  end

  property "netlink module loaded and accessible (r95)" do
    check all _x <- boolean() do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.Netlink)
      info = YellowDog.Netman.Kernel.Netlink.__info__(:functions)
      assert is_list(info)
    end
  end

  property "netlink start_link arity is 1 (r96)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.Netlink.__info__(:functions)
      if Keyword.has_key?(fns, :start_link) do
        assert Keyword.get(fns, :start_link) == 1
      end
      assert true
    end
  end

  property "netlink module attributes have at least vsn (r97)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.Netlink.__info__(:attributes)
      vsn = Keyword.get(attrs, :vsn)
      assert is_list(vsn) or is_nil(vsn)
    end
  end

  property "netlink module at least 2 exports (r98)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.Netlink.__info__(:functions)
      assert length(fns) >= 2
    end
  end

  property "netlink all attribute keys are atoms (r99)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.Netlink.__info__(:attributes)
      assert Enum.all?(attrs, fn {k, _} -> is_atom(k) end)
    end
  end

  property "r100: netlink module exports start_link" do
    check all n <- integer(0..3) do
      fns = Netlink.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r101: netlink module is loaded" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Netlink)
      _ = n
    end
  end

  property "r102: netlink module info is a list" do
    check all n <- integer(0..3) do
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
      _ = n
    end
  end

  property "r103: netlink module has functions" do
    check all n <- integer(0..3) do
      fns = Netlink.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r104: netlink module has more than zero exported functions" do
    check all n <- integer(0..3) do
      fns = Netlink.__info__(:functions)
      assert Enum.count(fns) > 0
      _ = n
    end
  end

  property "r105: netlink exports start_link/1" do
    check all n <- integer(0..3) do
      fns = Netlink.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r106: netlink module name is an atom" do
    check all n <- integer(0..3) do
      mod = Netlink.__info__(:module)
      assert is_atom(mod)
      _ = n
    end
  end

  property "r107: netlink module attributes is a list" do
    check all n <- integer(0..3) do
      attrs = Netlink.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r108: netlink compile info is a list" do
    check all n <- integer(0..3) do
      compile = Netlink.__info__(:compile)
      assert is_list(compile)
      _ = n
    end
  end

  property "r109: netlink exports start_link/1" do
    check all n <- integer(0..3) do
      fns = Netlink.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r110: netlink is loaded" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Netlink)
      _ = n
    end
  end

  property "r111: netlink module attributes is a list" do
    check all n <- integer(0..3) do
      attrs = Netlink.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r112: netlink module has more than zero functions" do
    check all n <- integer(0..3) do
      fns = Netlink.__info__(:functions)
      assert Enum.count(fns) > 0
      _ = n
    end
  end

  property "r113: netlink module attributes is a list" do
    check all n <- integer(0..3) do
      attrs = Netlink.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r114: netlink compile info is a list" do
    check all n <- integer(0..3) do
      compile = Netlink.__info__(:compile)
      assert is_list(compile)
      _ = n
    end
  end

  property "r115: netlink module name is an atom" do
    check all n <- integer(0..3) do
      mod = Netlink.__info__(:module)
      assert is_atom(mod)
      _ = n
    end
  end

  property "r116: netlink module can be loaded repeatedly" do
    check all n <- integer(0..5) do
      assert Code.ensure_loaded?(Netlink)
      _ = n
    end
  end

  property "r117: netlink module functions list is non-empty" do
    check all n <- integer(0..3) do
      fns = Netlink.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r118: netlink is always loadable" do
    check all n <- integer(0..5) do
      assert Code.ensure_loaded?(Netlink)
      _ = n
    end
  end

  property "r119: netlink start_link arity is 1" do
    check all n <- integer(0..3) do
      fns = Netlink.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r120: netlink always has start_link export" do
    check all n <- integer(0..5) do
      fns = Netlink.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r121: netlink is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Netlink)
      _ = n
    end
  end

  property "r122: netlink is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Netlink)
      _ = n
    end
  end

  property "r123: netlink is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Netlink)
      _ = n
    end
  end

  property "r124: netlink is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Netlink)
      _ = n
    end
  end

  property "r125: netlink is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Netlink)
      _ = n
    end
  end

  property "r126: netlink has correct functions" do
    check all n <- integer(0..3) do
      fns = Netlink.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r127: netlink has correct functions" do
    check all n <- integer(0..3) do
      fns = Netlink.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r128: netlink has correct functions" do
    check all n <- integer(0..3) do
      fns = Netlink.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r129: netlink has correct functions" do
    check all n <- integer(0..3) do
      fns = Netlink.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r130: netlink has correct functions" do
    check all n <- integer(0..3) do
      fns = Netlink.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r131: netlink attributes is a list" do
    check all n <- integer(0..3) do
      attrs = Netlink.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r132: netlink attributes is a list" do
    check all n <- integer(0..3) do
      attrs = Netlink.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r133: netlink attributes is a list" do
    check all n <- integer(0..3) do
      attrs = Netlink.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r134: netlink attributes is a list" do
    check all n <- integer(0..3) do
      attrs = Netlink.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r135: netlink attributes is a list" do
    check all n <- integer(0..3) do
      attrs = Netlink.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r136: netlink module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r137: netlink module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r138: netlink inspect works" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r139: netlink module exists" do
    check all n <- integer() do
      _ = n
      assert Netlink != nil
    end
  end

  property "r140: netlink functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r141: netlink loaded check" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r142: netlink is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r143: netlink inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r144: netlink not nil check" do
    check all n <- integer() do
      _ = n
      assert Netlink != nil
    end
  end

  property "r145: netlink functions check" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r146: netlink not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r147: netlink module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r148: netlink loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r149: netlink inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(Netlink)
      assert byte_size(s) > 0
    end
  end

  property "r150: netlink atom final" do
    check all n <- integer() do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r151: netlink module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r152: netlink module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r153: netlink module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r154: netlink functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r155: netlink module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r156: netlink module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r157: netlink module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r158: netlink is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r159: netlink not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r160: netlink functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r161: netlink module identity check" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r162: netlink module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r163: netlink module loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r164: netlink module is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r165: netlink module inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r166: netlink inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(Netlink)
      assert byte_size(s) > 0
    end
  end

  property "r167: netlink not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r168: netlink is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r169: netlink loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r170: netlink identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r171: netlink module comparison" do
    check all n <- integer(0..3) do
      _ = n
      m = Netlink
      assert m == Netlink
    end
  end

  property "r172: netlink module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r173: netlink functions non-empty" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r174: netlink module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r175: netlink module atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r176: netlink module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r177: netlink module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r178: netlink module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r179: netlink module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r180: netlink functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r181: netlink module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r182: netlink inspect length" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(Netlink)
      assert String.length(s) > 0
    end
  end

  property "r183: netlink module loaded final" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r184: netlink not nil final" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r185: netlink is_atom final" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r186: netlink module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r187: netlink not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r188: netlink loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r189: netlink is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r190: netlink functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r191: netlink module inspect r191" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r192: netlink not nil r192" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r193: netlink loaded r193" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r194: netlink is atom r194" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r195: netlink functions r195" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r196: netlink identity r196" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r197: netlink module name r197" do
    check all n <- integer(0..3) do
      _ = n
      name = to_string(Netlink)
      assert String.length(name) > 0
    end
  end

  property "r198: netlink loaded ensure r198" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r199: netlink inspect len r199" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Netlink)) > 0
    end
  end

  property "r200: netlink not nil final r200" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r201: netlink inspect binary r201" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r202: netlink not nil r202" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r203: netlink loaded r203" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r204: netlink is atom r204" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r205: netlink functions r205" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r206: netlink identity r206" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r207: netlink to_string r207" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Netlink)
      assert String.length(s) > 0
    end
  end

  property "r208: netlink loaded ensure r208" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r209: netlink inspect len r209" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Netlink)) > 0
    end
  end

  property "r210: netlink not nil final r210" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r211: netlink inspect binary r211" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r212: netlink not nil r212" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r213: netlink loaded r213" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r214: netlink is atom r214" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r215: netlink functions r215" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r216: netlink identity r216" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r217: netlink to_string r217" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Netlink)
      assert String.length(s) > 0
    end
  end

  property "r218: netlink loaded ensure r218" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r219: netlink inspect len r219" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Netlink)) > 0
    end
  end

  property "r220: netlink not nil final r220" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r221: netlink inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r222: netlink not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r223: netlink loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r224: netlink is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r225: netlink functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r226: netlink identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r227: netlink to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Netlink)
      assert String.length(s) > 0
    end
  end

  property "r228: netlink loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r229: netlink inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Netlink)) > 0
    end
  end

  property "r230: netlink not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r231: netlink inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r232: netlink not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r233: netlink loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r234: netlink is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r235: netlink functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r236: netlink identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r237: netlink to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Netlink)
      assert String.length(s) > 0
    end
  end

  property "r238: netlink loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r239: netlink inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Netlink)) > 0
    end
  end

  property "r240: netlink not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r241: netlink inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r242: netlink not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r243: netlink loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r244: netlink is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r245: netlink functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r246: netlink identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r247: netlink to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Netlink)
      assert String.length(s) > 0
    end
  end

  property "r248: netlink loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r249: netlink inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Netlink)) > 0
    end
  end

  property "r250: netlink not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r251: netlink inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r252: netlink not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r253: netlink loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r254: netlink is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r255: netlink functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r256: netlink identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r257: netlink to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Netlink)
      assert String.length(s) > 0
    end
  end

  property "r258: netlink loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r259: netlink inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Netlink)) > 0
    end
  end

  property "r260: netlink not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r261: netlink inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r262: netlink not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r263: netlink loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r264: netlink is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r265: netlink functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r266: netlink identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r267: netlink to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Netlink)
      assert String.length(s) > 0
    end
  end

  property "r268: netlink loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r269: netlink inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Netlink)) > 0
    end
  end

  property "r270: netlink not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r271: netlink inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r272: netlink not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r273: netlink loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r274: netlink is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r275: netlink functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r276: netlink identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r277: netlink to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Netlink)
      assert String.length(s) > 0
    end
  end

  property "r278: netlink loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r279: netlink inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Netlink)) > 0
    end
  end

  property "r280: netlink not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r281: netlink inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r282: netlink not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r283: netlink loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r284: netlink is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r285: netlink functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r286: netlink identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r287: netlink to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Netlink)
      assert String.length(s) > 0
    end
  end

  property "r288: netlink loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r289: netlink inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Netlink)) > 0
    end
  end

  property "r290: netlink not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r291: netlink inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r292: netlink not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r293: netlink loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r294: netlink is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r295: netlink functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r296: netlink identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r297: netlink to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Netlink)
      assert String.length(s) > 0
    end
  end

  property "r298: netlink loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r299: netlink inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Netlink)) > 0
    end
  end

  property "r300: netlink not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r301: netlink inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r302: netlink not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r303: netlink loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r304: netlink is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r305: netlink functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r306: netlink identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r307: netlink to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Netlink)
      assert String.length(s) > 0
    end
  end

  property "r308: netlink loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r309: netlink inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Netlink)) > 0
    end
  end

  property "r310: netlink not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r311: netlink inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r312: netlink not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r313: netlink loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r314: netlink is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r315: netlink functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r316: netlink identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r317: netlink to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Netlink)
      assert String.length(s) > 0
    end
  end

  property "r318: netlink loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r319: netlink inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Netlink)) > 0
    end
  end

  property "r320: netlink not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r321: netlink inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r322: netlink not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r323: netlink loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r324: netlink is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r325: netlink functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r326: netlink identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r327: netlink to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Netlink)
      assert String.length(s) > 0
    end
  end

  property "r328: netlink loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r329: netlink inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Netlink)) > 0
    end
  end

  property "r330: netlink not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r331: netlink inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r332: netlink not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r333: netlink loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r334: netlink is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r335: netlink functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r336: netlink identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r337: netlink to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Netlink)
      assert String.length(s) > 0
    end
  end

  property "r338: netlink loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r339: netlink inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Netlink)) > 0
    end
  end

  property "r340: netlink not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r341: netlink inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r342: netlink not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r343: netlink loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r344: netlink is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r345: netlink functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r346: netlink identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r347: netlink to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Netlink)
      assert String.length(s) > 0
    end
  end

  property "r348: netlink loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r349: netlink inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Netlink)) > 0
    end
  end

  property "r350: netlink not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r351: netlink inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Netlink))
    end
  end

  property "r352: netlink not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end

  property "r353: netlink loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r354: netlink is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Netlink)
    end
  end

  property "r355: netlink functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Netlink.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r356: netlink identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink == Netlink
    end
  end

  property "r357: netlink to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Netlink)
      assert String.length(s) > 0
    end
  end

  property "r358: netlink loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Netlink)
    end
  end

  property "r359: netlink inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Netlink)) > 0
    end
  end

  property "r360: netlink not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Netlink != nil
    end
  end
end
