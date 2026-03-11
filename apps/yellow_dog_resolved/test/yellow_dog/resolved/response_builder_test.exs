defmodule YellowDog.Resolved.ResponseBuilderTest do
  use ExUnit.Case, async: true

  alias YellowDog.Resolved.ResponseBuilder

  defp build_query(domain, type \\ :a) do
    query = DNS.Message.new()
    question = DNS.Message.Question.new(domain, type, :in)

    %{
      query
      | header: %{query.header | id: 12345, rd: 1, qdcount: 1},
        qdlist: [question]
    }
  end

  describe "intercept_response/2" do
    test "builds A record response" do
      query = build_query("myapp.test", :a)
      rule = %{match: {:exact, "myapp.test"}, type: :a, value: "192.168.1.100", ttl: 600}

      response = ResponseBuilder.intercept_response(query, rule)

      assert response.header.qr == 1
      assert response.header.aa == 1
      assert response.header.id == 12345
      assert response.header.rcode == DNS.Message.RCode.no_error()
      assert length(response.anlist) == 1

      [record] = response.anlist
      assert record.ttl == 600
    end

    test "builds AAAA record response" do
      query = build_query("myapp.test", :aaaa)
      rule = %{match: {:exact, "myapp.test"}, type: :aaaa, value: "::1", ttl: 300}

      response = ResponseBuilder.intercept_response(query, rule)

      assert response.header.qr == 1
      assert length(response.anlist) == 1
    end

    test "builds CNAME record response" do
      query = build_query("db.internal", :cname)

      rule = %{
        match: {:exact, "db.internal"},
        type: :cname,
        value: "postgres.local.dev",
        ttl: 300
      }

      response = ResponseBuilder.intercept_response(query, rule)

      assert length(response.anlist) == 1
    end

    test "builds TXT record response" do
      query = build_query("info.test", :txt)

      rule = %{
        match: {:exact, "info.test"},
        type: :txt,
        value: "v=spf1 include:example.com",
        ttl: 300
      }

      response = ResponseBuilder.intercept_response(query, rule)

      assert length(response.anlist) == 1
    end

    test "builds MX record response" do
      query = build_query("mail.test", :mx)
      rule = %{match: {:exact, "mail.test"}, type: :mx, value: "10 mail.example.com", ttl: 300}

      response = ResponseBuilder.intercept_response(query, rule)

      assert length(response.anlist) == 1
    end

    test "builds SRV record response" do
      query = build_query("_sip._tcp.test", :srv)

      rule = %{
        match: {:exact, "_sip._tcp.test"},
        type: :srv,
        value: "10 20 5060 sip.example.com",
        ttl: 300
      }

      response = ResponseBuilder.intercept_response(query, rule)

      assert length(response.anlist) == 1
    end

    test "returns empty answer when query type doesn't match rule type" do
      query = build_query("myapp.test", :aaaa)
      rule = %{match: {:exact, "myapp.test"}, type: :a, value: "192.168.1.100", ttl: 600}

      response = ResponseBuilder.intercept_response(query, rule)

      assert response.header.rcode == DNS.Message.RCode.no_error()
      assert response.anlist == []
    end

    test "preserves query transaction ID" do
      query = build_query("myapp.test", :a)
      rule = %{match: {:exact, "myapp.test"}, type: :a, value: "127.0.0.1", ttl: 300}

      response = ResponseBuilder.intercept_response(query, rule)
      assert response.header.id == query.header.id
    end

    test "preserves RD flag from query" do
      query = build_query("myapp.test", :a)
      query = %{query | header: %{query.header | rd: 0}}
      rule = %{match: {:exact, "myapp.test"}, type: :a, value: "127.0.0.1", ttl: 300}

      response = ResponseBuilder.intercept_response(query, rule)
      assert response.header.rd == 0
    end

    test "returns SERVFAIL for query with empty question list" do
      query = build_query("myapp.test", :a)
      query = %{query | qdlist: [], header: %{query.header | qdcount: 0}}
      rule = %{match: {:exact, "myapp.test"}, type: :a, value: "127.0.0.1", ttl: 300}

      response = ResponseBuilder.intercept_response(query, rule)
      assert response.header.qr == 1
      assert response.header.rcode == DNS.Message.RCode.serv_fail()
      assert response.anlist == []
    end
  end

  describe "servfail_response/1" do
    test "builds SERVFAIL response" do
      query = build_query("fail.test")
      response = ResponseBuilder.servfail_response(query)

      assert response.header.qr == 1
      assert response.header.rcode == DNS.Message.RCode.serv_fail()
      assert response.anlist == []
      assert response.header.id == query.header.id
    end
  end

  describe "nxdomain_response/1" do
    test "builds NXDOMAIN response" do
      query = build_query("nonexistent.test")
      response = ResponseBuilder.nxdomain_response(query)

      assert response.header.qr == 1
      assert response.header.rcode == DNS.Message.RCode.nx_domain()
      assert response.anlist == []
      assert response.header.id == query.header.id
    end
  end

  describe "build_response/3" do
    test "includes question section from query" do
      query = build_query("example.com")
      response = ResponseBuilder.build_response(query, [], DNS.Message.RCode.no_error())

      assert response.qdlist == query.qdlist
      assert response.header.qdcount == 1
    end

    test "sets RA=0" do
      query = build_query("example.com")
      response = ResponseBuilder.build_response(query, [], DNS.Message.RCode.no_error())

      assert response.header.ra == 0
    end

    test "REFUSED rcode is set correctly for rate-limited responses" do
      query = build_query("example.com")
      response = ResponseBuilder.build_response(query, [], DNS.Message.RCode.refused())

      assert response.header.rcode == DNS.Message.RCode.refused()
      assert response.header.qr == 1
      assert response.header.id == query.header.id
      assert response.anlist == []
    end
  end

  describe "build_record/4" do
    test "A record with valid IP returns {:ok, record}" do
      assert {:ok, record} = ResponseBuilder.build_record("test.com", :a, "192.168.1.1", 300)
      assert record.ttl == 300
    end

    test "A record with invalid IP returns :error" do
      assert :error = ResponseBuilder.build_record("test.com", :a, "not.an.ip", 300)
    end

    test "A record with IPv6 address returns :error" do
      assert :error = ResponseBuilder.build_record("test.com", :a, "::1", 300)
    end

    test "AAAA record with valid IPv6 returns {:ok, record}" do
      assert {:ok, _record} = ResponseBuilder.build_record("test.com", :aaaa, "::1", 300)
    end

    test "AAAA record with IPv4 address returns :error" do
      assert :error = ResponseBuilder.build_record("test.com", :aaaa, "192.168.1.1", 300)
    end

    test "MX record with valid format returns {:ok, record}" do
      assert {:ok, _record} =
               ResponseBuilder.build_record("test.com", :mx, "10 mail.example.com", 300)
    end

    test "MX record with missing exchange returns :error" do
      assert :error = ResponseBuilder.build_record("test.com", :mx, "10", 300)
    end

    test "MX record with non-integer priority returns :error" do
      assert :error = ResponseBuilder.build_record("test.com", :mx, "abc mail.example.com", 300)
    end

    test "SRV record with valid format returns {:ok, record}" do
      assert {:ok, _record} =
               ResponseBuilder.build_record("test.com", :srv, "10 20 5060 sip.example.com", 300)
    end

    test "SRV record with missing fields returns :error" do
      assert :error = ResponseBuilder.build_record("test.com", :srv, "10 20", 300)
    end

    test "SRV record with non-integer port returns :error" do
      assert :error =
               ResponseBuilder.build_record("test.com", :srv, "10 20 abc sip.example.com", 300)
    end

    test "NS record with domain name returns {:ok, record}" do
      assert {:ok, record} =
               ResponseBuilder.build_record("test.com", :ns, "ns1.example.com", 300)

      assert record.ttl == 300
      assert to_string(record.type) == "NS"
    end

    test "PTR record with domain name returns {:ok, record}" do
      assert {:ok, record} =
               ResponseBuilder.build_record("1.0.168.192.in-addr.arpa", :ptr, "host.example.com", 300)

      assert record.ttl == 300
      assert to_string(record.type) == "PTR"
    end

    test "unknown record type returns :error" do
      assert :error = ResponseBuilder.build_record("test.com", :soa, "ns1.example.com", 300)
    end
  end

  describe "intercept_response with malformed values" do
    test "returns SERVFAIL for invalid A record value" do
      query = build_query("bad.test", :a)
      rule = %{match: {:exact, "bad.test"}, type: :a, value: "not.an.ip", ttl: 300}

      response = ResponseBuilder.intercept_response(query, rule)
      assert response.header.rcode == DNS.Message.RCode.serv_fail()
      assert response.anlist == []
    end

    test "returns SERVFAIL for malformed MX record value" do
      query = build_query("bad.test", :mx)
      rule = %{match: {:exact, "bad.test"}, type: :mx, value: "invalid", ttl: 300}

      response = ResponseBuilder.intercept_response(query, rule)
      assert response.header.rcode == DNS.Message.RCode.serv_fail()
      assert response.anlist == []
    end

    test "returns SERVFAIL for malformed SRV record value" do
      query = build_query("bad.test", :srv)
      rule = %{match: {:exact, "bad.test"}, type: :srv, value: "not valid", ttl: 300}

      response = ResponseBuilder.intercept_response(query, rule)
      assert response.header.rcode == DNS.Message.RCode.serv_fail()
      assert response.anlist == []
    end
  end

  describe "response serialization" do
    test "intercept response can be serialized to valid DNS packet" do
      query = build_query("myapp.test", :a)
      rule = %{match: {:exact, "myapp.test"}, type: :a, value: "192.168.1.100", ttl: 600}

      response = ResponseBuilder.intercept_response(query, rule)
      binary = DNS.to_iodata(response) |> IO.iodata_to_binary()

      assert is_binary(binary)
      assert byte_size(binary) > 12

      # Round-trip: parse it back
      parsed = DNS.Message.from_iodata(binary)
      assert parsed.header.qr == 1
      assert parsed.header.id == 12345
    end

    test "servfail response can be serialized" do
      query = build_query("fail.test")
      response = ResponseBuilder.servfail_response(query)
      binary = DNS.to_iodata(response) |> IO.iodata_to_binary()

      assert is_binary(binary)
      parsed = DNS.Message.from_iodata(binary)
      assert parsed.header.rcode == DNS.Message.RCode.serv_fail()
    end
  end
end
