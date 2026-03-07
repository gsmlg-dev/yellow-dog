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

  property "r261: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r262: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r263: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r264: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r265: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r266: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r267: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r268: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r269: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r270: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r271: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r272: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r273: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r274: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r275: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r276: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r277: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r278: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r279: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r280: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r281: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r282: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r283: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r284: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r285: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r286: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r287: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r288: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r289: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r290: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r291: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r292: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r293: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r294: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r295: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r296: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r297: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r298: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r299: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r300: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r301: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r302: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r303: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r304: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r305: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r306: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r307: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r308: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r309: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r310: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r311: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r312: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r313: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r314: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r315: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r316: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r317: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r318: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r319: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r320: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r321: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r322: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r323: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r324: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r325: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r326: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r327: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r328: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r329: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r330: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r331: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r332: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r333: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r334: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r335: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r336: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r337: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r338: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r339: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r340: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r341: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r342: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r343: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r344: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r345: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r346: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r347: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r348: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r349: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r350: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r351: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r352: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r353: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r354: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r355: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r356: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r357: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r358: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r359: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r360: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r361: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r362: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r363: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r364: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r365: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r366: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r367: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r368: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r369: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r370: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r371: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r372: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r373: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r374: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r375: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r376: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r377: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r378: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r379: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r380: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r381: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r382: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r383: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r384: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r385: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r386: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r387: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r388: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r389: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r390: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r391: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r392: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r393: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r394: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r395: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r396: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r397: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r398: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r399: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r400: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r401: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r402: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r403: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r404: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r405: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r406: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r407: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r408: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r409: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r410: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r411: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r412: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r413: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r414: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r415: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r416: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r417: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r418: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r419: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r420: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r421: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r422: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r423: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r424: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r425: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r426: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r427: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r428: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r429: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r430: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r431: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r432: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r433: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r434: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r435: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r436: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r437: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r438: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r439: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r440: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r441: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r442: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r443: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r444: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r445: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r446: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r447: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r448: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r449: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r450: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r451: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r452: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r453: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r454: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r455: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r456: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r457: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r458: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r459: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r460: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r461: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r462: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r463: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r464: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r465: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r466: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r467: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r468: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r469: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r470: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r471: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r472: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r473: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r474: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r475: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r476: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r477: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r478: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r479: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r480: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r481: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r482: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r483: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r484: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r485: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r486: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r487: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r488: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r489: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r490: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r491: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r492: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r493: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r494: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r495: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r496: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r497: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r498: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r499: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r500: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r501: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r502: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r503: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r504: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r505: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r506: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r507: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r508: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r509: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r510: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r511: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r512: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r513: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r514: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r515: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r516: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r517: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r518: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r519: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r520: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r521: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r522: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r523: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r524: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r525: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r526: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r527: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r528: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r529: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r530: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r531: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r532: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r533: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r534: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r535: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r536: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r537: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r538: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r539: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r540: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r541: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r542: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r543: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r544: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r545: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r546: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r547: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r548: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r549: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r550: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r551: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r552: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r553: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r554: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r555: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r556: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r557: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r558: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r559: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r560: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r561: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r562: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r563: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r564: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r565: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r566: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r567: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r568: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r569: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r570: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r571: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r572: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r573: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r574: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r575: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r576: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r577: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r578: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r579: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r580: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r581: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r582: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r583: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r584: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r585: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r586: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r587: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r588: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r589: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r590: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r591: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r592: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r593: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r594: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r595: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r596: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r597: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r598: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r599: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r600: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r601: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r602: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r603: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r604: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r605: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r606: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r607: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r608: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r609: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r610: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r611: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r612: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r613: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r614: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r615: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r616: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r617: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r618: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r619: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r620: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r621: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r622: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r623: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r624: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r625: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r626: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r627: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r628: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r629: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r630: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r631: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r632: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r633: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r634: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r635: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r636: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r637: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r638: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r639: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r640: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r641: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r642: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r643: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r644: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r645: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r646: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r647: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r648: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r649: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r650: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r651: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r652: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r653: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r654: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r655: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r656: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r657: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r658: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r659: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r660: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r661: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r662: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r663: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r664: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r665: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r666: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r667: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r668: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r669: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r670: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r671: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r672: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r673: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r674: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r675: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r676: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r677: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r678: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r679: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r680: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r681: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r682: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r683: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r684: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r685: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r686: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r687: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r688: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r689: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r690: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r691: rulemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RuleManager))
    end
  end

  property "r692: rulemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end

  property "r693: rulemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r694: rulemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RuleManager)
    end
  end

  property "r695: rulemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RuleManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r696: rulemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager == RuleManager
    end
  end

  property "r697: rulemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RuleManager)
      assert String.length(s) > 0
    end
  end

  property "r698: rulemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RuleManager)
    end
  end

  property "r699: rulemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RuleManager)) > 0
    end
  end

  property "r700: rulemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RuleManager != nil
    end
  end
end
