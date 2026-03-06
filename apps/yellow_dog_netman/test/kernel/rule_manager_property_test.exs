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
end
