defmodule YellowDog.Store.SingleNodeTest do
  use ExUnit.Case, async: false

  alias YellowDog.Store.Backend.Ets, as: EtsBackend
  alias YellowDog.Store.ModeDetector
  alias YellowDog.Store.SingleNode

  setup do
    # Ensure table exists (started by ModeDetector in application; may not be
    # running in isolated test runs, so we create it if absent)
    EtsBackend.create_table()

    # Clean up the table before each test
    case :ets.whereis(EtsBackend.table()) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(EtsBackend.table())
    end

    :ok
  end

  describe "single_node?/0 (compatibility shim)" do
    test "returns true when no peers are connected" do
      # In test env there are no connected peers
      assert SingleNode.single_node?()
    end
  end

  describe "put/get/delete (Backend.Ets via SingleNode shim)" do
    test "basic put and get" do
      assert :ok = SingleNode.put("test:key1", %{value: 42})
      assert {:ok, %{value: 42}} = SingleNode.get("test:key1")
    end

    test "get returns not_found for missing key" do
      assert {:error, :not_found} = SingleNode.get("nonexistent")
    end

    test "put overwrites existing key" do
      SingleNode.put("test:overwrite", "original")
      SingleNode.put("test:overwrite", "updated")
      assert {:ok, "updated"} = SingleNode.get("test:overwrite")
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

    test "expected: existing_value succeeds when key matches (CAS on existing value)" do
      SingleNode.put("test:cas-existing", "old_value")

      assert :ok =
               SingleNode.put_if("test:cas-existing", "new_value", expected: "old_value")

      assert {:ok, "new_value"} = SingleNode.get("test:cas-existing")
    end

    test "expected: stale_value fails when key has changed" do
      SingleNode.put("test:cas-stale", "current_value")

      assert {:error, :condition_failed} =
               SingleNode.put_if("test:cas-stale", "new_value", expected: "stale_value")

      assert {:ok, "current_value"} = SingleNode.get("test:cas-stale")
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

    test "condition function called with nil when key is absent" do
      result =
        SingleNode.put_if("test:cas-nil", "value",
          condition: fn
            nil -> false
            _ -> true
          end
        )

      assert {:error, :condition_failed} = result
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

    test "condition function returning {:update, value, ttl_opts} updates with TTL override" do
      SingleNode.put("test:cas6", %{state: :offered})

      assert :ok =
               SingleNode.put_if("test:cas6", nil,
                 condition: fn %{state: :offered} = lease ->
                   {:update, %{lease | state: :bound}, [ttl: 3600]}
                 end
               )

      assert {:ok, %{state: :bound}} = SingleNode.get("test:cas6")
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

    test "expired entries remain in ETS after prefix_scan (lazy for scans)" do
      SingleNode.put("scan:stale:1", "v1", ttl: 0)

      # prefix_scan skips expired entries but doesn't delete them
      assert {:ok, []} = SingleNode.prefix_scan("scan:stale:")

      # The entry is still in the raw ETS table
      raw = :ets.lookup(EtsBackend.table(), "scan:stale:1")
      assert length(raw) == 1
    end

    test "limit option restricts number of results" do
      for i <- 1..5, do: SingleNode.put("limit:#{i}", "v#{i}")

      assert {:ok, entries} = SingleNode.prefix_scan("limit:", limit: 3)
      assert length(entries) == 3
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

    test "empty list returns ok with empty map" do
      assert {:ok, result} = SingleNode.put_many([])
      assert result == %{}
    end
  end

  describe "ModeDetector GenServer" do
    test "init detects single-node mode with no peers" do
      # Application starts ModeDetector; verify it reports single-node
      assert ModeDetector.single_node?()
      assert ModeDetector.mode() == :single_node
    end

    test "mode transitions on handle_info(:check_peers)" do
      # Simulate a peer-check cycle while still in single-node
      pid = GenServer.whereis(ModeDetector)

      # In test env there are no peers, so mode stays :single_node
      if pid do
        send(pid, :check_peers)
        Process.sleep(10)
        assert ModeDetector.mode() == :single_node
      else
        # ModeDetector not running in this test env — use start_supervised!
        {:ok, _pid} = start_supervised(ModeDetector)
        assert ModeDetector.single_node?()
      end
    end

    test "sweep_expired handle_info does not crash" do
      pid = GenServer.whereis(ModeDetector)

      if pid do
        send(pid, :sweep_expired)
        Process.sleep(10)
        # If it's still alive, the sweep succeeded
        assert Process.alive?(pid)
      else
        {:ok, pid} = start_supervised(ModeDetector)
        send(pid, :sweep_expired)
        Process.sleep(10)
        assert Process.alive?(pid)
      end
    end
  end

  describe "Backend routing via Store facade" do
    test "backend_put routes to ETS in single-node mode" do
      assert :ok = YellowDog.Store.backend_put("route:test1", "val")
      assert {:ok, "val"} = YellowDog.Store.backend_get("route:test1")
    end

    test "backend_delete routes to ETS in single-node mode" do
      YellowDog.Store.backend_put("route:del", "val")
      assert :ok = YellowDog.Store.backend_delete("route:del")
      assert {:error, :not_found} = YellowDog.Store.backend_get("route:del")
    end

    test "backend_put_if routes to ETS in single-node mode" do
      assert :ok = YellowDog.Store.backend_put_if("route:cas", "val", expected: nil)
      assert {:ok, "val"} = YellowDog.Store.backend_get("route:cas")
    end

    test "backend_prefix_scan routes to ETS in single-node mode" do
      YellowDog.Store.backend_put("route:scan:a", "v1")
      YellowDog.Store.backend_put("route:scan:b", "v2")
      assert {:ok, entries} = YellowDog.Store.backend_prefix_scan("route:scan:")
      assert length(entries) == 2
    end

    test "backend_put_many routes to ETS in single-node mode" do
      assert {:ok, _} =
               YellowDog.Store.backend_put_many([{"route:many:1", "v1"}, {"route:many:2", "v2"}])

      assert {:ok, "v1"} = YellowDog.Store.backend_get("route:many:1")
    end
  end
end
