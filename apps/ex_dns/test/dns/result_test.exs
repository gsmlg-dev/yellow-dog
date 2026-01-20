defmodule DNS.ResultTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Result module.

  Tests cover:
  - Module structure and exports
  - ok/1 - successful result wrapping
  - error/4 - error result creation
  - map/2 - functor mapping
  - flat_map/2 - monadic chaining
  - catch_throw/1 - exception handling
  - unwrap/2 - value extraction
  - error/1 - error extraction
  - result macro
  """
  use ExUnit.Case, async: true

  alias DNS.Result

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Result)
    end

    test "exports ok/1" do
      Code.ensure_loaded!(Result)
      assert Kernel.function_exported?(Result, :ok, 1)
    end

    test "exports error/4" do
      Code.ensure_loaded!(Result)
      assert Kernel.function_exported?(Result, :error, 4)
    end

    test "exports map/2" do
      Code.ensure_loaded!(Result)
      assert Kernel.function_exported?(Result, :map, 2)
    end

    test "exports flat_map/2" do
      Code.ensure_loaded!(Result)
      assert Kernel.function_exported?(Result, :flat_map, 2)
    end

    test "exports catch_throw/1" do
      Code.ensure_loaded!(Result)
      assert Kernel.function_exported?(Result, :catch_throw, 1)
    end

    test "exports unwrap/2" do
      Code.ensure_loaded!(Result)
      assert Kernel.function_exported?(Result, :unwrap, 2)
    end

    test "exports error/1" do
      Code.ensure_loaded!(Result)
      assert Kernel.function_exported?(Result, :error, 1)
    end
  end

  describe "ok/1" do
    test "wraps value in ok tuple" do
      result = Result.ok(42)
      assert result == {:ok, 42}
    end

    test "wraps string value" do
      result = Result.ok("hello")
      assert result == {:ok, "hello"}
    end

    test "wraps list value" do
      result = Result.ok([1, 2, 3])
      assert result == {:ok, [1, 2, 3]}
    end

    test "wraps map value" do
      result = Result.ok(%{key: "value"})
      assert result == {:ok, %{key: "value"}}
    end

    test "wraps nil value" do
      result = Result.ok(nil)
      assert result == {:ok, nil}
    end

    test "wraps tuple value" do
      result = Result.ok({:nested, :tuple})
      assert result == {:ok, {:nested, :tuple}}
    end
  end

  describe "error/4" do
    test "creates format_error for Domain module" do
      result = Result.error(:format_error, DNS.Message.Domain, "invalid", %{})

      assert {:error, {message, context}} = result
      assert String.contains?(message, "Format Error")
      assert context[:internal_reason] == "invalid"
    end

    test "creates parse_error for Record module" do
      result = Result.error(:parse_error, DNS.Message.Record, "parse failed", %{})

      assert {:error, {message, context}} = result
      assert String.contains?(message, "Parse Error")
      assert context[:internal_reason] == "parse failed"
    end

    test "creates validation_error" do
      result = Result.error(:validation_error, DNS.Message.Record, "validation failed", %{})

      assert {:error, {message, context}} = result
      assert String.contains?(message, "Validation Error")
    end

    test "creates compression_error" do
      result = Result.error(:compression_error, DNS.Message.Domain, "compression loop", %{})

      assert {:error, {message, _context}} = result
      assert String.contains?(message, "Compression Error")
    end

    test "creates security_error" do
      result = Result.error(:security_error, DNS.Message.Domain, "security issue", %{})

      assert {:error, {message, _context}} = result
      assert String.contains?(message, "Security Error")
    end

    test "includes additional context" do
      result = Result.error(:format_error, DNS.Message.Domain, "reason", %{line: 10})

      assert {:error, {_message, context}} = result
      assert context[:line] == 10
      assert context[:internal_reason] == "reason"
    end

    test "defaults to empty context" do
      result = Result.error(:format_error, DNS.Message.Domain, "reason")

      assert {:error, {_message, context}} = result
      assert context[:internal_reason] == "reason"
    end
  end

  describe "map/2" do
    test "maps over ok value" do
      result = {:ok, 5}
      mapped = Result.map(result, &(&1 * 2))

      assert mapped == {:ok, 10}
    end

    test "leaves error unchanged" do
      result = {:error, "some error"}
      mapped = Result.map(result, &(&1 * 2))

      assert mapped == {:error, "some error"}
    end

    test "allows chained mapping" do
      result =
        {:ok, 5}
        |> Result.map(&(&1 + 1))
        |> Result.map(&(&1 * 2))

      assert result == {:ok, 12}
    end

    test "maps string transformation" do
      result = {:ok, "hello"}
      mapped = Result.map(result, &String.upcase/1)

      assert mapped == {:ok, "HELLO"}
    end

    test "maps list transformation" do
      result = {:ok, [1, 2, 3]}
      mapped = Result.map(result, &Enum.sum/1)

      assert mapped == {:ok, 6}
    end
  end

  describe "flat_map/2" do
    test "chains ok results" do
      result = {:ok, 5}
      chained = Result.flat_map(result, fn x -> {:ok, x * 2} end)

      assert chained == {:ok, 10}
    end

    test "chains to error" do
      result = {:ok, 5}
      chained = Result.flat_map(result, fn _ -> {:error, "failed"} end)

      assert chained == {:error, "failed"}
    end

    test "short-circuits on initial error" do
      result = {:error, "initial error"}
      chained = Result.flat_map(result, fn _ -> {:ok, "never reached"} end)

      assert chained == {:error, "initial error"}
    end

    test "allows multiple chained operations" do
      result =
        {:ok, 5}
        |> Result.flat_map(fn x -> {:ok, x + 1} end)
        |> Result.flat_map(fn x -> {:ok, x * 2} end)

      assert result == {:ok, 12}
    end

    test "stops at first error in chain" do
      result =
        {:ok, 5}
        |> Result.flat_map(fn _ -> {:error, "first error"} end)
        |> Result.flat_map(fn _ -> {:ok, "never reached"} end)

      assert result == {:error, "first error"}
    end
  end

  describe "catch_throw/1" do
    test "catches and returns ok for successful function" do
      result = Result.catch_throw(fn -> 42 end)

      assert result == {:ok, 42}
    end

    test "catches runtime error" do
      result = Result.catch_throw(fn -> raise "error" end)

      assert {:error, _} = result
    end

    test "catches throw with error tuple" do
      result = Result.catch_throw(fn -> throw({:format_error, DNS.Message.Domain, "details"}) end)

      assert {:error, _} = result
    end

    test "catches throw with message tuple" do
      result = Result.catch_throw(fn -> throw({"error message", %{details: true}}) end)

      assert {:error, "error message"} = result
    end

    test "catches generic throw" do
      result = Result.catch_throw(fn -> throw(:something_else) end)

      assert {:error, "DNS operation failed"} = result
    end

    test "handles function returning value" do
      result = Result.catch_throw(fn -> %{data: "test"} end)

      assert result == {:ok, %{data: "test"}}
    end
  end

  describe "unwrap/2" do
    test "returns value for ok result" do
      result = {:ok, 42}
      value = Result.unwrap(result, 0)

      assert value == 42
    end

    test "returns default for error result" do
      result = {:error, "some error"}
      value = Result.unwrap(result, 0)

      assert value == 0
    end

    test "uses provided default" do
      result = {:error, "error"}
      value = Result.unwrap(result, "default value")

      assert value == "default value"
    end

    test "returns nil for ok with nil value" do
      result = {:ok, nil}
      value = Result.unwrap(result, "default")

      assert value == nil
    end
  end

  describe "error/1 (arity 1)" do
    test "returns nil for ok result" do
      result = {:ok, 42}
      error = Result.error(result)

      assert error == nil
    end

    test "returns error for error result" do
      error_value = {"error message", %{}}
      result = {:error, error_value}
      error = Result.error(result)

      assert error == error_value
    end

    test "returns string error" do
      result = {:error, "simple error"}
      error = Result.error(result)

      assert error == "simple error"
    end
  end

  describe "__using__ macro" do
    test "provides result macro" do
      defmodule TestModule do
        use DNS.Result

        def test_function do
          result do
            42
          end
        end
      end

      assert TestModule.test_function() == {:ok, 42}
    end
  end

  describe "integration patterns" do
    test "map and flat_map compose correctly" do
      result =
        {:ok, 10}
        |> Result.map(&(&1 + 5))
        |> Result.flat_map(fn x ->
          if x > 10, do: {:ok, x}, else: {:error, "too small"}
        end)

      assert result == {:ok, 15}
    end

    test "error propagates through composition" do
      result =
        {:ok, 5}
        |> Result.map(&(&1 + 5))
        |> Result.flat_map(fn x ->
          if x > 20, do: {:ok, x}, else: {:error, "too small"}
        end)
        |> Result.map(&(&1 * 2))

      assert result == {:error, "too small"}
    end

    test "unwrap with composition" do
      value =
        {:ok, 10}
        |> Result.map(&(&1 * 2))
        |> Result.unwrap(0)

      assert value == 20
    end
  end

  describe "edge cases" do
    test "handles empty list in ok" do
      result = Result.ok([])
      assert result == {:ok, []}
    end

    test "handles empty map in ok" do
      result = Result.ok(%{})
      assert result == {:ok, %{}}
    end

    test "map with identity function" do
      result = {:ok, 42}
      mapped = Result.map(result, & &1)
      assert mapped == {:ok, 42}
    end

    test "flat_map with identity returning ok" do
      result = {:ok, 42}
      chained = Result.flat_map(result, &{:ok, &1})
      assert chained == {:ok, 42}
    end

    test "unwrap with complex default" do
      result = {:error, "error"}
      value = Result.unwrap(result, %{default: true, nested: %{value: 1}})

      assert value == %{default: true, nested: %{value: 1}}
    end
  end
end
