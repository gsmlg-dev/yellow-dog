defmodule YellowDog.Dns.ConnectionProcessTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.Dns.ConnectionProcess.

  Tests cover:
  - Process lifecycle (start_link, connection_closed)
  - Query submission (submit_query, submit_raw_data)
  - Query state machine phases
  - Concurrent query handling
  - Timeout handling
  - Error handling and SERVFAIL responses
  - Stats reporting
  - Handler monitoring
  """
  use ExUnit.Case, async: true

  alias YellowDog.Dns.ConnectionProcess
  alias DNS.Message
  alias DNS.Message.Question
  alias DNS.Message.RCode

  # Test query builder helpers
  defp build_test_query(id, name \\ "example.com", type \\ :a) do
    query = Message.new()
    question = Question.new(name, type, :in)
    # Set ID and question
    header = %{query.header | id: id, qdcount: 1, rd: 1}
    %{query | header: header, qdlist: [question]}
  end

  defp build_test_response(query, answers \\ []) do
    header = %{
      query.header
      | qr: 1,
        aa: 1,
        ra: 1,
        ancount: length(answers),
        rcode: RCode.no_error()
    }

    %Message{
      header: header,
      qdlist: query.qdlist,
      anlist: answers,
      nslist: [],
      arlist: []
    }
  end

  # Helper to extract rcode value for comparison
  defp rcode_value(%RCode{value: <<value::4>>}), do: value
  defp rcode_value(other), do: other

  describe "start_link/1" do
    test "starts connection process with required options" do
      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {127, 0, 0, 1},
          client_port: 12345
        )

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Cleanup
      GenServer.stop(pid)
    end

    test "starts connection process with all options" do
      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {192, 168, 1, 100},
          client_port: 54321,
          socket: nil,
          query_timeout: 10_000
        )

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Cleanup
      GenServer.stop(pid)
    end

    test "starts with IPv6 client address" do
      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {0, 0, 0, 0, 0, 0, 0, 1},
          client_port: 12345
        )

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Cleanup
      GenServer.stop(pid)
    end

    test "fails when handler_pid is missing" do
      # GenServer.start_link raises when init/1 throws an error
      # The error comes from Keyword.fetch!
      Process.flag(:trap_exit, true)

      result =
        ConnectionProcess.start_link(
          client_ip: {127, 0, 0, 1},
          client_port: 12345
        )

      assert {:error, _} = result

      Process.flag(:trap_exit, false)
    end

    test "fails when client_ip is missing" do
      Process.flag(:trap_exit, true)

      result =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_port: 12345
        )

      assert {:error, _} = result

      Process.flag(:trap_exit, false)
    end

    test "fails when client_port is missing" do
      Process.flag(:trap_exit, true)

      result =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {127, 0, 0, 1}
        )

      assert {:error, _} = result

      Process.flag(:trap_exit, false)
    end
  end

  describe "submit_query/2" do
    setup do
      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {127, 0, 0, 1},
          client_port: 12345,
          query_timeout: 100
        )

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, pid: pid}
    end

    test "accepts query and returns :ok", %{pid: pid} do
      query = build_test_query(100)
      assert :ok = ConnectionProcess.submit_query(pid, query)
    end

    test "tracks query in stats", %{pid: pid} do
      query = build_test_query(101)
      :ok = ConnectionProcess.submit_query(pid, query)

      stats = ConnectionProcess.stats(pid)
      assert stats.active_queries == 1
      assert length(stats.queries) == 1
      assert hd(stats.queries).id == 101
    end

    test "accepts multiple concurrent queries", %{pid: pid} do
      for id <- 1..10 do
        query = build_test_query(id)
        :ok = ConnectionProcess.submit_query(pid, query)
      end

      stats = ConnectionProcess.stats(pid)
      assert stats.active_queries == 10
    end

    test "rejects query when max concurrent queries exceeded", %{pid: pid} do
      # Submit 100 queries (max default)
      for id <- 1..100 do
        query = build_test_query(id)
        :ok = ConnectionProcess.submit_query(pid, query)
      end

      # The 101st should fail
      query = build_test_query(101)
      assert {:error, :too_many_queries} = ConnectionProcess.submit_query(pid, query)
    end
  end

  describe "submit_raw_data/2" do
    setup do
      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {127, 0, 0, 1},
          client_port: 12345,
          query_timeout: 100
        )

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, pid: pid}
    end

    test "accepts valid raw DNS data", %{pid: pid} do
      query = build_test_query(200)
      raw_data = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert :ok = ConnectionProcess.submit_raw_data(pid, raw_data)

      stats = ConnectionProcess.stats(pid)
      assert stats.active_queries == 1
    end

    @tag :capture_log
    test "returns error for invalid DNS data", %{pid: pid} do
      invalid_data = <<0, 1, 2, 3, 4, 5>>
      assert {:error, _reason} = ConnectionProcess.submit_raw_data(pid, invalid_data)
    end

    @tag :capture_log
    test "returns error for empty data", %{pid: pid} do
      assert {:error, _reason} = ConnectionProcess.submit_raw_data(pid, <<>>)
    end

    test "returns error for truncated data", %{pid: pid} do
      query = build_test_query(201)
      raw_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      # Truncate to just part of the header
      truncated = binary_part(raw_data, 0, 10)

      assert {:error, _reason} = ConnectionProcess.submit_raw_data(pid, truncated)
    end

    @tag :capture_log
    test "discards DNS response packet (QR=1) — not_a_query (RFC 1035 §4.1.1)", %{pid: pid} do
      # Build a valid DNS response (QR=1) — as if someone sent a response to
      # the query port. The server must reject it without routing it.
      query = build_test_query(202)
      response = build_test_response(query)
      raw_data = DNS.to_iodata(response) |> IO.iodata_to_binary()

      # Parsed message should have QR=1
      parsed = DNS.Message.from_iodata(raw_data)
      assert parsed.header.qr == 1

      assert {:error, :not_a_query} = ConnectionProcess.submit_raw_data(pid, raw_data)

      # No query should have been added to the pipeline
      stats = ConnectionProcess.stats(pid)
      assert stats.active_queries == 0
    end

    @tag :capture_log
    test "returns NOTIMP for non-QUERY opcodes (RFC 1035 §4.1.1)", %{pid: pid} do
      # Build a STATUS query (opcode=2); the server only supports QUERY (opcode=0)
      query = build_test_query(203)
      status_query = %{query | header: %{query.header | opcode: DNS.Message.OpCode.new(2)}}
      raw_data = DNS.to_iodata(status_query) |> IO.iodata_to_binary()

      assert :ok = ConnectionProcess.submit_raw_data(pid, raw_data)

      # Should receive a NOTIMP response (rcode=4) with the original query ID
      assert_receive {:dns_raw_response, 203, response_data}, 500
      parsed = DNS.Message.from_iodata(response_data)
      assert parsed.header.qr == 1
      assert rcode_value(parsed.header.rcode) == 4

      stats = ConnectionProcess.stats(pid)
      assert stats.active_queries == 0
    end
  end

  describe "stats/1" do
    setup do
      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {192, 168, 1, 50},
          client_port: 55555,
          query_timeout: 100
        )

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, pid: pid}
    end

    test "returns connection info", %{pid: pid} do
      stats = ConnectionProcess.stats(pid)

      assert stats.client_ip == "192.168.1.50"
      assert stats.client_port == 55555
      assert stats.active_queries == 0
      assert stats.queries == []
    end

    test "includes query details when queries are active", %{pid: pid} do
      query = build_test_query(300, "test.example.com")
      :ok = ConnectionProcess.submit_query(pid, query)

      stats = ConnectionProcess.stats(pid)

      assert stats.active_queries == 1
      [query_stats] = stats.queries
      assert query_stats.id == 300
      assert query_stats.phase in [:received, :firewall_check, :view_routing]
      assert is_integer(query_stats.elapsed_ms)
      assert query_stats.elapsed_ms >= 0
    end

    test "formats IPv6 address correctly" do
      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {8193, 3512, 0, 0, 0, 0, 0, 1},
          client_port: 12345,
          query_timeout: 100
        )

      stats = ConnectionProcess.stats(pid)

      # IPv6 address formatted
      assert is_binary(stats.client_ip)

      GenServer.stop(pid)
    end
  end

  describe "connection_closed/1" do
    test "stops the connection process" do
      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {127, 0, 0, 1},
          client_port: 12345
        )

      ConnectionProcess.connection_closed(pid)

      # Wait for process to terminate
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "cancels all in-flight queries on close" do
      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {127, 0, 0, 1},
          client_port: 12345,
          query_timeout: 5000
        )

      # Submit some queries
      for id <- 1..5 do
        query = build_test_query(id)
        :ok = ConnectionProcess.submit_query(pid, query)
      end

      stats = ConnectionProcess.stats(pid)
      assert stats.active_queries == 5

      ConnectionProcess.connection_closed(pid)

      # Wait for process to terminate
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end

  describe "handler monitoring" do
    test "connection process terminates when handler dies" do
      # Start a temporary handler process
      handler =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: handler,
          client_ip: {127, 0, 0, 1},
          client_port: 12345
        )

      assert Process.alive?(pid)

      # Kill the handler
      send(handler, :stop)
      Process.sleep(50)

      # Connection process should also terminate
      refute Process.alive?(pid)
    end
  end

  describe "query timeout handling" do
    @tag :capture_log
    test "times out query after configured timeout" do
      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {127, 0, 0, 1},
          client_port: 12345,
          query_timeout: 50
        )

      query = build_test_query(400)
      :ok = ConnectionProcess.submit_query(pid, query)

      # Wait for timeout
      Process.sleep(100)

      # Should receive SERVFAIL response (raw or parsed depending on submission mode)
      assert_receive {:dns_response, 400, response}, 100
      # SERVFAIL has rcode value 2
      assert rcode_value(response.header.rcode) == 2

      # Query should be removed from active queries
      stats = ConnectionProcess.stats(pid)
      assert stats.active_queries == 0

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "logs warning on timeout" do
      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {127, 0, 0, 1},
          client_port: 12345,
          query_timeout: 50
        )

      query = build_test_query(401)
      :ok = ConnectionProcess.submit_query(pid, query)

      # Wait for timeout
      Process.sleep(100)

      # Verify response received
      assert_receive {:dns_response, 401, _response}, 100

      GenServer.stop(pid)
    end
  end

  describe "resolution complete messages" do
    setup do
      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {127, 0, 0, 1},
          client_port: 12345,
          query_timeout: 5000
        )

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, pid: pid}
    end

    test "completes query on resolution_complete message", %{pid: pid} do
      query = build_test_query(500)
      :ok = ConnectionProcess.submit_query(pid, query)

      # Simulate resolution complete
      response = build_test_response(query)
      send(pid, {:resolution_complete, 500, response})

      # Should receive response
      assert_receive {:dns_response, 500, received}, 100
      assert received.header.qr == 1

      # Query should be removed
      Process.sleep(10)
      stats = ConnectionProcess.stats(pid)
      assert stats.active_queries == 0
    end

    test "completes raw query with binary response", %{pid: pid} do
      query = build_test_query(501)
      raw_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      :ok = ConnectionProcess.submit_raw_data(pid, raw_data)

      # Simulate resolution complete
      response = build_test_response(query)
      send(pid, {:resolution_complete, 501, response})

      # Should receive raw binary response
      assert_receive {:dns_raw_response, 501, response_data}, 100
      assert is_binary(response_data) or is_list(response_data)

      # Query should be removed
      Process.sleep(10)
      stats = ConnectionProcess.stats(pid)
      assert stats.active_queries == 0
    end

    test "handles resolution_complete for unknown query_id gracefully", %{pid: pid} do
      # Send resolution complete for non-existent query
      response = build_test_response(build_test_query(999))
      send(pid, {:resolution_complete, 999, response})

      # Process should still be alive
      Process.sleep(10)
      assert Process.alive?(pid)
    end
  end

  describe "resolution error messages" do
    setup do
      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {127, 0, 0, 1},
          client_port: 12345,
          query_timeout: 5000
        )

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, pid: pid}
    end

    test "handles :timeout error with SERVFAIL", %{pid: pid} do
      query = build_test_query(600)
      :ok = ConnectionProcess.submit_query(pid, query)

      send(pid, {:resolution_error, 600, :timeout})

      assert_receive {:dns_response, 600, response}, 100
      # SERVFAIL = 2
      assert rcode_value(response.header.rcode) == 2
    end

    test "handles :refused error with REFUSED", %{pid: pid} do
      query = build_test_query(601)
      :ok = ConnectionProcess.submit_query(pid, query)

      send(pid, {:resolution_error, 601, :refused})

      assert_receive {:dns_response, 601, response}, 100
      # REFUSED = 5
      assert rcode_value(response.header.rcode) == 5
    end

    test "handles :nxdomain error with NXDOMAIN", %{pid: pid} do
      query = build_test_query(602)
      :ok = ConnectionProcess.submit_query(pid, query)

      send(pid, {:resolution_error, 602, :nxdomain})

      assert_receive {:dns_response, 602, response}, 100
      # NXDOMAIN = 3
      assert rcode_value(response.header.rcode) == 3
    end

    test "handles :format_error with FORMERR", %{pid: pid} do
      query = build_test_query(603)
      :ok = ConnectionProcess.submit_query(pid, query)

      send(pid, {:resolution_error, 603, :format_error})

      assert_receive {:dns_response, 603, response}, 100
      # FORMERR = 1
      assert rcode_value(response.header.rcode) == 1
    end

    test "handles unknown error with SERVFAIL", %{pid: pid} do
      query = build_test_query(604)
      :ok = ConnectionProcess.submit_query(pid, query)

      send(pid, {:resolution_error, 604, :some_unknown_error})

      assert_receive {:dns_response, 604, response}, 100
      # SERVFAIL = 2
      assert rcode_value(response.header.rcode) == 2
    end
  end

  describe "phase update messages" do
    setup do
      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {127, 0, 0, 1},
          client_port: 12345,
          query_timeout: 5000
        )

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, pid: pid}
    end

    test "updates phase on view_matched message", %{pid: pid} do
      query = build_test_query(700)
      :ok = ConnectionProcess.submit_query(pid, query)

      send(pid, {:view_matched, 700, "default"})
      Process.sleep(10)

      stats = ConnectionProcess.stats(pid)
      [query_stats] = stats.queries
      assert query_stats.phase == :zone_lookup
    end

    test "updates phase on zone_lookup message", %{pid: pid} do
      query = build_test_query(701)
      :ok = ConnectionProcess.submit_query(pid, query)

      send(pid, {:zone_lookup, 701, :hit})
      Process.sleep(10)

      stats = ConnectionProcess.stats(pid)
      [query_stats] = stats.queries
      assert query_stats.phase == :resolving
    end

    test "updates phase on zone_response message", %{pid: pid} do
      query = build_test_query(702)
      :ok = ConnectionProcess.submit_query(pid, query)

      response = build_test_response(query)
      send(pid, {:zone_response, 702, response})
      Process.sleep(10)

      stats = ConnectionProcess.stats(pid)
      [query_stats] = stats.queries
      assert query_stats.phase == :rpz_evaluation
    end

    test "ignores phase updates for unknown query_id", %{pid: pid} do
      send(pid, {:view_matched, 99999, "default"})
      send(pid, {:zone_lookup, 99999, :hit})
      send(pid, {:zone_response, 99999, nil})

      # Process should still be alive and have no queries
      Process.sleep(10)
      assert Process.alive?(pid)
      stats = ConnectionProcess.stats(pid)
      assert stats.active_queries == 0
    end
  end

  describe "recursive step and RPZ messages" do
    setup do
      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {127, 0, 0, 1},
          client_port: 12345,
          query_timeout: 5000
        )

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, pid: pid}
    end

    test "handles recursive_step message", %{pid: pid} do
      query = build_test_query(800)
      :ok = ConnectionProcess.submit_query(pid, query)

      send(pid, {:recursive_step, 800, %{server: "8.8.8.8", depth: 1}})

      # Process should still be alive
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles rpz_evaluation message", %{pid: pid} do
      query = build_test_query(801)
      :ok = ConnectionProcess.submit_query(pid, query)

      send(pid, {:rpz_evaluation, 801, :pass})

      # Process should still be alive
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "ignores recursive_step for unknown query", %{pid: pid} do
      send(pid, {:recursive_step, 99999, %{server: "8.8.8.8"}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "ignores rpz_evaluation for unknown query", %{pid: pid} do
      send(pid, {:rpz_evaluation, 99999, :blocked})
      Process.sleep(10)
      assert Process.alive?(pid)
    end
  end

  describe "unknown messages" do
    test "ignores unknown messages" do
      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {127, 0, 0, 1},
          client_port: 12345
        )

      # Send various unknown messages
      send(pid, :unknown_atom)
      send(pid, {:unknown_tuple, 123})
      send(pid, "string message")

      # Process should still be alive
      Process.sleep(10)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "QueryLogger integration" do
    setup do
      # Start a local QueryLogger instance for this test
      {:ok, logger_pid} =
        YellowDog.Dns.QueryLogger.start_link(name: YellowDog.Dns.QueryLogger, buffer_size: 100)

      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {10, 0, 0, 1},
          client_port: 40000,
          query_timeout: 5000
        )

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end

        try do
          if Process.alive?(logger_pid), do: GenServer.stop(logger_pid)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, pid: pid, logger_pid: logger_pid}
    end

    test "logs successful query to QueryLogger", %{pid: pid, logger_pid: logger_pid} do
      query = build_test_query(900, "logged.example.com", :a)
      :ok = ConnectionProcess.submit_query(pid, query)

      response = build_test_response(query)
      send(pid, {:resolution_complete, 900, response})

      assert_receive {:dns_response, 900, _response}, 100

      # Allow cast to be processed
      Process.sleep(50)

      logs = YellowDog.Dns.QueryLogger.get_recent_logs(logger_pid, limit: 10)
      assert length(logs) >= 1

      [entry | _] = logs
      assert entry.client_ip == "10.0.0.1"
      assert to_string(entry.qname) =~ "logged.example.com"
      assert to_string(entry.qtype) =~ "A"
      assert entry.response_code == RCode.no_error()
      assert entry.answer_count == 0
      assert is_integer(entry.response_time_us)
    end

    test "logs error query to QueryLogger", %{pid: pid, logger_pid: logger_pid} do
      query = build_test_query(901, "error.example.com", :aaaa)
      :ok = ConnectionProcess.submit_query(pid, query)

      send(pid, {:resolution_error, 901, :refused})

      assert_receive {:dns_response, 901, _response}, 100

      # Allow cast to be processed
      Process.sleep(50)

      logs = YellowDog.Dns.QueryLogger.get_recent_logs(logger_pid, limit: 10)
      assert length(logs) >= 1

      [entry | _] = logs
      assert entry.client_ip == "10.0.0.1"
      assert to_string(entry.qname) =~ "error.example.com"
      assert entry.error == :refused
    end
  end

  describe "concurrent query handling" do
    test "handles multiple queries with different IDs" do
      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {127, 0, 0, 1},
          client_port: 12345,
          query_timeout: 5000
        )

      # Submit 5 queries
      queries =
        for id <- 1..5 do
          query = build_test_query(id, "test#{id}.example.com")
          :ok = ConnectionProcess.submit_query(pid, query)
          query
        end

      stats = ConnectionProcess.stats(pid)
      assert stats.active_queries == 5

      # Complete queries out of order
      for id <- [3, 1, 5, 2, 4] do
        query = Enum.find(queries, &(&1.header.id == id))
        response = build_test_response(query)
        send(pid, {:resolution_complete, id, response})
        assert_receive {:dns_response, ^id, _response}, 100
      end

      # All queries should be completed
      Process.sleep(10)
      stats = ConnectionProcess.stats(pid)
      assert stats.active_queries == 0

      GenServer.stop(pid)
    end

    test "handles mixed success and error completions" do
      {:ok, pid} =
        ConnectionProcess.start_link(
          handler_pid: self(),
          client_ip: {127, 0, 0, 1},
          client_port: 12345,
          query_timeout: 5000
        )

      # Submit 4 queries
      for id <- 1..4 do
        query = build_test_query(id)
        :ok = ConnectionProcess.submit_query(pid, query)
      end

      # Complete with mixed results
      query1 = build_test_query(1)
      send(pid, {:resolution_complete, 1, build_test_response(query1)})
      send(pid, {:resolution_error, 2, :timeout})
      query3 = build_test_query(3)
      send(pid, {:resolution_complete, 3, build_test_response(query3)})
      send(pid, {:resolution_error, 4, :nxdomain})

      # Receive all responses
      for id <- 1..4 do
        assert_receive {:dns_response, ^id, _response}, 100
      end

      # All queries should be completed
      Process.sleep(10)
      stats = ConnectionProcess.stats(pid)
      assert stats.active_queries == 0

      GenServer.stop(pid)
    end
  end
end
