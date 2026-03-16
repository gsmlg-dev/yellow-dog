defmodule YellowDog.Store.SingleNodeTest do
  use ExUnit.Case, async: false

  alias YellowDog.Store.SingleNode

  @table :yellow_dog_store_single_node

  setup do
    # Ensure table exists and is clean
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(@table)
    end

    :ok
  end

  describe "single_node?/0" do
    test "returns true when no peers are connected" do
      # In test env there are no connected peers
      assert SingleNode.single_node?()
    end
  end

  describe "put/get/delete" do
    test "basic put and get" do
      assert :ok = SingleNode.put("test:key1", %{value: 42})
      assert {:ok, %{value: 42}} = SingleNode.get("test:key1")
    end

    test "get returns not_found for missing key" do
      assert {:error, :not_found} = SingleNode.get("nonexistent")
    end

    test "delete removes key" do
      SingleNode.put("test:del", "value")
      assert :ok = SingleNode.delete("test:del")
      assert {:error, :not_found} = SingleNode.get("test:del")
    end

    test "put with TTL expires" do
      # Set TTL to 0 seconds (already expired)
      SingleNode.put("test:ttl", "value", ttl: 0)
      # Immediately after, should be expired
      assert {:error, :not_found} = SingleNode.get("test:ttl")
    end

    test "put with long TTL persists" do
      SingleNode.put("test:ttl-long", "value", ttl: 3600)
      assert {:ok, "value"} = SingleNode.get("test:ttl-long")
    end
  end

  describe "put_if/3" do
    test "expected: nil succeeds when key missing" do
      assert :ok = SingleNode.put_if("test:cas1", "value", expected: nil)
      assert {:ok, "value"} = SingleNode.get("test:cas1")
    end

    test "expected: nil fails when key exists" do
      SingleNode.put("test:cas2", "existing")
      assert {:error, :condition_failed} = SingleNode.put_if("test:cas2", "new", expected: nil)
    end

    test "condition function returning true allows write" do
      SingleNode.put("test:cas3", %{state: :offered})

      assert :ok =
               SingleNode.put_if("test:cas3", %{state: :bound},
                 condition: fn %{state: :offered} -> true end
               )

      assert {:ok, %{state: :bound}} = SingleNode.get("test:cas3")
    end

    test "condition function returning false rejects write" do
      SingleNode.put("test:cas4", %{state: :bound})

      assert {:error, :condition_failed} =
               SingleNode.put_if("test:cas4", %{state: :released},
                 condition: fn
                   %{state: :offered} -> true
                   _ -> false
                 end
               )
    end

    test "condition function returning {:update, value} updates" do
      SingleNode.put("test:cas5", %{state: :offered, version: 1})

      assert :ok =
               SingleNode.put_if("test:cas5", nil,
                 condition: fn %{state: :offered} = lease ->
                   {:update, %{lease | state: :bound, version: 2}}
                 end
               )

      assert {:ok, %{state: :bound, version: 2}} = SingleNode.get("test:cas5")
    end

    test "put_if with TTL option" do
      assert :ok = SingleNode.put_if("test:cas-ttl", "value", expected: nil, ttl: 3600)
      assert {:ok, "value"} = SingleNode.get("test:cas-ttl")
    end
  end

  describe "prefix_scan/2" do
    test "scans keys by prefix" do
      SingleNode.put("scan:a:1", "v1")
      SingleNode.put("scan:a:2", "v2")
      SingleNode.put("scan:b:1", "v3")

      assert {:ok, entries} = SingleNode.prefix_scan("scan:a:")
      assert length(entries) == 2
      assert {"scan:a:1", "v1"} in entries
      assert {"scan:a:2", "v2"} in entries
    end

    test "excludes expired entries" do
      SingleNode.put("scan:exp:1", "v1", ttl: 0)
      SingleNode.put("scan:exp:2", "v2", ttl: 3600)

      assert {:ok, entries} = SingleNode.prefix_scan("scan:exp:")
      assert length(entries) == 1
      assert {"scan:exp:2", "v2"} in entries
    end

    test "returns empty list for no matches" do
      assert {:ok, []} = SingleNode.prefix_scan("no:match:")
    end
  end

  describe "put_many/1" do
    test "stores multiple entries" do
      assert {:ok, _results} =
               SingleNode.put_many([
                 {"multi:1", "v1"},
                 {"multi:2", "v2"},
                 {"multi:3", "v3", 3600}
               ])

      assert {:ok, "v1"} = SingleNode.get("multi:1")
      assert {:ok, "v2"} = SingleNode.get("multi:2")
      assert {:ok, "v3"} = SingleNode.get("multi:3")
    end
  end
end
