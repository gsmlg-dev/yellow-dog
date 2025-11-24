defmodule DNS.Message.Record.Data.NSECTest do
  use ExUnit.Case

  alias DNS.Message.Domain

  test "DNS Record Data Type NSEC new" do
    nsec =
      {"admin.gsmlg.com", [1, 16, 33]}

    data = DNS.Message.Record.Data.NSEC.new(nsec)

    assert {Domain.new(elem(nsec, 0)),
            [
              DNS.ResourceRecordType.new(1),
              DNS.ResourceRecordType.new(16),
              DNS.ResourceRecordType.new(33)
            ]} == data.data
  end

  test "DNS Record Data Type NSEC to_string/1" do
    nsec =
      {"admin.gsmlg.com", [1, 16, 33]}

    data = DNS.Message.Record.Data.NSEC.new(nsec)

    assert "#{data}" == "admin.gsmlg.com. A TXT SRV"
  end
end
