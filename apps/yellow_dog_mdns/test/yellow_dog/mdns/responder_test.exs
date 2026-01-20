defmodule YellowDog.Mdns.ResponderTest do
  use ExUnit.Case, async: true

  alias YellowDog.Mdns.Responder
  alias DNS.Message
  alias DNS.Message.{Header, Question, Record}

  # Test service fixtures
  # Note: RecordBuilder expects:
  # - addresses: list of both IPv4 and IPv6 tuples
  # - priority, weight: for SRV record data
  @http_service %{
    id: "web-server-1",
    name: "My Web Server",
    type: "_http._tcp",
    domain: "local",
    host: "myhost.local",
    port: 8080,
    fqdn: "My Web Server._http._tcp.local",
    addresses: [{192, 168, 1, 100}, {0xFE80, 0, 0, 0, 0, 0, 0, 1}],
    txt_records: %{"path" => "/", "version" => "1.0"},
    ttl: 4500,
    priority: 0,
    weight: 0
  }

  @ssh_service %{
    id: "ssh-server-1",
    name: "SSH Server",
    type: "_ssh._tcp",
    domain: "local",
    host: "server.local",
    port: 22,
    fqdn: "SSH Server._ssh._tcp.local",
    addresses: [{10, 0, 0, 5}],
    txt_records: %{},
    ttl: 4500,
    priority: 0,
    weight: 0
  }

  # Helper to create a query message
  defp create_query(questions) do
    %Message{
      header: %Header{
        id: :rand.uniform(65535),
        qr: 0,
        opcode: 0,
        aa: 0,
        tc: 0,
        rd: 0,
        ra: 0,
        z: 0,
        rcode: 0,
        qdcount: length(questions),
        ancount: 0,
        nscount: 0,
        arcount: 0
      },
      qdlist: questions,
      anlist: [],
      nslist: [],
      arlist: []
    }
  end

  defp create_question(name, type) do
    %Question{name: name, type: type, class: :IN}
  end

  defp create_record(name, type, data, ttl \\ 4500) do
    %Record{name: name, type: type, class: :IN, ttl: ttl, data: data}
  end

  describe "should_respond?/2" do
    test "returns false with empty services list" do
      query = create_query([create_question("_http._tcp.local", :PTR)])
      refute Responder.should_respond?(query, [])
    end

    test "returns true when services match and no known answers" do
      query = create_query([create_question("_http._tcp.local", :PTR)])
      assert Responder.should_respond?(query, [@http_service])
    end

    test "returns false when query has known answers with sufficient TTL" do
      # Create a query with a known answer
      ptr_record =
        create_record(
          "_http._tcp.local",
          :PTR,
          "My Web Server._http._tcp.local",
          3000
        )

      query = %{
        create_query([create_question("_http._tcp.local", :PTR)])
        | anlist: [ptr_record]
      }

      refute Responder.should_respond?(query, [@http_service])
    end

    test "returns true when known answer TTL is less than half of our TTL" do
      # Known answer with very low TTL (less than half of 4500)
      ptr_record =
        create_record(
          "_http._tcp.local",
          :PTR,
          "My Web Server._http._tcp.local",
          # Less than 4500/2 = 2250
          1000
        )

      query = %{
        create_query([create_question("_http._tcp.local", :PTR)])
        | anlist: [ptr_record]
      }

      assert Responder.should_respond?(query, [@http_service])
    end
  end

  describe "build_response/2" do
    test "builds response with correct header flags" do
      query = create_query([create_question("_http._tcp.local", :PTR)])
      response = Responder.build_response(query, [@http_service])

      assert response.header.qr == 1
      assert response.header.aa == 1
      assert response.header.tc == 0
      assert response.header.rd == 0
      assert response.header.ra == 0
      assert response.header.rcode == 0
    end

    test "echoes query ID in response" do
      query = create_query([create_question("_http._tcp.local", :PTR)])
      response = Responder.build_response(query, [@http_service])

      assert response.header.id == query.header.id
    end

    test "echoes questions in response" do
      questions = [create_question("_http._tcp.local", :PTR)]
      query = create_query(questions)
      response = Responder.build_response(query, [@http_service])

      assert response.qdlist == questions
    end

    test "includes answer records" do
      query = create_query([create_question("_http._tcp.local", :PTR)])
      response = Responder.build_response(query, [@http_service])

      assert length(response.anlist) > 0
    end

    test "deduplicates records" do
      # Query both services but they might produce duplicate host records
      query =
        create_query([
          create_question("_http._tcp.local", :PTR),
          create_question("_ssh._tcp.local", :PTR)
        ])

      response = Responder.build_response(query, [@http_service, @ssh_service])

      # Check no duplicate records by name+type combination
      unique_pairs =
        (response.anlist ++ response.arlist)
        |> Enum.map(fn r -> {String.downcase(to_string(r.name)), r.type} end)
        |> Enum.uniq()

      total_records = length(response.anlist) + length(response.arlist)
      assert length(unique_pairs) == total_records
    end

    test "has empty authority section for mDNS" do
      query = create_query([create_question("_http._tcp.local", :PTR)])
      response = Responder.build_response(query, [@http_service])

      assert response.nslist == []
    end
  end

  describe "calculate_response_delay/1" do
    test "returns value between 20 and 120 ms" do
      delay = Responder.calculate_response_delay([@http_service])
      assert delay >= 20
      assert delay <= 120
    end

    test "returns different values on multiple calls (randomness)" do
      delays = for _ <- 1..100, do: Responder.calculate_response_delay([@http_service])
      unique_delays = Enum.uniq(delays)

      # Should have multiple unique values if random
      assert length(unique_delays) > 1
    end
  end

  describe "has_known_answers?/2" do
    test "returns false when query has no answers" do
      query = create_query([create_question("_http._tcp.local", :PTR)])
      refute Responder.has_known_answers?(query, [@http_service])
    end

    test "returns true when query contains matching PTR record with sufficient TTL" do
      ptr_record =
        create_record(
          "_http._tcp.local",
          :PTR,
          "My Web Server._http._tcp.local",
          3000
        )

      query = %{
        create_query([create_question("_http._tcp.local", :PTR)])
        | anlist: [ptr_record]
      }

      assert Responder.has_known_answers?(query, [@http_service])
    end

    test "returns false when known answer has low TTL" do
      ptr_record =
        create_record(
          "_http._tcp.local",
          :PTR,
          "My Web Server._http._tcp.local",
          # Very low TTL
          100
        )

      query = %{
        create_query([create_question("_http._tcp.local", :PTR)])
        | anlist: [ptr_record]
      }

      refute Responder.has_known_answers?(query, [@http_service])
    end

    test "returns false when known answer does not match our records" do
      # Different service name
      ptr_record =
        create_record(
          "_http._tcp.local",
          :PTR,
          "Other Service._http._tcp.local",
          4000
        )

      query = %{
        create_query([create_question("_http._tcp.local", :PTR)])
        | anlist: [ptr_record]
      }

      refute Responder.has_known_answers?(query, [@http_service])
    end
  end

  describe "validate_response_size/1" do
    test "returns {:ok, message} for small response" do
      query = create_query([create_question("_http._tcp.local", :PTR)])
      response = Responder.build_response(query, [@http_service])

      assert {:ok, ^response} = Responder.validate_response_size(response)
    end

    test "returns {:error, :too_large, size} for oversized response" do
      # Create a message with many large records
      large_records =
        for i <- 1..100 do
          create_record(
            "very-long-service-name-#{i}._http._tcp.local",
            :TXT,
            ["key1=value1", "key2=value2", "key3=value3", "key4=value4"]
          )
        end

      oversized_message = %Message{
        header: %Header{
          id: 12345,
          qr: 1,
          aa: 1,
          rcode: 0
        },
        qdlist: [],
        anlist: large_records,
        nslist: [],
        arlist: []
      }

      assert {:error, :too_large, size} = Responder.validate_response_size(oversized_message)
      assert size > 1232
    end
  end

  describe "filter_answerable_questions/2" do
    test "returns empty list when no questions" do
      result = Responder.filter_answerable_questions([], [@http_service])
      assert result == []
    end

    test "returns empty list when no services" do
      questions = [create_question("_http._tcp.local", :PTR)]
      result = Responder.filter_answerable_questions(questions, [])
      assert result == []
    end

    test "filters questions with matching PTR queries" do
      questions = [create_question("_http._tcp.local", :PTR)]
      result = Responder.filter_answerable_questions(questions, [@http_service])

      assert length(result) == 1
      {question, services} = hd(result)
      assert question.name == "_http._tcp.local"
      assert length(services) == 1
    end

    test "filters out questions with no matching services" do
      questions = [
        create_question("_http._tcp.local", :PTR),
        create_question("_unknown._tcp.local", :PTR)
      ]

      result = Responder.filter_answerable_questions(questions, [@http_service])

      # Only one question should match
      assert length(result) == 1
      {question, _services} = hd(result)
      assert question.name == "_http._tcp.local"
    end

    test "matches SRV queries for service instance" do
      questions = [create_question("My Web Server._http._tcp.local", :SRV)]
      result = Responder.filter_answerable_questions(questions, [@http_service])

      assert length(result) == 1
    end

    test "matches TXT queries for service instance" do
      questions = [create_question("My Web Server._http._tcp.local", :TXT)]
      result = Responder.filter_answerable_questions(questions, [@http_service])

      assert length(result) == 1
    end

    test "matches A queries for host" do
      questions = [create_question("myhost.local", :A)]
      result = Responder.filter_answerable_questions(questions, [@http_service])

      assert length(result) == 1
    end

    test "matches AAAA queries for host" do
      questions = [create_question("myhost.local", :AAAA)]
      result = Responder.filter_answerable_questions(questions, [@http_service])

      assert length(result) == 1
    end

    test "matches ANY queries" do
      questions = [create_question("My Web Server._http._tcp.local", :ANY)]
      result = Responder.filter_answerable_questions(questions, [@http_service])

      assert length(result) == 1
    end

    test "handles case-insensitive matching" do
      questions = [create_question("_HTTP._TCP.LOCAL", :PTR)]
      result = Responder.filter_answerable_questions(questions, [@http_service])

      assert length(result) == 1
    end

    test "handles multiple services matching same question" do
      # Create two HTTP services
      http_service2 = %{
        @http_service
        | id: "web-server-2",
          name: "Another Web Server",
          fqdn: "Another Web Server._http._tcp.local"
      }

      questions = [create_question("_http._tcp.local", :PTR)]
      result = Responder.filter_answerable_questions(questions, [@http_service, http_service2])

      assert length(result) == 1
      {_question, services} = hd(result)
      assert length(services) == 2
    end
  end

  describe "edge cases" do
    test "handles service with no IPv4 addresses" do
      # IPv6-only addresses
      ipv6_only_service = %{@http_service | addresses: [{0xFE80, 0, 0, 0, 0, 0, 0, 1}]}

      query = create_query([create_question("_http._tcp.local", :PTR)])
      response = Responder.build_response(query, [ipv6_only_service])

      # Should still build a valid response
      assert response.header.qr == 1
    end

    test "handles service with no IPv6 addresses" do
      # IPv4-only addresses
      ipv4_only_service = %{@http_service | addresses: [{192, 168, 1, 100}]}

      query = create_query([create_question("_http._tcp.local", :PTR)])
      response = Responder.build_response(query, [ipv4_only_service])

      # Should still build a valid response
      assert response.header.qr == 1
    end

    test "handles service with empty TXT records" do
      no_txt_service = %{@http_service | txt_records: %{}}

      query = create_query([create_question("_http._tcp.local", :PTR)])
      response = Responder.build_response(query, [no_txt_service])

      # Should still build a valid response
      assert response.header.qr == 1
    end

    test "handles multiple questions in single query" do
      questions = [
        create_question("_http._tcp.local", :PTR),
        create_question("_ssh._tcp.local", :PTR),
        create_question("myhost.local", :A)
      ]

      query = create_query(questions)
      response = Responder.build_response(query, [@http_service, @ssh_service])

      # Should include all questions in response
      assert length(response.qdlist) == 3
    end

    test "normalizes domain names with trailing dots" do
      questions = [create_question("_http._tcp.local.", :PTR)]
      result = Responder.filter_answerable_questions(questions, [@http_service])

      # Should still match despite trailing dot
      assert length(result) == 1
    end
  end
end
