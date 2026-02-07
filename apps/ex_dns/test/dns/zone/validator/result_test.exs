defmodule DNS.Zone.Validator.ResultTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Zone.Validator.Result module.

  Tests cover:
  - Module structure and exports
  - new/0 - result creation
  - add_error/4 - adding errors
  - add_warning/4 - adding warnings
  - valid?/1 - validity check
  - errors/1 - error retrieval
  - warnings/1 - warning retrieval
  - to_tuple/1 - tuple conversion
  - merge/2 - result merging
  """
  use ExUnit.Case, async: true

  alias DNS.Zone.Validator.Result

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Result)
    end

    test "exports new/0" do
      Code.ensure_loaded!(Result)
      assert Kernel.function_exported?(Result, :new, 0)
    end

    test "exports add_error/3" do
      Code.ensure_loaded!(Result)
      assert Kernel.function_exported?(Result, :add_error, 3)
    end

    test "exports add_error/4" do
      Code.ensure_loaded!(Result)
      assert Kernel.function_exported?(Result, :add_error, 4)
    end

    test "exports add_warning/3" do
      Code.ensure_loaded!(Result)
      assert Kernel.function_exported?(Result, :add_warning, 3)
    end

    test "exports add_warning/4" do
      Code.ensure_loaded!(Result)
      assert Kernel.function_exported?(Result, :add_warning, 4)
    end

    test "exports valid?/1" do
      Code.ensure_loaded!(Result)
      assert Kernel.function_exported?(Result, :valid?, 1)
    end

    test "exports errors/1" do
      Code.ensure_loaded!(Result)
      assert Kernel.function_exported?(Result, :errors, 1)
    end

    test "exports warnings/1" do
      Code.ensure_loaded!(Result)
      assert Kernel.function_exported?(Result, :warnings, 1)
    end

    test "exports to_tuple/1" do
      Code.ensure_loaded!(Result)
      assert Kernel.function_exported?(Result, :to_tuple, 1)
    end

    test "exports merge/2" do
      Code.ensure_loaded!(Result)
      assert Kernel.function_exported?(Result, :merge, 2)
    end
  end

  describe "struct" do
    test "has errors field defaulting to empty list" do
      result = %Result{}
      assert result.errors == []
    end

    test "has warnings field defaulting to empty list" do
      result = %Result{}
      assert result.warnings == []
    end

    test "has valid? field defaulting to true" do
      result = %Result{}
      assert result.valid? == true
    end
  end

  describe "new/0" do
    test "returns a Result struct" do
      result = Result.new()
      assert %Result{} = result
    end

    test "returns empty errors list" do
      result = Result.new()
      assert result.errors == []
    end

    test "returns empty warnings list" do
      result = Result.new()
      assert result.warnings == []
    end

    test "returns valid? = true" do
      result = Result.new()
      assert result.valid? == true
    end
  end

  describe "add_error/3" do
    test "adds error to result" do
      result =
        Result.new()
        |> Result.add_error(:missing_soa, "Zone must have SOA")

      assert length(result.errors) == 1
    end

    test "sets valid? to false" do
      result =
        Result.new()
        |> Result.add_error(:missing_soa, "Zone must have SOA")

      assert result.valid? == false
    end

    test "error contains code and message" do
      result =
        Result.new()
        |> Result.add_error(:missing_soa, "Zone must have SOA")

      [error] = result.errors
      assert error.code == :missing_soa
      assert error.message == "Zone must have SOA"
    end

    test "error has nil field and name by default" do
      result =
        Result.new()
        |> Result.add_error(:missing_soa, "Zone must have SOA")

      [error] = result.errors
      assert error.field == nil
      assert error.name == nil
    end
  end

  describe "add_error/4 with options" do
    test "adds field to error" do
      result =
        Result.new()
        |> Result.add_error(:invalid_ttl, "TTL must be positive", field: :ttl)

      [error] = result.errors
      assert error.field == :ttl
    end

    test "adds name to error" do
      result =
        Result.new()
        |> Result.add_error(:duplicate_record, "Duplicate A record", name: "example.com.")

      [error] = result.errors
      assert error.name == "example.com."
    end

    test "adds both field and name" do
      result =
        Result.new()
        |> Result.add_error(:invalid_value, "Invalid value", field: :data, name: "test.com.")

      [error] = result.errors
      assert error.field == :data
      assert error.name == "test.com."
    end
  end

  describe "multiple errors" do
    test "accumulates multiple errors" do
      result =
        Result.new()
        |> Result.add_error(:error1, "First error")
        |> Result.add_error(:error2, "Second error")
        |> Result.add_error(:error3, "Third error")

      assert length(result.errors) == 3
    end

    test "remains invalid after multiple errors" do
      result =
        Result.new()
        |> Result.add_error(:error1, "First error")
        |> Result.add_error(:error2, "Second error")

      assert result.valid? == false
    end
  end

  describe "add_warning/3" do
    test "adds warning to result" do
      result =
        Result.new()
        |> Result.add_warning(:single_ns, "Only 1 NS record")

      assert length(result.warnings) == 1
    end

    test "does NOT set valid? to false" do
      result =
        Result.new()
        |> Result.add_warning(:single_ns, "Only 1 NS record")

      assert result.valid? == true
    end

    test "warning contains code and message" do
      result =
        Result.new()
        |> Result.add_warning(:single_ns, "Only 1 NS record")

      [warning] = result.warnings
      assert warning.code == :single_ns
      assert warning.message == "Only 1 NS record"
    end
  end

  describe "add_warning/4 with options" do
    test "adds field to warning" do
      result =
        Result.new()
        |> Result.add_warning(:low_ttl, "TTL is very low", field: :ttl)

      [warning] = result.warnings
      assert warning.field == :ttl
    end

    test "adds name to warning" do
      result =
        Result.new()
        |> Result.add_warning(:missing_ptr, "No PTR record", name: "1.168.192.in-addr.arpa.")

      [warning] = result.warnings
      assert warning.name == "1.168.192.in-addr.arpa."
    end
  end

  describe "mixed errors and warnings" do
    test "result can have both errors and warnings" do
      result =
        Result.new()
        |> Result.add_error(:missing_soa, "No SOA record")
        |> Result.add_warning(:single_ns, "Only 1 NS record")

      assert length(result.errors) == 1
      assert length(result.warnings) == 1
    end

    test "warnings don't affect validity when errors present" do
      result =
        Result.new()
        |> Result.add_error(:missing_soa, "No SOA record")
        |> Result.add_warning(:single_ns, "Only 1 NS record")

      assert result.valid? == false
    end
  end

  describe "valid?/1" do
    test "returns true for new result" do
      result = Result.new()
      assert Result.valid?(result)
    end

    test "returns false when errors present" do
      result =
        Result.new()
        |> Result.add_error(:missing_soa, "No SOA")

      refute Result.valid?(result)
    end

    test "returns true when only warnings present" do
      result =
        Result.new()
        |> Result.add_warning(:single_ns, "Only 1 NS")

      assert Result.valid?(result)
    end
  end

  describe "errors/1" do
    test "returns empty list for new result" do
      result = Result.new()
      assert Result.errors(result) == []
    end

    test "returns errors in order they were added" do
      result =
        Result.new()
        |> Result.add_error(:first, "First")
        |> Result.add_error(:second, "Second")
        |> Result.add_error(:third, "Third")

      errors = Result.errors(result)
      codes = Enum.map(errors, & &1.code)

      # reversed because add_error prepends, and errors/1 reverses
      assert codes == [:first, :second, :third]
    end
  end

  describe "warnings/1" do
    test "returns empty list for new result" do
      result = Result.new()
      assert Result.warnings(result) == []
    end

    test "returns warnings in order they were added" do
      result =
        Result.new()
        |> Result.add_warning(:first, "First")
        |> Result.add_warning(:second, "Second")

      warnings = Result.warnings(result)
      codes = Enum.map(warnings, & &1.code)

      assert codes == [:first, :second]
    end
  end

  describe "to_tuple/1" do
    test "returns {:ok, result} for valid result" do
      result = Result.new()

      assert {:ok, ^result} = Result.to_tuple(result)
    end

    test "returns {:ok, result} for result with only warnings" do
      result =
        Result.new()
        |> Result.add_warning(:single_ns, "Only 1 NS")

      assert {:ok, ^result} = Result.to_tuple(result)
    end

    test "returns {:error, result} for invalid result" do
      result =
        Result.new()
        |> Result.add_error(:missing_soa, "No SOA")

      assert {:error, ^result} = Result.to_tuple(result)
    end
  end

  describe "merge/2" do
    test "merges two empty results" do
      r1 = Result.new()
      r2 = Result.new()

      merged = Result.merge(r1, r2)

      assert merged.errors == []
      assert merged.warnings == []
      assert merged.valid? == true
    end

    test "merges errors from both results" do
      r1 = Result.new() |> Result.add_error(:error1, "E1")
      r2 = Result.new() |> Result.add_error(:error2, "E2")

      merged = Result.merge(r1, r2)

      # After merge, errors from r2 are prepended to r1
      assert length(merged.errors) == 2
    end

    test "merges warnings from both results" do
      r1 = Result.new() |> Result.add_warning(:warn1, "W1")
      r2 = Result.new() |> Result.add_warning(:warn2, "W2")

      merged = Result.merge(r1, r2)

      assert length(merged.warnings) == 2
    end

    test "merged result is invalid if first is invalid" do
      r1 = Result.new() |> Result.add_error(:error1, "E1")
      r2 = Result.new()

      merged = Result.merge(r1, r2)

      assert merged.valid? == false
    end

    test "merged result is invalid if second is invalid" do
      r1 = Result.new()
      r2 = Result.new() |> Result.add_error(:error2, "E2")

      merged = Result.merge(r1, r2)

      assert merged.valid? == false
    end

    test "merged result is invalid if both are invalid" do
      r1 = Result.new() |> Result.add_error(:error1, "E1")
      r2 = Result.new() |> Result.add_error(:error2, "E2")

      merged = Result.merge(r1, r2)

      assert merged.valid? == false
    end

    test "merged result is valid if both are valid" do
      r1 = Result.new() |> Result.add_warning(:warn1, "W1")
      r2 = Result.new() |> Result.add_warning(:warn2, "W2")

      merged = Result.merge(r1, r2)

      assert merged.valid? == true
    end

    test "merge preserves error details" do
      r1 =
        Result.new()
        |> Result.add_error(:error1, "E1", field: :ttl, name: "a.com.")

      r2 =
        Result.new()
        |> Result.add_error(:error2, "E2", field: :data, name: "b.com.")

      merged = Result.merge(r1, r2)

      errors = merged.errors
      assert length(errors) == 2

      # Check that both errors have their fields preserved
      fields = Enum.map(errors, & &1.field)
      assert :ttl in fields
      assert :data in fields
    end
  end

  describe "chaining operations" do
    test "can chain multiple add_error calls" do
      result =
        Result.new()
        |> Result.add_error(:e1, "Error 1")
        |> Result.add_error(:e2, "Error 2")
        |> Result.add_error(:e3, "Error 3")

      assert length(Result.errors(result)) == 3
      assert result.valid? == false
    end

    test "can chain multiple add_warning calls" do
      result =
        Result.new()
        |> Result.add_warning(:w1, "Warning 1")
        |> Result.add_warning(:w2, "Warning 2")

      assert length(Result.warnings(result)) == 2
      assert result.valid? == true
    end

    test "can chain mixed error and warning calls" do
      result =
        Result.new()
        |> Result.add_warning(:w1, "Warning 1")
        |> Result.add_error(:e1, "Error 1")
        |> Result.add_warning(:w2, "Warning 2")
        |> Result.add_error(:e2, "Error 2")

      assert length(Result.errors(result)) == 2
      assert length(Result.warnings(result)) == 2
      assert result.valid? == false
    end
  end

  describe "edge cases" do
    test "handles empty string message" do
      result =
        Result.new()
        |> Result.add_error(:empty, "")

      [error] = result.errors
      assert error.message == ""
    end

    test "handles long message" do
      long_message = String.duplicate("x", 1000)

      result =
        Result.new()
        |> Result.add_error(:long, long_message)

      [error] = result.errors
      assert error.message == long_message
    end

    test "handles special characters in message" do
      message = "Error with special chars: <>&\"\n\t"

      result =
        Result.new()
        |> Result.add_error(:special, message)

      [error] = result.errors
      assert error.message == message
    end
  end
end
