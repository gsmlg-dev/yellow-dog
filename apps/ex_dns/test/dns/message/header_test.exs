defmodule DNS.Message.HeaderTest do
  use ExUnit.Case

  test "DNS Message Header new" do
    h = DNS.Message.Header.new()
    assert %DNS.Message.Header{} = h
  end

  test "DNS Message Header to_string/1" do
    h1 = DNS.Message.Header.new()
    assert "#{h1}" =~ " qr: 0, opcode: Query, status: NoError"
    assert "#{h1}" =~ "aa: 0, tc: 0, rd: 1, ra: 0, z: 0, ad: 0, cd: 0"
    assert "#{h1}" =~ "QUERY: 0, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 0"
  end
end
