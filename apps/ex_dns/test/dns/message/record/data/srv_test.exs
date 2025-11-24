defmodule DNS.Message.Record.Data.SRVTest do
  use ExUnit.Case

  test "DNS Record Data Type SRV new" do
    domain = "www.gsmlg.com."
    data = DNS.Message.Record.Data.SRV.new({0, 0, 1194, domain})
    assert {0, 0, 1194, DNS.Message.Domain.new(domain)} == data.data
  end

  test "DNS Record Data Type SRV to_string/1" do
    domain = "www.gsmlg.com"
    data = DNS.Message.Record.Data.SRV.new({0, 0, 1194, domain})

    assert "#{data}" == "0 0 1194 #{domain}."
  end
end
