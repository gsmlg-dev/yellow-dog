defmodule DNS.ZoneTest do
  use ExUnit.Case

  alias DNS.Zone
  alias DNS.Zone.Name

  test "DNS Zone new" do
    name = "."
    root_zone = Zone.new(name)

    assert root_zone == %Zone{
             name: Name.new(name),
             type: :authoritative,
             options: []
           }

    assert Zone.new("example.com") == %Zone{
             name: Name.new("example.com"),
             type: :authoritative,
             options: []
           }
  end
end
