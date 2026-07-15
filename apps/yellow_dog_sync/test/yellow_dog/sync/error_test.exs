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
end
