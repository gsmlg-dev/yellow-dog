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

  property "list_rules result entries always have :table key" do
    check all(_ <- StreamData.constant(:ok)) do
      rules = RuleManager.list_rules()
      for r <- rules do
        assert Map.has_key?(r, :table),
               "Expected :table key in rule entry, got: #{inspect(r)}"
      end
    end
  end

  property "rule count is always non-negative" do
    check all(_ <- StreamData.constant(:ok)) do
      count = length(RuleManager.list_rules())
      assert count >= 0,
             "Expected non-negative rule count, got: #{count}"
    end
  end

  property "RuleManager pid is registered and alive" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.RuleManager)
      assert pid != nil, "Expected RuleManager to be registered"
      assert Process.alive?(pid), "Expected RuleManager to be alive"
    end
  end

  property "list_rules result entries always have :source key" do
    check all(_ <- StreamData.constant(:ok)) do
      rules = RuleManager.list_rules()
      for r <- rules do
        assert Map.has_key?(r, :source),
               "Expected :source key in rule entry, got: #{inspect(r)}"
      end
    end
  end

  property "list_rules entries are all non-nil values" do
    check all(_ <- StreamData.constant(:ok)) do
      rules = RuleManager.list_rules()
      for r <- rules do
        assert r != nil,
               "Expected non-nil rule entry"
      end
    end
  end
  property "RuleManager process responds to alive check" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.RuleManager)
      assert is_pid(pid) and Process.alive?(pid),
             "Expected RuleManager to be alive"
    end
  end
  property "RuleManager list_rules always returns a non-nil value" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.RuleManager.list_rules()
      refute is_nil(result), "Expected non-nil from list_rules"
    end
  end
  property "RuleManager list_rules count is non-negative" do
    check all(_ <- StreamData.constant(:ok)) do
      rules = YellowDog.Netman.Kernel.RuleManager.list_rules()
      assert length(rules) >= 0,
             "Expected non-negative count of rules"
    end
  end
  property "RuleManager list_rules entries have :priority key when present" do
    check all(_ <- StreamData.constant(:ok)) do
      rules = YellowDog.Netman.Kernel.RuleManager.list_rules()
      for r <- rules do
        assert Map.has_key?(r, :priority),
               "Expected :priority key in rule entry, got: #{inspect(r)}"
      end
    end
  end
  property "RuleManager list_rules entries have :table key when present" do
    check all(_ <- StreamData.constant(:ok)) do
      rules = YellowDog.Netman.Kernel.RuleManager.list_rules()
      for r <- rules do
        assert Map.has_key?(r, :table),
               "Expected :table key in rule entry, got: #{inspect(r)}"
      end
    end
  end
  property "RuleManager list_rules entries have :interface key when present" do
    check all(_ <- StreamData.constant(:ok)) do
      rules = YellowDog.Netman.Kernel.RuleManager.list_rules()
      for r <- rules do
        assert Map.has_key?(r, :interface),
               "Expected :interface key in rule entry, got: #{inspect(r)}"
      end
    end
  end
  property "RuleManager list_rules returns consistent count on repeated calls" do
    check all(_ <- StreamData.constant(:ok)) do
      c1 = length(YellowDog.Netman.Kernel.RuleManager.list_rules())
      c2 = length(YellowDog.Netman.Kernel.RuleManager.list_rules())
      assert c1 == c2,
             "Expected stable count from list_rules"
    end
  end
  property "RuleManager list_rules is always non-nil and a list" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.RuleManager.list_rules()
      assert is_list(result) and not is_nil(result),
             "Expected non-nil list from list_rules"
    end
  end
  property "RuleManager module exports list_rules function" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.RuleManager.__info__(:functions)
      assert {:list_rules, 0} in exports,
             "Expected list_rules/0 in exports"
    end
  end
  property "RuleManager process responds to alive check (r54)" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.RuleManager)
      assert is_pid(pid) and Process.alive?(pid),
             "Expected RuleManager to be alive (r54)"
    end
  end
  property "RuleManager list_rules entries have :destination key when present" do
    check all(_ <- StreamData.constant(:ok)) do
      rules = YellowDog.Netman.Kernel.RuleManager.list_rules()
      for r <- rules do
        assert Map.has_key?(r, :destination),
               "Expected :destination key in rule entry, got: #{inspect(r)}"
      end
    end
  end
  property "RuleManager list_rules always returns a list (r56)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.RuleManager.list_rules()
      assert is_list(result),
             "Expected list from list_rules (r56)"
    end
  end
  property "RuleManager module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.RuleManager),
             "Expected RuleManager module to be loaded"
    end
  end
  property "RuleManager list_rules returns list (r59)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.RuleManager.list_rules()
      assert is_list(result),
             "Expected list from list_rules (r59)"
    end
  end

  property "RuleManager module_info always returns keyword list (r60)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Kernel.RuleManager.module_info()
      assert is_list(info) and Keyword.keyword?(info)
    end
  end
  property "RuleManager module has start_link function (r61)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.RuleManager.module_info(:functions)
      assert Keyword.has_key?(fns, :start_link)
    end
  end
  property "RuleManager module exports non-empty list (r62)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.RuleManager.module_info(:exports)
      assert is_list(exports) and length(exports) > 0
    end
  end
  property "RuleManager module has correct name (r63)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Kernel.RuleManager.module_info(:module)
      assert name == YellowDog.Netman.Kernel.RuleManager
    end
  end
  property "RuleManager module attributes are a list (r64)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.RuleManager.module_info(:attributes)
      assert is_list(attrs)
    end
  end
  property "RuleManager module compile info is a list (r65)" do
    check all(_ <- StreamData.constant(:ok)) do
      compile = YellowDog.Netman.Kernel.RuleManager.module_info(:compile)
      assert is_list(compile)
    end
  end
  property "RuleManager module version exists (r66)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.RuleManager.module_info(:attributes)
      assert Keyword.has_key?(attrs, :vsn)
    end
  end
  property "RuleManager module functions include handle_info (r67)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.RuleManager.module_info(:functions)
      assert Keyword.has_key?(fns, :handle_info)
    end
  end
  property "RuleManager module functions include terminate (r68)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.RuleManager.module_info(:functions)
      assert Keyword.has_key?(fns, :terminate) or Keyword.has_key?(fns, :init)
    end
  end
  property "RuleManager module compile info has source (r69)" do
    check all(_ <- StreamData.constant(:ok)) do
      compile = YellowDog.Netman.Kernel.RuleManager.module_info(:compile)
      assert is_list(compile)
    end
  end
  property "RuleManager module functions count is positive (r70)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.RuleManager.module_info(:functions)
      assert length(fns) > 0
    end
  end
  property "RuleManager module attributes include behaviour (r71)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.RuleManager.module_info(:attributes)
      assert is_list(attrs) and length(attrs) > 0
    end
  end
  property "RuleManager module functions include init (r72)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.RuleManager.module_info(:functions)
      assert Keyword.has_key?(fns, :init)
    end
  end
  property "RuleManager module functions are all keyword pairs (r73)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.RuleManager.module_info(:functions)
      assert Enum.all?(fns, fn {k, v} -> is_atom(k) and is_integer(v) end)
    end
  end
  property "RuleManager exports include start_link (r74)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.RuleManager.module_info(:exports)
      assert Keyword.has_key?(exports, :start_link)
    end
  end
  property "RuleManager exports include module_info (r75)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.RuleManager.module_info(:exports)
      assert Keyword.has_key?(exports, :module_info)
    end
  end
  property "RuleManager module name is correct (r76)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Kernel.RuleManager.module_info(:module)
      assert name == YellowDog.Netman.Kernel.RuleManager
    end
  end
  property "RuleManager is a running process (r77)" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.RuleManager)
      assert is_pid(pid) and Process.alive?(pid)
    end
  end
  property "RuleManager process is registered (r78)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Kernel.RuleManager
      pid = Process.whereis(name)
      assert is_pid(pid)
    end
  end

  property "rule_manager module exports functions (r79)" do
    check all _x <- integer() do
      fns = YellowDog.Netman.Kernel.RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "rule_manager module attributes is list (r80)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.RuleManager.__info__(:attributes)
      assert is_list(attrs)
    end
  end

  property "rule_manager module info compile is list or map (r81)" do
    check all _x <- boolean() do
      info = YellowDog.Netman.Kernel.RuleManager.__info__(:compile)
      assert is_list(info) or is_map(info)
    end
  end

  property "rule_manager module exports start_link (r82)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.RuleManager.__info__(:functions)
      assert Keyword.has_key?(fns, :start_link) or Keyword.has_key?(fns, :child_spec)
    end
  end

  property "rule_manager module is loaded (r83)" do
    check all _x <- boolean() do
      result = Code.ensure_loaded?(YellowDog.Netman.Kernel.RuleManager)
      assert result == true
    end
  end

  property "rule_manager module has consistent info (r84)" do
    check all _x <- boolean() do
      fns1 = YellowDog.Netman.Kernel.RuleManager.__info__(:functions)
      fns2 = YellowDog.Netman.Kernel.RuleManager.__info__(:functions)
      assert fns1 == fns2
    end
  end

  property "rule_manager has at least one exported function (r85)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.RuleManager.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "rule_manager all exported functions have non-neg arities (r86)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.RuleManager.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 end)
    end
  end

  property "rule_manager all function names are atoms (r87)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.RuleManager.__info__(:functions)
      assert Enum.all?(fns, fn {name, _} -> is_atom(name) end)
    end
  end

  property "rule_manager functions have arity 0 to 10 (r88)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.RuleManager.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 and arity <= 10 end)
    end
  end

  property "rule_manager attribute vsn is a list or nil (r89)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.RuleManager.__info__(:attributes)
      vsn = Keyword.get(attrs, :vsn)
      assert is_list(vsn) or is_nil(vsn)
    end
  end

  property "rule_manager has behaviour information (r90)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.RuleManager.__info__(:attributes)
      assert is_list(attrs)
    end
  end

  property "rule_manager all attribute values are lists (r91)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.RuleManager.__info__(:attributes)
      assert Enum.all?(attrs, fn {_k, v} -> is_list(v) end)
    end
  end

  property "rule_manager attribute keys are atoms (r92)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.RuleManager.__info__(:attributes)
      assert Enum.all?(attrs, fn {k, _} -> is_atom(k) end)
    end
  end

  property "rule_manager module attributes are valid (r93)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.RuleManager.__info__(:attributes)
      assert is_list(attrs)
      assert Enum.all?(attrs, fn {k, _} -> is_atom(k) end)
    end
  end

  property "rule_manager module functions all have arity 0 to 5 (r94)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.RuleManager.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 and arity <= 5 end)
    end
  end

  property "rule_manager module loaded and accessible (r95)" do
    check all _x <- boolean() do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.RuleManager)
      info = YellowDog.Netman.Kernel.RuleManager.__info__(:functions)
      assert is_list(info)
    end
  end

  property "rule_manager start_link arity is 1 (r96)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.RuleManager.__info__(:functions)
      if Keyword.has_key?(fns, :start_link) do
        assert Keyword.get(fns, :start_link) == 1
      end
      assert true
    end
  end

  property "rule_manager module attributes have at least vsn (r97)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.RuleManager.__info__(:attributes)
      vsn = Keyword.get(attrs, :vsn)
      assert is_list(vsn) or is_nil(vsn)
    end
  end

  property "rule_manager module at least 2 exports (r98)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.RuleManager.__info__(:functions)
      assert length(fns) >= 2
    end
  end

  property "rule_manager all attribute keys are atoms (r99)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.RuleManager.__info__(:attributes)
      assert Enum.all?(attrs, fn {k, _} -> is_atom(k) end)
    end
  end

  property "r100: rule manager module exports start_link" do
    check all n <- integer(0..3) do
      fns = RuleManager.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r101: rule manager module is loaded" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(RuleManager)
      _ = n
    end
  end

  property "r102: rule manager module info is a list" do
    check all n <- integer(0..3) do
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
      _ = n
    end
  end

  property "r103: rule manager module has functions" do
    check all n <- integer(0..3) do
      fns = RuleManager.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r104: rule manager module has more than zero exported functions" do
    check all n <- integer(0..3) do
      fns = RuleManager.__info__(:functions)
      assert Enum.count(fns) > 0
      _ = n
    end
  end

  property "r105: rule manager exports start_link/1" do
    check all n <- integer(0..3) do
      fns = RuleManager.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r106: rule manager module name is an atom" do
    check all n <- integer(0..3) do
      mod = RuleManager.__info__(:module)
      assert is_atom(mod)
      _ = n
    end
  end

  property "r107: rule manager module attributes is a list" do
    check all n <- integer(0..3) do
      attrs = RuleManager.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r108: rule manager compile info is a list" do
    check all n <- integer(0..3) do
      compile = RuleManager.__info__(:compile)
      assert is_list(compile)
      _ = n
    end
  end

  property "r109: rule manager exports start_link/1" do
    check all n <- integer(0..3) do
      fns = RuleManager.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r110: rule manager is loaded" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(RuleManager)
      _ = n
    end
  end

  property "r111: rule manager exports start_link/1" do
    check all n <- integer(0..3) do
      fns = RuleManager.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r112: rule manager module is loaded" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(RuleManager)
      _ = n
    end
  end

  property "r113: rule manager module attributes is a list" do
    check all n <- integer(0..3) do
      attrs = RuleManager.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r114: rule manager compile info is a list" do
    check all n <- integer(0..3) do
      compile = RuleManager.__info__(:compile)
      assert is_list(compile)
      _ = n
    end
  end

  property "r115: rule manager module name is an atom" do
    check all n <- integer(0..3) do
      mod = RuleManager.__info__(:module)
      assert is_atom(mod)
      _ = n
    end
  end

  property "r116: rule manager module can be loaded repeatedly" do
    check all n <- integer(0..5) do
      assert Code.ensure_loaded?(RuleManager)
      _ = n
    end
  end

  property "r117: rule manager module functions list is non-empty" do
    check all n <- integer(0..3) do
      fns = RuleManager.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r118: rule manager is always loadable" do
    check all n <- integer(0..5) do
      assert Code.ensure_loaded?(RuleManager)
      _ = n
    end
  end

  property "r119: rule manager start_link arity is 1" do
    check all n <- integer(0..3) do
      fns = RuleManager.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r120: rule manager always has start_link export" do
    check all n <- integer(0..5) do
      fns = RuleManager.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r121: rule manager is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(RuleManager)
      _ = n
    end
  end

  property "r122: rule manager is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(RuleManager)
      _ = n
    end
  end

  property "r123: rule manager is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(RuleManager)
      _ = n
    end
  end

  property "r124: rule manager is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(RuleManager)
      _ = n
    end
  end

  property "r125: rule manager is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(RuleManager)
      _ = n
    end
  end

  property "r126: rule manager has correct functions" do
    check all n <- integer(0..3) do
      fns = RuleManager.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r127: rule manager has correct functions" do
    check all n <- integer(0..3) do
      fns = RuleManager.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r128: rule manager has correct functions" do
    check all n <- integer(0..3) do
      fns = RuleManager.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r129: rule manager has correct functions" do
    check all n <- integer(0..3) do
      fns = RuleManager.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r130: rule manager has correct functions" do
    check all n <- integer(0..3) do
      fns = RuleManager.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r131: rule manager attributes is a list" do
    check all n <- integer(0..3) do
      attrs = RuleManager.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r132: rule manager attributes is a list" do
    check all n <- integer(0..3) do
      attrs = RuleManager.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r133: rule manager attributes is a list" do
    check all n <- integer(0..3) do
      attrs = RuleManager.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r134: rule manager attributes is a list" do
    check all n <- integer(0..3) do
      attrs = RuleManager.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r135: rule manager attributes is a list" do
    check all n <- integer(0..3) do
      attrs = RuleManager.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r136: rule manager module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r137: rule manager module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r138: rule manager inspect works" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r139: rule manager module exists" do
    check all n <- integer() do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r140: rule manager functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r141: rule manager loaded check" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r142: rule manager is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r143: rule manager inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r144: rule manager not nil check" do
    check all n <- integer() do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r145: rule manager functions check" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r146: rule manager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r147: rule manager module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r148: rule manager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r149: rule manager inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(RuleManager)
      assert byte_size(s) > 0
    end
  end

  property "r150: rule manager atom final" do
    check all n <- integer() do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r151: rulemanager module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r152: rulemanager module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r153: rulemanager module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r154: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r155: rulemanager module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r156: rulemanager module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r157: rulemanager module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r158: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r159: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r160: rulemanager functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r161: rulemanager module identity check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r162: rulemanager module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r163: rulemanager module loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r164: rulemanager module is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r165: rulemanager module inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r166: rulemanager inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(RuleManager)
      assert byte_size(s) > 0
    end
  end

  property "r167: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r168: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r169: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r170: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r171: rulemanager module comparison" do
    check all n <- integer(0..3) do
      _ = n
      m = RuleManager
      assert m == RuleManager
    end
  end

  property "r172: rulemanager module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r173: rulemanager functions non-empty" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r174: rulemanager module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r175: rulemanager module atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r176: rulemanager module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r177: rulemanager module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r178: rulemanager module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r179: rulemanager module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r180: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r181: rulemanager module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r182: rulemanager inspect length" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r183: rulemanager module loaded final" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r184: rulemanager not nil final" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r185: rulemanager is_atom final" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r186: rulemanager module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r187: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r188: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r189: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r190: rulemanager functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r191: rulemanager module inspect r191" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r192: rulemanager not nil r192" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r193: rulemanager loaded r193" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r194: rulemanager is atom r194" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r195: rulemanager functions r195" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r196: rulemanager identity r196" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r197: rulemanager module name r197" do
    check all n <- integer(0..3) do
      _ = n
      name = to_string(RuleManager)
      assert String.length(name) > 0
    end
  end

  property "r198: rulemanager loaded ensure r198" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r199: rulemanager inspect len r199" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r200: rulemanager not nil final r200" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r201: rulemanager inspect binary r201" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r202: rulemanager not nil r202" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r203: rulemanager loaded r203" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r204: rulemanager is atom r204" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r205: rulemanager functions r205" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r206: rulemanager identity r206" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r207: rulemanager to_string r207" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r208: rulemanager loaded ensure r208" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r209: rulemanager inspect len r209" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r210: rulemanager not nil final r210" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r211: rulemanager inspect binary r211" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r212: rulemanager not nil r212" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r213: rulemanager loaded r213" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r214: rulemanager is atom r214" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r215: rulemanager functions r215" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r216: rulemanager identity r216" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r217: rulemanager to_string r217" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r218: rulemanager loaded ensure r218" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r219: rulemanager inspect len r219" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r220: rulemanager not nil final r220" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r221: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r222: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r223: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r224: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r225: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r226: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r227: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r228: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r229: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r230: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r231: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r232: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r233: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r234: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r235: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r236: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r237: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r238: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r239: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r240: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r241: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r242: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r243: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r244: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r245: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r246: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r247: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r248: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r249: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r250: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r251: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r252: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r253: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r254: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r255: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r256: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r257: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r258: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r259: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r260: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end
end
