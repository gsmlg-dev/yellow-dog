defmodule YellowDog.DnsTest do
  use ExUnit.Case
  doctest YellowDog.Dns

  test "greets the world" do
    assert YellowDog.Dns.hello() == :world
  end
end
