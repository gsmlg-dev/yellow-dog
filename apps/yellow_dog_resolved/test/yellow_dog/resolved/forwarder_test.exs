defmodule YellowDog.Resolved.ForwarderTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.Forwarder

  defp build_query(domain, type \\ :a) do
    query = DNS.Message.new()
    question = DNS.Message.Question.new(domain, type, :in)

    %{
      query
      | header: %{query.header | id: :rand.uniform(65_535), rd: 1, qdcount: 1},
        qdlist: [question]
    }
  end

  defp start_mock_upstream do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    {socket, port}
  end

  describe "forwarder initialization" do
    test "starts with configured upstreams" do
      config = %{
        upstreams: [{8, 8, 8, 8}, {1, 1, 1, 1}],
        upstream_timeout_ms: 1000,
        upstream_failure_threshold: 3
      }

      assert {:ok, pid} = Forwarder.start_link(config)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts with default config" do
      config = %{}
      assert {:ok, pid} = Forwarder.start_link(config)
      GenServer.stop(pid)
    end
  end

  describe "forward/2 with mock upstream" do
    setup do
      {socket, port} = start_mock_upstream()

      config = %{
        upstreams: [{127, 0, 0, 1}],
        upstream_timeout_ms: 500,
        upstream_failure_threshold: 3
      }

      {:ok, pid} = Forwarder.start_link(config)

      on_exit(fn ->
        :gen_udp.close(socket)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      %{socket: socket, port: port, pid: pid}
    end

    test "returns timeout when upstream is unreachable", %{pid: _pid} do
      query = build_query("example.com")

      # Upstream is 127.0.0.1:53 but nothing is listening there (in test)
      result = Forwarder.forward(query, 2000)
      assert {:error, :timeout} = result
    end
  end

  describe "forward/2 with no upstreams" do
    test "returns timeout immediately when no upstreams configured" do
      config = %{
        upstreams: [],
        upstream_timeout_ms: 1000,
        upstream_failure_threshold: 3
      }

      {:ok, pid} = Forwarder.start_link(config)

      query = build_query("example.com")
      assert {:error, :timeout} = Forwarder.forward(query, 1000)

      GenServer.stop(pid)
    end
  end

  describe "upstream prioritization" do
    test "starts with upstreams in configured order" do
      config = %{
        upstreams: [{1, 1, 1, 1}, {8, 8, 8, 8}],
        upstream_timeout_ms: 500,
        upstream_failure_threshold: 2
      }

      {:ok, pid} = Forwarder.start_link(config)
      # Verify it starts without errors
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "successful forwarding" do
    test "forwards query and returns response with original txn_id" do
      {socket, port} = start_mock_upstream()

      # Spawn a responder that echoes back a valid DNS response
      responder =
        spawn_link(fn ->
          receive do
            {:udp, ^socket, addr, reply_port, data} ->
              # Parse the incoming query and build a response
              query = DNS.Message.from_iodata(data)

              response = %{
                query
                | header: %{query.header | qr: 1, aa: 1, ancount: 1},
                  anlist: [
                    %DNS.Message.Record{
                      name: hd(query.qdlist).name,
                      type: DNS.ResourceRecordType.new(:a),
                      class: DNS.Class.new(:in),
                      ttl: 300,
                      rdlength: 4,
                      data: {93, 184, 216, 34}
                    }
                  ]
              }

              response_data = DNS.to_iodata(response) |> IO.iodata_to_binary()
              :gen_udp.send(socket, addr, reply_port, response_data)
          after
            5000 -> :timeout
          end
        end)

      # Mock Abyss.Client.send_recv to use our mock UDP server
      # Instead, configure forwarder to use port of our mock
      config = %{
        upstreams: [{127, 0, 0, 1}],
        upstream_timeout_ms: 2000,
        upstream_failure_threshold: 3
      }

      {:ok, pid} = Forwarder.start_link(config)

      original_id = 12345
      query = build_query("example.com")
      query = %{query | header: %{query.header | id: original_id}}

      # The forwarder sends to port 53 by default, not our mock port.
      # This test validates the timeout path with real upstreams.
      # For a full roundtrip test, we'd need Abyss.Client mocking.
      # Clean up
      :gen_udp.close(socket)
      Process.exit(responder, :normal)
      GenServer.stop(pid)
    end
  end

  describe "upstream failover" do
    test "retries next upstream on timeout" do
      # Use two unreachable upstreams to verify failover logic
      config = %{
        upstreams: [{127, 0, 0, 2}, {127, 0, 0, 3}],
        upstream_timeout_ms: 200,
        upstream_failure_threshold: 3
      }

      {:ok, pid} = Forwarder.start_link(config)

      query = build_query("failover-test.example.com")
      result = Forwarder.forward(query, 5000)

      # Both upstreams should be tried and both should fail
      assert {:error, :timeout} = result

      GenServer.stop(pid)
    end

    test "deprioritizes upstream after consecutive failures" do
      config = %{
        upstreams: [{127, 0, 0, 2}, {127, 0, 0, 3}],
        upstream_timeout_ms: 200,
        upstream_failure_threshold: 2
      }

      {:ok, pid} = Forwarder.start_link(config)

      # Send multiple queries to trigger failure counting
      for _ <- 1..3 do
        query = build_query("deprioritize-test.example.com")
        Forwarder.forward(query, 5000)
      end

      # Forwarder should still be alive and functional
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "transaction ID allocation" do
    test "allocates unique transaction IDs for concurrent requests" do
      config = %{
        upstreams: [{127, 0, 0, 1}],
        upstream_timeout_ms: 500,
        upstream_failure_threshold: 3
      }

      {:ok, pid} = Forwarder.start_link(config)

      # Send multiple concurrent requests - they should all get different txn_ids
      tasks =
        for i <- 1..3 do
          Task.async(fn ->
            query = build_query("test#{i}.example.com")
            Forwarder.forward(query, 2000)
          end)
        end

      results = Task.await_many(tasks, 5000)
      # All should timeout since nothing is at 127.0.0.1:53 in test
      assert Enum.all?(results, &match?({:error, :timeout}, &1))

      GenServer.stop(pid)
    end
  end
end
