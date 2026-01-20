defmodule DNS.Message.EDNS0.Option.ExpireTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.Option.Expire.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with expire_time integer
  - from_iodata/1 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 7314)
  - EDNS EXPIRE semantics
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.Expire
  alias DNS.Message.EDNS0.OptionCode

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Expire)
    end

    test "exports new/1" do
      Code.ensure_loaded!(Expire)
      assert Kernel.function_exported?(Expire, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(Expire)
      assert Kernel.function_exported?(Expire, :from_iodata, 1)
    end

    test "defines a struct" do
      Code.ensure_loaded!(Expire)
      assert is_struct(Expire.__struct__())
    end
  end

  describe "struct fields" do
    test "has code field" do
      option = %Expire{}
      assert Map.has_key?(option, :code)
    end

    test "has length field" do
      option = %Expire{}
      assert Map.has_key?(option, :length)
    end

    test "has data field" do
      option = %Expire{}
      assert Map.has_key?(option, :data)
    end

    test "default code is EXPIRE (9)" do
      option = %Expire{}
      assert option.code == OptionCode.new(9)
    end

    test "default length is 4" do
      option = %Expire{}
      assert option.length == 4
    end

    test "default data is nil" do
      assert %Expire{}.data == nil
    end
  end

  describe "new/1" do
    test "creates Expire option with valid expire time" do
      option = Expire.new(3600)
      assert %Expire{} = option
    end

    test "stores expire_time field" do
      option = Expire.new(3600)
      assert option.data == 3600
    end

    test "creates option with zero expire time" do
      option = Expire.new(0)
      assert option.data == 0
    end

    test "creates option with 1 hour (3600s)" do
      option = Expire.new(3600)
      assert option.data == 3600
    end

    test "creates option with 1 day (86400s)" do
      option = Expire.new(86400)
      assert option.data == 86400
    end

    test "creates option with 1 week (604800s)" do
      option = Expire.new(604800)
      assert option.data == 604800
    end

    test "creates option with max value (4294967295)" do
      max_time = 0xFFFFFFFF
      option = Expire.new(max_time)
      assert option.data == max_time
    end

    test "option code is EXPIRE (9)" do
      option = Expire.new(3600)
      assert option.code.value == <<9::16>>
    end

    test "option length is 4" do
      option = Expire.new(3600)
      assert option.length == 4
    end
  end

  describe "from_iodata/1" do
    test "parses Expire option from binary" do
      binary = <<9::16, 4::16, 7200::32>>
      option = Expire.from_iodata(binary)
      assert %Expire{} = option
    end

    test "parses expire_time correctly" do
      binary = <<9::16, 4::16, 7200::32>>
      option = Expire.from_iodata(binary)
      assert option.data == 7200
    end

    test "parses zero expire_time" do
      binary = <<9::16, 4::16, 0::32>>
      option = Expire.from_iodata(binary)
      assert option.data == 0
    end

    test "parses max expire_time" do
      binary = <<9::16, 4::16, 0xFFFFFFFF::32>>
      option = Expire.from_iodata(binary)
      assert option.data == 0xFFFFFFFF
    end

    test "parses 1 day expire time" do
      binary = <<9::16, 4::16, 86400::32>>
      option = Expire.from_iodata(binary)
      assert option.data == 86400
    end

    test "parses length correctly" do
      binary = <<9::16, 4::16, 3600::32>>
      option = Expire.from_iodata(binary)
      assert option.length == 4
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      option = Expire.new(1800)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<9::16, 4::16, 1800::32>>
    end

    test "wire format starts with option code 9" do
      option = Expire.new(3600)
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 9
    end

    test "wire format has length 4" do
      option = Expire.new(3600)
      <<_code::16, length::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert length == 4
    end

    test "encodes expire_time as 32-bit unsigned" do
      option = Expire.new(86400)
      <<_code::16, _length::16, expire_time::32>> = DNS.Parameter.to_iodata(option)
      assert expire_time == 86400
    end

    test "encodes zero correctly" do
      option = Expire.new(0)
      <<_code::16, _length::16, expire_time::32>> = DNS.Parameter.to_iodata(option)
      assert expire_time == 0
    end

    test "encodes max value correctly" do
      option = Expire.new(0xFFFFFFFF)
      <<_code::16, _length::16, expire_time::32>> = DNS.Parameter.to_iodata(option)
      assert expire_time == 0xFFFFFFFF
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'EDNS EXPIRE: Ns'" do
      option = Expire.new(3600)
      assert to_string(option) == "EDNS EXPIRE: 3600s"
    end

    test "includes expire_time value" do
      option = Expire.new(7200)
      str = to_string(option)
      assert str =~ "7200"
    end

    test "includes seconds suffix" do
      option = Expire.new(3600)
      str = to_string(option)
      assert str =~ "s"
    end

    test "formats zero value" do
      option = Expire.new(0)
      assert to_string(option) == "EDNS EXPIRE: 0s"
    end

    test "string interpolation works" do
      option = Expire.new(3600)
      result = "Option: #{option}"
      assert result =~ "EDNS EXPIRE:"
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> from_iodata preserves data" do
      original = Expire.new(3600)
      iodata = DNS.Parameter.to_iodata(original)
      parsed = Expire.from_iodata(iodata)
      assert parsed.data == original.data
    end

    test "round-trip preserves various time values" do
      for time <- [0, 300, 3600, 86400, 604800, 0xFFFFFFFF] do
        original = Expire.new(time)
        iodata = DNS.Parameter.to_iodata(original)
        parsed = Expire.from_iodata(iodata)
        assert parsed.data == time
      end
    end
  end

  describe "EDNS EXPIRE semantics" do
    test "expire time 0 means expired" do
      option = Expire.new(0)
      assert option.data == 0
    end

    test "typical zone refresh time (1 hour)" do
      option = Expire.new(3600)
      assert option.data == 3600
    end

    test "typical zone retry time (15 minutes)" do
      option = Expire.new(900)
      assert option.data == 900
    end

    test "typical zone expire time (1 week)" do
      option = Expire.new(604800)
      assert option.data == 604800
    end

    test "typical minimum TTL (1 day)" do
      option = Expire.new(86400)
      assert option.data == 86400
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      option = Expire.new(3600)
      inspect_output = inspect(option)
      assert is_binary(inspect_output)
    end

    test "handles common time intervals" do
      intervals = [
        60,           # 1 minute
        300,          # 5 minutes
        900,          # 15 minutes
        3600,         # 1 hour
        86400,        # 1 day
        604800,       # 1 week
        2_592_000     # 30 days
      ]

      for interval <- intervals do
        option = Expire.new(interval)
        assert option.data == interval
      end
    end

    test "handles max 32-bit value" do
      option = Expire.new(0xFFFFFFFF)
      assert option.data == 0xFFFFFFFF
    end
  end
end
