defmodule YellowDog.Data.Persistence.TomlTest do
  @moduledoc """
  Tests for the TOML persistence strategy.
  """
  use ExUnit.Case, async: true

  alias YellowDog.Data.Persistence.Toml

  defp tmp_path do
    Path.join(System.tmp_dir!(), "toml_persist_#{:erlang.unique_integer([:positive])}.toml")
  end

  describe "load/1" do
    test "loads records from TOML array tables" do
      path = tmp_path()

      content = """
      [[records]]
      id = "acl1"
      name = "internal"
      entries = ["10.0.0.0/8"]

      [[records]]
      id = "acl2"
      name = "external"
      entries = ["0.0.0.0/0"]
      """

      File.write!(path, content)

      opts = %{path: path, key_field: :id, section: "records"}
      assert {:ok, pairs} = Toml.load(opts)
      assert length(pairs) == 2

      {key1, record1} = Enum.find(pairs, fn {k, _} -> k == "acl1" end)
      assert key1 == "acl1"
      assert record1["name"] == "internal"
      assert record1["entries"] == ["10.0.0.0/8"]

      File.rm(path)
    end

    test "returns empty list for missing file" do
      opts = %{path: "/tmp/definitely_missing_#{System.unique_integer()}.toml", key_field: :id}
      assert {:ok, []} = Toml.load(opts)
    end

    test "returns error for invalid TOML" do
      path = tmp_path()
      File.write!(path, "this is not valid [[[ toml")

      opts = %{path: path, key_field: :id}
      assert {:error, _} = Toml.load(opts)

      File.rm(path)
    end

    test "uses custom deserializer" do
      path = tmp_path()

      content = """
      [[records]]
      id = "dev1"
      mac = "aa:bb:cc:dd:ee:ff"
      """

      File.write!(path, content)

      deserialize = fn item ->
        %{id: item["id"], mac: String.upcase(item["mac"])}
      end

      opts = %{path: path, key_field: :id, deserialize: deserialize}
      assert {:ok, [{_key, record}]} = Toml.load(opts)
      assert record.mac == "AA:BB:CC:DD:EE:FF"

      File.rm(path)
    end

    test "uses default section name 'records'" do
      path = tmp_path()

      content = """
      [[records]]
      id = "item1"
      """

      File.write!(path, content)

      opts = %{path: path, key_field: :id}
      assert {:ok, [{_, _}]} = Toml.load(opts)

      File.rm(path)
    end

    test "supports custom section name" do
      path = tmp_path()

      content = """
      [[devices]]
      id = "dev1"
      name = "switch"
      """

      File.write!(path, content)

      opts = %{path: path, key_field: :id, section: "devices"}
      assert {:ok, [{_, record}]} = Toml.load(opts)
      assert record["name"] == "switch"

      File.rm(path)
    end
  end

  describe "save/2" do
    test "writes records as TOML array tables" do
      path = tmp_path()

      pairs = [
        {"acl1", %{"id" => "acl1", "name" => "internal"}},
        {"acl2", %{"id" => "acl2", "name" => "external"}}
      ]

      opts = %{path: path, key_field: :id, section: "records"}
      assert :ok = Toml.save(pairs, opts)

      {:ok, content} = File.read(path)
      assert content =~ "[[records]]"
      assert content =~ "internal"
      assert content =~ "external"

      File.rm(path)
    end

    test "creates parent directory if needed" do
      dir = Path.join(System.tmp_dir!(), "nested_#{:erlang.unique_integer([:positive])}")
      path = Path.join(dir, "data.toml")

      pairs = [{"k", %{"id" => "k"}}]
      opts = %{path: path, key_field: :id}
      assert :ok = Toml.save(pairs, opts)
      assert File.exists?(path)

      File.rm_rf!(dir)
    end

    test "uses custom serializer" do
      path = tmp_path()

      serialize = fn record ->
        %{"id" => record.id, "name" => String.downcase(record.name)}
      end

      pairs = [{"k1", %{id: "k1", name: "UPPER"}}]
      opts = %{path: path, key_field: :id, serialize: serialize}
      assert :ok = Toml.save(pairs, opts)

      {:ok, content} = File.read(path)
      assert content =~ "upper"

      File.rm(path)
    end

    test "converts atom keys to strings" do
      path = tmp_path()

      pairs = [{"k1", %{id: "k1", name: "test", active: true}}]
      opts = %{path: path, key_field: :id}
      assert :ok = Toml.save(pairs, opts)

      {:ok, content} = File.read(path)
      assert content =~ "name"
      assert content =~ "active"

      File.rm(path)
    end

    test "empty pairs writes empty file" do
      path = tmp_path()

      opts = %{path: path, key_field: :id}
      assert :ok = Toml.save([], opts)
      assert File.exists?(path)

      File.rm(path)
    end
  end

  describe "round-trip" do
    test "save then load preserves data" do
      path = tmp_path()

      original = [
        {"r1", %{"id" => "r1", "name" => "alpha", "count" => 42}},
        {"r2", %{"id" => "r2", "name" => "beta", "count" => 7}}
      ]

      opts = %{path: path, key_field: :id, section: "records"}
      assert :ok = Toml.save(original, opts)
      assert {:ok, loaded} = Toml.load(opts)

      assert length(loaded) == 2

      loaded_map = Map.new(loaded)
      assert loaded_map["r1"]["name"] == "alpha"
      assert loaded_map["r1"]["count"] == 42
      assert loaded_map["r2"]["name"] == "beta"

      File.rm(path)
    end
  end
end
