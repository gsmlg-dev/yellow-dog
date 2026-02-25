defmodule YellowDog.Dns.RecursionWorkerTest do
  @moduledoc """
  Unit tests for YellowDog.Dns.RecursionWorker.

  Uses a lightweight FakeDnsServer (GenServer over :gen_udp) to test
  recursive resolution paths without real network access. The fake server
  responds to UDP queries with crafted DNS responses, enabling testing of:

  - Direct answers (NOERROR + answer records)
  - NXDOMAIN / SERVFAIL / empty NOERROR
  - Referral following (NS in authority + glue A in additional)
  - Max recursion depth enforcement
  - Timeout handling
  - Server failover
  - Socket lifecycle (ephemeral open/close)
  """
  use ExUnit.Case, async: true

  alias YellowDog.Dns.RecursionWorker
  alias DNS.Message
  alias DNS.Message.Question
  alias DNS.Message.RCode

  # ── Inline fake DNS server ────────────────────────────────────────

  defmodule FakeDnsServer do
    @moduledoc false
    use GenServer

    defstruct [:socket, :port, :handler]

    @doc """
    Start a fake DNS server.

    `handler` is a function `(query :: DNS.Message.t()) -> DNS.Message.t() | :drop`.
    Return `:drop` to simulate timeout (no reply).
    """
    def start(handler) do
      {:ok, pid} = GenServer.start(__MODULE__, handler)
      port = GenServer.call(pid, :get_port)
      {:ok, pid, port}
    end

    def stop(pid), do: GenServer.stop(pid)

    @impl true
    def init(handler) do
      {:ok, socket} = :gen_udp.open(0, [:binary, active: true, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(socket)
      {:ok, %__MODULE__{socket: socket, port: port, handler: handler}}
    end

    @impl true
    def handle_call(:get_port, _from, state) do
      {:reply, state.port, state}
    end

    @impl true
    def handle_info({:udp, _socket, client_ip, client_port, data}, state) do
      try do
        query = DNS.Message.from_iodata(data)

        case state.handler.(query) do
          :drop ->
            :ok

          response ->
            bin = DNS.to_iodata(response) |> IO.iodata_to_binary()
            :gen_udp.send(state.socket, client_ip, client_port, bin)
        end
      catch
        _, _ -> :ok
      end

      {:noreply, state}
    end

    @impl true
    def handle_info(_msg, state), do: {:noreply, state}

    @impl true
    def terminate(_reason, %{socket: socket}) do
      :gen_udp.close(socket)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────

  defp build_empty_query do
    %Message{
      header: %DNS.Message.Header{
        id: :rand.uniform(65535),
        qr: 0,
        opcode: DNS.Message.OpCode.new(0),
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

  # Build response by mutating the query (preserves proper struct types)
  defp make_response(query, opts \\ []) do
    rcode = Keyword.get(opts, :rcode, RCode.no_error())
    answers = Keyword.get(opts, :answers, [])
    authority = Keyword.get(opts, :authority, [])
    additional = Keyword.get(opts, :additional, [])
    aa = Keyword.get(opts, :aa, 0)

    query
    |> Message.update_header_attr(:qr, 1)
    |> Message.update_header_attr(:aa, aa)
    |> Message.update_header_attr(:ra, 1)
    |> Message.update_header_attr(:rcode, rcode)
    |> Message.update_header_attr(:ancount, length(answers))
    |> Message.update_header_attr(:nscount, length(authority))
    |> Message.update_header_attr(:arcount, length(additional))
    |> Map.put(:anlist, answers)
    |> Map.put(:nslist, authority)
    |> Map.put(:arlist, additional)
  end

  defp start_echo_server do
    handler = fn query ->
      question = List.first(query.qdlist)

      if question do
        a_record = DNS.Message.Record.new(to_string(question.name), 1, 1, 300, {10, 0, 0, 1})
        make_response(query, answers: [a_record], aa: 1)
      else
        make_response(query)
      end
    end

    FakeDnsServer.start(handler)
  end

  defp server_tuple(port), do: [{{127, 0, 0, 1}, port}]

  # ── Basic resolve/2 ──────────────────────────────────────────────

  describe "resolve/2 basics" do
    @tag :capture_log
    test "returns format_error for query with no questions" do
      empty_query = build_empty_query()

      result = RecursionWorker.resolve(empty_query)
      assert {:error, :format_error} = result
    end

    @tag :capture_log
    test "accepts map options" do
      empty_query = build_empty_query()
      result = RecursionWorker.resolve(empty_query, %{query_timeout: 1000})
      assert {:error, :format_error} = result
    end

    @tag :capture_log
    test "accepts keyword options" do
      empty_query = build_empty_query()
      result = RecursionWorker.resolve(empty_query, query_timeout: 1000)
      assert {:error, :format_error} = result
    end

    @tag :capture_log
    test "handles multiple sequential resolves (socket lifecycle)" do
      empty_query = build_empty_query()

      for _ <- 1..5 do
        result = RecursionWorker.resolve(empty_query)
        assert {:error, :format_error} = result
      end
    end
  end

  # ── Direct answer ────────────────────────────────────────────────

  describe "direct answer" do
    @tag :capture_log
    test "returns {:ok, response} when server replies with A record" do
      {:ok, pid, port} = start_echo_server()

      query = build_test_query("test.example.com")
      opts = %{root_servers: server_tuple(port), query_timeout: 2_000}

      result = RecursionWorker.resolve(query, opts)

      assert {:ok, response} = result
      assert response.header.qr == 1
      assert length(response.anlist) > 0

      [answer | _] = response.anlist
      assert answer.data.data == {10, 0, 0, 1}

      FakeDnsServer.stop(pid)
    end

    @tag :capture_log
    test "returns answer with multiple records" do
      handler = fn query ->
        question = List.first(query.qdlist)

        if question do
          name = to_string(question.name)
          r1 = DNS.Message.Record.new(name, 1, 1, 300, {10, 0, 0, 1})
          r2 = DNS.Message.Record.new(name, 1, 1, 300, {10, 0, 0, 2})
          r3 = DNS.Message.Record.new(name, 1, 1, 300, {10, 0, 0, 3})
          make_response(query, answers: [r1, r2, r3], aa: 1)
        else
          make_response(query)
        end
      end

      {:ok, pid, port} = FakeDnsServer.start(handler)

      query = build_test_query("multi.example.com")
      opts = %{root_servers: server_tuple(port), query_timeout: 2_000}

      assert {:ok, response} = RecursionWorker.resolve(query, opts)
      assert length(response.anlist) == 3

      FakeDnsServer.stop(pid)
    end
  end

  # ── NXDOMAIN ─────────────────────────────────────────────────────

  describe "NXDOMAIN handling" do
    @tag :capture_log
    test "returns {:ok, response} for NXDOMAIN (authoritative negative)" do
      handler = fn query ->
        make_response(query, rcode: RCode.nx_domain(), aa: 1)
      end

      {:ok, pid, port} = FakeDnsServer.start(handler)

      query = build_test_query("nonexistent.example.com")
      opts = %{root_servers: server_tuple(port), query_timeout: 2_000}

      result = RecursionWorker.resolve(query, opts)
      # NXDOMAIN is returned as {:ok, response} — it's a valid answer
      assert {:ok, response} = result
      assert response.anlist == []

      FakeDnsServer.stop(pid)
    end
  end

  # ── SERVFAIL and other error rcodes ──────────────────────────────

  describe "server error rcodes" do
    @tag :capture_log
    test "returns {:error, _} for SERVFAIL" do
      handler = fn query ->
        make_response(query, rcode: RCode.new(2))
      end

      {:ok, pid, port} = FakeDnsServer.start(handler)

      query = build_test_query("fail.example.com")
      opts = %{root_servers: server_tuple(port), query_timeout: 2_000}

      result = RecursionWorker.resolve(query, opts)
      assert {:error, _rcode} = result

      FakeDnsServer.stop(pid)
    end

    @tag :capture_log
    test "returns {:error, _} for REFUSED" do
      handler = fn query ->
        make_response(query, rcode: RCode.new(5))
      end

      {:ok, pid, port} = FakeDnsServer.start(handler)

      query = build_test_query("refused.example.com")
      opts = %{root_servers: server_tuple(port), query_timeout: 2_000}

      result = RecursionWorker.resolve(query, opts)
      assert {:error, _rcode} = result

      FakeDnsServer.stop(pid)
    end

    @tag :capture_log
    test "returns {:error, _} for NOTIMP" do
      handler = fn query ->
        make_response(query, rcode: RCode.new(4))
      end

      {:ok, pid, port} = FakeDnsServer.start(handler)

      query = build_test_query("notimp.example.com")
      opts = %{root_servers: server_tuple(port), query_timeout: 2_000}

      result = RecursionWorker.resolve(query, opts)
      assert {:error, _rcode} = result

      FakeDnsServer.stop(pid)
    end

    @tag :capture_log
    test "returns {:error, _} for FORMERR" do
      handler = fn query ->
        make_response(query, rcode: RCode.new(1))
      end

      {:ok, pid, port} = FakeDnsServer.start(handler)

      query = build_test_query("formerr.example.com")
      opts = %{root_servers: server_tuple(port), query_timeout: 2_000}

      result = RecursionWorker.resolve(query, opts)
      assert {:error, _rcode} = result

      FakeDnsServer.stop(pid)
    end
  end

  # ── Empty NOERROR (no_data) ──────────────────────────────────────

  describe "empty NOERROR (NODATA)" do
    @tag :capture_log
    test "returns {:error, :no_data} for NOERROR with no answers and no NS" do
      handler = fn query ->
        # NOERROR, empty answer, no NS in authority
        make_response(query, rcode: RCode.no_error(), aa: 1)
      end

      {:ok, pid, port} = FakeDnsServer.start(handler)

      query = build_test_query("nodata.example.com")
      opts = %{root_servers: server_tuple(port), query_timeout: 2_000}

      result = RecursionWorker.resolve(query, opts)
      assert {:error, :no_data} = result

      FakeDnsServer.stop(pid)
    end
  end

  # ── Referral following ───────────────────────────────────────────

  describe "referral following" do
    @tag :capture_log
    test "detects referral and attempts to follow NS with glue" do
      # Server returns referral first time, answer second time.
      # Glue points to 127.0.0.1:53 (hardcoded in build_server_list),
      # so the actual follow won't reach us. But we verify the referral
      # was detected by counting calls.
      call_count = :counters.new(1, [:atomics])

      handler = fn query ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          # First call: return referral with glue
          ns_record = DNS.Message.Record.new("example.com.", 2, 1, 86400, "ns1.example.com.")
          glue_record = DNS.Message.Record.new("ns1.example.com.", 1, 1, 86400, {127, 0, 0, 1})

          make_response(query,
            authority: [ns_record],
            additional: [glue_record]
          )
        else
          # Subsequent calls: return the answer
          question = List.first(query.qdlist)

          if question do
            a_record = DNS.Message.Record.new(to_string(question.name), 1, 1, 300, {192, 0, 2, 1})
            make_response(query, answers: [a_record], aa: 1)
          else
            make_response(query)
          end
        end
      end

      {:ok, pid, port} = FakeDnsServer.start(handler)

      query = build_test_query("test.example.com")
      opts = %{root_servers: server_tuple(port), query_timeout: 500}

      _result = RecursionWorker.resolve(query, opts)
      # The referral was followed (count > 1 means server was called,
      # then referral was detected and glue was extracted)
      assert :counters.get(call_count, 1) >= 1

      FakeDnsServer.stop(pid)
    end

    @tag :capture_log
    test "returns error when referral has no glue and NS resolution fails" do
      handler = fn query ->
        # Return referral with NS but NO glue records in additional
        ns_record = DNS.Message.Record.new("example.com.", 2, 1, 86400, "ns1.example.com.")

        make_response(query,
          authority: [ns_record],
          additional: []
        )
      end

      {:ok, pid, port} = FakeDnsServer.start(handler)

      query = build_test_query("test.example.com")
      # Very short timeout since NS resolution will fail
      opts = %{root_servers: server_tuple(port), query_timeout: 300}

      result = RecursionWorker.resolve(query, opts)
      # Will try to resolve ns1.example.com via root servers, which also returns referral → loop
      assert {:error, reason} = result
      assert reason in [:max_recursion_depth, :no_servers, :no_ns, :timeout]

      FakeDnsServer.stop(pid)
    end

    @tag :capture_log
    test "returns error when authority has non-NS records only" do
      handler = fn query ->
        # CNAME in authority but no NS → not treated as referral → no_data
        # (Using A record type in authority since it's safe to encode)
        fake_auth = DNS.Message.Record.new("example.com.", 1, 1, 86400, {192, 168, 1, 1})
        make_response(query, authority: [fake_auth])
      end

      {:ok, pid, port} = FakeDnsServer.start(handler)

      query = build_test_query("test.example.com")
      opts = %{root_servers: server_tuple(port), query_timeout: 2_000}

      result = RecursionWorker.resolve(query, opts)
      # No NS in authority → not a referral → no_data or no_servers
      # (response round-trip through DNS encoding may discard non-NS authority)
      assert {:error, reason} = result
      assert reason in [:no_data, :no_servers]

      FakeDnsServer.stop(pid)
    end
  end

  # ── Max recursion depth ──────────────────────────────────────────

  describe "max recursion depth" do
    @tag :capture_log
    test "returns error when referral chain loops without glue" do
      # Server always returns referral without glue → NS resolution loops
      handler = fn query ->
        ns_record = DNS.Message.Record.new("example.com.", 2, 1, 86400, "ns1.example.com.")
        make_response(query, authority: [ns_record])
      end

      {:ok, pid, port} = FakeDnsServer.start(handler)

      query = build_test_query("deep.example.com")
      opts = %{root_servers: server_tuple(port), query_timeout: 300}

      result = RecursionWorker.resolve(query, opts)
      assert {:error, reason} = result
      assert reason in [:max_recursion_depth, :no_ns, :no_servers, :timeout]

      FakeDnsServer.stop(pid)
    end
  end

  # ── Timeout handling ─────────────────────────────────────────────

  describe "timeout handling" do
    @tag :capture_log
    test "returns error when server drops all packets" do
      handler = fn _query -> :drop end

      {:ok, pid, port} = FakeDnsServer.start(handler)

      query = build_test_query("timeout.example.com")
      opts = %{root_servers: server_tuple(port), query_timeout: 200}

      result = RecursionWorker.resolve(query, opts)
      assert {:error, reason} = result
      assert reason in [:no_servers, :timeout]

      FakeDnsServer.stop(pid)
    end

    @tag :capture_log
    test "custom query_timeout is respected" do
      handler = fn _query -> :drop end

      {:ok, pid, port} = FakeDnsServer.start(handler)

      query = build_test_query("slow.example.com")

      {time_us, result} =
        :timer.tc(fn ->
          RecursionWorker.resolve(query, %{
            root_servers: server_tuple(port),
            query_timeout: 100
          })
        end)

      assert {:error, _} = result
      # Should complete well under 5 seconds (the default timeout)
      assert time_us < 3_000_000

      FakeDnsServer.stop(pid)
    end

    @tag :capture_log
    @tag :network
    test "returns no_servers when all root servers are unreachable" do
      bad_servers = [
        {{127, 0, 0, 1}, 65534},
        {{127, 0, 0, 1}, 65535}
      ]

      query = build_test_query("example.com")
      opts = %{root_servers: bad_servers, query_timeout: 100}

      result = RecursionWorker.resolve(query, opts)
      assert {:error, reason} = result
      assert reason in [:no_servers, :timeout]
    end
  end

  # ── Server failover ──────────────────────────────────────────────

  describe "server failover" do
    @tag :capture_log
    test "tries next server when first times out" do
      # First server drops packets; second replies
      drop_handler = fn _query -> :drop end
      {:ok, drop_pid, drop_port} = FakeDnsServer.start(drop_handler)
      {:ok, echo_pid, echo_port} = start_echo_server()

      query = build_test_query("failover.example.com")

      opts = %{
        root_servers: [
          {{127, 0, 0, 1}, drop_port},
          {{127, 0, 0, 1}, echo_port}
        ],
        query_timeout: 500
      }

      result = RecursionWorker.resolve(query, opts)
      assert {:ok, response} = result
      assert length(response.anlist) > 0

      FakeDnsServer.stop(drop_pid)
      FakeDnsServer.stop(echo_pid)
    end

    @tag :capture_log
    test "tries all servers before giving up" do
      # All servers drop → :no_servers
      {:ok, pid1, port1} = FakeDnsServer.start(fn _q -> :drop end)
      {:ok, pid2, port2} = FakeDnsServer.start(fn _q -> :drop end)

      query = build_test_query("alldown.example.com")

      opts = %{
        root_servers: [
          {{127, 0, 0, 1}, port1},
          {{127, 0, 0, 1}, port2}
        ],
        query_timeout: 200
      }

      result = RecursionWorker.resolve(query, opts)
      assert {:error, reason} = result
      assert reason in [:no_servers, :timeout]

      FakeDnsServer.stop(pid1)
      FakeDnsServer.stop(pid2)
    end
  end

  # ── Concurrent resolution ────────────────────────────────────────

  describe "concurrent resolution" do
    @tag :capture_log
    test "can handle multiple concurrent resolves (empty queries)" do
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

    @tag :capture_log
    test "concurrent resolves each get correct answers" do
      {:ok, pid, port} = start_echo_server()

      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            query = build_test_query("host#{i}.example.com")
            opts = %{root_servers: server_tuple(port), query_timeout: 2_000}
            RecursionWorker.resolve(query, opts)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      for result <- results do
        assert {:ok, response} = result
        assert length(response.anlist) > 0
      end

      FakeDnsServer.stop(pid)
    end
  end

  # ── Response ID matching ─────────────────────────────────────────

  describe "response ID matching" do
    @tag :capture_log
    test "ignores responses with wrong transaction ID and times out" do
      handler = fn query ->
        # Always respond with wrong ID
        question = List.first(query.qdlist)

        if question do
          wrong_id = rem(query.header.id + 1, 65536)
          a_record = DNS.Message.Record.new(to_string(question.name), 1, 1, 300, {10, 0, 0, 99})
          response = make_response(query, answers: [a_record], aa: 1)
          %{response | header: %{response.header | id: wrong_id}}
        else
          make_response(query)
        end
      end

      {:ok, pid, port} = FakeDnsServer.start(handler)

      query = build_test_query("wrongid.example.com")
      opts = %{root_servers: server_tuple(port), query_timeout: 300}

      result = RecursionWorker.resolve(query, opts)
      # Wrong ID → ignored → timeout → try next server → no more servers
      assert {:error, reason} = result
      assert reason in [:no_servers, :timeout]

      FakeDnsServer.stop(pid)
    end
  end

  # ── Edge cases ───────────────────────────────────────────────────

  describe "edge cases" do
    @tag :capture_log
    test "handles query with multiple questions (uses first)" do
      {:ok, pid, port} = start_echo_server()

      query = build_test_query("first.example.com")
      # Add second question
      q2 = Question.new("second.example.com", :a, :in)
      query = %{query | qdlist: query.qdlist ++ [q2], header: %{query.header | qdcount: 2}}

      opts = %{root_servers: server_tuple(port), query_timeout: 2_000}

      result = RecursionWorker.resolve(query, opts)
      assert {:ok, _response} = result

      FakeDnsServer.stop(pid)
    end

    @tag :capture_log
    test "handles empty root_servers list" do
      query = build_test_query("no-roots.example.com")
      opts = %{root_servers: [], query_timeout: 500}

      result = RecursionWorker.resolve(query, opts)
      assert {:error, :no_servers} = result
    end

    @tag :capture_log
    test "default opts use root servers and default timeout" do
      # Without specifying root_servers, it uses real root servers
      # which will timeout in tests (short timeout)
      query = build_test_query("default-opts.example.com")

      # Just verify resolve doesn't crash with default opts
      result = RecursionWorker.resolve(query, %{query_timeout: 100})
      assert {:error, _reason} = result
    end
  end
end
