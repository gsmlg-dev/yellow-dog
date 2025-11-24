defmodule DNS.ResourceRecordTypeTest do
  use ExUnit.Case

  test "DNS resourceRecordType new" do
    t = DNS.ResourceRecordType.new(1)
    assert t == %DNS.ResourceRecordType{value: <<1::16>>}
  end

  test "DNS resourceRecordType to_string/1" do
    t1 = DNS.ResourceRecordType.new(1)
    assert "#{t1}" == "A"

    t2 = DNS.ResourceRecordType.new(:ns)
    assert "#{t2}" =~ "NS"
  end
end
