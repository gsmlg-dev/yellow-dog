defmodule YellowDog.MdnsTest do
  use ExUnit.Case
  doctest YellowDog.Mdns

  test "greets the world" do
    assert YellowDog.Mdns.hello() == :world
  end
end
