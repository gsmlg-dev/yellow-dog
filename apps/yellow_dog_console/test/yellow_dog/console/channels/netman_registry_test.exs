defmodule YellowDog.Console.NetmanRegistryTest do
  use ExUnit.Case, async: false

  alias YellowDog.Console.NetmanRegistry

  setup do
    NetmanRegistry.reset()
    :ok
  end

  test "rejects invalid client records" do
    NetmanRegistry.register(%{node_id: String.duplicate("n", 129)})
    Process.sleep(20)

    assert NetmanRegistry.list() == []
  end

  test "caps new client records while allowing existing updates" do
    for index <- 1..1_000 do
      NetmanRegistry.register(%{node_id: "netman-#{index}", status: :online})
    end

    wait_until_count(1_000)

    NetmanRegistry.register(%{node_id: "netman-1001", status: :online})
    Process.sleep(20)

    assert NetmanRegistry.count() == 1_000
    assert NetmanRegistry.get("netman-1001") == :error

    NetmanRegistry.update(%{node_id: "netman-1", status: :updated})
    Process.sleep(20)

    assert {:ok, %{status: :updated}} = NetmanRegistry.get("netman-1")
  end

  defp wait_until_count(count, attempts \\ 50)
  defp wait_until_count(_count, 0), do: flunk("Netman registry did not reach expected count")

  defp wait_until_count(count, attempts) do
    if NetmanRegistry.count() == count do
      :ok
    else
      Process.sleep(10)
      wait_until_count(count, attempts - 1)
    end
  end
end
