defmodule DNS.Message.Record.Data.MXTest do
  use ExUnit.Case

  test "DNS Record Data Type MX new" do
    domain = "www.gsmlg.com"
    data = DNS.Message.Record.Data.MX.new({10, domain})
    assert {10, DNS.Message.Domain.new(domain)} == data.data
  end

  test "DNS Record Data Type MX to_string/1" do
    domain = "www.gsmlg.com"
    data = DNS.Message.Record.Data.MX.new({10, domain})

    assert "#{data}" == "10 #{domain}."
  end
end
