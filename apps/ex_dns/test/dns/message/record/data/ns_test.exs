defmodule DNS.Message.Record.Data.NSTest do
  use ExUnit.Case

  test "DNS Record Data Type NS new" do
    domain = "www.gsmlg.com."
    data = DNS.Message.Record.Data.NS.new(domain)
    assert domain == data.data.value
  end

  test "DNS Record Data Type NS to_string/1" do
    domain = "www.gsmlg.com"
    data = DNS.Message.Record.Data.NS.new(domain)

    assert "#{data}" == domain <> "."
  end
end
