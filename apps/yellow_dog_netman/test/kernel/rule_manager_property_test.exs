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

  property "all list_rules entries have non-negative priority" do
    check all(
            priority <- priority_gen(),
            table <- table_gen()
          ) do
      send_rule_event(%{"action" => "add", "priority" => priority, "table" => table})

      rules = RuleManager.list_rules()

      for rule <- rules do
        assert is_integer(rule.priority) and rule.priority >= 0,
               "Rule has invalid priority: #{inspect(rule.priority)}"
      end
    end
  end

  property "rule added without source/destination/interface has those fields as nil" do
    check all(
            priority <- priority_gen(),
            table <- table_gen()
          ) do
      send_rule_event(%{"action" => "add", "priority" => priority, "table" => table})

      rules = RuleManager.list_rules()
      rule = Enum.find(rules, &(&1.priority == priority))
      assert rule != nil

      assert rule.source == nil,
             "Expected nil source when not in event, got: #{inspect(rule.source)}"

      assert rule.destination == nil,
             "Expected nil destination when not in event, got: #{inspect(rule.destination)}"

      assert rule.interface == nil,
             "Expected nil interface when not in event, got: #{inspect(rule.interface)}"
    end
  end

  property "del then re-add same priority restores the rule with new table" do
    check all(
            priority <- priority_gen(),
            table1 <- table_gen(),
            table2 <- table_gen()
          ) do
      send_rule_event(%{"action" => "add", "priority" => priority, "table" => table1})
      send_rule_event(%{"action" => "del", "priority" => priority, "table" => table1})
      send_rule_event(%{"action" => "add", "priority" => priority, "table" => table2})

      rules = RuleManager.list_rules()
      rule = Enum.find(rules, &(&1.priority == priority))

      assert rule != nil, "Expected rule at priority #{priority} to be re-added"
      assert rule.table == table2, "Expected table #{table2} after re-add, got #{rule.table}"
    end
  end

  property "adding to unused priority increases list count by exactly 1" do
    check all(
            priority <- StreamData.integer(90_000..99_999),
            table <- table_gen()
          ) do
      # Remove any pre-existing entry at this priority
      send_rule_event(%{"action" => "del", "priority" => priority, "table" => table})

      before_count = length(RuleManager.list_rules())

      send_rule_event(%{"action" => "add", "priority" => priority, "table" => table})

      after_count = length(RuleManager.list_rules())

      assert after_count == before_count + 1,
             "Expected count to increase by 1: #{before_count} -> #{after_count}"
    end
  end

  property "add N rules at distinct priorities produces N entries in list" do
    check all(
            priorities <-
              StreamData.list_of(
                StreamData.integer(80_000..89_999),
                min_length: 2,
                max_length: 5
              )
              |> StreamData.map(&Enum.uniq/1)
              |> StreamData.filter(&(length(&1) >= 2))
          ) do
      for p <- priorities do
        send_rule_event(%{"action" => "add", "priority" => p, "table" => 150})
      end

      rules = RuleManager.list_rules()
      matching = Enum.filter(rules, &(&1.priority in priorities))
      assert length(matching) == length(priorities),
             "Expected #{length(priorities)} rules but found #{length(matching)}"
    end
  end

  property "list_rules entries are all unique by priority" do
    check all(_ <- StreamData.constant(:ok)) do
      rules = RuleManager.list_rules()
      priorities = Enum.map(rules, & &1.priority)

      assert length(priorities) == length(Enum.uniq(priorities)),
             "list_rules contains duplicate priorities: #{inspect(priorities)}"
    end
  end

  property "del decreases list count by exactly 1 when rule was present" do
    check all(
            priority <- StreamData.integer(32_000..34_999),
            table <- table_gen()
          ) do
      send_rule_event(%{"action" => "add", "priority" => priority, "table" => table})
      before_count = length(RuleManager.list_rules())

      send_rule_event(%{"action" => "del", "priority" => priority, "table" => table})
      after_count = length(RuleManager.list_rules())

      assert after_count == before_count - 1,
             "Expected count to decrease by 1: #{before_count} -> #{after_count}"
    end
  end

  property "all rules in list_rules always have a non-nil integer table field" do
    check all(
            priority <- priority_gen(),
            table <- table_gen()
          ) do
      send_rule_event(%{"action" => "add", "priority" => priority, "table" => table})

      rules = RuleManager.list_rules()

      for rule <- rules do
        assert rule.table != nil,
               "Rule at priority #{rule.priority} has nil table"

        assert is_integer(rule.table),
               "Rule table is not an integer: #{inspect(rule.table)}"
      end
    end
  end

  property "list_rules always returns a list of maps" do
    check all(_ <- StreamData.constant(:ok)) do
      rules = RuleManager.list_rules()
      assert is_list(rules)

      for r <- rules do
        assert is_map(r),
               "Expected map in list_rules, got: #{inspect(r)}"
      end
    end
  end

  property "each added rule is findable by its exact priority in list_rules" do
    check all(
            priority <- StreamData.integer(20_000..24_999),
            table <- table_gen()
          ) do
      send_rule_event(%{"action" => "add", "priority" => priority, "table" => table})

      rules = RuleManager.list_rules()
      match = Enum.find(rules, &(&1.priority == priority))

      assert match != nil,
             "Expected rule at priority #{priority} to be findable in list_rules"

      assert match.table == table,
             "Expected table #{table} for priority #{priority}, got #{match.table}"
    end
  end

  property "add rule with non-nil destination preserves destination value in list_rules" do
    check all(
            priority <- StreamData.integer(35_000..39_999),
            table <- table_gen(),
            dst <- cidr_gen()
          ) do
      send_rule_event(%{
        "action" => "add",
        "priority" => priority,
        "table" => table,
        "destination" => dst
      })

      rules = RuleManager.list_rules()
      match = Enum.find(rules, &(&1.priority == priority))

      assert match != nil,
             "Expected rule at priority #{priority} to be present"

      assert match.destination == dst,
             "Expected destination #{dst}, got: #{inspect(match.destination)}"
    end
  end

  property "add rule with non-nil source preserves source value in list_rules" do
    check all(
            priority <- StreamData.integer(25_000..29_999),
            table <- table_gen(),
            src <- cidr_gen()
          ) do
      send_rule_event(%{
        "action" => "add",
        "priority" => priority,
        "table" => table,
        "source" => src
      })

      rules = RuleManager.list_rules()
      match = Enum.find(rules, &(&1.priority == priority))

      assert match != nil,
             "Expected rule at priority #{priority} to be present"

      assert match.source == src,
             "Expected source #{src}, got: #{inspect(match.source)}"
    end
  end

  property "list_rules returns consistent results on consecutive calls" do
    check all(_ <- StreamData.constant(:ok)) do
      r1 = RuleManager.list_rules()
      r2 = RuleManager.list_rules()
      assert r1 == r2, "list_rules returned different results on consecutive calls"
    end
  end

  property "all rules in list_rules have binary-or-nil source, destination, and interface fields" do
    check all(
            priority <- priority_gen(),
            table <- table_gen()
          ) do
      send_rule_event(%{"action" => "add", "priority" => priority, "table" => table})

      rules = RuleManager.list_rules()

      for r <- rules do
        assert is_nil(r.source) or is_binary(r.source),
               "Expected nil or binary source, got: #{inspect(r.source)}"

        assert is_nil(r.destination) or is_binary(r.destination),
               "Expected nil or binary destination, got: #{inspect(r.destination)}"

        assert is_nil(r.interface) or is_binary(r.interface),
               "Expected nil or binary interface, got: #{inspect(r.interface)}"
      end
    end
  end

  property "rule table field is always a non-negative integer after add event" do
    check all(
            priority <- priority_gen(),
            table <- table_gen()
          ) do
      send_rule_event(%{"action" => "add", "priority" => priority, "table" => table})

      rules = RuleManager.list_rules()

      for r <- rules do
        assert is_integer(r.table) and r.table >= 0,
               "Expected non-negative integer table, got: #{inspect(r.table)}"
      end
    end
  end

  property "list_rules always has non-negative integer priority for all entries" do
    check all(_ <- StreamData.constant(:ok)) do
      rules = RuleManager.list_rules()

      for r <- rules do
        assert is_integer(r.priority) and r.priority >= 0,
               "Expected non-negative integer priority, got: #{inspect(r.priority)}"
      end
    end
  end

  property "rule added with source cidr has binary source field in list_rules" do
    check all(
            priority <- priority_gen(),
            table <- table_gen(),
            src <- cidr_gen()
          ) do
      send_rule_event(%{
        "action" => "add",
        "priority" => priority,
        "table" => table,
        "source" => src
      })

      rules = RuleManager.list_rules()
      rule = Enum.find(rules, &(&1.priority == priority))

      if rule do
        assert is_binary(rule.source) or is_nil(rule.source),
               "Expected binary or nil source, got: #{inspect(rule.source)}"
      end
    end
  end

  property "list_rules never has duplicate priorities" do
    check all(_ <- StreamData.constant(:ok)) do
      rules = RuleManager.list_rules()
      priorities = Enum.map(rules, & &1.priority)

      assert length(priorities) == length(Enum.uniq(priorities)),
             "list_rules has duplicate priorities: #{inspect(priorities)}"
    end
  end

  property "unknown action in rule event does not add any new rule" do
    check all(
            priority <- priority_gen(),
            table <- table_gen(),
            unknown_action <-
              StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
              |> StreamData.filter(&(&1 not in ["add", "del"]))
          ) do
      before_count = length(RuleManager.list_rules())

      send_rule_event(%{
        "action" => unknown_action,
        "priority" => priority,
        "table" => table
      })

      after_count = length(RuleManager.list_rules())

      assert after_count == before_count,
             "Unknown action '#{unknown_action}' changed rule count: #{before_count} -> #{after_count}"
    end
  end

  property "rule count never decreases without a del event" do
    check all(
            priority <- priority_gen(),
            table <- table_gen()
          ) do
      before_count = length(RuleManager.list_rules())
      send_rule_event(%{"action" => "add", "priority" => priority, "table" => table})
      after_count = length(RuleManager.list_rules())
      assert after_count >= before_count,
             "Rule count decreased after add event: #{before_count} -> #{after_count}"
    end
  end

  property "RuleManager process is always alive" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.RuleManager)
      assert pid != nil, "Expected RuleManager to be registered"
      assert Process.alive?(pid), "Expected RuleManager process to be alive"
    end
  end

  property "list_rules result length is always a non-negative integer" do
    check all(_ <- StreamData.constant(:ok)) do
      count = length(RuleManager.list_rules())
      assert is_integer(count) and count >= 0,
             "Expected non-negative rule count, got: #{count}"
    end
  end

  property "rules have :priority and :table fields" do
    check all(_ <- StreamData.constant(:ok)) do
      rules = RuleManager.list_rules()
      for rule <- rules do
        assert Map.has_key?(rule, :priority),
               "Expected :priority key in rule, got: #{inspect(rule)}"
        assert Map.has_key?(rule, :table),
               "Expected :table key in rule, got: #{inspect(rule)}"
      end
    end
  end

  property "adding and deleting a rule leaves count unchanged" do
    check all(
            priority <- priority_gen(),
            table <- table_gen()
          ) do
      # Pre-delete to ensure the key is absent, then measure baseline
      send_rule_event(%{"action" => "del", "priority" => priority, "table" => table})
      initial_count = length(RuleManager.list_rules())
      send_rule_event(%{"action" => "add", "priority" => priority, "table" => table})
      send_rule_event(%{"action" => "del", "priority" => priority, "table" => table})
      final_count = length(RuleManager.list_rules())
      assert final_count == initial_count,
             "Expected rule count to return to #{initial_count}, got #{final_count}"
    end
  end

  property "rule priority is always an integer" do
    check all(_ <- StreamData.constant(:ok)) do
      rules = RuleManager.list_rules()
      for rule <- rules do
        assert is_integer(rule.priority),
               "Expected integer priority in rule, got: #{inspect(rule.priority)}"
      end
    end
  end

  property "list_rules never contains nil entries" do
    check all(_ <- StreamData.constant(:ok)) do
      rules = RuleManager.list_rules()
      for rule <- rules do
        assert rule != nil,
               "Expected non-nil entry in list_rules"
      end
    end
  end

  property "list_rules result rules all have :table key" do
    check all(_ <- StreamData.constant(:ok)) do
      rules = RuleManager.list_rules()
      for rule <- rules do
        assert Map.has_key?(rule, :table),
               "Expected :table key in rule, got: #{inspect(rule)}"
      end
    end
  end

  property "adding a rule always increases or maintains the count" do
    check all(
            priority <- priority_gen(),
            table <- table_gen()
          ) do
      before_count = length(RuleManager.list_rules())
      send_rule_event(%{"action" => "add", "priority" => priority, "table" => table})
      after_count = length(RuleManager.list_rules())
      assert after_count >= before_count,
             "Expected count to not decrease after add: #{before_count} -> #{after_count}"
    end
  end

  property "list_rules result all have :priority key" do
    check all(_ <- StreamData.constant(:ok)) do
      rules = RuleManager.list_rules()
      for rule <- rules do
        assert Map.has_key?(rule, :priority),
               "Expected :priority key in rule, got: #{inspect(rule)}"
      end
    end
  end

  property "list_rules result entries always have :priority key" do
    check all(_ <- StreamData.constant(:ok)) do
      rules = RuleManager.list_rules()
      for r <- rules do
        assert Map.has_key?(r, :priority),
               "Expected :priority key in rule entry, got: \#{inspect(r)}"
      end
    end
  end
end
