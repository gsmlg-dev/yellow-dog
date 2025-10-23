defmodule DNS.Message.OpCodeTest do
  use ExUnit.Case

  test "DNS Message OpCode new" do
    c0 = DNS.Message.OpCode.new(0)
    c1 = DNS.Message.OpCode.new(1)
    c2 = DNS.Message.OpCode.new(2)
    c4 = DNS.Message.OpCode.new(4)
    c5 = DNS.Message.OpCode.new(5)
    c6 = DNS.Message.OpCode.new(6)
    c3 = DNS.Message.OpCode.new(3)
    c9 = DNS.Message.OpCode.new(9)

    assert %DNS.Message.OpCode{} = c0
    assert %DNS.Message.OpCode{} = c1
    assert %DNS.Message.OpCode{} = c2
    assert %DNS.Message.OpCode{} = c4
    assert %DNS.Message.OpCode{} = c5
    assert %DNS.Message.OpCode{} = c6
    assert %DNS.Message.OpCode{} = c3
    assert %DNS.Message.OpCode{} = c9
  end

  test "DNS Message OpCode to_string/1" do
    c0 = DNS.Message.OpCode.new(0)
    c1 = DNS.Message.OpCode.new(1)
    c2 = DNS.Message.OpCode.new(2)
    c4 = DNS.Message.OpCode.new(4)
    c5 = DNS.Message.OpCode.new(5)
    c6 = DNS.Message.OpCode.new(6)
    c3 = DNS.Message.OpCode.new(3)
    c9 = DNS.Message.OpCode.new(9)

    assert "#{c0}" =~ "Query"
    assert "#{c1}" =~ "IQuery"
    assert "#{c2}" =~ "Status"
    assert "#{c4}" =~ "Notify"
    assert "#{c5}" =~ "Update"
    assert "#{c6}" =~ "DSO"
    assert "#{c3}" =~ "Unassigned(3)"
    assert "#{c9}" =~ "Unassigned(9)"
  end
end
