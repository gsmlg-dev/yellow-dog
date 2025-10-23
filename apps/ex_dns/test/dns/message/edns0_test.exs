defmodule DNS.Message.EDNS0Test do
  use ExUnit.Case

  test "DNS Message EDNS0 new" do
    edns0 = DNS.Message.EDNS0.new()

    assert %DNS.Message.EDNS0{} = edns0
  end

  test "DNS Message EDNS0 to_string/1" do
    edns0 = DNS.Message.EDNS0.new()

    assert "#{edns0}" == "; EDNS: version: 0, flags:  udp: 0\n"
  end
end
