defmodule DNS.Message.OpCodeTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.OpCode.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 function with integer and binary values
  - Named constructors (query, iquery, status, notify, update, dso)
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Unassigned opcode handling
  - Edge cases and boundary values
  """
  use ExUnit.Case, async: true

  alias DNS.Message.OpCode

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(OpCode)
    end

    test "exports new/1" do
      Code.ensure_loaded!(OpCode)
      assert Kernel.function_exported?(OpCode, :new, 1)
    end

    test "exports query/0" do
      Code.ensure_loaded!(OpCode)
      assert Kernel.function_exported?(OpCode, :query, 0)
    end

    test "exports iquery/0" do
      Code.ensure_loaded!(OpCode)
      assert Kernel.function_exported?(OpCode, :iquery, 0)
    end

    test "exports status/0" do
      Code.ensure_loaded!(OpCode)
      assert Kernel.function_exported?(OpCode, :status, 0)
    end

    test "exports notify/0" do
      Code.ensure_loaded!(OpCode)
      assert Kernel.function_exported?(OpCode, :notify, 0)
    end

    test "exports update/0" do
      Code.ensure_loaded!(OpCode)
      assert Kernel.function_exported?(OpCode, :update, 0)
    end

    test "exports dso/0" do
      Code.ensure_loaded!(OpCode)
      assert Kernel.function_exported?(OpCode, :dso, 0)
    end

    test "defines a struct" do
      Code.ensure_loaded!(OpCode)
      assert is_struct(OpCode.__struct__())
    end
  end

  describe "struct fields" do
    test "has value field" do
      opcode = %OpCode{}
      assert Map.has_key?(opcode, :value)
    end

    test "default value is 0" do
      assert %OpCode{}.value == 0
    end
  end

  describe "new/1 with integer values" do
    test "creates OpCode from integer 0" do
      opcode = OpCode.new(0)
      assert %OpCode{} = opcode
      assert opcode.value == <<0::4>>
    end

    test "creates OpCode from integer 1" do
      opcode = OpCode.new(1)
      assert opcode.value == <<1::4>>
    end

    test "creates OpCode from integer 2" do
      opcode = OpCode.new(2)
      assert opcode.value == <<2::4>>
    end

    test "creates OpCode from integer 4" do
      opcode = OpCode.new(4)
      assert opcode.value == <<4::4>>
    end

    test "creates OpCode from integer 5" do
      opcode = OpCode.new(5)
      assert opcode.value == <<5::4>>
    end

    test "creates OpCode from integer 6" do
      opcode = OpCode.new(6)
      assert opcode.value == <<6::4>>
    end

    test "creates OpCode from unassigned value 3" do
      opcode = OpCode.new(3)
      assert opcode.value == <<3::4>>
    end

    test "creates OpCode from unassigned value 7" do
      opcode = OpCode.new(7)
      assert opcode.value == <<7::4>>
    end

    test "creates OpCode from max 4-bit value 15" do
      opcode = OpCode.new(15)
      assert opcode.value == <<15::4>>
    end
  end

  describe "new/1 with binary values" do
    test "creates OpCode from binary value" do
      binary = <<0::4>>
      opcode = OpCode.new(binary)
      assert opcode.value == binary
    end

    test "creates OpCode from 4-bit binary" do
      binary = <<5::4>>
      opcode = OpCode.new(binary)
      assert opcode.value == binary
    end
  end

  describe "named constructors" do
    test "query/0 returns OpCode with value 0" do
      opcode = OpCode.query()
      assert %OpCode{} = opcode
      assert opcode.value == <<0::4>>
    end

    test "iquery/0 returns OpCode with value 1" do
      opcode = OpCode.iquery()
      assert opcode.value == <<1::4>>
    end

    test "status/0 returns OpCode with value 2" do
      opcode = OpCode.status()
      assert opcode.value == <<2::4>>
    end

    test "notify/0 returns OpCode with value 4" do
      opcode = OpCode.notify()
      assert opcode.value == <<4::4>>
    end

    test "update/0 returns OpCode with value 5" do
      opcode = OpCode.update()
      assert opcode.value == <<5::4>>
    end

    test "dso/0 returns OpCode with value 6" do
      opcode = OpCode.dso()
      assert opcode.value == <<6::4>>
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "query displays as 'Query'" do
      assert to_string(OpCode.query()) == "Query"
    end

    test "iquery displays as 'IQuery'" do
      assert to_string(OpCode.iquery()) == "IQuery"
    end

    test "status displays as 'Status'" do
      assert to_string(OpCode.status()) == "Status"
    end

    test "notify displays as 'Notify'" do
      assert to_string(OpCode.notify()) == "Notify"
    end

    test "update displays as 'Update'" do
      assert to_string(OpCode.update()) == "Update"
    end

    test "dso displays as 'DSO'" do
      assert to_string(OpCode.dso()) == "DSO"
    end

    test "unassigned 3 displays as 'Unassigned(3)'" do
      assert to_string(OpCode.new(3)) == "Unassigned(3)"
    end

    test "unassigned 7 displays as 'Unassigned(7)'" do
      assert to_string(OpCode.new(7)) == "Unassigned(7)"
    end

    test "unassigned 8 displays as 'Unassigned(8)'" do
      assert to_string(OpCode.new(8)) == "Unassigned(8)"
    end

    test "unassigned 9 displays as 'Unassigned(9)'" do
      assert to_string(OpCode.new(9)) == "Unassigned(9)"
    end

    test "unassigned 15 displays as 'Unassigned(15)'" do
      assert to_string(OpCode.new(15)) == "Unassigned(15)"
    end

    test "string interpolation works" do
      opcode = OpCode.query()
      assert "OpCode: #{opcode}" == "OpCode: Query"
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "to_iodata returns the value field" do
      opcode = OpCode.query()
      iodata = DNS.Parameter.to_iodata(opcode)
      assert iodata == <<0::4>>
    end

    test "to_iodata for iquery returns 4-bit binary" do
      opcode = OpCode.iquery()
      iodata = DNS.Parameter.to_iodata(opcode)
      assert iodata == <<1::4>>
    end

    test "to_iodata for status returns 4-bit binary" do
      opcode = OpCode.status()
      iodata = DNS.Parameter.to_iodata(opcode)
      assert iodata == <<2::4>>
    end

    test "to_iodata for notify returns 4-bit binary" do
      opcode = OpCode.notify()
      iodata = DNS.Parameter.to_iodata(opcode)
      assert iodata == <<4::4>>
    end

    test "to_iodata for update returns 4-bit binary" do
      opcode = OpCode.update()
      iodata = DNS.Parameter.to_iodata(opcode)
      assert iodata == <<5::4>>
    end

    test "to_iodata for dso returns 4-bit binary" do
      opcode = OpCode.dso()
      iodata = DNS.Parameter.to_iodata(opcode)
      assert iodata == <<6::4>>
    end
  end

  describe "RFC compliance" do
    test "Query opcode is 0 per RFC 1035" do
      assert <<0::4>> = OpCode.query().value
    end

    test "IQuery opcode is 1 per RFC 3425" do
      assert <<1::4>> = OpCode.iquery().value
    end

    test "Status opcode is 2 per RFC 1035" do
      assert <<2::4>> = OpCode.status().value
    end

    test "Notify opcode is 4 per RFC 1996" do
      assert <<4::4>> = OpCode.notify().value
    end

    test "Update opcode is 5 per RFC 2136" do
      assert <<5::4>> = OpCode.update().value
    end

    test "DSO opcode is 6 per RFC 8490" do
      assert <<6::4>> = OpCode.dso().value
    end

    test "values 7-15 are unassigned" do
      for value <- 7..15 do
        opcode = OpCode.new(value)
        assert to_string(opcode) =~ "Unassigned(#{value})"
      end
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      opcode = OpCode.query()
      inspect_output = inspect(opcode)
      assert is_binary(inspect_output)
      assert String.contains?(inspect_output, "OpCode")
    end

    test "all opcodes create valid structs" do
      for value <- 0..15 do
        opcode = OpCode.new(value)
        assert is_struct(opcode, OpCode)
      end
    end

    test "named constructors return same value as new/1" do
      assert OpCode.query().value == OpCode.new(0).value
      assert OpCode.iquery().value == OpCode.new(1).value
      assert OpCode.status().value == OpCode.new(2).value
      assert OpCode.notify().value == OpCode.new(4).value
      assert OpCode.update().value == OpCode.new(5).value
      assert OpCode.dso().value == OpCode.new(6).value
    end
  end
end
