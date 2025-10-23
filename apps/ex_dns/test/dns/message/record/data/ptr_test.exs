defmodule DNS.Message.Record.Data.PTRTest do
  use ExUnit.Case

  test "DNS Record Data Type PTR new" do
    domain = "_ewelink._tcp.local."
    data = DNS.Message.Record.Data.PTR.new(domain)
    assert domain == data.data.value
  end

  test "DNS Record Data Type PTR to_string/1" do
    domain = "_ewelink._tcp.local."
    data = DNS.Message.Record.Data.PTR.new(domain)

    assert "#{data}" == domain
  end
end
