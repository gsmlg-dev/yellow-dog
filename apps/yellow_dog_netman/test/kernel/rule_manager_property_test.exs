defmodule YellowDog.Netman.Kernel.RuleManagerPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias YellowDog.Netman.Kernel.{Netlink, RuleManager}

  defp send_rule_event(event) do
    send(Netlink, {:mock_event, Map.put(event, "type", "rule_change")})
    Process.sleep(50)
  end

  defp priority_gen do
    # Use high priorities to avoid collisions with test suite's existing rules
    StreamData.integer(40_000..59_999)
  end

  defp table_gen do
    StreamData.integer(100..200)
  end

  defp cidr_gen do
    gen all(
          a <- StreamData.integer(10..10),
          b <- StreamData.integer(0..255),
          prefix <- StreamData.integer(8..30)
        ) do
      "#{a}.#{b}.0.0/#{prefix}"
    end
  end

  # Properties

  property "add then list_rules contains the rule" do
    check all(
            priority <- priority_gen(),
            table <- table_gen()
          ) do
      send_rule_event(%{"action" => "add", "priority" => priority, "table" => table})

      rules = RuleManager.list_rules()
      rule = Enum.find(rules, &(&1.priority == priority))
      assert rule != nil, "Expected rule with priority #{priority}"
      assert rule.table == table
    end
  end

  property "add then del then list_rules does not contain the rule" do
    check all(
            priority <- priority_gen(),
            table <- table_gen()
          ) do
      send_rule_event(%{"action" => "add", "priority" => priority, "table" => table})
      send_rule_event(%{"action" => "del", "priority" => priority, "table" => table})

      rules = RuleManager.list_rules()
      rule = Enum.find(rules, &(&1.priority == priority))
      assert rule == nil, "Expected rule with priority #{priority} to be deleted"
    end
  end

  property "same priority (last write wins)" do
    check all(
            priority <- priority_gen(),
            table1 <- table_gen(),
            table2 <- table_gen()
          ) do
      send_rule_event(%{"action" => "add", "priority" => priority, "table" => table1})
      send_rule_event(%{"action" => "add", "priority" => priority, "table" => table2})

      rules = RuleManager.list_rules()
      matching = Enum.filter(rules, &(&1.priority == priority))
      assert length(matching) == 1
      assert hd(matching).table == table2
    end
  end

  property "source, destination, and interface fields are preserved" do
    check all(
            priority <- priority_gen(),
            src <- cidr_gen(),
            dst <- cidr_gen()
          ) do
      send_rule_event(%{
        "action" => "add",
        "priority" => priority,
        "table" => 100,
        "source" => src,
        "destination" => dst,
        "interface" => "eth0"
      })

      rules = RuleManager.list_rules()
      rule = Enum.find(rules, &(&1.priority == priority))
      assert rule != nil
      assert rule.source == src
      assert rule.destination == dst
      assert rule.interface == "eth0"
    end
  end

  property "list_rules always returns a list" do
    check all(_ <- StreamData.constant(:ok)) do
      assert is_list(RuleManager.list_rules())
    end
  end

  property "del for non-existent priority does not crash and leaves list intact" do
    check all(
            priority <- priority_gen(),
            table <- table_gen()
          ) do
      rules_before = RuleManager.list_rules()

      # Delete something that was never added — must not crash
      send_rule_event(%{"action" => "del", "priority" => priority, "table" => table})

      rules_after = RuleManager.list_rules()

      # Specifically, the non-existent entry must remain absent
      entry = Enum.find(rules_after, &(&1.priority == priority))
      assert entry == nil

      # No rules that existed before should disappear (except possibly at this priority)
      for r <- rules_before, r.priority != priority do
        assert Enum.any?(rules_after, &(&1.priority == r.priority)),
               "Rule at priority #{r.priority} vanished after unrelated del"
      end
    end
  end

  property "two rules at distinct priorities coexist independently" do
    check all(
            p1 <- StreamData.integer(60_000..69_999),
            p2 <- StreamData.integer(70_000..79_999),
            t1 <- table_gen(),
            t2 <- table_gen()
          ) do
      send_rule_event(%{"action" => "add", "priority" => p1, "table" => t1})
      send_rule_event(%{"action" => "add", "priority" => p2, "table" => t2})

      rules = RuleManager.list_rules()

      r1 = Enum.find(rules, &(&1.priority == p1))
      r2 = Enum.find(rules, &(&1.priority == p2))

      assert r1 != nil, "Rule at priority #{p1} missing"
      assert r2 != nil, "Rule at priority #{p2} missing"
      assert r1.table == t1
      assert r2.table == t2
    end
  end

  property "all list_rules entries have required fields" do
    check all(
            priority <- priority_gen(),
            table <- table_gen()
          ) do
      send_rule_event(%{"action" => "add", "priority" => priority, "table" => table})

      rules = RuleManager.list_rules()
      rule = Enum.find(rules, &(&1.priority == priority))
      assert rule != nil

      for field <- [:priority, :table, :source, :destination, :interface] do
        assert Map.has_key?(rule, field),
               "Rule missing required field: #{field}"
      end
    end
  end
end
