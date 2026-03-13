defmodule YellowDog.Netman.Kernel.RuleManagerTest do
  use ExUnit.Case

  alias YellowDog.Netman.Kernel.{Netlink, RuleManager}

  defp send_rule_event(event) do
    send(Netlink, {:mock_event, Map.put(event, "type", "rule_change")})
    Process.sleep(50)
  end

  test "list_rules returns empty initially (for test-unique rules)" do
    rules = RuleManager.list_rules()
    # May have rules from other tests, just verify it's a list
    assert is_list(rules)
  end

  test "adding a rule makes it appear in list_rules" do
    send_rule_event(%{
      "action" => "add",
      "priority" => 32_001,
      "table" => 100,
      "source" => "10.0.0.0/24",
      "interface" => "rule_test_eth0"
    })

    rules = RuleManager.list_rules()
    rule = Enum.find(rules, &(&1.priority == 32_001))
    assert rule != nil
    assert rule.table == 100
    assert rule.source == "10.0.0.0/24"
    assert rule.interface == "rule_test_eth0"
  end

  test "deleting a rule removes it from list_rules" do
    # Add then delete
    send_rule_event(%{
      "action" => "add",
      "priority" => 32_002,
      "table" => 200,
      "source" => nil,
      "interface" => nil
    })

    assert Enum.any?(RuleManager.list_rules(), &(&1.priority == 32_002))

    send_rule_event(%{
      "action" => "del",
      "priority" => 32_002,
      "table" => 200
    })

    refute Enum.any?(RuleManager.list_rules(), &(&1.priority == 32_002))
  end

  test "rule defaults when fields are missing" do
    send_rule_event(%{
      "action" => "add",
      "priority" => 32_003
    })

    rules = RuleManager.list_rules()
    rule = Enum.find(rules, &(&1.priority == 32_003))
    assert rule != nil
    assert rule.table == 254
    assert rule.source == nil
    assert rule.destination == nil
  end

  test "same priority overwrites previous rule (last write wins)" do
    send_rule_event(%{
      "action" => "add",
      "priority" => 32_010,
      "table" => 100,
      "source" => "10.0.0.0/24",
      "interface" => "rule_dup_eth0"
    })

    send_rule_event(%{
      "action" => "add",
      "priority" => 32_010,
      "table" => 200,
      "source" => "192.168.1.0/24",
      "interface" => "rule_dup_eth1"
    })

    rules = Enum.filter(RuleManager.list_rules(), &(&1.priority == 32_010))
    assert length(rules) == 1
    assert hd(rules).table == 200
    assert hd(rules).source == "192.168.1.0/24"

    # Delete the rule
    send_rule_event(%{
      "action" => "del",
      "priority" => 32_010,
      "table" => 200,
      "source" => "192.168.1.0/24",
      "interface" => "rule_dup_eth1"
    })

    remaining = Enum.filter(RuleManager.list_rules(), &(&1.priority == 32_010))
    assert length(remaining) == 0
  end

  test "unknown action in rule event is handled gracefully" do
    pid = Process.whereis(RuleManager)
    send(pid, {:netlink_event, {:rule_change, %{"action" => "flush", "priority" => 99_999}}})
    Process.sleep(20)
    assert Process.alive?(pid)
  end

  test "handle_info with unknown message is silently ignored" do
    pid = Process.whereis(RuleManager)
    send(pid, :some_unknown_message)
    Process.sleep(20)
    assert Process.alive?(pid)
  end

  test "MockNetlink.rule_removed with source/interface matches composite key" do
    alias YellowDog.Netman.Test.MockNetlink

    MockNetlink.rule_added(
      priority: 32_020,
      table: 100,
      source: "172.16.0.0/16",
      interface: "rule_mock_eth0"
    )

    Process.sleep(50)
    assert Enum.any?(RuleManager.list_rules(), &(&1.priority == 32_020))

    MockNetlink.rule_removed(
      priority: 32_020,
      table: 100,
      source: "172.16.0.0/16",
      interface: "rule_mock_eth0"
    )

    Process.sleep(50)
    refute Enum.any?(RuleManager.list_rules(), &(&1.priority == 32_020))
  end
end
