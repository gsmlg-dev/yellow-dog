defmodule YellowDog.Data.StoreTest do
  @moduledoc """
  Contract tests for the Store behaviour.

  These tests verify that the Store dispatch functions correctly delegate
  to the adapter specified in the state's `__adapter__` field.
  """
  use ExUnit.Case, async: true

  alias YellowDog.Data.{Store, Collection}

  setup do
    collection = %Collection{
      name: :"test_store_#{:erlang.unique_integer([:positive])}",
      key_field: :id,
      adapter: YellowDog.Data.Store.Ets
    }

    {:ok, state} = Store.init(collection, [])
    %{state: state, collection: collection}
  end

  describe "init/2" do
    test "creates a new store from collection", %{state: state} do
      assert state.__adapter__ == YellowDog.Data.Store.Ets
      assert is_atom(state.table) or is_reference(state.table)
    end
  end

  describe "put/3 and get/2" do
    test "stores and retrieves a record", %{state: state} do
      {:ok, state} = Store.put(state, "key1", %{id: "key1", name: "test"})
      assert {:ok, %{id: "key1", name: "test"}} = Store.get(state, "key1")
    end

    test "overwrites existing record", %{state: state} do
      {:ok, state} = Store.put(state, "key1", %{id: "key1", v: 1})
      {:ok, _state} = Store.put(state, "key1", %{id: "key1", v: 2})
      assert {:ok, %{id: "key1", v: 2}} = Store.get(state, "key1")
    end

    test "returns not_found for missing key", %{state: state} do
      assert {:error, :not_found} = Store.get(state, "nonexistent")
    end
  end

  describe "delete/2" do
    test "removes a record", %{state: state} do
      {:ok, state} = Store.put(state, "key1", %{id: "key1"})
      {:ok, state} = Store.delete(state, "key1")
      assert {:error, :not_found} = Store.get(state, "key1")
    end

    test "deleting nonexistent key is ok", %{state: state} do
      assert {:ok, _state} = Store.delete(state, "nonexistent")
    end
  end

  describe "exists?/2" do
    test "returns true for existing key", %{state: state} do
      {:ok, state} = Store.put(state, "key1", %{id: "key1"})
      assert Store.exists?(state, "key1")
    end

    test "returns false for missing key", %{state: state} do
      refute Store.exists?(state, "nonexistent")
    end
  end

  describe "list/1" do
    test "returns all records", %{state: state} do
      {:ok, state} = Store.put(state, "a", %{id: "a"})
      {:ok, state} = Store.put(state, "b", %{id: "b"})
      {:ok, records} = Store.list(state)
      assert length(records) == 2
      ids = Enum.map(records, & &1.id) |> Enum.sort()
      assert ids == ["a", "b"]
    end

    test "returns empty list when no records", %{state: state} do
      assert {:ok, []} = Store.list(state)
    end
  end

  describe "list/2 with filter" do
    test "filters records", %{state: state} do
      {:ok, state} = Store.put(state, "a", %{id: "a", active: true})
      {:ok, state} = Store.put(state, "b", %{id: "b", active: false})
      {:ok, records} = Store.list(state, fn r -> r.active end)
      assert length(records) == 1
      assert hd(records).id == "a"
    end
  end

  describe "count/1" do
    test "counts records", %{state: state} do
      {:ok, state} = Store.put(state, "a", %{id: "a"})
      {:ok, state} = Store.put(state, "b", %{id: "b"})
      assert {:ok, 2} = Store.count(state)
    end

    test "returns 0 when empty", %{state: state} do
      assert {:ok, 0} = Store.count(state)
    end
  end

  describe "match/2" do
    test "matches records by pattern", %{state: state} do
      {:ok, state} = Store.put(state, "a", %{id: "a", type: :dns, zone: "example.com"})
      {:ok, state} = Store.put(state, "b", %{id: "b", type: :dns, zone: "test.com"})
      {:ok, state} = Store.put(state, "c", %{id: "c", type: :dhcp, zone: "example.com"})

      {:ok, matches} = Store.match(state, %{type: :dns})
      assert length(matches) == 2

      {:ok, matches} = Store.match(state, %{zone: "example.com"})
      assert length(matches) == 2

      {:ok, matches} = Store.match(state, %{type: :dns, zone: "example.com"})
      assert length(matches) == 1
    end
  end

  describe "update/3" do
    test "applies update function to record", %{state: state} do
      {:ok, state} = Store.put(state, "a", %{id: "a", count: 0})
      {:ok, updated, _state} = Store.update(state, "a", fn r -> %{r | count: r.count + 1} end)
      assert updated.count == 1
    end

    test "returns not_found for missing key", %{state: state} do
      assert {:error, :not_found} = Store.update(state, "missing", fn r -> r end)
    end
  end

  describe "clear/1" do
    test "removes all records", %{state: state} do
      {:ok, state} = Store.put(state, "a", %{id: "a"})
      {:ok, state} = Store.put(state, "b", %{id: "b"})
      {:ok, state} = Store.clear(state)
      assert {:ok, 0} = Store.count(state)
    end
  end

  describe "transaction/2" do
    test "executes function and returns result", %{state: state} do
      assert {:ok, 42} = Store.transaction(state, fn -> 42 end)
    end
  end

  describe "flush/1" do
    test "succeeds with no persistence configured", %{state: state} do
      assert :ok = Store.flush(state)
    end
  end
end
