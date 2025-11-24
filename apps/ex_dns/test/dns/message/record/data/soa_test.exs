defmodule DNS.Message.Record.Data.SOATest do
  use ExUnit.Case

  alias DNS.Message.Domain

  test "DNS Record Data Type SOA new" do
    soa =
      {Domain.new("ns.gsmlg.com"), Domain.new("admin.gsmlg.com"), 2_367_333_983, 10000, 2400,
       604_800, 1800}

    data = DNS.Message.Record.Data.SOA.new(soa)
    assert soa == data.data
  end

  test "DNS Record Data Type SOA to_string/1" do
    soa =
      {Domain.new("ns.gsmlg.com"), Domain.new("admin.gsmlg.com"), 2_367_333_983, 10000, 2400,
       604_800, 1800}

    data = DNS.Message.Record.Data.SOA.new(soa)

    assert "#{data}" == "ns.gsmlg.com. admin.gsmlg.com. 2367333983 10000 2400 604800 1800"
  end
end
