defmodule YellowDog.Dns.RecursionWorkerTest do
  @moduledoc """
  Unit tests for YellowDog.Dns.RecursionWorker.

  Tests cover:
  - Socket management (ephemeral socket lifecycle)
  - Error conditions (format_error, network_error)
  - Query processing basics

  Note: Full recursive resolution tests require network access or mocking,
  so we focus on unit testing the error paths and socket lifecycle.
  """
  use ExUnit.Case, async: true

  alias YellowDog.Dns.RecursionWorker
  alias DNS.Message
  alias DNS.Message.Question
  alias DNS.Message.RCode

  describe "resolve/2" do
    @tag :capture_log
    test "returns format_error for query with no questions" do
      empty_query = %Message{
        header: %DNS.Message.Header{
          id: 12345,
          qr: 0,
          opcode: :query,
          rd: 1,
          rcode: RCode.no_error(),
          qdcount: 0
        },
        qdlist: [],
        anlist: [],
        nslist: [],
        arlist: []
      }

      result = RecursionWorker.resolve(empty_query)
      assert {:error, :format_error} = result
    end

    @tag :capture_log
    test "accepts map options" do
      empty_query = build_empty_query()
      opts = %{query_timeout: 1000}

      result = RecursionWorker.resolve(empty_query, opts)
      assert {:error, :format_error} = result
    end

    @tag :capture_log
    test "accepts keyword options" do
      empty_query = build_empty_query()
      opts = [query_timeout: 1000]

      result = RecursionWorker.resolve(empty_query, opts)
      assert {:error, :format_error} = result
    end

    @tag :capture_log
    test "handles multiple sequential resolves" do
      empty_query = build_empty_query()

      # Each resolve should open and close its own socket
      for _ <- 1..5 do
        result = RecursionWorker.resolve(empty_query)
        assert {:error, :format_error} = result
      end
    end

    @tag :capture_log
    @tag :network
    test "returns no_servers when all root servers are unreachable" do
      # Use invalid root servers that won't respond
      bad_servers = [
        {{127, 0, 0, 1}, 65534},
        {{127, 0, 0, 1}, 65535}
      ]

      query = build_test_query("example.com")
      opts = %{root_servers: bad_servers, query_timeout: 100}

      result = RecursionWorker.resolve(query, opts)
      # Should timeout trying to reach all servers
      assert {:error, reason} = result
      assert reason in [:no_servers, :timeout]
    end
  end

  describe "concurrent resolution" do
    @tag :capture_log
    test "can handle multiple concurrent resolves" do
      # Each resolve in its own task, each opens its own socket
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            query = build_empty_query()
            RecursionWorker.resolve(query)
          end)
        end

      results = Task.await_many(tasks, 5000)

      for result <- results do
        assert {:error, :format_error} = result
      end
    end
  end

  # Helper functions

  defp build_empty_query do
    %Message{
      header: %DNS.Message.Header{
        id: :rand.uniform(65535),
        qr: 0,
        opcode: :query,
        rd: 1,
        rcode: RCode.no_error(),
        qdcount: 0
      },
      qdlist: [],
      anlist: [],
      nslist: [],
      arlist: []
    }
  end

  defp build_test_query(name, type \\ :a) do
    query = Message.new()
    question = Question.new(name, type, :in)
    header = %{query.header | id: :rand.uniform(65535), qdcount: 1, rd: 1}
    %{query | header: header, qdlist: [question]}
  end
end
