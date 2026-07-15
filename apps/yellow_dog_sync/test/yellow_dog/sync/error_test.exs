defmodule YellowDog.Sync.ErrorTest do
  use ExUnit.Case, async: true

  alias YellowDog.Sync.Error

  @codes [
    :not_connected,
    :not_found,
    :invalid,
    :conflict,
    :unsupported,
    :timeout,
    :apply_failed,
    :rollback_failed,
    :internal
  ]

  test "constructs every accepted stable error code" do
    for code <- @codes do
      assert %Error{code: ^code, message: "failed", details: %{field: "target_id"}} =
               Error.new(code, "failed", %{field: "target_id"})
    end
  end

  test "rejects unknown error codes" do
    assert {:error, %Error{code: :invalid}} = Error.new(:unknown, "failed", %{})
  end

  test "decodes only known wire error codes without creating atoms" do
    assert {:ok, %Error{code: :not_found, message: "missing", details: %{}}} =
             Error.from_wire(%{"code" => "not_found", "message" => "missing", "details" => %{}})

    unknown_code = "unknown_" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:error, %Error{code: :invalid}} = Error.from_wire(%{"code" => unknown_code})
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_code) end
  end

  test "encodes stable wire error codes" do
    error = Error.new(:conflict, "stale revision", %{field: "expected_revision"})

    assert %{
             "code" => "conflict",
             "message" => "stale revision",
             "details" => %{field: "expected_revision"}
           } = Error.to_wire(error)
  end

  test "decodes error details at every approved nested boundary" do
    nested_map = Map.new(1..100, fn index -> {Integer.to_string(index), "value"} end)
    nested_list = List.duplicate("value", 1_000)

    details = %{
      "map" => nested_map,
      "list" => nested_list,
      "depth" => nested_details(7),
      "message" => String.duplicate("m", 1_024),
      "scalars" => [nil, true, false, 42, 3.14]
    }

    assert {:ok, %Error{details: ^details}} =
             Error.from_wire(%{
               "code" => "invalid",
               "message" => "invalid input",
               "details" => details
             })
  end

  test "rejects error details beyond nested map list string and depth limits" do
    oversized_map = Map.new(1..101, fn index -> {Integer.to_string(index), "value"} end)
    oversized_list = List.duplicate("value", 1_001)
    oversized_string = String.duplicate("v", 1_025)
    oversized_key = String.duplicate("k", 1_025)

    for details <- [
          %{"nested" => oversized_map},
          %{"nested" => oversized_list},
          %{"nested" => %{"value" => oversized_string}},
          %{oversized_key => "value"},
          %{"nested" => %{"value" => <<255>>}},
          %{<<255>> => "value"},
          %{"nested" => nested_details(8)}
        ] do
      assert {:error, %Error{code: :invalid}} =
               Error.from_wire(%{
                 "code" => "invalid",
                 "message" => "invalid input",
                 "details" => details
               })
    end
  end

  test "rejects error details outside JSON-safe values" do
    for details <- [
          %{field: "atom key"},
          %{"value" => :atom},
          %{"value" => {"tuple"}},
          %{"value" => self()}
        ] do
      assert {:error, %Error{code: :invalid}} =
               Error.from_wire(%{
                 "code" => "invalid",
                 "message" => "invalid input",
                 "details" => details
               })
    end
  end

  defp nested_details(1), do: %{"value" => "ok"}
  defp nested_details(depth), do: %{"nested" => nested_details(depth - 1)}
end
