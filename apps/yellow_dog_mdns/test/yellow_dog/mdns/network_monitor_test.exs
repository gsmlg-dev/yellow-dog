defmodule YellowDog.Mdns.NetworkMonitorTest do
  use ExUnit.Case, async: false

  alias YellowDog.Mdns.NetworkMonitor
  alias DNS.Message.{Record, Question}

  # Helper to create a mock DNS message
  defp create_dns_message(opts) do
    answers = Keyword.get(opts, :answers, [])
    questions = Keyword.get(opts, :questions, [])
    authority = Keyword.get(opts, :authority, [])
    additional = Keyword.get(opts, :additional, [])

    %DNS.Message{
      header: %DNS.Message.Header{
        id: Keyword.get(opts, :id, :rand.uniform(65535)),
        qr: Keyword.get(opts, :qr, 1),
        opcode: 0,
        aa: 1,
        tc: 0,
        rd: 0,
        ra: 0,
        z: 0,
        rcode: 0,
        qdcount: length(questions),
        ancount: length(answers),
        nscount: length(authority),
        arcount: length(additional)
      },
      qdlist: questions,
      anlist: answers,
      nslist: authority,
      arlist: additional
    }
  end

  defp create_a_record(name, ip, ttl \\ 4500) do
    %Record{name: name, type: :A, class: :IN, ttl: ttl, data: ip}
  end

  defp create_aaaa_record(name, ip, ttl \\ 4500) do
    %Record{name: name, type: :AAAA, class: :IN, ttl: ttl, data: ip}
  end

  defp create_ptr_record(name, target, ttl \\ 4500) do
    %Record{name: name, type: :PTR, class: :IN, ttl: ttl, data: target}
  end

  defp create_srv_record(name, target, port, ttl \\ 4500) do
    %Record{
      name: name,
      type: :SRV,
      class: :IN,
      ttl: ttl,
      data: %{priority: 0, weight: 0, port: port, target: target}
    }
  end

  defp create_txt_record(name, data, ttl \\ 4500) do
    %Record{name: name, type: :TXT, class: :IN, ttl: ttl, data: data}
  end

  defp create_question(name, type) do
    %Question{name: name, type: type, class: :IN}
  end

  setup do
    start_supervised!(NetworkMonitor)
    NetworkMonitor.clear()
    :ok
  end

  describe "start_link/1" do
    test "starts successfully" do
      assert Process.whereis(NetworkMonitor) != nil
    end
  end

  describe "log_query/3" do
    test "logs a query from the network" do
      question = create_question("_http._tcp.local", :PTR)
      message = create_dns_message(questions: [question], qr: 0)

      assert :ok = NetworkMonitor.log_query(message, {192, 168, 1, 10}, 5353)
      :timer.sleep(10)

      queries = NetworkMonitor.get_queries()
      assert length(queries) == 1

      query = hd(queries)
      assert query.domain == "_http._tcp.local"
      assert query.record_type == :PTR
      assert query.source_ip == {192, 168, 1, 10}
      assert query.answered == false
    end

    test "logs multiple questions from same message" do
      q1 = create_question("_http._tcp.local", :PTR)
      q2 = create_question("_ssh._tcp.local", :PTR)
      message = create_dns_message(questions: [q1, q2], qr: 0)

      assert :ok = NetworkMonitor.log_query(message, {192, 168, 1, 10}, 5353)
      :timer.sleep(10)

      queries = NetworkMonitor.get_queries()
      assert length(queries) == 2

      domains = Enum.map(queries, & &1.domain) |> Enum.sort()
      assert domains == ["_http._tcp.local", "_ssh._tcp.local"]
    end
  end

  describe "cache_response/3" do
    test "caches response records" do
      record = create_a_record("myhost.local", {192, 168, 1, 100})
      message = create_dns_message(answers: [record])

      assert :ok = NetworkMonitor.cache_response(message, {192, 168, 1, 100}, 5353)
      :timer.sleep(10)

      entries = NetworkMonitor.query("myhost.local")
      assert length(entries) == 1
      assert hd(entries).domain == "myhost.local"
    end

    test "caches multiple record types" do
      a_record = create_a_record("service.local", {192, 168, 1, 50})
      aaaa_record = create_aaaa_record("service.local", {0, 0, 0, 0, 0, 0, 0, 1})
      txt_record = create_txt_record("service.local", ["key=value"])

      message = create_dns_message(answers: [a_record, aaaa_record, txt_record])

      assert :ok = NetworkMonitor.cache_response(message, {192, 168, 1, 50}, 5353)
      :timer.sleep(10)

      entries = NetworkMonitor.query("service.local")
      assert length(entries) == 3
    end
  end

  describe "query/2" do
    test "returns empty list for non-existent domain" do
      assert NetworkMonitor.query("nonexistent.local") == []
    end

    test "filters by record type" do
      a_record = create_a_record("multi.local", {192, 168, 1, 1})
      aaaa_record = create_aaaa_record("multi.local", {0, 0, 0, 0, 0, 0, 0, 1})

      message = create_dns_message(answers: [a_record, aaaa_record])
      NetworkMonitor.cache_response(message, {192, 168, 1, 1}, 5353)
      :timer.sleep(10)

      a_entries = NetworkMonitor.query("multi.local", :A)
      assert length(a_entries) == 1

      aaaa_entries = NetworkMonitor.query("multi.local", :AAAA)
      assert length(aaaa_entries) == 1
    end

    test "normalizes domain names (case insensitive)" do
      record = create_a_record("MyHost.Local", {192, 168, 1, 100})
      message = create_dns_message(answers: [record])

      NetworkMonitor.cache_response(message, {192, 168, 1, 100}, 5353)
      :timer.sleep(10)

      assert length(NetworkMonitor.query("myhost.local")) == 1
      assert length(NetworkMonitor.query("MYHOST.LOCAL")) == 1
    end
  end

  describe "get_queries/1" do
    test "returns recent queries" do
      question = create_question("test.local", :A)
      message = create_dns_message(questions: [question], qr: 0)

      NetworkMonitor.log_query(message, {192, 168, 1, 10}, 5353)
      :timer.sleep(10)

      queries = NetworkMonitor.get_queries()
      assert length(queries) == 1
    end

    test "respects limit option" do
      # Log 5 queries
      for i <- 1..5 do
        question = create_question("test#{i}.local", :A)
        message = create_dns_message(questions: [question], qr: 0)
        NetworkMonitor.log_query(message, {192, 168, 1, 10}, 5353)
      end

      :timer.sleep(10)

      queries = NetworkMonitor.get_queries(limit: 3)
      assert length(queries) == 3
    end

    test "sorts by timestamp descending (most recent first)" do
      for i <- 1..3 do
        question = create_question("test#{i}.local", :A)
        message = create_dns_message(questions: [question], qr: 0)
        NetworkMonitor.log_query(message, {192, 168, 1, 10}, 5353)
        :timer.sleep(5)
      end

      :timer.sleep(10)

      queries = NetworkMonitor.get_queries()
      # Most recent should be first
      timestamps = Enum.map(queries, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps, :desc)
    end
  end

  describe "get_unanswered_queries/0" do
    test "returns queries that have not been answered" do
      question = create_question("unanswered.local", :A)
      query_message = create_dns_message(questions: [question], qr: 0)

      NetworkMonitor.log_query(query_message, {192, 168, 1, 10}, 5353)
      :timer.sleep(10)

      unanswered = NetworkMonitor.get_unanswered_queries()
      assert length(unanswered) == 1
      assert hd(unanswered).domain == "unanswered.local"
    end

    test "excludes answered queries" do
      # Log a query
      question = create_question("answered.local", :A)
      query_message = create_dns_message(questions: [question], qr: 0)
      NetworkMonitor.log_query(query_message, {192, 168, 1, 10}, 5353)

      # Answer it
      record = create_a_record("answered.local", {192, 168, 1, 100})
      response_message = create_dns_message(answers: [record])
      NetworkMonitor.cache_response(response_message, {192, 168, 1, 100}, 5353)

      :timer.sleep(10)

      unanswered = NetworkMonitor.get_unanswered_queries()
      assert Enum.empty?(unanswered)
    end
  end

  describe "service discovery" do
    test "discovers service from complete announcement" do
      # Service announcement with PTR, SRV, TXT, A records
      ptr_record = create_ptr_record("_http._tcp.local", "webserver._http._tcp.local")
      srv_record = create_srv_record("webserver._http._tcp.local", "webserver.local", 8080)
      txt_record = create_txt_record("webserver._http._tcp.local", ["path=/api", "version=1.0"])
      a_record = create_a_record("webserver.local", {192, 168, 1, 50})

      message =
        create_dns_message(
          answers: [ptr_record, srv_record, txt_record],
          additional: [a_record]
        )

      NetworkMonitor.cache_response(message, {192, 168, 1, 50}, 5353)
      :timer.sleep(10)

      services = NetworkMonitor.list_discovered_services()
      assert length(services) == 1

      service = hd(services)
      assert service.name == "webserver"
      assert service.type == "_http._tcp.local"
      assert service.host == "webserver.local"
      assert service.port == 8080
      assert service.txt_records == %{"path" => "/api", "version" => "1.0"}
      assert {192, 168, 1, 50} in service.addresses
    end

    test "discovers service from parsed DNS record data structs" do
      ptr_record = %Record{
        name: DNS.Message.Domain.new("_http._tcp.local"),
        type: DNS.ResourceRecordType.new(:ptr),
        class: :IN,
        ttl: 4500,
        data: DNS.Message.Record.Data.PTR.new("webserver._http._tcp.local")
      }

      srv_record = %Record{
        name: DNS.Message.Domain.new("webserver._http._tcp.local"),
        type: DNS.ResourceRecordType.new(:srv),
        class: :IN,
        ttl: 4500,
        data: DNS.Message.Record.Data.SRV.new({0, 0, 8080, "webserver.local"})
      }

      txt_record = %Record{
        name: DNS.Message.Domain.new("webserver._http._tcp.local"),
        type: DNS.ResourceRecordType.new(:txt),
        class: :IN,
        ttl: 4500,
        data: DNS.Message.Record.Data.TXT.new(["path=/api"])
      }

      a_record = %Record{
        name: DNS.Message.Domain.new("webserver.local"),
        type: DNS.ResourceRecordType.new(:a),
        class: :IN,
        ttl: 4500,
        data: DNS.Message.Record.Data.A.new({192, 168, 1, 50})
      }

      message =
        create_dns_message(
          answers: [ptr_record, srv_record, txt_record],
          additional: [a_record]
        )

      NetworkMonitor.cache_response(message, {192, 168, 1, 50}, 5353)
      assert %{} = :sys.get_state(NetworkMonitor)

      assert [
               %{
                 name: "webserver",
                 type: "_http._tcp.local.",
                 host: "webserver.local.",
                 port: 8080,
                 txt_records: %{"path" => "/api"},
                 addresses: [{192, 168, 1, 50}]
               }
             ] = NetworkMonitor.list_discovered_services()
    end

    test "get_discovered_service/1 returns specific service" do
      ptr_record = create_ptr_record("_http._tcp.local", "myservice._http._tcp.local")
      srv_record = create_srv_record("myservice._http._tcp.local", "host.local", 80)

      message = create_dns_message(answers: [ptr_record, srv_record])
      NetworkMonitor.cache_response(message, {192, 168, 1, 10}, 5353)
      :timer.sleep(10)

      service = NetworkMonitor.get_discovered_service("myservice._http._tcp.local")
      assert service != nil
      assert service.name == "myservice"
    end

    test "updates repeated service announcements without duplicating the service row" do
      ptr_record = create_ptr_record("_hap._tcp.local", "Aqara Hub-537B 6._hap._tcp.local")
      srv_record = create_srv_record("Aqara Hub-537B 6._hap._tcp.local", "aqara.local", 4567)
      a_record = create_a_record("aqara.local", {10, 100, 10, 66})

      message = create_dns_message(answers: [ptr_record, srv_record], additional: [a_record])

      NetworkMonitor.cache_response(message, {10, 100, 10, 66}, 5353)
      assert %{} = :sys.get_state(NetworkMonitor)

      NetworkMonitor.cache_response(message, {10, 100, 10, 66}, 5353)
      assert %{} = :sys.get_state(NetworkMonitor)

      NetworkMonitor.cache_response(message, {10, 100, 10, 66}, 5353)
      assert %{} = :sys.get_state(NetworkMonitor)

      assert [
               %{
                 service_id: "Aqara Hub-537B 6._hap._tcp.local",
                 response_count: 3,
                 source_ips: [{10, 100, 10, 66}]
               }
             ] = NetworkMonitor.list_discovered_services()
    end

    test "get_discovered_service/1 returns nil for unknown service" do
      assert NetworkMonitor.get_discovered_service("unknown._http._tcp.local") == nil
    end

    # RFC 6762 §11.3: Goodbye packets (TTL=0) must remove cached records and services
    test "Goodbye PTR (TTL=0) removes the service from the registry" do
      # First announce the service
      ptr = create_ptr_record("_http._tcp.local", "goodbyehost._http._tcp.local")
      srv = create_srv_record("goodbyehost._http._tcp.local", "goodbyehost.local", 80)

      NetworkMonitor.cache_response(
        create_dns_message(answers: [ptr, srv]),
        {192, 168, 1, 99},
        5353
      )

      :timer.sleep(10)

      assert NetworkMonitor.get_discovered_service("goodbyehost._http._tcp.local") != nil

      # Now send a Goodbye (TTL=0 PTR) for the same service instance
      goodbye_ptr = create_ptr_record("_http._tcp.local", "goodbyehost._http._tcp.local", 0)

      NetworkMonitor.cache_response(
        create_dns_message(answers: [goodbye_ptr]),
        {192, 168, 1, 99},
        5353
      )

      :timer.sleep(10)

      assert NetworkMonitor.get_discovered_service("goodbyehost._http._tcp.local") == nil
    end

    test "Goodbye record (TTL=0) removes A record from cache" do
      # First cache an A record
      a_record = create_a_record("goodbye.local", {10, 0, 0, 1})
      NetworkMonitor.cache_response(create_dns_message(answers: [a_record]), {10, 0, 0, 1}, 5353)
      :timer.sleep(10)

      assert NetworkMonitor.query("goodbye.local") != []

      # Send Goodbye (TTL=0) for same record
      goodbye_a = create_a_record("goodbye.local", {10, 0, 0, 1}, 0)
      NetworkMonitor.cache_response(create_dns_message(answers: [goodbye_a]), {10, 0, 0, 1}, 5353)
      :timer.sleep(10)

      assert NetworkMonitor.query("goodbye.local") == []
    end

    test "search_services/1 filters by type" do
      # Add HTTP service
      http_ptr = create_ptr_record("_http._tcp.local", "web._http._tcp.local")
      http_srv = create_srv_record("web._http._tcp.local", "web.local", 80)
      http_msg = create_dns_message(answers: [http_ptr, http_srv])
      NetworkMonitor.cache_response(http_msg, {192, 168, 1, 10}, 5353)

      # Add SSH service
      ssh_ptr = create_ptr_record("_ssh._tcp.local", "server._ssh._tcp.local")
      ssh_srv = create_srv_record("server._ssh._tcp.local", "server.local", 22)
      ssh_msg = create_dns_message(answers: [ssh_ptr, ssh_srv])
      NetworkMonitor.cache_response(ssh_msg, {192, 168, 1, 20}, 5353)

      :timer.sleep(10)

      # All services
      all = NetworkMonitor.search_services()
      assert length(all) == 2

      # Only HTTP
      http = NetworkMonitor.search_services(type: "_http._tcp.local")
      assert length(http) == 1
      assert hd(http).type == "_http._tcp.local"

      # Only SSH
      ssh = NetworkMonitor.search_services(type: "_ssh._tcp.local")
      assert length(ssh) == 1
      assert hd(ssh).type == "_ssh._tcp.local"
    end
  end

  describe "network_stats/0" do
    test "returns zero counts when empty" do
      stats = NetworkMonitor.network_stats()

      assert stats.total_responses == 0
      assert stats.total_queries == 0
      assert stats.active_services == 0
      assert stats.unique_hosts == 0
    end

    test "counts responses and queries" do
      # Add some queries
      for i <- 1..3 do
        question = create_question("test#{i}.local", :A)
        message = create_dns_message(questions: [question], qr: 0)
        NetworkMonitor.log_query(message, {192, 168, 1, i}, 5353)
      end

      # Add some responses
      for i <- 1..2 do
        record = create_a_record("host#{i}.local", {192, 168, 1, 100 + i})
        message = create_dns_message(answers: [record])
        NetworkMonitor.cache_response(message, {192, 168, 1, 100 + i}, 5353)
      end

      :timer.sleep(10)

      stats = NetworkMonitor.network_stats()
      assert stats.total_queries == 3
      assert stats.total_responses == 2
      assert stats.unique_hosts == 2
    end

    test "calculates queries per minute" do
      stats = NetworkMonitor.network_stats()
      assert is_float(stats.queries_per_minute)
    end

    test "tracks most queried services" do
      # Query same domain multiple times from different sources
      # Note: ETS :bag deduplicates identical tuples, so we use different source IPs
      # to make each entry unique. This mimics real-world behavior where queries
      # come from different clients or at different times.
      for i <- 1..5 do
        question = create_question("popular.local", :A)
        message = create_dns_message(questions: [question], qr: 0)
        NetworkMonitor.log_query(message, {192, 168, 1, i}, 5353)
      end

      # Query different domain once
      question = create_question("other.local", :A)
      message = create_dns_message(questions: [question], qr: 0)
      NetworkMonitor.log_query(message, {192, 168, 1, 20}, 5353)

      :timer.sleep(10)

      stats = NetworkMonitor.network_stats()
      assert length(stats.most_queried_services) > 0

      # Find the popular.local entry
      popular = Enum.find(stats.most_queried_services, fn s -> s.domain == "popular.local" end)
      assert popular != nil
      assert popular.count == 5

      # And the other.local entry
      other = Enum.find(stats.most_queried_services, fn s -> s.domain == "other.local" end)
      assert other != nil
      assert other.count == 1
    end
  end

  describe "list_all/0 and stats/0 (legacy API)" do
    test "list_all returns all cached responses" do
      record1 = create_a_record("host1.local", {192, 168, 1, 1})
      record2 = create_a_record("host2.local", {192, 168, 1, 2})

      msg1 = create_dns_message(answers: [record1])
      msg2 = create_dns_message(answers: [record2])

      NetworkMonitor.cache_response(msg1, {192, 168, 1, 1}, 5353)
      NetworkMonitor.cache_response(msg2, {192, 168, 1, 2}, 5353)
      :timer.sleep(10)

      all = NetworkMonitor.list_all()
      assert length(all) == 2
    end

    test "stats returns cache statistics" do
      record = create_a_record("stat.local", {192, 168, 1, 1})
      message = create_dns_message(answers: [record])

      NetworkMonitor.cache_response(message, {192, 168, 1, 1}, 5353)
      :timer.sleep(10)

      stats = NetworkMonitor.stats()
      assert stats.total_entries == 1
      assert stats.active_entries == 1
      assert stats.expired_entries == 0
    end
  end

  describe "clear/0" do
    test "removes all entries" do
      # Add query
      question = create_question("test.local", :A)
      query_msg = create_dns_message(questions: [question], qr: 0)
      NetworkMonitor.log_query(query_msg, {192, 168, 1, 10}, 5353)

      # Add response
      record = create_a_record("test.local", {192, 168, 1, 100})
      response_msg = create_dns_message(answers: [record])
      NetworkMonitor.cache_response(response_msg, {192, 168, 1, 100}, 5353)

      # Add service
      ptr = create_ptr_record("_http._tcp.local", "web._http._tcp.local")
      srv = create_srv_record("web._http._tcp.local", "web.local", 80)
      service_msg = create_dns_message(answers: [ptr, srv])
      NetworkMonitor.cache_response(service_msg, {192, 168, 1, 50}, 5353)

      :timer.sleep(10)

      # Verify data exists
      assert length(NetworkMonitor.get_queries()) > 0
      assert length(NetworkMonitor.list_all()) > 0
      assert length(NetworkMonitor.list_discovered_services()) > 0

      # Clear
      assert :ok = NetworkMonitor.clear()

      # Verify empty
      assert NetworkMonitor.get_queries() == []
      assert NetworkMonitor.list_all() == []
      assert NetworkMonitor.list_discovered_services() == []
    end
  end

  describe "query answering" do
    test "marks queries as answered when response arrives" do
      # Log query
      question = create_question("tobeANSWERED.local", :A)
      query_msg = create_dns_message(questions: [question], qr: 0)
      NetworkMonitor.log_query(query_msg, {192, 168, 1, 10}, 5353)
      :timer.sleep(10)

      # Verify unanswered
      assert length(NetworkMonitor.get_unanswered_queries()) == 1

      # Send response
      record = create_a_record("tobeanswered.local", {192, 168, 1, 100})
      response_msg = create_dns_message(answers: [record])
      NetworkMonitor.cache_response(response_msg, {192, 168, 1, 100}, 5353)
      :timer.sleep(10)

      # Should be marked answered
      assert NetworkMonitor.get_unanswered_queries() == []
    end

    test "marks ANY type queries as answered by any response" do
      # Log ANY query
      question = create_question("any.local", :ANY)
      query_msg = create_dns_message(questions: [question], qr: 0)
      NetworkMonitor.log_query(query_msg, {192, 168, 1, 10}, 5353)
      :timer.sleep(10)

      # Verify unanswered
      assert length(NetworkMonitor.get_unanswered_queries()) == 1

      # Send A record response
      record = create_a_record("any.local", {192, 168, 1, 100})
      response_msg = create_dns_message(answers: [record])
      NetworkMonitor.cache_response(response_msg, {192, 168, 1, 100}, 5353)
      :timer.sleep(10)

      # Should be marked answered since it was ANY query
      assert NetworkMonitor.get_unanswered_queries() == []
    end
  end
end
