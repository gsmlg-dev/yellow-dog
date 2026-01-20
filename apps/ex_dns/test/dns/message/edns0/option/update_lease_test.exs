defmodule DNS.Message.EDNS0.Option.UpdateLeaseTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.Option.UpdateLease.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with lease_time integer
  - from_iodata/1 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC draft)
  - DNS-SD Update Lease semantics
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.UpdateLease
  alias DNS.Message.EDNS0.OptionCode

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(UpdateLease)
    end

    test "exports new/1" do
      Code.ensure_loaded!(UpdateLease)
      assert Kernel.function_exported?(UpdateLease, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(UpdateLease)
      assert Kernel.function_exported?(UpdateLease, :from_iodata, 1)
    end

    test "defines a struct" do
      Code.ensure_loaded!(UpdateLease)
      assert is_struct(UpdateLease.__struct__())
    end
  end

  describe "struct fields" do
    test "has code field" do
      option = %UpdateLease{}
      assert Map.has_key?(option, :code)
    end

    test "has length field" do
      option = %UpdateLease{}
      assert Map.has_key?(option, :length)
    end

    test "has data field" do
      option = %UpdateLease{}
      assert Map.has_key?(option, :data)
    end

    test "default code is UpdateLease (2)" do
      option = %UpdateLease{}
      assert option.code == OptionCode.new(2)
    end

    test "default length is 4" do
      option = %UpdateLease{}
      assert option.length == 4
    end

    test "default data is nil" do
      assert %UpdateLease{}.data == nil
    end
  end

  describe "new/1" do
    test "creates UpdateLease option with valid lease time" do
      option = UpdateLease.new(7200)
      assert %UpdateLease{} = option
    end

    test "stores lease_time field" do
      option = UpdateLease.new(7200)
      assert option.data == 7200
    end

    test "creates option with zero lease time" do
      option = UpdateLease.new(0)
      assert option.data == 0
    end

    test "creates option with 1 hour (3600s)" do
      option = UpdateLease.new(3600)
      assert option.data == 3600
    end

    test "creates option with 2 hours (7200s)" do
      option = UpdateLease.new(7200)
      assert option.data == 7200
    end

    test "creates option with 1 day (86400s)" do
      option = UpdateLease.new(86400)
      assert option.data == 86400
    end

    test "creates option with max value (4294967295)" do
      max_time = 0xFFFFFFFF
      option = UpdateLease.new(max_time)
      assert option.data == max_time
    end

    test "option code is UpdateLease (2)" do
      option = UpdateLease.new(7200)
      assert option.code.value == <<2::16>>
    end

    test "option length is 4" do
      option = UpdateLease.new(7200)
      assert option.length == 4
    end
  end

  describe "from_iodata/1" do
    test "parses UpdateLease option from binary" do
      binary = <<2::16, 4::16, 3600::32>>
      option = UpdateLease.from_iodata(binary)
      assert %UpdateLease{} = option
    end

    test "parses lease_time correctly" do
      binary = <<2::16, 4::16, 3600::32>>
      option = UpdateLease.from_iodata(binary)
      assert option.data == 3600
    end

    test "parses zero lease_time" do
      binary = <<2::16, 4::16, 0::32>>
      option = UpdateLease.from_iodata(binary)
      assert option.data == 0
    end

    test "parses max lease_time" do
      binary = <<2::16, 4::16, 0xFFFFFFFF::32>>
      option = UpdateLease.from_iodata(binary)
      assert option.data == 0xFFFFFFFF
    end

    test "parses 1 hour lease time" do
      binary = <<2::16, 4::16, 3600::32>>
      option = UpdateLease.from_iodata(binary)
      assert option.data == 3600
    end

    test "parses length correctly" do
      binary = <<2::16, 4::16, 7200::32>>
      option = UpdateLease.from_iodata(binary)
      assert option.length == 4
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      option = UpdateLease.new(1800)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<2::16, 4::16, 1800::32>>
    end

    test "wire format starts with option code 2" do
      option = UpdateLease.new(7200)
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 2
    end

    test "wire format has length 4" do
      option = UpdateLease.new(7200)
      <<_code::16, length::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert length == 4
    end

    test "encodes lease_time as 32-bit unsigned" do
      option = UpdateLease.new(86400)
      <<_code::16, _length::16, lease_time::32>> = DNS.Parameter.to_iodata(option)
      assert lease_time == 86400
    end

    test "encodes zero correctly" do
      option = UpdateLease.new(0)
      <<_code::16, _length::16, lease_time::32>> = DNS.Parameter.to_iodata(option)
      assert lease_time == 0
    end

    test "encodes max value correctly" do
      option = UpdateLease.new(0xFFFFFFFF)
      <<_code::16, _length::16, lease_time::32>> = DNS.Parameter.to_iodata(option)
      assert lease_time == 0xFFFFFFFF
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'Update Lease: Ns'" do
      option = UpdateLease.new(3600)
      assert to_string(option) == "Update Lease: 3600s"
    end

    test "includes lease_time value" do
      option = UpdateLease.new(7200)
      str = to_string(option)
      assert str =~ "7200"
    end

    test "includes seconds suffix" do
      option = UpdateLease.new(3600)
      str = to_string(option)
      assert str =~ "s"
    end

    test "formats zero value" do
      option = UpdateLease.new(0)
      assert to_string(option) == "Update Lease: 0s"
    end

    test "string interpolation works" do
      option = UpdateLease.new(7200)
      result = "Option: #{option}"
      assert result =~ "Update Lease:"
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> from_iodata preserves data" do
      original = UpdateLease.new(7200)
      iodata = DNS.Parameter.to_iodata(original)
      parsed = UpdateLease.from_iodata(iodata)
      assert parsed.data == original.data
    end

    test "round-trip preserves various time values" do
      for time <- [0, 300, 3600, 7200, 86400, 0xFFFFFFFF] do
        original = UpdateLease.new(time)
        iodata = DNS.Parameter.to_iodata(original)
        parsed = UpdateLease.from_iodata(iodata)
        assert parsed.data == time
      end
    end
  end

  describe "DNS-SD Update Lease semantics" do
    test "lease time 0 means immediate deletion" do
      option = UpdateLease.new(0)
      assert option.data == 0
    end

    test "typical mDNS service lease (2 hours)" do
      option = UpdateLease.new(7200)
      assert option.data == 7200
    end

    test "short-lived service (30 minutes)" do
      option = UpdateLease.new(1800)
      assert option.data == 1800
    end

    test "long-lived service (1 day)" do
      option = UpdateLease.new(86400)
      assert option.data == 86400
    end

    test "default recommended lease (75 minutes)" do
      # DNS-SD recommends 75 minutes as default
      option = UpdateLease.new(4500)
      assert option.data == 4500
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      option = UpdateLease.new(7200)
      inspect_output = inspect(option)
      assert is_binary(inspect_output)
    end

    test "handles common time intervals" do
      intervals = [
        60,           # 1 minute
        300,          # 5 minutes
        1800,         # 30 minutes
        3600,         # 1 hour
        7200,         # 2 hours
        86400,        # 1 day
        604800        # 1 week
      ]

      for interval <- intervals do
        option = UpdateLease.new(interval)
        assert option.data == interval
      end
    end

    test "handles max 32-bit value" do
      option = UpdateLease.new(0xFFFFFFFF)
      assert option.data == 0xFFFFFFFF
    end
  end
end
