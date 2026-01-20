defmodule DNS.Message.EDNS0.Option.LLQTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.Option.LLQ.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with {version, opcode, id, lease_life} tuple
  - from_iodata/1 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 8764)
  - LLQ operation semantics
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.LLQ
  alias DNS.Message.EDNS0.OptionCode

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(LLQ)
    end

    test "exports new/1" do
      Code.ensure_loaded!(LLQ)
      assert Kernel.function_exported?(LLQ, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(LLQ)
      assert Kernel.function_exported?(LLQ, :from_iodata, 1)
    end

    test "defines a struct" do
      Code.ensure_loaded!(LLQ)
      assert is_struct(LLQ.__struct__())
    end
  end

  describe "struct fields" do
    test "has code field" do
      option = %LLQ{}
      assert Map.has_key?(option, :code)
    end

    test "has length field" do
      option = %LLQ{}
      assert Map.has_key?(option, :length)
    end

    test "has data field" do
      option = %LLQ{}
      assert Map.has_key?(option, :data)
    end

    test "default code is LLQ (1)" do
      option = %LLQ{}
      assert option.code == OptionCode.new(1)
    end

    test "default length is 18" do
      option = %LLQ{}
      assert option.length == 18
    end

    test "default data is nil" do
      assert %LLQ{}.data == nil
    end
  end

  describe "new/1" do
    test "creates LLQ option with valid data" do
      option = LLQ.new({1, 1, <<1, 2, 3, 4, 5, 6, 7, 8>>, 3600})
      assert %LLQ{} = option
    end

    test "stores version field" do
      option = LLQ.new({1, 2, <<1::64>>, 3600})
      {version, _, _, _} = option.data
      assert version == 1
    end

    test "stores opcode field" do
      option = LLQ.new({1, 3, <<1::64>>, 3600})
      {_, opcode, _, _} = option.data
      assert opcode == 3
    end

    test "stores id field" do
      id = <<1, 2, 3, 4, 5, 6, 7, 8>>
      option = LLQ.new({1, 1, id, 3600})
      {_, _, stored_id, _} = option.data
      assert stored_id == id
    end

    test "stores lease_life field" do
      option = LLQ.new({1, 1, <<1::64>>, 7200})
      {_, _, _, lease_life} = option.data
      assert lease_life == 7200
    end

    test "option code is LLQ (1)" do
      option = LLQ.new({1, 1, <<1::64>>, 3600})
      assert option.code.value == <<1::16>>
    end

    test "option length is 18" do
      option = LLQ.new({1, 1, <<1::64>>, 3600})
      assert option.length == 18
    end

    test "creates option with version 1" do
      option = LLQ.new({1, 1, <<1::64>>, 3600})
      {version, _, _, _} = option.data
      assert version == 1
    end

    test "creates option with LLQ-SETUP opcode (1)" do
      option = LLQ.new({1, 1, <<1::64>>, 3600})
      {_, opcode, _, _} = option.data
      assert opcode == 1
    end

    test "creates option with LLQ-REFRESH opcode (2)" do
      option = LLQ.new({1, 2, <<1::64>>, 3600})
      {_, opcode, _, _} = option.data
      assert opcode == 2
    end

    test "creates option with LLQ-EVENT opcode (3)" do
      option = LLQ.new({1, 3, <<1::64>>, 3600})
      {_, opcode, _, _} = option.data
      assert opcode == 3
    end

    test "creates option with zero lease_life" do
      option = LLQ.new({1, 1, <<1::64>>, 0})
      {_, _, _, lease_life} = option.data
      assert lease_life == 0
    end

    test "creates option with max lease_life" do
      max_lease = 0xFFFFFFFF
      option = LLQ.new({1, 1, <<1::64>>, max_lease})
      {_, _, _, lease_life} = option.data
      assert lease_life == max_lease
    end

    test "creates option with unique id" do
      id = :crypto.strong_rand_bytes(8)
      option = LLQ.new({1, 1, id, 3600})
      {_, _, stored_id, _} = option.data
      assert stored_id == id
    end
  end

  describe "from_iodata/1" do
    test "parses LLQ option from binary" do
      binary = <<1::16, 18::16, 1::16, 1::16, 1::64, 3600::32>>
      option = LLQ.from_iodata(binary)
      assert %LLQ{} = option
    end

    test "parses version correctly" do
      binary = <<1::16, 18::16, 1::16, 2::16, 1::64, 3600::32>>
      option = LLQ.from_iodata(binary)
      {version, _, _, _} = option.data
      assert version == 1
    end

    test "parses opcode correctly" do
      binary = <<1::16, 18::16, 1::16, 2::16, 1::64, 3600::32>>
      option = LLQ.from_iodata(binary)
      {_, opcode, _, _} = option.data
      assert opcode == 2
    end

    test "parses id correctly" do
      id_value = 0x0102030405060708
      binary = <<1::16, 18::16, 1::16, 1::16, id_value::64, 3600::32>>
      option = LLQ.from_iodata(binary)
      {_, _, id, _} = option.data
      assert id == <<id_value::64>>
    end

    test "parses lease_life correctly" do
      binary = <<1::16, 18::16, 1::16, 1::16, 1::64, 7200::32>>
      option = LLQ.from_iodata(binary)
      {_, _, _, lease_life} = option.data
      assert lease_life == 7200
    end

    test "parses zero lease_life" do
      binary = <<1::16, 18::16, 1::16, 1::16, 1::64, 0::32>>
      option = LLQ.from_iodata(binary)
      {_, _, _, lease_life} = option.data
      assert lease_life == 0
    end

    test "parses max lease_life" do
      binary = <<1::16, 18::16, 1::16, 1::16, 1::64, 0xFFFFFFFF::32>>
      option = LLQ.from_iodata(binary)
      {_, _, _, lease_life} = option.data
      assert lease_life == 0xFFFFFFFF
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      option = LLQ.new({1, 2, <<1, 2, 3, 4, 5, 6, 7, 8>>, 1800})
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<1::16, 18::16, 1::16, 2::16, 0x0102030405060708::64, 1800::32>>
    end

    test "wire format starts with option code 1" do
      option = LLQ.new({1, 1, <<0::64>>, 3600})
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 1
    end

    test "wire format has length 18" do
      option = LLQ.new({1, 1, <<0::64>>, 3600})
      <<_code::16, length::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert length == 18
    end

    test "encodes version field" do
      option = LLQ.new({1, 1, <<0::64>>, 3600})
      <<_code::16, _length::16, version::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert version == 1
    end

    test "encodes opcode field" do
      option = LLQ.new({1, 3, <<0::64>>, 3600})
      <<_code::16, _length::16, _version::16, opcode::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert opcode == 3
    end

    test "encodes id field" do
      id = <<0xABCDEF0123456789::64>>
      option = LLQ.new({1, 1, id, 3600})
      <<_code::16, _length::16, _version::16, _opcode::16, id_value::64, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert id_value == 0xABCDEF0123456789
    end

    test "encodes lease_life field" do
      option = LLQ.new({1, 1, <<0::64>>, 86400})
      <<_::16, _::16, _::16, _::16, _::64, lease_life::32>> = DNS.Parameter.to_iodata(option)
      assert lease_life == 86400
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'LLQ: vN opN id:HEX lease:Ns'" do
      option = LLQ.new({1, 2, <<1, 2, 3, 4, 5, 6, 7, 8>>, 1800})
      assert to_string(option) == "LLQ: v1 op2 id:0102030405060708 lease:1800s"
    end

    test "includes version number" do
      option = LLQ.new({1, 1, <<0::64>>, 3600})
      str = to_string(option)
      assert str =~ "v1"
    end

    test "includes opcode number" do
      option = LLQ.new({1, 3, <<0::64>>, 3600})
      str = to_string(option)
      assert str =~ "op3"
    end

    test "includes hex-encoded id" do
      option = LLQ.new({1, 1, <<0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE>>, 3600})
      str = to_string(option)
      assert str =~ "DEADBEEFCAFEBABE"
    end

    test "includes lease time with seconds suffix" do
      option = LLQ.new({1, 1, <<0::64>>, 7200})
      str = to_string(option)
      assert str =~ "7200s"
    end

    test "string interpolation works" do
      option = LLQ.new({1, 1, <<0::64>>, 3600})
      result = "Option: #{option}"
      assert result =~ "LLQ:"
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> from_iodata preserves data" do
      original = LLQ.new({1, 2, <<0xABCDEF0123456789::64>>, 3600})
      iodata = DNS.Parameter.to_iodata(original)
      parsed = LLQ.from_iodata(iodata)
      assert parsed.data == original.data
    end

    test "round-trip preserves all opcodes" do
      for opcode <- [1, 2, 3] do
        original = LLQ.new({1, opcode, <<1::64>>, 3600})
        iodata = DNS.Parameter.to_iodata(original)
        parsed = LLQ.from_iodata(iodata)
        {_, parsed_opcode, _, _} = parsed.data
        assert parsed_opcode == opcode
      end
    end

    test "round-trip preserves various lease times" do
      for lease <- [0, 300, 3600, 86400, 0xFFFFFFFF] do
        original = LLQ.new({1, 1, <<1::64>>, lease})
        iodata = DNS.Parameter.to_iodata(original)
        parsed = LLQ.from_iodata(iodata)
        {_, _, _, parsed_lease} = parsed.data
        assert parsed_lease == lease
      end
    end
  end

  describe "LLQ operation semantics" do
    test "LLQ-SETUP opcode is 1" do
      option = LLQ.new({1, 1, <<1::64>>, 3600})
      {_, opcode, _, _} = option.data
      assert opcode == 1
    end

    test "LLQ-REFRESH opcode is 2" do
      option = LLQ.new({1, 2, <<1::64>>, 3600})
      {_, opcode, _, _} = option.data
      assert opcode == 2
    end

    test "LLQ-EVENT opcode is 3" do
      option = LLQ.new({1, 3, <<1::64>>, 3600})
      {_, opcode, _, _} = option.data
      assert opcode == 3
    end

    test "version 1 is current" do
      option = LLQ.new({1, 1, <<1::64>>, 3600})
      {version, _, _, _} = option.data
      assert version == 1
    end

    test "lease life 0 means cancel subscription" do
      option = LLQ.new({1, 2, <<1::64>>, 0})
      {_, _, _, lease_life} = option.data
      assert lease_life == 0
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      option = LLQ.new({1, 1, <<1::64>>, 3600})
      inspect_output = inspect(option)
      assert is_binary(inspect_output)
    end

    test "handles all-zeros id" do
      option = LLQ.new({1, 1, <<0::64>>, 3600})
      {_, _, id, _} = option.data
      assert id == <<0::64>>
    end

    test "handles all-ones id" do
      option = LLQ.new({1, 1, <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>, 3600})
      {_, _, id, _} = option.data
      assert id == <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
    end

    test "handles random id" do
      random_id = :crypto.strong_rand_bytes(8)
      option = LLQ.new({1, 1, random_id, 3600})
      {_, _, id, _} = option.data
      assert id == random_id
    end
  end
end
