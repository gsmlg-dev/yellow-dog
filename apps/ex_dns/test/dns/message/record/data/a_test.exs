defmodule DNS.Message.Record.Data.ATest do
  use ExUnit.Case

  test "DNS Record Data Type A new" do
    {:ok, ip} = :inet.parse_ipv4_address(~c"1.1.1.1")
    data = DNS.Message.Record.Data.A.new(ip)
    assert ip == data.data
  end

  test "DNS Record Data Type A to_string/1" do
    {:ok, ip} = :inet.parse_ipv4_address(~c"1.1.1.1")
    data = DNS.Message.Record.Data.A.new(ip)

    assert "#{data}" =~ "1.1.1.1"
  end
end
