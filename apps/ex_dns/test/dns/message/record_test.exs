defmodule DNS.Message.RecordTest do
  use ExUnit.Case

  test "DNS Record Data Type A new" do
    record = DNS.Message.Record.new("example.com", 1, 1, 3600, {1, 1, 1, 1})
    assert {1, 1, 1, 1} == record.data.data
  end

  test "DNS Record Data Type A to_string/1" do
    record = DNS.Message.Record.new("example.com", 1, 1, 3600, {1, 1, 1, 1})

    assert "#{record}" == "example.com. A IN 3600 1.1.1.1"
  end
end
