defmodule DNS.Zone.RRSetTest do
  use ExUnit.Case

  alias DNS.Zone.RRSet
  alias DNS.Zone.Name
  alias DNS.ResourceRecordType, as: RRType

  test "DNS Zone RRSet" do
    root = RRSet.new(Name.new("."), RRType.new(:ns), ["a.root-servers.net"], [])
    assert root.data == ["a.root-servers.net"]
    assert root.name == Name.new(".")
    assert root.type == RRType.new(:ns)
    assert root.options == []
    assert root.ttl == 0
  end
end
