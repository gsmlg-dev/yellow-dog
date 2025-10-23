defmodule DNS.Message.Record.Data.AAAATest do
  use ExUnit.Case

  test "DNS Record Data Type AAAA new" do
    {:ok, ip} = :inet.parse_ipv6_address(~c"2001:4860:4860::8888")
    data = DNS.Message.Record.Data.AAAA.new(ip)
    assert ip == data.data
  end

  test "DNS Record Data Type AAAA to_string/1" do
    {:ok, ip} = :inet.parse_ipv6_address(~c"2001:4860:4860::8888")
    data = DNS.Message.Record.Data.AAAA.new(ip)

    assert "#{data}" =~ "2001:4860:4860::8888"
  end
end
