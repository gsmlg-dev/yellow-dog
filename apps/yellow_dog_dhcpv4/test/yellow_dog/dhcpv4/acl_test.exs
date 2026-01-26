defmodule YellowDog.Dhcpv4.ACLTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv4.ACL

  describe "validate_rule/1" do
    test "validates a complete MAC rule" do
      rule_config = %{
        "priority" => 10,
        "type" => "mac",
        "pattern" => "aa:bb:cc:*",
        "action" => "allow",
        "target_pool" => "office_network"
      }

      assert {:ok, rule} = ACL.validate_rule(rule_config)
      assert rule.priority == 10
      assert rule.type == :mac
      assert rule.pattern == "aa:bb:cc:*"
      assert rule.action == :allow
      assert rule.target_pool == "office_network"
    end

    test "validates a deny rule" do
      rule_config = %{
        "priority" => 100,
        "type" => "mac",
        "pattern" => "00:00:00:*",
        "action" => "deny"
      }

      assert {:ok, rule} = ACL.validate_rule(rule_config)
      assert rule.action == :deny
      assert rule.target_pool == nil
    end

    test "validates a custom_options rule" do
      rule_config = %{
        "priority" => 20,
        "type" => "vendor_class",
        "pattern" => "MSFT 5.0",
        "action" => "custom_options",
        "option_set" => "windows_clients"
      }

      assert {:ok, rule} = ACL.validate_rule(rule_config)
      assert rule.action == :custom_options
      assert rule.option_set == "windows_clients"
    end

    test "returns error for missing priority" do
      rule_config = %{
        "type" => "mac",
        "pattern" => "aa:bb:cc:*",
        "action" => "allow"
      }

      assert {:error, :missing_priority} = ACL.validate_rule(rule_config)
    end

    test "returns error for invalid type" do
      rule_config = %{
        "priority" => 10,
        "type" => "invalid_type",
        "pattern" => "aa:bb:cc:*",
        "action" => "allow"
      }

      assert {:error, :invalid_type} = ACL.validate_rule(rule_config)
    end

    test "returns error for invalid action" do
      rule_config = %{
        "priority" => 10,
        "type" => "mac",
        "pattern" => "aa:bb:cc:*",
        "action" => "invalid_action"
      }

      assert {:error, :invalid_action} = ACL.validate_rule(rule_config)
    end
  end

  describe "evaluate/3" do
    setup do
      rules = [
        %{
          priority: 10,
          type: :mac,
          pattern: "AA:BB:CC:*",
          action: :allow,
          target_pool: "office",
          option_set: nil
        },
        %{
          priority: 20,
          type: :vendor_class,
          pattern: "MSFT*",
          action: :custom_options,
          target_pool: nil,
          option_set: "windows_opts"
        },
        %{
          priority: 100,
          type: :mac,
          pattern: "00:00:00:*",
          action: :deny,
          target_pool: nil,
          option_set: nil
        }
      ]

      {:ok, rules: rules}
    end

    test "matches MAC pattern with allow action", %{rules: rules} do
      client_info = %{
        mac_address: <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>,
        vendor_class: nil,
        user_class: nil,
        client_arch: nil
      }

      result = ACL.evaluate(rules, client_info)
      assert {:allow, "office"} = result
    end

    test "matches vendor class pattern with custom_options action", %{rules: rules} do
      client_info = %{
        mac_address: <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>,
        vendor_class: "MSFT 5.0",
        user_class: nil,
        client_arch: nil
      }

      result = ACL.evaluate(rules, client_info)
      assert {:custom_options, "windows_opts"} = result
    end

    test "matches deny rule", %{rules: rules} do
      client_info = %{
        mac_address: <<0x00, 0x00, 0x00, 0x11, 0x22, 0x33>>,
        vendor_class: nil,
        user_class: nil,
        client_arch: nil
      }

      result = ACL.evaluate(rules, client_info)
      assert {:deny, _reason} = result
    end

    test "uses default policy when no match", %{rules: rules} do
      client_info = %{
        mac_address: <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>,
        vendor_class: nil,
        user_class: nil,
        client_arch: nil
      }

      # Default is :allow
      result = ACL.evaluate(rules, client_info)
      assert {:allow, nil} = result

      # Explicit :deny default
      result = ACL.evaluate(rules, client_info, :deny)
      assert {:deny, _reason} = result
    end

    test "evaluates rules in priority order" do
      # Two rules that could both match - lower priority should win
      rules = [
        %{
          priority: 20,
          type: :mac,
          pattern: "*",
          action: :deny,
          target_pool: nil,
          option_set: nil
        },
        %{
          priority: 10,
          type: :mac,
          pattern: "*",
          action: :allow,
          target_pool: "first",
          option_set: nil
        }
      ]

      client_info = %{
        mac_address: <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>,
        vendor_class: nil,
        user_class: nil,
        client_arch: nil
      }

      result = ACL.evaluate(rules, client_info)
      # Priority 10 should match first
      assert {:allow, "first"} = result
    end
  end

  describe "allowed?/2" do
    test "returns true for allow action" do
      rules = [
        %{
          priority: 10,
          type: :mac,
          pattern: "*",
          action: :allow,
          target_pool: nil,
          option_set: nil
        }
      ]

      client_info = %{
        mac_address: <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>,
        vendor_class: nil,
        user_class: nil,
        client_arch: nil
      }

      assert ACL.allowed?(rules, client_info) == true
    end

    test "returns false for deny action" do
      rules = [
        %{
          priority: 10,
          type: :mac,
          pattern: "*",
          action: :deny,
          target_pool: nil,
          option_set: nil
        }
      ]

      client_info = %{
        mac_address: <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>,
        vendor_class: nil,
        user_class: nil,
        client_arch: nil
      }

      assert ACL.allowed?(rules, client_info) == false
    end

    test "returns true for custom_options action" do
      rules = [
        %{
          priority: 10,
          type: :mac,
          pattern: "*",
          action: :custom_options,
          target_pool: nil,
          option_set: "test_opts"
        }
      ]

      client_info = %{
        mac_address: <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>,
        vendor_class: nil,
        user_class: nil,
        client_arch: nil
      }

      assert ACL.allowed?(rules, client_info) == true
    end
  end

  describe "get_target_pool/2" do
    test "returns pool name when rule specifies one" do
      rules = [
        %{
          priority: 10,
          type: :mac,
          pattern: "*",
          action: :allow,
          target_pool: "office",
          option_set: nil
        }
      ]

      client_info = %{
        mac_address: <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>,
        vendor_class: nil,
        user_class: nil,
        client_arch: nil
      }

      assert ACL.get_target_pool(rules, client_info) == "office"
    end

    test "returns nil when no pool specified" do
      rules = [
        %{
          priority: 10,
          type: :mac,
          pattern: "*",
          action: :deny,
          target_pool: nil,
          option_set: nil
        }
      ]

      client_info = %{
        mac_address: <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>,
        vendor_class: nil,
        user_class: nil,
        client_arch: nil
      }

      assert ACL.get_target_pool(rules, client_info) == nil
    end
  end

  describe "get_option_set/2" do
    test "returns option set name for custom_options action" do
      rules = [
        %{
          priority: 10,
          type: :mac,
          pattern: "*",
          action: :custom_options,
          target_pool: nil,
          option_set: "windows_opts"
        }
      ]

      client_info = %{
        mac_address: <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>,
        vendor_class: nil,
        user_class: nil,
        client_arch: nil
      }

      assert ACL.get_option_set(rules, client_info) == "windows_opts"
    end

    test "returns nil for non-custom_options actions" do
      rules = [
        %{
          priority: 10,
          type: :mac,
          pattern: "*",
          action: :allow,
          target_pool: "office",
          option_set: nil
        }
      ]

      client_info = %{
        mac_address: <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>,
        vendor_class: nil,
        user_class: nil,
        client_arch: nil
      }

      assert ACL.get_option_set(rules, client_info) == nil
    end
  end

  describe "load_with_fallback/1" do
    test "returns empty list for non-existent file" do
      assert ACL.load_with_fallback("/nonexistent/path.toml") == []
    end
  end
end
