defmodule YellowDog.ConfigHelpersTest do
  use ExUnit.Case, async: true

  alias YellowDog.ConfigHelpers

  describe "get_value/3" do
    test "gets value by atom key" do
      assert ConfigHelpers.get_value(%{name: "foo"}, :name) == "foo"
    end

    test "falls back to string key" do
      assert ConfigHelpers.get_value(%{"name" => "foo"}, :name) == "foo"
    end

    test "returns default when key missing" do
      assert ConfigHelpers.get_value(%{}, :name, "default") == "default"
    end

    test "returns nil when key missing and no default" do
      assert ConfigHelpers.get_value(%{}, :name) == nil
    end

    test "prefers atom key over string key" do
      map = Map.put(%{name: "atom"}, "name", "string")
      assert ConfigHelpers.get_value(map, :name) == "atom"
    end
  end

  describe "parse_state/1" do
    test "passes through atoms" do
      assert ConfigHelpers.parse_state(:active) == :active
      assert ConfigHelpers.parse_state(:custom) == :custom
    end

    test "parses known string states" do
      assert ConfigHelpers.parse_state("active") == :active
      assert ConfigHelpers.parse_state("offered") == :offered
      assert ConfigHelpers.parse_state("declined") == :declined
      assert ConfigHelpers.parse_state("released") == :released
      assert ConfigHelpers.parse_state("expired") == :expired
    end

    test "defaults to :active for unknown strings" do
      assert ConfigHelpers.parse_state("unknown") == :active
      assert ConfigHelpers.parse_state("") == :active
    end
  end

  describe "parse_datetime/1" do
    test "nil returns current UTC time" do
      assert {:ok, %DateTime{}} = ConfigHelpers.parse_datetime(nil)
    end

    test "passes through DateTime structs" do
      dt = ~U[2024-01-01 00:00:00Z]
      assert ConfigHelpers.parse_datetime(dt) == {:ok, dt}
    end

    test "parses ISO 8601 strings" do
      assert {:ok, %DateTime{year: 2024}} = ConfigHelpers.parse_datetime("2024-01-01T00:00:00Z")
    end

    test "returns error for invalid strings" do
      assert {:error, "Invalid datetime format"} = ConfigHelpers.parse_datetime("not-a-date")
    end

    test "parses unix timestamps" do
      assert {:ok, %DateTime{}} = ConfigHelpers.parse_datetime(1_704_067_200)
    end

    test "returns error for other types" do
      assert {:error, "Invalid datetime"} = ConfigHelpers.parse_datetime([])
    end
  end

  describe "parse_option_code/1" do
    test "passes through integers" do
      assert ConfigHelpers.parse_option_code(42) == 42
    end

    test "parses string integers" do
      assert ConfigHelpers.parse_option_code("42") == 42
    end

    test "returns 0 for invalid strings" do
      assert ConfigHelpers.parse_option_code("abc") == 0
      assert ConfigHelpers.parse_option_code("42abc") == 0
    end

    test "converts other types via to_string" do
      assert ConfigHelpers.parse_option_code(:"42") == 42
    end
  end

  describe "maybe_put/3" do
    test "skips nil values" do
      assert ConfigHelpers.maybe_put(%{}, "key", nil) == %{}
    end

    test "puts non-nil values" do
      assert ConfigHelpers.maybe_put(%{}, "key", "val") == %{"key" => "val"}
    end
  end

  describe "maybe_put_list/3" do
    test "skips empty lists" do
      assert ConfigHelpers.maybe_put_list(%{}, "key", []) == %{}
    end

    test "puts non-empty lists" do
      assert ConfigHelpers.maybe_put_list(%{}, "key", [1]) == %{"key" => [1]}
    end
  end

  describe "maybe_put_map/3" do
    test "skips nil" do
      assert ConfigHelpers.maybe_put_map(%{}, "key", nil) == %{}
    end

    test "skips empty maps" do
      assert ConfigHelpers.maybe_put_map(%{}, "key", %{}) == %{}
    end

    test "puts non-empty maps" do
      assert ConfigHelpers.maybe_put_map(%{}, "key", %{a: 1}) == %{"key" => %{a: 1}}
    end
  end
end
