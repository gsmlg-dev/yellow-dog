defmodule DNS.Message.Record.Data.CNAMETest do
  use ExUnit.Case

  test "DNS Record Data Type CNAME new" do
    domain = "www.gsmlg.com."
    data = DNS.Message.Record.Data.CNAME.new(domain)
    assert domain == data.data.value
  end

  test "DNS Record Data Type CNAME to_string/1" do
    domain = "www.gsmlg.com."
    data = DNS.Message.Record.Data.CNAME.new(domain)

    assert "#{data}" == domain
  end
end
