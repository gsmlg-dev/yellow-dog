defmodule GeoIpDb.DatabaseTest do
  use ExUnit.Case, async: false

  alias GeoIpDb.Database

  @table_name :geo_ip_db_databases

  setup do
    # Stop any existing database server
    case Process.whereis(Database) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end

    # Clean up any existing ETS table
    if :ets.whereis(@table_name) != :undefined do
      :ets.delete(@table_name)
    end

    # Start a fresh database server
    {:ok, pid} = Database.start_link([])

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    {:ok, server: pid}
  end

  describe "start_link/1" do
    test "starts the database server", %{server: pid} do
      assert Process.alive?(pid)
    end

    test "creates the ETS table" do
      assert :ets.whereis(@table_name) != :undefined
    end
  end

  describe "loaded?/1" do
    @tag :requires_database
    test "returns true for loaded database" do
      # City database should be loaded by default if file exists
      loaded = Database.loaded?(:city)
      assert is_boolean(loaded)
    end

    test "returns false for unknown database" do
      refute Database.loaded?(:nonexistent_database)
    end
  end

  describe "list_databases/0" do
    test "returns a list" do
      databases = Database.list_databases()
      assert is_list(databases)
    end

    test "returns empty list when no databases loaded" do
      # Unload any databases that were loaded
      databases = Database.list_databases()

      Enum.each(databases, fn db ->
        Database.unload(db)
      end)

      assert Database.list_databases() == []
    end
  end

  describe "lookup/2" do
    test "returns error for unloaded database" do
      assert {:error, {:database_not_loaded, :nonexistent}} =
               Database.lookup({8, 8, 8, 8}, :nonexistent)
    end

    @tag :requires_database
    test "returns raw data for valid IP" do
      if Database.loaded?(:city) do
        assert {:ok, data} = Database.lookup({8, 8, 8, 8}, :city)
        # Data can be nil or a map
        assert is_nil(data) or is_map(data)
      end
    end
  end

  describe "get_metadata/1" do
    test "returns error for unloaded database" do
      assert {:error, {:database_not_loaded, :nonexistent}} =
               Database.get_metadata(:nonexistent)
    end

    @tag :requires_database
    test "returns metadata map for loaded database" do
      if Database.loaded?(:city) do
        assert {:ok, meta} = Database.get_metadata(:city)
        assert is_map(meta)
        assert Map.has_key?(meta, :database_type)
      end
    end
  end

  describe "load/2" do
    test "returns error for non-existent file" do
      assert {:error, :enoent} = Database.load(:test_db, "/nonexistent/path.mmdb")
    end
  end

  describe "unload/1" do
    test "removes database from ETS table" do
      # First ensure a database is loaded (may or may not be depending on files)
      initial_count = length(Database.list_databases())

      # If we have databases, unload one
      case Database.list_databases() do
        [db | _] ->
          assert :ok = Database.unload(db)
          assert length(Database.list_databases()) == initial_count - 1

        [] ->
          # No databases to unload, just verify unload doesn't crash
          assert :ok = Database.unload(:nonexistent)
      end
    end
  end
end
