defmodule YellowDog.Netman.Control.ModeGateTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netman.Control.ModeGate
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.NetmanOperation

  test "allows queries in every apply mode" do
    assert {:ok, query} = NetmanOperation.fetch("netman.network.links.list")

    for mode <- [:managed, :observe, :observe_first] do
      assert :ok = ModeGate.check(query, mode, %{})
    end
  end

  test "allows profile validation in every apply mode" do
    assert {:ok, operation} = NetmanOperation.fetch("netman.profiles.validate")

    for mode <- [:managed, :observe, :observe_first] do
      assert :ok = ModeGate.check(operation, mode, %{})
    end
  end

  test "rejects mutations outside managed mode" do
    assert {:ok, operation} = NetmanOperation.fetch("netman.profiles.put")

    for mode <- [:observe, :observe_first] do
      assert {:error, %Error{code: :unsupported, details: %{}}} =
               ModeGate.check(operation, mode, %{})
    end
  end

  test "does not allow payload approval flags in observe-first mode" do
    assert {:ok, operation} = NetmanOperation.fetch("netman.profiles.put")

    assert {:error, %Error{code: :unsupported, details: %{}}} =
             ModeGate.check(operation, :observe_first, %{
               "approved" => true,
               "approval" => "local",
               "policy" => "allow"
             })
  end
end
