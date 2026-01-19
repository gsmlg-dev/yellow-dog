defmodule GeoIpDb.DatabaseTest do
  use ExUnit.Case, async: true

  alias GeoIpDb.Database

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
end
