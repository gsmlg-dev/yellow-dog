defmodule DNS.Message.DomainTest do
  use ExUnit.Case

  alias DNS.Message.Domain

  test "DNS Message Domain new" do
    d = Domain.new("www.example.com")
    assert %Domain{} = d
  end

  test "DNS Message Domain to_string/1" do
    d = Domain.new("www.example.com")
    assert "www.example.com." = "#{d}"
  end

  test "DNS Message Domain to_iodata/1" do
    d = Domain.new("www.example.com")
    assert DNS.Parameter.to_iodata(d) == <<3, "www", 7, "example", 3, "com", 0>>
  end

  test "DNS Message Domain inspect" do
    d = Domain.new("www.example.com")
    assert inspect(d) == "#DNS.Domain<www.example.com.>"
  end
end
