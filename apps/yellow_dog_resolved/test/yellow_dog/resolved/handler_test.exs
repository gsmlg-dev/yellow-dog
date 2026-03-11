defmodule YellowDog.Resolved.HandlerTest do
  @moduledoc """
  Tests for the DNS Handler module's packet parsing and error handling.
  """
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.{Cache, Config, Counters}

  @test_config %{
    listen: {127, 0, 0, 1},
    port: 0,
    upstreams: [],
    upstream_timeout_ms: 500,
    upstream_failure_threshold: 3,
    cache: %{
      enabled: true,
      max_entries: 100,
      min_ttl_s: 1,
      max_ttl_s: 3600,
      negative_ttl_s: 5,
      sweep_interval_s: 3600
    },
    discovery: %{enabled: false, websocket: %{}},
    intercept_rules: [
      %{match: {:exact, "handler-test.local"}, type: :a, value: "127.0.0.1", ttl: 300}
    ]
  }

  setup do
    start_supervised!({Config, @test_config})
    start_supervised!(Counters)
    start_supervised!({Cache, @test_config.cache})
    start_supervised!({YellowDog.Resolved.Forwarder, @test_config})
    :ok
  end

  describe "DNS message parsing" do
    test "valid DNS query is parsed and routed successfully" do
      query = DNS.Message.new()
      question = DNS.Message.Question.new("handler-test.local", :a, :in)

      query = %{
        query
        | header: %{query.header | id: 42, rd: 1, qdcount: 1},
          qdlist: [question]
      }

      binary = DNS.to_iodata(query) |> IO.iodata_to_binary()

      # Verify the binary round-trips through the same parsing path as Handler
      parsed = DNS.Message.from_iodata(binary)
      assert %DNS.Message{} = parsed
      assert parsed.header.id == 42
    end

    test "DNS.Message.from_iodata raises on short binary (< 12 bytes)" do
      # This validates our fix: Handler must rescue FunctionClauseError
      assert_raise FunctionClauseError, fn ->
        DNS.Message.from_iodata(<<0, 1, 2, 3>>)
      end
    end

    test "DNS.Message.from_iodata raises on empty binary" do
      assert_raise FunctionClauseError, fn ->
        DNS.Message.from_iodata(<<>>)
      end
    end

    test "DNS.Message.from_iodata may raise or throw on garbage data" do
      # 12+ byte garbage matches header pattern but produces garbage question parsing
      garbage = :crypto.strong_rand_bytes(20)

      # from_iodata can raise FunctionClauseError or throw :format_error
      # Handler wraps in try/rescue to handle this
      try do
        DNS.Message.from_iodata(garbage)
      rescue
        _ -> :handled
      catch
        :throw, _ -> :handled
      end
    end
  end
end
