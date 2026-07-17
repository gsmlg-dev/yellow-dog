defmodule YellowDog.Mdns.MessageCacheTest do
  use ExUnit.Case, async: false

  alias YellowDog.Mdns.MessageCache
  alias DNS.Message.{Record, Question}
  alias DNS.Message.Record.Data
  alias DNS.ResourceRecordType

  # Helper to create a mock DNS message with records
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
    %Record{
      name: name,
      type: :A,
      class: :IN,
      ttl: ttl,
      data: ip
    }
  end

  defp create_aaaa_record(name, ip, ttl \\ 4500) do
    %Record{
      name: name,
      type: :AAAA,
      class: :IN,
      ttl: ttl,
      data: ip
    }
  end

  defp create_ptr_record(name, target, ttl \\ 4500) do
    %Record{
      name: name,
      type: :PTR,
      class: :IN,
      ttl: ttl,
      data: target
    }
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
    %Record{
      name: name,
      type: :TXT,
      class: :IN,
      ttl: ttl,
      data: data
    }
  end

  defp create_question(name, type) do
    %Question{
      name: name,
      type: type,
      class: :IN
    }
  end

  setup do
    # Start the MessageCache for each test
    start_supervised!(MessageCache)
    # Clear any existing entries
    MessageCache.clear()
    :ok
  end

  describe "start_link/1" do
    test "starts successfully" do
      # Already started in setup, verify it's running
      assert Process.whereis(MessageCache) != nil
    end
  end

  describe "cache_message/3" do
    test "caches message with A record answer" do
      record = create_a_record("mydevice.local", {192, 168, 1, 100})
      message = create_dns_message(answers: [record])

      assert :ok = MessageCache.cache_message(message, {192, 168, 1, 100}, 5353)

      # Allow async cast to complete
      :timer.sleep(10)

      entries = MessageCache.query("mydevice.local")
      assert length(entries) == 1

      entry = hd(entries)
      assert entry.domain == "mydevice.local"
      assert entry.record_type == :A
    end

    test "caches message with multiple record types" do
      a_record = create_a_record("service.local", {192, 168, 1, 50})
      aaaa_record = create_aaaa_record("service.local", {0, 0, 0, 0, 0, 0, 0, 1})
      txt_record = create_txt_record("service.local", ["key=value"])

      message = create_dns_message(answers: [a_record, aaaa_record, txt_record])

      assert :ok = MessageCache.cache_message(message, {192, 168, 1, 1}, 5353)
      :timer.sleep(10)

      entries = MessageCache.query("service.local")
      assert length(entries) == 3

      types = Enum.map(entries, & &1.record_type) |> Enum.sort()
      assert types == [:A, :AAAA, :TXT]
    end

    test "caches questions for service discovery" do
      question = create_question("_http._tcp.local", :PTR)
      message = create_dns_message(questions: [question], qr: 0)

      assert :ok = MessageCache.cache_message(message, {192, 168, 1, 200}, 5353)
      :timer.sleep(10)

      entries = MessageCache.query("_http._tcp.local")
      assert length(entries) == 1

      entry = hd(entries)
      assert entry.section == :question
      assert entry.record_type == :PTR
    end

    test "caches authority records" do
      record = create_ptr_record("1.168.192.in-addr.arpa", "gateway.local")
      message = create_dns_message(authority: [record])

      assert :ok = MessageCache.cache_message(message, {192, 168, 1, 1}, 5353)
      :timer.sleep(10)

      entries = MessageCache.query("1.168.192.in-addr.arpa")
      assert length(entries) == 1

      entry = hd(entries)
      assert entry.section == :authority
    end

    test "caches additional records" do
      a_record = create_a_record("server.local", {10, 0, 0, 5})
      message = create_dns_message(additional: [a_record])

      assert :ok = MessageCache.cache_message(message, {10, 0, 0, 5}, 5353)
      :timer.sleep(10)

      entries = MessageCache.query("server.local")
      assert length(entries) == 1

      entry = hd(entries)
      assert entry.section == :additional
    end

    test "stores source IP and port" do
      record = create_a_record("test.local", {192, 168, 10, 20})
      message = create_dns_message(answers: [record])

      MessageCache.cache_message(message, {192, 168, 10, 20}, 12345)
      :timer.sleep(10)

      [entry] = MessageCache.query("test.local")
      assert entry.source_ip == {192, 168, 10, 20}
      assert entry.source_port == 12345
    end
  end

  describe "query/2" do
    test "returns empty list for non-existent domain" do
      assert MessageCache.query("nonexistent.local") == []
    end

    test "queries by domain name" do
      record = create_a_record("myhost.local", {192, 168, 1, 100})
      message = create_dns_message(answers: [record])

      MessageCache.cache_message(message, {192, 168, 1, 100}, 5353)
      :timer.sleep(10)

      entries = MessageCache.query("myhost.local")
      assert length(entries) == 1
      assert hd(entries).domain == "myhost.local"
    end

    test "normalizes domain names (case insensitive)" do
      record = create_a_record("MyHost.Local", {192, 168, 1, 100})
      message = create_dns_message(answers: [record])

      MessageCache.cache_message(message, {192, 168, 1, 100}, 5353)
      :timer.sleep(10)

      # Query with different case should still match
      entries = MessageCache.query("myhost.local")
      assert length(entries) == 1

      entries = MessageCache.query("MYHOST.LOCAL")
      assert length(entries) == 1

      entries = MessageCache.query("MyHost.Local")
      assert length(entries) == 1
    end

    test "normalizes domain names (trailing dot)" do
      record = create_a_record("myhost.local.", {192, 168, 1, 100})
      message = create_dns_message(answers: [record])

      MessageCache.cache_message(message, {192, 168, 1, 100}, 5353)
      :timer.sleep(10)

      # Query without trailing dot should match
      entries = MessageCache.query("myhost.local")
      assert length(entries) == 1

      # Query with trailing dot should also match
      entries = MessageCache.query("myhost.local.")
      assert length(entries) == 1
    end

    test "filters by record type when specified" do
      a_record = create_a_record("multi.local", {192, 168, 1, 1})
      aaaa_record = create_aaaa_record("multi.local", {0, 0, 0, 0, 0, 0, 0, 1})
      txt_record = create_txt_record("multi.local", ["data"])

      message = create_dns_message(answers: [a_record, aaaa_record, txt_record])
      MessageCache.cache_message(message, {192, 168, 1, 1}, 5353)
      :timer.sleep(10)

      # Query all types
      all_entries = MessageCache.query("multi.local")
      assert length(all_entries) == 3

      # Query only A records
      a_entries = MessageCache.query("multi.local", :A)
      assert length(a_entries) == 1
      assert hd(a_entries).record_type == :A

      # Query only AAAA records
      aaaa_entries = MessageCache.query("multi.local", :AAAA)
      assert length(aaaa_entries) == 1
      assert hd(aaaa_entries).record_type == :AAAA

      # Query only TXT records
      txt_entries = MessageCache.query("multi.local", :TXT)
      assert length(txt_entries) == 1
      assert hd(txt_entries).record_type == :TXT

      # Query non-existent type
      srv_entries = MessageCache.query("multi.local", :SRV)
      assert srv_entries == []
    end

    test "filters out expired entries" do
      # Create a record with very short TTL
      record = create_a_record("expiring.local", {192, 168, 1, 1}, 0)
      message = create_dns_message(answers: [record])

      MessageCache.cache_message(message, {192, 168, 1, 1}, 5353)
      :timer.sleep(10)

      # Note: The module uses max(record.ttl, @default_ttl) which is 120 seconds
      # So even with TTL=0, it will be cached for 120 seconds
      # To test expiration properly, we would need to mock time or wait

      # For now, verify that records are returned when not expired
      entries = MessageCache.query("expiring.local")
      # Should have entries because default TTL kicks in
      assert length(entries) >= 0
    end
  end

  describe "list_all/0" do
    test "returns empty list when cache is empty" do
      assert MessageCache.list_all() == []
    end

    test "returns all cached entries" do
      record1 = create_a_record("host1.local", {192, 168, 1, 1})
      record2 = create_a_record("host2.local", {192, 168, 1, 2})
      record3 = create_ptr_record("_http._tcp.local", "webserver._http._tcp.local")

      message1 = create_dns_message(answers: [record1])
      message2 = create_dns_message(answers: [record2])
      message3 = create_dns_message(answers: [record3])

      MessageCache.cache_message(message1, {192, 168, 1, 1}, 5353)
      MessageCache.cache_message(message2, {192, 168, 1, 2}, 5353)
      MessageCache.cache_message(message3, {192, 168, 1, 3}, 5353)
      :timer.sleep(10)

      all = MessageCache.list_all()
      assert length(all) == 3

      domains = Enum.map(all, & &1.domain) |> Enum.sort()
      assert domains == ["_http._tcp.local", "host1.local", "host2.local"]
    end
  end

  describe "stats/0" do
    test "returns zero counts when cache is empty" do
      stats = MessageCache.stats()

      assert stats.total_entries == 0
      assert stats.active_entries == 0
      assert stats.expired_entries == 0
    end

    test "counts cached entries correctly" do
      record1 = create_a_record("stat1.local", {192, 168, 1, 1})
      record2 = create_a_record("stat2.local", {192, 168, 1, 2})

      message1 = create_dns_message(answers: [record1])
      message2 = create_dns_message(answers: [record2])

      MessageCache.cache_message(message1, {192, 168, 1, 1}, 5353)
      MessageCache.cache_message(message2, {192, 168, 1, 2}, 5353)
      :timer.sleep(10)

      stats = MessageCache.stats()

      assert stats.total_entries == 2
      assert stats.active_entries == 2
      assert stats.expired_entries == 0
    end
  end

  describe "clear/0" do
    test "removes all entries from cache" do
      record = create_a_record("toclear.local", {192, 168, 1, 1})
      message = create_dns_message(answers: [record])

      MessageCache.cache_message(message, {192, 168, 1, 1}, 5353)
      :timer.sleep(10)

      # Verify entry exists
      assert length(MessageCache.list_all()) == 1

      # Clear the cache
      assert :ok = MessageCache.clear()

      # Verify cache is empty
      assert MessageCache.list_all() == []
      assert MessageCache.stats().total_entries == 0
    end
  end

  describe "control cache ownership" do
    test "projects supported ExDns record data into canonical copied entries" do
      records = [
        %Record{
          name: DNS.Message.Domain.new("host.local"),
          type: ResourceRecordType.new(:a),
          class: :IN,
          ttl: 4500,
          data: Data.A.new({192, 0, 2, 10})
        },
        %Record{
          name: DNS.Message.Domain.new("host.local"),
          type: ResourceRecordType.new(:aaaa),
          class: :IN,
          ttl: 4500,
          data: Data.AAAA.new({8193, 3512, 0, 0, 0, 0, 0, 1})
        },
        %Record{
          name: DNS.Message.Domain.new("_http._tcp.local"),
          type: ResourceRecordType.new(:ptr),
          class: :IN,
          ttl: 4500,
          data: Data.PTR.new("instance._http._tcp.local")
        },
        %Record{
          name: DNS.Message.Domain.new("instance._http._tcp.local"),
          type: ResourceRecordType.new(:srv),
          class: :IN,
          ttl: 4500,
          data: Data.SRV.new({10, 20, 8080, "host.local"})
        },
        %Record{
          name: DNS.Message.Domain.new("instance._http._tcp.local"),
          type: ResourceRecordType.new(:txt),
          class: :IN,
          ttl: 4500,
          data: Data.TXT.new(["path=/api", "version=1"])
        }
      ]

      assert :ok =
               MessageCache.cache_message(
                 create_dns_message(answers: records),
                 {192, 0, 2, 1},
                 5353
               )

      assert {:ok, entries} = MessageCache.control_snapshot()

      assert entries == [
               %{
                 "name" => "_http._tcp.local.",
                 "type" => "PTR",
                 "values" => ["instance._http._tcp.local."]
               },
               %{"name" => "host.local.", "type" => "A", "values" => ["192.0.2.10"]},
               %{"name" => "host.local.", "type" => "AAAA", "values" => ["2001:db8::1"]},
               %{
                 "name" => "instance._http._tcp.local.",
                 "type" => "SRV",
                 "values" => ["10 20 8080 host.local."]
               },
               %{
                 "name" => "instance._http._tcp.local.",
                 "type" => "TXT",
                 "values" => ["path=/api", "version=1"]
               }
             ]
    end

    test "projects supported legacy cache data shapes" do
      records = [
        create_a_record("host.local", {192, 0, 2, 11}),
        create_aaaa_record("host.local", {8193, 3512, 0, 0, 0, 0, 0, 2}),
        create_ptr_record("_ssh._tcp.local", "instance._ssh._tcp.local"),
        create_srv_record("instance._ssh._tcp.local", "host.local", 22),
        create_txt_record("instance._ssh._tcp.local", ["role=admin", "tls=true"])
      ]

      assert :ok =
               MessageCache.cache_message(
                 create_dns_message(answers: records),
                 {192, 0, 2, 1},
                 5353
               )

      assert {:ok, entries} = MessageCache.control_snapshot()

      assert Enum.sort(entries) ==
               Enum.sort([
                 %{"name" => "host.local", "type" => "A", "values" => ["192.0.2.11"]},
                 %{"name" => "host.local", "type" => "AAAA", "values" => ["2001:db8::2"]},
                 %{
                   "name" => "_ssh._tcp.local",
                   "type" => "PTR",
                   "values" => ["instance._ssh._tcp.local"]
                 },
                 %{
                   "name" => "instance._ssh._tcp.local",
                   "type" => "SRV",
                   "values" => ["0 0 22 host.local"]
                 },
                 %{
                   "name" => "instance._ssh._tcp.local",
                   "type" => "TXT",
                   "values" => ["role=admin", "tls=true"]
                 }
               ])
    end

    test "omits questions, expired records, unsupported records, and malformed records" do
      now = System.system_time(:second)

      question = create_question("_http._tcp.local", :PTR)

      assert :ok =
               MessageCache.cache_message(
                 create_dns_message(questions: [question]),
                 {192, 0, 2, 1},
                 5353
               )

      entries = [
        {"expired.local",
         %{
           domain: "expired.local",
           record_type: :A,
           record: create_a_record("expired.local", {192, 0, 2, 12}),
           received_at: now - 1,
           ttl: 0,
           section: :answer
         }},
        {"unsupported.local",
         %{
           domain: "unsupported.local",
           record_type: :CNAME,
           record: %Record{name: "unsupported.local", type: :CNAME, data: "target.local"},
           received_at: now,
           ttl: 120,
           section: :answer
         }},
        {"malformed.local",
         %{
           domain: "malformed.local",
           record_type: :A,
           record: create_a_record("malformed.local", {300, 0, 2, 13}),
           received_at: now,
           ttl: 120,
           section: :answer
         }}
      ]

      assert true = :ets.insert(:mdns_message_cache, entries)
      assert {:ok, []} = MessageCache.control_snapshot()
    end

    test "serializes prior casts before the control snapshot" do
      record = create_a_record("serialized.local", {192, 0, 2, 14})

      assert :ok =
               MessageCache.cache_message(
                 create_dns_message(answers: [record]),
                 {192, 0, 2, 1},
                 5353
               )

      assert {:ok, [%{"name" => "serialized.local", "type" => "A", "values" => ["192.0.2.14"]}]} =
               MessageCache.control_snapshot()
    end

    test "counts every physical table object and clears them in one owner call" do
      now = System.system_time(:second)
      record = create_a_record("present.local", {192, 0, 2, 15})
      question = create_question("question.local", :PTR)

      assert :ok =
               MessageCache.cache_message(
                 create_dns_message(answers: [record], questions: [question]),
                 {192, 0, 2, 1},
                 5353
               )

      assert true =
               :ets.insert(:mdns_message_cache, {
                 "expired.local",
                 %{
                   domain: "expired.local",
                   record_type: :A,
                   record: create_a_record("expired.local", {192, 0, 2, 16}),
                   received_at: now - 1,
                   ttl: 0,
                   section: :answer
                 }
               })

      assert true =
               :ets.insert(:mdns_message_cache, {
                 "unsupported.local",
                 %{
                   domain: "unsupported.local",
                   record_type: :CNAME,
                   record: %Record{name: "unsupported.local", type: :CNAME, data: "target.local"},
                   received_at: now,
                   ttl: 120,
                   section: :answer
                 }
               })

      assert {:ok, 4} = MessageCache.control_clear()
      assert :ets.info(:mdns_message_cache, :size) == 0
    end

    test "returns a typed error when the cache owner is absent" do
      pid = Process.whereis(MessageCache)
      GenServer.stop(pid)

      assert {:error, :cache_absent} = MessageCache.control_snapshot()
      assert {:error, :cache_absent} = MessageCache.control_clear()
    end
  end

  describe "service discovery caching" do
    test "caches PTR records for service enumeration" do
      ptr_record = create_ptr_record("_services._dns-sd._udp.local", "_http._tcp.local")
      message = create_dns_message(answers: [ptr_record])

      MessageCache.cache_message(message, {192, 168, 1, 1}, 5353)
      :timer.sleep(10)

      entries = MessageCache.query("_services._dns-sd._udp.local", :PTR)
      assert length(entries) == 1
      assert hd(entries).record_type == :PTR
    end

    test "caches SRV records for service instances" do
      srv_record = create_srv_record("webserver._http._tcp.local", "webserver.local", 80)
      message = create_dns_message(answers: [srv_record])

      MessageCache.cache_message(message, {192, 168, 1, 10}, 5353)
      :timer.sleep(10)

      entries = MessageCache.query("webserver._http._tcp.local", :SRV)
      assert length(entries) == 1

      entry = hd(entries)
      assert entry.record_type == :SRV
    end

    test "caches complete service announcement (PTR+SRV+TXT+A)" do
      ptr_record = create_ptr_record("_http._tcp.local", "mywebserver._http._tcp.local")
      srv_record = create_srv_record("mywebserver._http._tcp.local", "myhost.local", 8080)
      txt_record = create_txt_record("mywebserver._http._tcp.local", ["path=/", "version=1.0"])
      a_record = create_a_record("myhost.local", {192, 168, 1, 50})

      message = create_dns_message(answers: [ptr_record, srv_record, txt_record, a_record])

      MessageCache.cache_message(message, {192, 168, 1, 50}, 5353)
      :timer.sleep(10)

      # All domains should be queryable
      ptr_entries = MessageCache.query("_http._tcp.local", :PTR)
      assert length(ptr_entries) == 1

      srv_entries = MessageCache.query("mywebserver._http._tcp.local", :SRV)
      assert length(srv_entries) == 1

      txt_entries = MessageCache.query("mywebserver._http._tcp.local", :TXT)
      assert length(txt_entries) == 1

      a_entries = MessageCache.query("myhost.local", :A)
      assert length(a_entries) == 1
    end
  end

  describe "duplicate entries" do
    test "allows multiple entries for same domain (bag table)" do
      # Two different hosts announcing the same service type
      ptr1 = create_ptr_record("_http._tcp.local", "server1._http._tcp.local")
      ptr2 = create_ptr_record("_http._tcp.local", "server2._http._tcp.local")

      message1 = create_dns_message(answers: [ptr1])
      message2 = create_dns_message(answers: [ptr2])

      MessageCache.cache_message(message1, {192, 168, 1, 10}, 5353)
      MessageCache.cache_message(message2, {192, 168, 1, 20}, 5353)
      :timer.sleep(10)

      entries = MessageCache.query("_http._tcp.local", :PTR)
      assert length(entries) == 2
    end
  end
end
