defmodule DNS.Message.RCodeTest do
  use ExUnit.Case

  test "DNS Message RCode new" do
    c0 = DNS.Message.RCode.new(0)
    c1 = DNS.Message.RCode.new(1)
    c2 = DNS.Message.RCode.new(2)
    c4 = DNS.Message.RCode.new(4)
    c5 = DNS.Message.RCode.new(5)
    c6 = DNS.Message.RCode.new(6)
    c3 = DNS.Message.RCode.new(3)
    c9 = DNS.Message.RCode.new(9)

    assert %DNS.Message.RCode{} = c0
    assert %DNS.Message.RCode{} = c1
    assert %DNS.Message.RCode{} = c2
    assert %DNS.Message.RCode{} = c4
    assert %DNS.Message.RCode{} = c5
    assert %DNS.Message.RCode{} = c6
    assert %DNS.Message.RCode{} = c3
    assert %DNS.Message.RCode{} = c9
  end

  test "DNS Message RCode to_string/1" do
    c0 = DNS.Message.RCode.new(0)
    c1 = DNS.Message.RCode.new(1)
    c2 = DNS.Message.RCode.new(2)
    c3 = DNS.Message.RCode.new(3)
    c4 = DNS.Message.RCode.new(4)
    c5 = DNS.Message.RCode.new(5)
    c6 = DNS.Message.RCode.new(6)
    c7 = DNS.Message.RCode.new(7)
    c8 = DNS.Message.RCode.new(8)
    c9 = DNS.Message.RCode.new(9)
    c10 = DNS.Message.RCode.new(10)
    c11 = DNS.Message.RCode.new(11)

    assert "#{c0}" == "NoError"
    assert "#{c1}" == "FormErr"
    assert "#{c2}" == "ServFail"
    assert "#{c3}" == "NXDomain"
    assert "#{c4}" == "NotImp"
    assert "#{c5}" == "Refused"
    assert "#{c6}" == "YXDomain"
    assert "#{c7}" == "YXRRSet"
    assert "#{c8}" == "NXRRSet"
    assert "#{c9}" == "NotAuth"
    assert "#{c10}" == "NotZone"
    assert "#{c11}" == "DSOTYPENI"
  end
end
