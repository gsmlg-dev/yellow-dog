defmodule DNS.Zone.RootHintTest do
  use ExUnit.Case

  alias DNS.ResourceRecordType, as: RRType
  alias DNS.Zone.RootHint
  alias DNS.Zone.RRSet
  alias DNS.Zone.Name

  test "DNS zone root hint" do
    root_hints = RootHint.root_hints()

    assert is_list(root_hints)

    ns_list =
      root_hints
      |> Enum.reduce([], fn rr, list ->
        if rr[:type] == RRType.new(:ns) and rr[:name] == "." do
          [rr | list]
        else
          list
        end
      end)

    rrset = RRSet.new(Name.new("."), RRType.new(:ns), ns_list |> Enum.map(& &1[:rdata]), [])

    glues =
      rrset.data
      |> Enum.reduce([], fn d, list ->
        glues =
          root_hints
          |> Enum.filter(fn rr ->
            rr[:name] == to_string(d)
          end)

        list ++ glues
      end)

    rrset = %{rrset | options: [glues: glues]}

    assert is_struct(rrset, RRSet)
  end
end
