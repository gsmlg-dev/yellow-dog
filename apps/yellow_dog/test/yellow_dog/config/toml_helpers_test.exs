defmodule YellowDog.Config.TomlHelpersTest do
  use ExUnit.Case, async: true

  alias YellowDog.Config.TomlHelpers

  describe "get_value/3" do
    test "finds value by atom key" do
      assert TomlHelpers.get_value(%{name: "test"}, [:name, "name"]) == "test"
    end

    test "finds value by string key" do
      assert TomlHelpers.get_value(%{"name" => "test"}, [:name, "name"]) == "test"
    end

    test "returns default when no key matches" do
      assert TomlHelpers.get_value(%{}, [:name, "name"], "default") == "default"
    end

    test "returns nil default when no key matches" do
      assert TomlHelpers.get_value(%{other: 1}, [:name, "name"]) == nil
    end

    test "prefers first matching key in key list" do
      # Atom key comes first in list, so it's found first
      assert TomlHelpers.get_value(%{name: "atom_val"}, [:name, "name"]) == "atom_val"
      # String key also works
      assert TomlHelpers.get_value(%{"name" => "str_val"}, [:name, "name"]) == "str_val"
    end

    test "returns false when value is false (not default)" do
      assert TomlHelpers.get_value(%{enabled: false}, [:enabled, "enabled"], true) == false
    end

    test "returns 0 when value is zero (not default)" do
      assert TomlHelpers.get_value(%{count: 0}, [:count, "count"], 100) == 0
    end

    test "returns nil when value is explicitly nil (not default)" do
      assert TomlHelpers.get_value(%{field: nil}, [:field], "default") == nil
    end
  end

  describe "get_integer/3" do
    test "returns integer value directly" do
      assert TomlHelpers.get_integer(%{port: 8080}, [:port, "port"], 0) == 8080
    end

    test "coerces string to integer" do
      assert TomlHelpers.get_integer(%{"port" => "9090"}, [:port, "port"], 0) == 9090
    end

    test "returns default for non-integer/string value" do
      assert TomlHelpers.get_integer(%{port: :invalid}, [:port, "port"], 42) == 42
    end

    test "returns default when key not found" do
      assert TomlHelpers.get_integer(%{}, [:port, "port"], 53) == 53
    end

    test "returns 0 when value is zero (not default)" do
      assert TomlHelpers.get_integer(%{port: 0}, [:port, "port"], 8080) == 0
    end
  end

  describe "get_boolean/3" do
    test "returns boolean true directly" do
      assert TomlHelpers.get_boolean(%{enabled: true}, [:enabled, "enabled"], false) == true
    end

    test "returns boolean false directly" do
      assert TomlHelpers.get_boolean(%{enabled: false}, [:enabled, "enabled"], true) == false
    end

    test "coerces string true" do
      assert TomlHelpers.get_boolean(%{"enabled" => "true"}, [:enabled, "enabled"], false) == true
    end

    test "coerces string false" do
      assert TomlHelpers.get_boolean(%{"enabled" => "false"}, [:enabled, "enabled"], true) ==
               false
    end

    test "returns default for non-boolean value" do
      assert TomlHelpers.get_boolean(%{enabled: "yes"}, [:enabled, "enabled"], true) == true
    end

    test "returns default when key not found" do
      assert TomlHelpers.get_boolean(%{}, [:enabled, "enabled"], false) == false
    end
  end

  describe "get_list/3" do
    test "returns list value" do
      assert TomlHelpers.get_list(%{servers: [1, 2]}, [:servers, "servers"]) == [1, 2]
    end

    test "returns default for non-list value" do
      assert TomlHelpers.get_list(%{servers: "not-a-list"}, [:servers, "servers"], []) == []
    end

    test "returns default when key not found" do
      assert TomlHelpers.get_list(%{}, [:servers, "servers"], [:default]) == [:default]
    end
  end

  describe "get_map/3" do
    test "returns map value" do
      inner = %{a: 1}
      assert TomlHelpers.get_map(%{config: inner}, [:config, "config"], %{}) == inner
    end

    test "returns default for non-map value" do
      assert TomlHelpers.get_map(%{config: "string"}, [:config, "config"], %{x: 1}) == %{x: 1}
    end

    test "returns default when key not found" do
      assert TomlHelpers.get_map(%{}, [:config, "config"], %{}) == %{}
    end
  end

  describe "parse_toml/1" do
    test "parses valid TOML" do
      assert {:ok, %{"key" => "value"}} = TomlHelpers.parse_toml(~s(key = "value"))
    end

    test "returns error for invalid TOML" do
      assert {:error, {:toml_parse_error, _reason}} = TomlHelpers.parse_toml("invalid = = =")
    end
  end

  describe "encode_toml_string/1" do
    test "wraps string in double quotes" do
      assert TomlHelpers.encode_toml_string("hello") == ~s("hello")
    end

    test "escapes inner double quotes" do
      assert TomlHelpers.encode_toml_string(~s(say "hi")) == ~s("say \\"hi\\"")
    end

    test "inspects non-string values" do
      assert TomlHelpers.encode_toml_string(42) == "42"
    end
  end

  describe "atomic_write/2" do
    @tag :tmp_dir
    test "writes content atomically", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.toml")
      assert :ok = TomlHelpers.atomic_write(path, "content")
      assert File.read!(path) == "content"
    end

    @tag :tmp_dir
    test "creates parent directories", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "nested", "dir", "test.toml"])
      assert :ok = TomlHelpers.atomic_write(path, "data")
      assert File.read!(path) == "data"
    end

    @tag :tmp_dir
    test "cleans up temp file on success", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.toml")
      TomlHelpers.atomic_write(path, "data")
      refute File.exists?(path <> ".tmp")
    end
  end

  describe "ensure_directory/1" do
    @tag :tmp_dir
    test "creates parent directory", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "new_dir", "file.toml"])
      assert :ok = TomlHelpers.ensure_directory(path)
      assert File.dir?(Path.join(tmp_dir, "new_dir"))
    end
  end

  describe "maybe_create_backup/2" do
    test "returns :ok when backup is false" do
      assert :ok = TomlHelpers.maybe_create_backup("/any/path", false)
    end

    test "returns :ok when file does not exist" do
      assert :ok = TomlHelpers.maybe_create_backup("/nonexistent/path", true)
    end

    @tag :tmp_dir
    test "creates backup when file exists", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config.toml")
      File.write!(path, "original")

      assert :ok = TomlHelpers.maybe_create_backup(path, true)
      assert File.read!(path <> ".backup") == "original"
    end
  end

  describe "format_datetime/1" do
    test "formats DateTime to ISO 8601" do
      dt = ~U[2025-06-15 12:30:00Z]
      assert TomlHelpers.format_datetime(dt) == "2025-06-15T12:30:00Z"
    end

    test "formats unix timestamp to ISO 8601" do
      unix = 1_718_451_000
      result = TomlHelpers.format_datetime(unix)
      assert String.ends_with?(result, "Z") or String.contains?(result, "+")
      assert {:ok, _, _} = DateTime.from_iso8601(result)
    end

    test "returns current time ISO 8601 for other values" do
      result = TomlHelpers.format_datetime(:unknown)
      assert {:ok, _, _} = DateTime.from_iso8601(result)
    end

    test "returns current time ISO 8601 for nil" do
      result = TomlHelpers.format_datetime(nil)
      assert {:ok, _, _} = DateTime.from_iso8601(result)
    end

    test "returns current time for out-of-range unix timestamp" do
      result = TomlHelpers.format_datetime(999_999_999_999_999)
      assert {:ok, _, _} = DateTime.from_iso8601(result)
    end
  end

  describe "read_toml_file/1" do
    @tag :tmp_dir
    test "reads and parses valid TOML file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.toml")
      File.write!(path, ~s(name = "yellow-dog"\nport = 53))

      assert {:ok, %{"name" => "yellow-dog", "port" => 53}} = TomlHelpers.read_toml_file(path)
    end

    @tag :tmp_dir
    test "returns error for missing file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "missing.toml")
      assert {:error, :enoent} = TomlHelpers.read_toml_file(path)
    end

    @tag :tmp_dir
    test "returns error for invalid TOML content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad.toml")
      File.write!(path, "invalid = = =")

      assert {:error, _} = TomlHelpers.read_toml_file(path)
    end
  end
end
