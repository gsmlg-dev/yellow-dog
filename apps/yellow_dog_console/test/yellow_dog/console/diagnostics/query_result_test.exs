defmodule YellowDog.Console.Diagnostics.QueryResultTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.Console.Diagnostics.QueryResult.

  Tests cover:
  - Struct creation and defaults
  - Factory functions (new, success, error, timeout, multicast_success)
  - Auto-generated IDs and timestamps
  - Status handling
  """
  use ExUnit.Case, async: true

  alias YellowDog.Console.Diagnostics.QueryResult

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(QueryResult)
    end

    test "defines t() type" do
      Code.ensure_loaded!(QueryResult)
      # The struct should exist
      assert %QueryResult{} == struct(QueryResult)
    end

    test "exports new/0" do
      Code.ensure_loaded!(QueryResult)
      assert Kernel.function_exported?(QueryResult, :new, 0)
    end

    test "exports new/1" do
      Code.ensure_loaded!(QueryResult)
      assert Kernel.function_exported?(QueryResult, :new, 1)
    end

    test "exports success/6" do
      Code.ensure_loaded!(QueryResult)
      assert Kernel.function_exported?(QueryResult, :success, 6)
    end

    test "exports error/4" do
      Code.ensure_loaded!(QueryResult)
      assert Kernel.function_exported?(QueryResult, :error, 4)
    end

    test "exports error/5" do
      Code.ensure_loaded!(QueryResult)
      assert Kernel.function_exported?(QueryResult, :error, 5)
    end

    test "exports timeout/4" do
      Code.ensure_loaded!(QueryResult)
      assert Kernel.function_exported?(QueryResult, :timeout, 4)
    end

    test "exports multicast_success/5" do
      Code.ensure_loaded!(QueryResult)
      assert Kernel.function_exported?(QueryResult, :multicast_success, 5)
    end
  end

  describe "new/0 and new/1" do
    test "creates struct with defaults" do
      result = QueryResult.new()

      assert %QueryResult{} = result
      assert is_binary(result.id)
      assert byte_size(result.id) == 16
      assert %DateTime{} = result.timestamp
      assert result.params == %{}
      assert result.request_binary == <<>>
      assert result.request_struct == nil
      assert result.response_binary == nil
      assert result.response_struct == nil
      assert result.sources == []
      assert result.latency_ms == 0
      assert result.status == :success
      assert result.error == nil
    end

    test "generates unique IDs" do
      result1 = QueryResult.new()
      result2 = QueryResult.new()

      refute result1.id == result2.id
    end

    test "sets current timestamp" do
      before = DateTime.utc_now()
      result = QueryResult.new()
      after_time = DateTime.utc_now()

      assert DateTime.compare(result.timestamp, before) in [:gt, :eq]
      assert DateTime.compare(result.timestamp, after_time) in [:lt, :eq]
    end

    test "accepts custom attributes" do
      params = %{server: "127.0.0.1", port: 53}
      result = QueryResult.new(%{params: params, latency_ms: 42})

      assert result.params == params
      assert result.latency_ms == 42
    end

    test "overrides default status" do
      result = QueryResult.new(%{status: :error})

      assert result.status == :error
    end
  end

  describe "success/6" do
    test "creates success result with all fields" do
      params = %{query: "example.com", type: :A}
      request_struct = %{question: "example.com"}
      request_binary = <<0, 1, 2, 3>>
      response_struct = %{answer: "1.2.3.4"}
      response_binary = <<4, 5, 6, 7>>
      latency_ms = 25

      result =
        QueryResult.success(
          params,
          request_struct,
          request_binary,
          response_struct,
          response_binary,
          latency_ms
        )

      assert %QueryResult{} = result
      assert result.status == :success
      assert result.params == params
      assert result.request_struct == request_struct
      assert result.request_binary == request_binary
      assert result.response_struct == response_struct
      assert result.response_binary == response_binary
      assert result.latency_ms == latency_ms
      assert result.error == nil
    end

    test "auto-generates ID and timestamp" do
      result =
        QueryResult.success(
          %{},
          nil,
          <<>>,
          nil,
          <<>>,
          0
        )

      assert is_binary(result.id)
      assert %DateTime{} = result.timestamp
    end
  end

  describe "error/4 and error/5" do
    test "creates error result with default latency" do
      params = %{query: "example.com"}
      request_struct = %{question: "example.com"}
      request_binary = <<0, 1, 2, 3>>
      error_message = "Connection refused"

      result = QueryResult.error(params, request_struct, request_binary, error_message)

      assert %QueryResult{} = result
      assert result.status == :error
      assert result.error == error_message
      assert result.latency_ms == 0
      assert result.params == params
      assert result.request_struct == request_struct
      assert result.request_binary == request_binary
    end

    test "creates error result with custom latency" do
      result = QueryResult.error(%{}, nil, <<>>, "Timeout", 5000)

      assert result.status == :error
      assert result.error == "Timeout"
      assert result.latency_ms == 5000
    end

    test "handles nil request_struct" do
      result = QueryResult.error(%{}, nil, <<>>, "Parse error")

      assert result.request_struct == nil
      assert result.status == :error
    end
  end

  describe "timeout/4" do
    test "creates timeout result" do
      params = %{query: "slow.example.com"}
      request_struct = %{question: "slow.example.com"}
      request_binary = <<0, 1, 2, 3>>
      latency_ms = 5000

      result = QueryResult.timeout(params, request_struct, request_binary, latency_ms)

      assert %QueryResult{} = result
      assert result.status == :timeout
      assert result.error == "Query timed out"
      assert result.latency_ms == latency_ms
      assert result.params == params
      assert result.request_struct == request_struct
      assert result.request_binary == request_binary
    end

    test "handles nil request_struct" do
      result = QueryResult.timeout(%{}, nil, <<>>, 3000)

      assert result.request_struct == nil
      assert result.status == :timeout
    end
  end

  describe "multicast_success/5" do
    test "creates multicast success result with sources" do
      params = %{query: "_http._tcp.local", type: :PTR}
      request_struct = %{question: "_http._tcp.local"}
      request_binary = <<0, 1, 2, 3>>

      sources = [
        %{address: "192.168.1.10", response: %{answer: "service1"}},
        %{address: "192.168.1.20", response: %{answer: "service2"}}
      ]

      latency_ms = 100

      result =
        QueryResult.multicast_success(
          params,
          request_struct,
          request_binary,
          sources,
          latency_ms
        )

      assert %QueryResult{} = result
      assert result.status == :success
      assert result.sources == sources
      assert length(result.sources) == 2
      assert result.latency_ms == latency_ms
      assert result.params == params
      assert result.request_struct == request_struct
      assert result.request_binary == request_binary
    end

    test "handles empty sources list" do
      result = QueryResult.multicast_success(%{}, nil, <<>>, [], 50)

      assert result.sources == []
      assert result.status == :success
    end
  end

  describe "struct fields" do
    test "has all expected fields" do
      result = %QueryResult{}

      assert Map.has_key?(result, :id)
      assert Map.has_key?(result, :timestamp)
      assert Map.has_key?(result, :params)
      assert Map.has_key?(result, :request_binary)
      assert Map.has_key?(result, :request_struct)
      assert Map.has_key?(result, :response_binary)
      assert Map.has_key?(result, :response_struct)
      assert Map.has_key?(result, :sources)
      assert Map.has_key?(result, :latency_ms)
      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :error)
    end
  end

  describe "ID generation" do
    test "generates 16 character hex string" do
      result = QueryResult.new()

      assert String.length(result.id) == 16
      assert String.match?(result.id, ~r/^[0-9a-f]+$/)
    end

    test "IDs are cryptographically random" do
      ids =
        for _ <- 1..100 do
          QueryResult.new().id
        end

      # All IDs should be unique
      assert length(Enum.uniq(ids)) == 100
    end
  end
end
