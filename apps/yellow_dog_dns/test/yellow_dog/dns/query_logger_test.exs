defmodule YellowDog.Dns.QueryLoggerTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dns.QueryLogger
  alias YellowDog.Dns.QueryLogger.Entry

  setup do
    name = :"query_logger_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = QueryLogger.start_link(name: name, buffer_size: 10)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{pid: pid, name: name}
  end

  describe "start_link/1" do
    test "starts with default options" do
      name = :"ql_default_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = QueryLogger.start_link(name: name)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts with custom buffer size" do
      name = :"ql_custom_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = QueryLogger.start_link(name: name, buffer_size: 50)
      stats = QueryLogger.stats(pid)
      assert stats.buffer_size == 50
      GenServer.stop(pid)
    end

    test "starts with logging disabled" do
      name = :"ql_disabled_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = QueryLogger.start_link(name: name, enabled: false)
      stats = QueryLogger.stats(pid)
      assert stats.enabled == false
      GenServer.stop(pid)
    end
  end

  describe "log_query/2" do
    test "logs a query entry", %{pid: pid} do
      QueryLogger.log_query(pid, %{
        client_ip: {192, 168, 1, 1},
        qname: "example.com",
        qtype: :a,
        response_code: :noerror
      })

      # Cast is async, give it a moment
      Process.sleep(10)

      entries = QueryLogger.get_recent_logs(pid, limit: 10)
      assert length(entries) == 1
      [entry] = entries
      assert entry.qname == "example.com"
      assert entry.qtype == :a
      assert entry.response_code == :noerror
    end

    test "assigns unique IDs to entries", %{pid: pid} do
      Enum.each(1..5, fn _ ->
        QueryLogger.log_query(pid, %{qname: "test.com", qtype: :a})
      end)

      Process.sleep(10)
      entries = QueryLogger.get_recent_logs(pid, limit: 10)
      ids = Enum.map(entries, & &1.id)
      assert length(Enum.uniq(ids)) == 5
    end

    test "assigns timestamps to entries", %{pid: pid} do
      QueryLogger.log_query(pid, %{qname: "test.com", qtype: :a})
      Process.sleep(10)

      [entry] = QueryLogger.get_recent_logs(pid, limit: 1)
      assert %DateTime{} = entry.timestamp
    end

    test "respects buffer size limit", %{pid: pid} do
      # Buffer size is 10
      Enum.each(1..15, fn i ->
        QueryLogger.log_query(pid, %{qname: "test#{i}.com", qtype: :a})
      end)

      Process.sleep(20)
      entries = QueryLogger.get_recent_logs(pid, limit: 20)
      assert length(entries) == 10
    end

    test "drops oldest entries when buffer is full", %{pid: pid} do
      Enum.each(1..15, fn i ->
        QueryLogger.log_query(pid, %{qname: "test#{i}.com", qtype: :a})
      end)

      Process.sleep(20)
      entries = QueryLogger.get_recent_logs(pid, limit: 20)
      qnames = Enum.map(entries, & &1.qname)

      # Oldest 5 should be dropped, newest 10 should remain
      refute "test1.com" in qnames
      assert "test15.com" in qnames
      assert "test6.com" in qnames
    end

    test "does not log when disabled", %{pid: pid} do
      QueryLogger.set_enabled(pid, false)

      QueryLogger.log_query(pid, %{qname: "test.com", qtype: :a})
      Process.sleep(10)

      entries = QueryLogger.get_recent_logs(pid, limit: 10)
      assert entries == []
    end

    test "fills all entry fields from attrs", %{pid: pid} do
      QueryLogger.log_query(pid, %{
        client_ip: {10, 0, 0, 1},
        client_port: 12345,
        view: "internal",
        qname: "www.example.com",
        qtype: :a,
        qclass: :in,
        protocol: :tcp,
        response_code: :noerror,
        response_time_us: 1500,
        answer_count: 2,
        authority_count: 1,
        additional_count: 0,
        cache_hit: true,
        zone_used: "example.com",
        fallback_used: false,
        error: nil
      })

      Process.sleep(10)
      [entry] = QueryLogger.get_recent_logs(pid, limit: 1)

      assert entry.client_ip == {10, 0, 0, 1}
      assert entry.client_port == 12345
      assert entry.view == "internal"
      assert entry.qname == "www.example.com"
      assert entry.qtype == :a
      assert entry.qclass == :in
      assert entry.protocol == :tcp
      assert entry.response_code == :noerror
      assert entry.response_time_us == 1500
      assert entry.answer_count == 2
      assert entry.authority_count == 1
      assert entry.additional_count == 0
      assert entry.cache_hit == true
      assert entry.zone_used == "example.com"
      assert entry.fallback_used == false
      assert entry.error == nil
    end
  end

  describe "get_recent_logs/2" do
    test "returns entries in reverse chronological order", %{pid: pid} do
      Enum.each(1..5, fn i ->
        QueryLogger.log_query(pid, %{qname: "test#{i}.com", qtype: :a})
        Process.sleep(5)
      end)

      Process.sleep(10)
      entries = QueryLogger.get_recent_logs(pid, limit: 5)
      qnames = Enum.map(entries, & &1.qname)

      assert List.first(qnames) == "test5.com"
      assert List.last(qnames) == "test1.com"
    end

    test "respects limit parameter", %{pid: pid} do
      Enum.each(1..10, fn i ->
        QueryLogger.log_query(pid, %{qname: "test#{i}.com", qtype: :a})
      end)

      Process.sleep(10)
      entries = QueryLogger.get_recent_logs(pid, limit: 3)
      assert length(entries) == 3
    end

    test "returns empty list when no entries", %{pid: pid} do
      entries = QueryLogger.get_recent_logs(pid, limit: 10)
      assert entries == []
    end
  end

  describe "get_logs_by_client/3" do
    test "filters by client IP tuple", %{pid: pid} do
      QueryLogger.log_query(pid, %{client_ip: {192, 168, 1, 1}, qname: "a.com", qtype: :a})
      QueryLogger.log_query(pid, %{client_ip: {192, 168, 1, 2}, qname: "b.com", qtype: :a})
      QueryLogger.log_query(pid, %{client_ip: {192, 168, 1, 1}, qname: "c.com", qtype: :a})

      Process.sleep(10)
      entries = QueryLogger.get_logs_by_client(pid, {192, 168, 1, 1}, limit: 10)
      assert length(entries) == 2
      qnames = Enum.map(entries, & &1.qname)
      assert "a.com" in qnames
      assert "c.com" in qnames
    end

    test "filters by client IP string", %{pid: pid} do
      QueryLogger.log_query(pid, %{client_ip: {10, 0, 0, 1}, qname: "x.com", qtype: :a})
      QueryLogger.log_query(pid, %{client_ip: {10, 0, 0, 2}, qname: "y.com", qtype: :a})

      Process.sleep(10)
      entries = QueryLogger.get_logs_by_client(pid, "10.0.0.1", limit: 10)
      assert length(entries) == 1
      assert hd(entries).qname == "x.com"
    end
  end

  describe "get_logs_by_view/3" do
    test "filters by view name", %{pid: pid} do
      QueryLogger.log_query(pid, %{view: "internal", qname: "a.com", qtype: :a})
      QueryLogger.log_query(pid, %{view: "external", qname: "b.com", qtype: :a})
      QueryLogger.log_query(pid, %{view: "internal", qname: "c.com", qtype: :a})

      Process.sleep(10)
      entries = QueryLogger.get_logs_by_view(pid, "internal", limit: 10)
      assert length(entries) == 2
    end
  end

  describe "get_logs_by_qname/3" do
    test "filters by qname pattern", %{pid: pid} do
      QueryLogger.log_query(pid, %{qname: "www.example.com", qtype: :a})
      QueryLogger.log_query(pid, %{qname: "api.example.com", qtype: :a})
      QueryLogger.log_query(pid, %{qname: "www.other.com", qtype: :a})

      Process.sleep(10)
      entries = QueryLogger.get_logs_by_qname(pid, "example.com", limit: 10)
      assert length(entries) == 2
    end

    test "pattern matching is case-insensitive", %{pid: pid} do
      QueryLogger.log_query(pid, %{qname: "WWW.Example.COM", qtype: :a})

      Process.sleep(10)
      entries = QueryLogger.get_logs_by_qname(pid, "example.com", limit: 10)
      assert length(entries) == 1
    end

    test "handles nil qname entries", %{pid: pid} do
      QueryLogger.log_query(pid, %{qname: nil, qtype: :a})
      QueryLogger.log_query(pid, %{qname: "test.com", qtype: :a})

      Process.sleep(10)
      entries = QueryLogger.get_logs_by_qname(pid, "test", limit: 10)
      assert length(entries) == 1
    end
  end

  describe "clear_buffer/1" do
    test "clears all entries", %{pid: pid} do
      Enum.each(1..5, fn i ->
        QueryLogger.log_query(pid, %{qname: "test#{i}.com", qtype: :a})
      end)

      Process.sleep(10)
      assert length(QueryLogger.get_recent_logs(pid, limit: 10)) == 5

      :ok = QueryLogger.clear_buffer(pid)
      assert QueryLogger.get_recent_logs(pid, limit: 10) == []
    end
  end

  describe "stats/1" do
    test "returns correct statistics", %{pid: pid} do
      Enum.each(1..3, fn i ->
        QueryLogger.log_query(pid, %{qname: "test#{i}.com", qtype: :a})
      end)

      Process.sleep(10)
      stats = QueryLogger.stats(pid)

      assert stats.buffer_size == 10
      assert stats.current_entries == 3
      assert stats.total_logged == 3
      assert stats.enabled == true
    end

    test "total_logged counts beyond buffer size", %{pid: pid} do
      Enum.each(1..15, fn i ->
        QueryLogger.log_query(pid, %{qname: "test#{i}.com", qtype: :a})
      end)

      Process.sleep(20)
      stats = QueryLogger.stats(pid)

      assert stats.current_entries == 10
      assert stats.total_logged == 15
    end
  end

  describe "set_enabled/2" do
    test "can disable and re-enable logging", %{pid: pid} do
      QueryLogger.log_query(pid, %{qname: "before.com", qtype: :a})
      Process.sleep(10)
      assert length(QueryLogger.get_recent_logs(pid, limit: 10)) == 1

      QueryLogger.set_enabled(pid, false)
      QueryLogger.log_query(pid, %{qname: "during.com", qtype: :a})
      Process.sleep(10)
      assert length(QueryLogger.get_recent_logs(pid, limit: 10)) == 1

      QueryLogger.set_enabled(pid, true)
      QueryLogger.log_query(pid, %{qname: "after.com", qtype: :a})
      Process.sleep(10)
      assert length(QueryLogger.get_recent_logs(pid, limit: 10)) == 2
    end
  end

  describe "pubsub_topic/0" do
    test "returns the topic string" do
      assert QueryLogger.pubsub_topic() == "dns:query_logs"
    end
  end

  describe "Entry struct" do
    test "has expected fields" do
      entry = %Entry{}
      assert Map.has_key?(entry, :id)
      assert Map.has_key?(entry, :timestamp)
      assert Map.has_key?(entry, :client_ip)
      assert Map.has_key?(entry, :qname)
      assert Map.has_key?(entry, :qtype)
      assert Map.has_key?(entry, :response_code)
      assert Map.has_key?(entry, :response_time_us)
      assert Map.has_key?(entry, :cache_hit)
      assert Map.has_key?(entry, :fallback_used)
    end
  end

  describe "concurrent access" do
    test "handles concurrent log and read operations", %{pid: pid} do
      # Spawn multiple writers
      writers =
        Enum.map(1..10, fn i ->
          Task.async(fn ->
            Enum.each(1..5, fn j ->
              QueryLogger.log_query(pid, %{qname: "w#{i}-q#{j}.com", qtype: :a})
            end)
          end)
        end)

      # Spawn concurrent readers
      readers =
        Enum.map(1..5, fn _i ->
          Task.async(fn ->
            Enum.each(1..3, fn _ ->
              QueryLogger.get_recent_logs(pid, limit: 10)
              Process.sleep(1)
            end)
          end)
        end)

      # Wait for all tasks
      Enum.each(writers ++ readers, &Task.await/1)
      Process.sleep(10)

      # Should have entries (up to buffer size)
      entries = QueryLogger.get_recent_logs(pid, limit: 20)
      assert length(entries) <= 10
      assert length(entries) > 0
    end
  end
end
