defmodule YellowDog.Data.Store.EtsTest do
  @moduledoc """
  Unit tests for the ETS adapter, including persistence integration
  and PubSub broadcasting.
  """
  use ExUnit.Case, async: true

  alias YellowDog.Data.{Collection, Store.Ets}

  defp unique_name, do: :"test_ets_#{:erlang.unique_integer([:positive])}"

  defp new_state(opts \\ []) do
    name = Keyword.get_lazy(opts, :name, &unique_name/0)

    collection = %Collection{
      name: name,
      key_field: Keyword.get(opts, :key_field, :id),
      adapter: Ets,
      persistence: Keyword.get(opts, :persistence)
    }

    {:ok, state} = Ets.init(collection, Keyword.get(opts, :init_opts, []))
    state
  end

  describe "init/2" do
    test "creates a named ETS table" do
      name = unique_name()
      state = new_state(name: name)
      assert :ets.info(state.table, :type) == :set
      assert :ets.info(state.table, :named_table) == true
    end

    test "allows custom table name" do
      custom = unique_name()
      collection = %Collection{name: :ignored, key_field: :id, adapter: Ets}
      {:ok, state} = Ets.init(collection, table_name: custom)
      assert state.table == custom
    end

    test "loads data from persistence on init" do
      dir = System.tmp_dir!()
      path = Path.join(dir, "ets_init_test_#{:erlang.unique_integer([:positive])}.toml")

      # Write a TOML file with test data
      content = """
      [[records]]
      id = "item1"
      name = "first"

      [[records]]
      id = "item2"
      name = "second"
      """

      File.write!(path, content)

      state =
        new_state(persistence: %{strategy: :toml, path: path, interval: 0})

      assert {:ok, 2} = Ets.count(state)
      assert {:ok, %{"id" => "item1", "name" => "first"}} = Ets.get(state, "item1")

      File.rm(path)
    end

    test "handles missing persistence file gracefully" do
      state =
        new_state(
          persistence: %{
            strategy: :toml,
            path: "/tmp/nonexistent_#{System.unique_integer()}.toml",
            interval: 0
          }
        )

      assert {:ok, 0} = Ets.count(state)
    end
  end

  describe "CRUD operations" do
    test "put inserts and get retrieves" do
      state = new_state()
      {:ok, state} = Ets.put(state, "k1", %{id: "k1", data: "hello"})
      assert {:ok, %{id: "k1", data: "hello"}} = Ets.get(state, "k1")
    end

    test "put overwrites existing" do
      state = new_state()
      {:ok, state} = Ets.put(state, "k1", %{id: "k1", v: 1})
      {:ok, _state} = Ets.put(state, "k1", %{id: "k1", v: 2})
      assert {:ok, %{id: "k1", v: 2}} = Ets.get(state, "k1")
    end

    test "delete removes record" do
      state = new_state()
      {:ok, state} = Ets.put(state, "k1", %{id: "k1"})
      {:ok, state} = Ets.delete(state, "k1")
      assert {:error, :not_found} = Ets.get(state, "k1")
    end

    test "delete nonexistent is ok" do
      state = new_state()
      assert {:ok, _} = Ets.delete(state, "nope")
    end

    test "exists? checks presence" do
      state = new_state()
      {:ok, state} = Ets.put(state, "k1", %{id: "k1"})
      assert Ets.exists?(state, "k1")
      refute Ets.exists?(state, "k2")
    end
  end

  describe "query operations" do
    setup do
      state = new_state()
      {:ok, state} = Ets.put(state, "a", %{id: "a", type: :x, val: 1})
      {:ok, state} = Ets.put(state, "b", %{id: "b", type: :y, val: 2})
      {:ok, state} = Ets.put(state, "c", %{id: "c", type: :x, val: 3})
      %{state: state}
    end

    test "list returns all records", %{state: state} do
      {:ok, records} = Ets.list(state)
      assert length(records) == 3
    end

    test "list with filter returns matching records", %{state: state} do
      {:ok, records} = Ets.list(state, fn r -> r.type == :x end)
      assert length(records) == 2
    end

    test "count returns total", %{state: state} do
      assert {:ok, 3} = Ets.count(state)
    end

    test "match finds by pattern", %{state: state} do
      {:ok, records} = Ets.match(state, %{type: :x})
      assert length(records) == 2
    end

    test "match with multiple fields narrows results", %{state: state} do
      {:ok, records} = Ets.match(state, %{type: :x, val: 1})
      assert length(records) == 1
      assert hd(records).id == "a"
    end

    test "match with empty pattern returns all", %{state: state} do
      {:ok, records} = Ets.match(state, %{})
      assert length(records) == 3
    end
  end

  describe "update/3" do
    test "applies function to record" do
      state = new_state()
      {:ok, state} = Ets.put(state, "k", %{id: "k", n: 0})
      {:ok, updated, _} = Ets.update(state, "k", fn r -> %{r | n: r.n + 1} end)
      assert updated.n == 1
    end

    test "persists the update in ETS" do
      state = new_state()
      {:ok, state} = Ets.put(state, "k", %{id: "k", n: 0})
      {:ok, _updated, state} = Ets.update(state, "k", fn r -> %{r | n: 5} end)
      assert {:ok, %{n: 5}} = Ets.get(state, "k")
    end

    test "returns error for missing key" do
      state = new_state()
      assert {:error, :not_found} = Ets.update(state, "nope", fn r -> r end)
    end
  end

  describe "clear/1" do
    test "removes all records" do
      state = new_state()
      {:ok, state} = Ets.put(state, "a", %{id: "a"})
      {:ok, state} = Ets.put(state, "b", %{id: "b"})
      {:ok, state} = Ets.clear(state)
      assert {:ok, 0} = Ets.count(state)
    end
  end

  describe "flush/1" do
    test "writes to TOML file when persistence configured" do
      dir = System.tmp_dir!()
      path = Path.join(dir, "ets_flush_test_#{:erlang.unique_integer([:positive])}.toml")

      state =
        new_state(persistence: %{strategy: :toml, path: path, interval: 0})

      {:ok, state} = Ets.put(state, "item1", %{"id" => "item1", "name" => "test"})
      assert :ok = Ets.flush(state)

      assert File.exists?(path)
      {:ok, content} = File.read(path)
      assert content =~ "item1"
      assert content =~ "test"

      File.rm(path)
    end

    test "no-op when persistence not configured" do
      state = new_state()
      assert :ok = Ets.flush(state)
    end
  end

  describe "transaction/2" do
    test "executes function and returns result" do
      state = new_state()
      assert {:ok, :done} = Ets.transaction(state, fn -> :done end)
    end

    test "wraps exceptions in error tuple" do
      state = new_state()
      assert {:error, %RuntimeError{}} = Ets.transaction(state, fn -> raise "boom" end)
    end
  end

  describe "round-trip persistence" do
    test "data survives flush and reload" do
      dir = System.tmp_dir!()
      path = Path.join(dir, "ets_roundtrip_#{:erlang.unique_integer([:positive])}.toml")

      # Create and populate a store
      state =
        new_state(
          name: :"rt_write_#{:erlang.unique_integer([:positive])}",
          persistence: %{strategy: :toml, path: path, interval: 0}
        )

      {:ok, state} = Ets.put(state, "rec1", %{"id" => "rec1", "value" => "hello"})
      {:ok, _state} = Ets.put(state, "rec2", %{"id" => "rec2", "value" => "world"})
      assert :ok = Ets.flush(state)

      # Create a new store that loads from the same file
      state2 =
        new_state(
          name: :"rt_read_#{:erlang.unique_integer([:positive])}",
          persistence: %{strategy: :toml, path: path, interval: 0}
        )

      assert {:ok, 2} = Ets.count(state2)
      assert {:ok, %{"id" => "rec1", "value" => "hello"}} = Ets.get(state2, "rec1")
      assert {:ok, %{"id" => "rec2", "value" => "world"}} = Ets.get(state2, "rec2")

      File.rm(path)
    end
  end
end
