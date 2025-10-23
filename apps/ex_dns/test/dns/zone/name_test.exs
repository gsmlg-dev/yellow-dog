defmodule DNS.Zone.NameTest do
  use ExUnit.Case

  alias DNS.Zone.Name

  test "DNS Zone Name" do
    root = Name.new(".")
    assert root.data == <<0>>

    name = "example.com"
    zone_name = Name.new(name)

    assert zone_name.value == name
    assert zone_name.data == <<3, "com", 7, "example">>
  end

  test "DNS Zone Name child?/2" do
    name1 = "com"
    zone_name1 = Name.new(name1)

    name2 = "example.com"
    zone_name2 = Name.new(name2)

    assert Name.child?(zone_name1, zone_name2)

    assert Name.child?(Name.new("."), zone_name1)
    assert Name.child?(Name.new("com"), Name.new("example.com"))
    assert Name.child?(Name.new("com"), Name.new("gsmlg.com"))
  end
end
