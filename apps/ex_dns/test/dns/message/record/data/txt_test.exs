defmodule DNS.Message.Record.Data.TXTTest do
  use ExUnit.Case

  test "DNS Record Data Type TXT new" do
    txt = ["www.gsmlg.com"]
    data = DNS.Message.Record.Data.TXT.new(txt)
    assert txt == data.data
  end

  test "DNS Record Data Type TXT to_string/1" do
    txt = ["www.gsmlg.com"]
    data = DNS.Message.Record.Data.TXT.new(txt)

    assert "#{data}" == ~s["www.gsmlg.com"]
  end
end
