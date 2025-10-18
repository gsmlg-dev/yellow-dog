defmodule YellowDogTest do
  use ExUnit.Case
  doctest YellowDog

  test "greets the world" do
    assert YellowDog.hello() == :world
  end
end
