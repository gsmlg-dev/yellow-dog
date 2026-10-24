defmodule YellowDog.Sync.IdentityTest do
  use ExUnit.Case, async: true

  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Identity
  alias YellowDog.Sync.Identity.Server

  @revision String.duplicate("b", 64)

  test "round trips concrete Server identities without a generic node" do
    server = identity(Server, "server-east-1", ["dns", "dhcpv4"])

    assert {:ok, %Server{} = decoded_server} =
             server |> Identity.to_wire() |> Identity.from_wire()

    assert decoded_server == server
  end

  test "rejects malformed identity data and target-type mismatches" do
    invalid_id = identity(Server, <<255>>, []) |> Identity.to_wire()

    assert_invalid(Identity.from_wire(invalid_id))

    retired =
      identity(Server, "retired", []) |> Identity.to_wire() |> Map.put("target_type", "netman")

    assert_invalid(Identity.from_wire(retired))
    assert_invalid(Identity.from_wire(retired, :server))
  end

  test "rejects uppercase revisions and non-string capability values" do
    uppercase_revision =
      identity(Server, "server-east-1", [])
      |> Identity.to_wire()
      |> Map.put("config_revision", String.duplicate("B", 64))

    atom_capability =
      identity(Server, "server-east-1", [])
      |> Identity.to_wire()
      |> Map.put("capabilities", [:dns])

    assert_invalid(Identity.from_wire(uppercase_revision))
    assert_invalid(Identity.from_wire(atom_capability))
  end

  test "rejects direct identity maps over the approved entry limit" do
    oversized =
      identity(Server, "server-east-1", [])
      |> Identity.to_wire()
      |> add_entries_to_exceed_map_limit()

    assert map_size(oversized) > Bounds.max_map_entries()
    assert_invalid(Identity.from_wire(oversized))
  end

  defp identity(module, id, capabilities) do
    struct!(module,
      id: id,
      name: "edge node",
      version: "1.0.0",
      profile: "default",
      capabilities: capabilities,
      config_revision: @revision
    )
  end

  defp assert_invalid(result) do
    assert {:error, %Error{code: :invalid}} = result
  end

  defp add_entries_to_exceed_map_limit(map) do
    entries_to_add = Bounds.max_map_entries() - map_size(map) + 1

    Enum.reduce(1..entries_to_add, map, fn index, map ->
      Map.put(map, "unexpected_#{index}", nil)
    end)
  end
end
