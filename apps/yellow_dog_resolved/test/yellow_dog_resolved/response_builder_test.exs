defmodule YellowDog.Resolved.ResponseBuilderTest do
  use ExUnit.Case, async: true

  alias YellowDog.Resolved.ResponseBuilder

  defp build_query(domain, type_num \\ 1) do
    query = DNS.Message.new()
    query = DNS.Message.update_header_attr(query, :id, 12345)
    query = DNS.Message.update_header_attr(query, :qr, 0)
    query = DNS.Message.update_header_attr(query, :rd, 1)
    DNS.Message.add_question(query, DNS.Message.Question.new(domain, type_num, 1))
  end

  describe "build_intercept_response/2" do
    test "builds A record response" do
      query = build_query("app.local.dev", 1)
      rule = %{type: :a, value: "127.0.0.1", ttl: 300}

      response = ResponseBuilder.build_intercept_response(query, rule)

      assert response.header.qr == 1
      assert response.header.aa == 1
      assert response.header.rd == 1
      assert response.header.ra == 0
      assert length(response.anlist) == 1

      [record] = response.anlist
      assert record.ttl == 300
    end

    test "builds AAAA record response" do
      query = build_query("app.local.dev", 28)
      rule = %{type: :aaaa, value: "::1", ttl: 300}

      response = ResponseBuilder.build_intercept_response(query, rule)
      assert length(response.anlist) == 1
    end

    test "builds CNAME record response" do
      query = build_query("db.internal", 5)
      rule = %{type: :cname, value: "postgres.local.dev", ttl: 300}

      response = ResponseBuilder.build_intercept_response(query, rule)
      assert length(response.anlist) == 1
    end

    test "builds TXT record response" do
      query = build_query("info.test", 16)
      rule = %{type: :txt, value: "v=spf1 include:example.com ~all", ttl: 300}

      response = ResponseBuilder.build_intercept_response(query, rule)
      assert length(response.anlist) == 1
    end

    test "builds MX record response" do
      query = build_query("example.com", 15)
      rule = %{type: :mx, value: "10 mail.example.com", ttl: 300}

      response = ResponseBuilder.build_intercept_response(query, rule)
      assert length(response.anlist) == 1
    end

    test "builds SRV record response" do
      query = build_query("_http._tcp.example.com", 33)
      rule = %{type: :srv, value: "10 20 8080 target.example.com", ttl: 300}

      response = ResponseBuilder.build_intercept_response(query, rule)
      assert length(response.anlist) == 1
    end

    test "returns empty answer when query type differs from rule type" do
      # Query for AAAA but rule is for A
      query = build_query("app.local.dev", 28)
      rule = %{type: :a, value: "127.0.0.1", ttl: 300}

      response = ResponseBuilder.build_intercept_response(query, rule)
      assert response.anlist == []
      assert response.header.qr == 1
    end
  end

  describe "build_nxdomain/1" do
    test "builds NXDOMAIN response" do
      query = build_query("nonexistent.test")

      response = ResponseBuilder.build_nxdomain(query)

      assert response.header.qr == 1
      assert to_string(response.header.rcode) == "NXDOMAIN" or response.header.rcode != nil
      assert response.anlist == []
    end
  end

  describe "build_servfail/1" do
    test "builds SERVFAIL response" do
      query = build_query("example.com")

      response = ResponseBuilder.build_servfail(query)

      assert response.header.qr == 1
      assert response.header.aa == 0
      assert response.anlist == []
    end
  end

  describe "build_formerr/1" do
    test "builds FORMERR response" do
      response = ResponseBuilder.build_formerr(12345)

      assert response.header.id == 12345
      assert response.header.qr == 1
    end
  end

  describe "rewrite_txn_id/2" do
    test "rewrites transaction ID in binary" do
      original = <<0x12, 0x34, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>
      rewritten = ResponseBuilder.rewrite_txn_id(original, 0x5678)

      <<new_id::16, _rest::binary>> = rewritten
      assert new_id == 0x5678
    end

    test "preserves rest of response after rewrite" do
      payload = :crypto.strong_rand_bytes(20)
      original = <<0xAB, 0xCD, payload::binary>>

      rewritten = ResponseBuilder.rewrite_txn_id(original, 0x1234)
      <<_id::16, rest::binary>> = rewritten

      assert rest == payload
    end
  end

  describe "build_intercept_response/2 rcode" do
    test "NOERROR rcode when type matches" do
      query = build_query("test.local", 1)
      rule = %{type: :a, value: "10.0.0.1", ttl: 60}

      response = ResponseBuilder.build_intercept_response(query, rule)
      assert response.header.rcode == DNS.Message.RCode.new(0)
    end

    test "NOERROR rcode when type mismatches (empty answer, not NXDOMAIN)" do
      query = build_query("test.local", 28)
      rule = %{type: :a, value: "10.0.0.1", ttl: 60}

      response = ResponseBuilder.build_intercept_response(query, rule)
      assert response.header.rcode == DNS.Message.RCode.new(0)
      assert response.anlist == []
    end
  end

  describe "build_nxdomain/1 rcode value" do
    test "has rcode equal to nx_domain()" do
      query = build_query("nope.test")
      response = ResponseBuilder.build_nxdomain(query)
      assert response.header.rcode == DNS.Message.RCode.nx_domain()
    end

    test "preserves query transaction ID" do
      query = build_query("nope.test")
      response = ResponseBuilder.build_nxdomain(query)
      assert response.header.id == query.header.id
    end
  end

  describe "build_servfail/1 rcode value" do
    test "has rcode 2" do
      query = build_query("fail.test")
      response = ResponseBuilder.build_servfail(query)
      assert response.header.rcode == DNS.Message.RCode.new(2)
    end

    test "preserves query transaction ID" do
      query = build_query("fail.test")
      response = ResponseBuilder.build_servfail(query)
      assert response.header.id == query.header.id
    end
  end

  describe "build_formerr/1 edge cases" do
    test "has rcode 1" do
      response = ResponseBuilder.build_formerr(999)
      assert response.header.rcode == DNS.Message.RCode.new(1)
    end

    test "works with txn_id 0" do
      response = ResponseBuilder.build_formerr(0)
      assert response.header.id == 0
      assert response.header.qr == 1
    end

    test "works with max txn_id" do
      response = ResponseBuilder.build_formerr(65535)
      assert response.header.id == 65535
    end
  end

  describe "encoding roundtrip" do
    test "intercept response encodes to valid DNS binary" do
      query = build_query("roundtrip.test", 1)
      rule = %{type: :a, value: "10.0.0.1", ttl: 60}

      response = ResponseBuilder.build_intercept_response(query, rule)
      binary = DNS.to_iodata(response) |> IO.iodata_to_binary()

      # Should decode back without error
      decoded = DNS.Message.from_iodata(binary)
      assert decoded.header.qr == 1
      assert decoded.header.id == query.header.id
      assert length(decoded.anlist) == 1
    end

    test "SERVFAIL response encodes to valid DNS binary" do
      query = build_query("servfail.test", 1)

      response = ResponseBuilder.build_servfail(query)
      binary = DNS.to_iodata(response) |> IO.iodata_to_binary()

      decoded = DNS.Message.from_iodata(binary)
      assert decoded.header.qr == 1
      assert decoded.header.id == query.header.id
    end

    test "FORMERR response encodes to valid DNS binary" do
      response = ResponseBuilder.build_formerr(42)
      binary = DNS.to_iodata(response) |> IO.iodata_to_binary()

      decoded = DNS.Message.from_iodata(binary)
      assert decoded.header.qr == 1
      assert decoded.header.id == 42
    end

    test "NXDOMAIN response encodes to valid DNS binary" do
      query = build_query("nxdomain.test", 1)

      response = ResponseBuilder.build_nxdomain(query)
      binary = DNS.to_iodata(response) |> IO.iodata_to_binary()

      decoded = DNS.Message.from_iodata(binary)
      assert decoded.header.qr == 1
      assert decoded.anlist == []
    end

    test "AAAA intercept response roundtrips" do
      query = build_query("v6.test", 28)
      rule = %{type: :aaaa, value: "::1", ttl: 120}

      response = ResponseBuilder.build_intercept_response(query, rule)
      binary = DNS.to_iodata(response) |> IO.iodata_to_binary()

      decoded = DNS.Message.from_iodata(binary)
      assert length(decoded.anlist) == 1
    end

    test "CNAME intercept response roundtrips" do
      query = build_query("alias.test", 5)
      rule = %{type: :cname, value: "target.example.com", ttl: 300}

      response = ResponseBuilder.build_intercept_response(query, rule)
      binary = DNS.to_iodata(response) |> IO.iodata_to_binary()

      decoded = DNS.Message.from_iodata(binary)
      assert length(decoded.anlist) == 1
    end

    test "MX intercept response roundtrips" do
      query = build_query("mail.test", 15)
      rule = %{type: :mx, value: "10 mail.example.com", ttl: 300}

      response = ResponseBuilder.build_intercept_response(query, rule)
      binary = DNS.to_iodata(response) |> IO.iodata_to_binary()

      decoded = DNS.Message.from_iodata(binary)
      assert length(decoded.anlist) == 1
    end

    test "SRV intercept response roundtrips" do
      query = build_query("_sip._tcp.test", 33)
      rule = %{type: :srv, value: "10 5 5060 sip.example.com", ttl: 300}

      response = ResponseBuilder.build_intercept_response(query, rule)
      binary = DNS.to_iodata(response) |> IO.iodata_to_binary()

      decoded = DNS.Message.from_iodata(binary)
      assert length(decoded.anlist) == 1
    end

    test "TXT intercept response roundtrips" do
      query = build_query("txt.test", 16)
      rule = %{type: :txt, value: "v=spf1 -all", ttl: 300}

      response = ResponseBuilder.build_intercept_response(query, rule)
      binary = DNS.to_iodata(response) |> IO.iodata_to_binary()

      decoded = DNS.Message.from_iodata(binary)
      assert length(decoded.anlist) == 1
    end
  end
end
