defmodule YellowDog.Dhcpv4.CustomOptionsTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv4.CustomOptions

  describe "validate_option/1" do
    test "validates string option" do
      config = %{"code" => 66, "type" => "string", "value" => "tftp.local"}

      assert {:ok, option} = CustomOptions.validate_option(config)
      assert option.code == 66
      assert option.type == :string
      assert option.value == "tftp.local"
    end

    test "validates ip option" do
      config = %{"code" => 3, "type" => "ip", "value" => "192.168.1.1"}

      assert {:ok, option} = CustomOptions.validate_option(config)
      assert option.code == 3
      assert option.type == :ip
      assert option.value == {192, 168, 1, 1}
    end

    test "validates ip_list option" do
      config = %{"code" => 6, "type" => "ip_list", "value" => ["8.8.8.8", "8.8.4.4"]}

      assert {:ok, option} = CustomOptions.validate_option(config)
      assert option.code == 6
      assert option.type == :ip_list
      assert option.value == [{8, 8, 8, 8}, {8, 8, 4, 4}]
    end

    test "validates uint8 option" do
      config = %{"code" => 23, "type" => "uint8", "value" => 64}

      assert {:ok, option} = CustomOptions.validate_option(config)
      assert option.code == 23
      assert option.type == :uint8
      assert option.value == 64
    end

    test "validates uint16 option" do
      config = %{"code" => 57, "type" => "uint16", "value" => 1500}

      assert {:ok, option} = CustomOptions.validate_option(config)
      assert option.code == 57
      assert option.type == :uint16
      assert option.value == 1500
    end

    test "validates uint32 option" do
      config = %{"code" => 51, "type" => "uint32", "value" => 86400}

      assert {:ok, option} = CustomOptions.validate_option(config)
      assert option.code == 51
      assert option.type == :uint32
      assert option.value == 86400
    end

    test "validates hex option" do
      config = %{"code" => 43, "type" => "hex", "value" => "AABBCCDD"}

      assert {:ok, option} = CustomOptions.validate_option(config)
      assert option.code == 43
      assert option.type == :hex
      assert option.value == <<0xAA, 0xBB, 0xCC, 0xDD>>
    end

    test "validates hex option with 0x prefix" do
      config = %{"code" => 43, "type" => "hex", "value" => "0xAABBCCDD"}

      assert {:ok, option} = CustomOptions.validate_option(config)
      assert option.value == <<0xAA, 0xBB, 0xCC, 0xDD>>
    end

    test "returns error for missing code" do
      config = %{"type" => "string", "value" => "test"}

      assert {:error, :missing_code} = CustomOptions.validate_option(config)
    end

    test "returns error for invalid code" do
      config = %{"code" => 0, "type" => "string", "value" => "test"}

      assert {:error, :invalid_code} = CustomOptions.validate_option(config)
    end

    test "returns error for code out of range" do
      config = %{"code" => 255, "type" => "string", "value" => "test"}

      assert {:error, :invalid_code} = CustomOptions.validate_option(config)
    end

    test "returns error for missing type" do
      config = %{"code" => 66, "value" => "test"}

      assert {:error, :missing_type} = CustomOptions.validate_option(config)
    end

    test "returns error for invalid type" do
      config = %{"code" => 66, "type" => "invalid", "value" => "test"}

      assert {:error, :invalid_type} = CustomOptions.validate_option(config)
    end

    test "returns error for missing value" do
      config = %{"code" => 66, "type" => "string"}

      assert {:error, :missing_value} = CustomOptions.validate_option(config)
    end

    test "returns error for invalid IP address" do
      config = %{"code" => 3, "type" => "ip", "value" => "not.an.ip"}

      assert {:error, {:invalid_ip, "not.an.ip"}} = CustomOptions.validate_option(config)
    end

    test "returns error for invalid uint8 value" do
      config = %{"code" => 23, "type" => "uint8", "value" => 256}

      assert {:error, {:invalid_value, :uint8, 256}} = CustomOptions.validate_option(config)
    end
  end

  describe "apply_templates/2" do
    test "substitutes ${client_mac} variable" do
      option_set = %{
        name: "test",
        scope: :pool,
        options: [
          %{code: 66, type: :string, value: "tftp-${client_mac}.local"}
        ]
      }

      context = %{
        client_mac: <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>,
        client_hostname: nil,
        lease_address: nil,
        pool_name: nil
      }

      result = CustomOptions.apply_templates(option_set, context)
      assert hd(result.options).value == "tftp-AA:BB:CC:DD:EE:FF.local"
    end

    test "substitutes ${client_hostname} variable" do
      option_set = %{
        name: "test",
        scope: :pool,
        options: [
          %{code: 66, type: :string, value: "server-${client_hostname}.local"}
        ]
      }

      context = %{
        client_mac: nil,
        client_hostname: "workstation01",
        lease_address: nil,
        pool_name: nil
      }

      result = CustomOptions.apply_templates(option_set, context)
      assert hd(result.options).value == "server-workstation01.local"
    end

    test "substitutes ${lease_address} variable" do
      option_set = %{
        name: "test",
        scope: :pool,
        options: [
          %{code: 66, type: :string, value: "config-${lease_address}.cfg"}
        ]
      }

      context = %{
        client_mac: nil,
        client_hostname: nil,
        lease_address: {192, 168, 1, 100},
        pool_name: nil
      }

      result = CustomOptions.apply_templates(option_set, context)
      assert hd(result.options).value == "config-192.168.1.100.cfg"
    end

    test "substitutes ${pool_name} variable" do
      option_set = %{
        name: "test",
        scope: :pool,
        options: [
          %{code: 66, type: :string, value: "tftp-${pool_name}.local"}
        ]
      }

      context = %{
        client_mac: nil,
        client_hostname: nil,
        lease_address: nil,
        pool_name: "office"
      }

      result = CustomOptions.apply_templates(option_set, context)
      assert hd(result.options).value == "tftp-office.local"
    end

    test "replaces missing variables with empty string" do
      option_set = %{
        name: "test",
        scope: :pool,
        options: [
          %{code: 66, type: :string, value: "tftp-${pool_name}.local"}
        ]
      }

      context = %{
        client_mac: nil,
        client_hostname: nil,
        lease_address: nil,
        pool_name: nil
      }

      result = CustomOptions.apply_templates(option_set, context)
      assert hd(result.options).value == "tftp-.local"
    end

    test "does not modify non-string options" do
      option_set = %{
        name: "test",
        scope: :pool,
        options: [
          %{code: 6, type: :ip_list, value: [{8, 8, 8, 8}]}
        ]
      }

      context = %{
        client_mac: nil,
        client_hostname: nil,
        lease_address: nil,
        pool_name: nil
      }

      result = CustomOptions.apply_templates(option_set, context)
      assert hd(result.options).value == [{8, 8, 8, 8}]
    end
  end

  describe "merge_option_sets/2" do
    test "later options override earlier ones" do
      option_sets = [
        %{
          name: "global",
          scope: :global,
          options: [
            %{code: 6, type: :ip_list, value: [{8, 8, 8, 8}]},
            %{code: 66, type: :string, value: "global.local"}
          ]
        },
        %{
          name: "pool",
          scope: :pool,
          options: [
            %{code: 66, type: :string, value: "pool.local"}
          ]
        }
      ]

      context = %{
        client_mac: nil,
        client_hostname: nil,
        lease_address: nil,
        pool_name: nil
      }

      result = CustomOptions.merge_option_sets(option_sets, context)

      # Should have 2 unique options
      assert length(result) == 2

      # Code 66 should have the pool value (later override)
      option_66 = Enum.find(result, fn opt -> opt.code == 66 end)
      assert option_66.value == "pool.local"

      # Code 6 should still be from global
      option_6 = Enum.find(result, fn opt -> opt.code == 6 end)
      assert option_6.value == [{8, 8, 8, 8}]
    end
  end

  describe "encode_options/1" do
    test "encodes string option" do
      options = [%{code: 66, type: :string, value: "tftp.local"}]

      result = CustomOptions.encode_options(options)

      assert length(result) == 1
      encoded = hd(result)
      assert encoded.type == 66
      assert encoded.value == "tftp.local"
    end

    test "encodes ip option" do
      options = [%{code: 3, type: :ip, value: {192, 168, 1, 1}}]

      result = CustomOptions.encode_options(options)

      assert length(result) == 1
      encoded = hd(result)
      assert encoded.type == 3
      assert encoded.value == <<192, 168, 1, 1>>
    end

    test "encodes ip_list option" do
      options = [%{code: 6, type: :ip_list, value: [{8, 8, 8, 8}, {8, 8, 4, 4}]}]

      result = CustomOptions.encode_options(options)

      assert length(result) == 1
      encoded = hd(result)
      assert encoded.type == 6
      assert encoded.value == <<8, 8, 8, 8, 8, 8, 4, 4>>
    end

    test "encodes uint8 option" do
      options = [%{code: 23, type: :uint8, value: 64}]

      result = CustomOptions.encode_options(options)

      assert length(result) == 1
      encoded = hd(result)
      assert encoded.type == 23
      assert encoded.value == <<64>>
    end

    test "encodes uint16 option" do
      options = [%{code: 57, type: :uint16, value: 1500}]

      result = CustomOptions.encode_options(options)

      assert length(result) == 1
      encoded = hd(result)
      assert encoded.type == 57
      assert encoded.value == <<5, 220>>
    end

    test "encodes uint32 option" do
      options = [%{code: 51, type: :uint32, value: 86400}]

      result = CustomOptions.encode_options(options)

      assert length(result) == 1
      encoded = hd(result)
      assert encoded.type == 51
      assert encoded.value == <<0, 1, 81, 128>>
    end
  end

  describe "get_option_set/2" do
    test "finds option set by name" do
      option_sets = [
        %{name: "global", scope: :global, options: []},
        %{name: "windows", scope: :acl, options: []}
      ]

      assert {:ok, set} = CustomOptions.get_option_set(option_sets, "windows")
      assert set.name == "windows"
    end

    test "returns error for unknown name" do
      option_sets = [
        %{name: "global", scope: :global, options: []}
      ]

      assert {:error, :not_found} = CustomOptions.get_option_set(option_sets, "unknown")
    end
  end

  describe "load_with_fallback/1" do
    test "returns empty list for non-existent file" do
      assert CustomOptions.load_with_fallback("/nonexistent/path.toml") == []
    end
  end
end
