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

  describe "rewrite_txn_id/2 boundary values" do
    test "rewrites txn_id 0 (minimum)" do
      original = <<0xFF, 0xFF, 1, 2, 3, 4>>
      result = ResponseBuilder.rewrite_txn_id(original, 0)
      <<id::16, _::binary>> = result
      assert id == 0
    end

    test "rewrites txn_id 65535 (maximum)" do
      original = <<0x00, 0x00, 1, 2, 3, 4>>
      result = ResponseBuilder.rewrite_txn_id(original, 65535)
      <<id::16, _::binary>> = result
      assert id == 65535
    end

    test "rewrites minimal 2-byte binary" do
      result = ResponseBuilder.rewrite_txn_id(<<0xAB, 0xCD>>, 0x1234)
      assert result == <<0x12, 0x34>>
    end

    test "preserves full DNS response structure after rewrite" do
      # Build a real DNS response and rewrite its ID
      query = build_query("rewrite.test", 1)
      rule = %{type: :a, value: "10.0.0.1", ttl: 60}
      response = ResponseBuilder.build_intercept_response(query, rule)
      binary = DNS.to_iodata(response) |> IO.iodata_to_binary()

      rewritten = ResponseBuilder.rewrite_txn_id(binary, 42)
      decoded = DNS.Message.from_iodata(rewritten)

      assert decoded.header.id == 42
      assert decoded.header.qr == 1
      assert length(decoded.anlist) == 1
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

  describe "build_intercept_response/2 validation" do
    test "raises on MX value with no space" do
      query = build_query("bad-mx.test", 15)
      rule = %{type: :mx, value: "mailserver.com", ttl: 300}

      assert_raise ArgumentError, ~r/invalid MX value format/, fn ->
        ResponseBuilder.build_intercept_response(query, rule)
      end
    end

    test "raises on MX value with non-integer priority" do
      query = build_query("bad-mx.test", 15)
      rule = %{type: :mx, value: "abc mail.example.com", ttl: 300}

      assert_raise ArgumentError, ~r/invalid MX priority/, fn ->
        ResponseBuilder.build_intercept_response(query, rule)
      end
    end

    test "raises on SRV value with too few fields" do
      query = build_query("bad-srv.test", 33)
      rule = %{type: :srv, value: "10 20 8080", ttl: 300}

      assert_raise ArgumentError, ~r/invalid SRV value format/, fn ->
        ResponseBuilder.build_intercept_response(query, rule)
      end
    end

    test "raises on A record with invalid IPv4" do
      query = build_query("bad-a.test", 1)
      rule = %{type: :a, value: "999.999.999.999", ttl: 300}

      assert_raise ArgumentError, ~r/invalid IP address/, fn ->
        ResponseBuilder.build_intercept_response(query, rule)
      end
    end

    test "raises on A record with non-IP string" do
      query = build_query("bad-a.test", 1)
      rule = %{type: :a, value: "not-an-ip", ttl: 300}

      assert_raise ArgumentError, ~r/invalid IP address/, fn ->
        ResponseBuilder.build_intercept_response(query, rule)
      end
    end

    test "raises on AAAA record with invalid IPv6" do
      query = build_query("bad-aaaa.test", 28)
      rule = %{type: :aaaa, value: "gggg::1", ttl: 300}

      assert_raise ArgumentError, ~r/invalid IP address/, fn ->
        ResponseBuilder.build_intercept_response(query, rule)
      end
    end

    test "raises on SRV value with non-integer priority" do
      query = build_query("bad-srv.test", 33)
      rule = %{type: :srv, value: "abc 20 8080 target.com", ttl: 300}

      assert_raise ArgumentError, ~r/invalid SRV priority/, fn ->
        ResponseBuilder.build_intercept_response(query, rule)
      end
    end

    test "raises on SRV value with non-integer port" do
      query = build_query("bad-srv.test", 33)
      rule = %{type: :srv, value: "10 20 notaport target.com", ttl: 300}

      assert_raise ArgumentError, ~r/invalid SRV port/, fn ->
        ResponseBuilder.build_intercept_response(query, rule)
      end
    end

    test "MX with empty target after split still builds record" do
      query = build_query("mx-edge.test", 15)
      rule = %{type: :mx, value: "10 ", ttl: 300}

      # "10 " → String.split("10 ", " ", parts: 2) → ["10", ""]
      # Empty target is technically accepted (config validation should catch this)
      response = ResponseBuilder.build_intercept_response(query, rule)
      assert length(response.anlist) == 1
    end

    test "raises on MX priority with leading whitespace" do
      query = build_query("bad-mx.test", 15)
      rule = %{type: :mx, value: " 10 mail.example.com", ttl: 300}

      # " 10 mail.example.com" → split → [" 10", "mail.example.com"]
      # Integer.parse(" 10") → :error (leading space)
      assert_raise ArgumentError, ~r/invalid MX priority/, fn ->
        ResponseBuilder.build_intercept_response(query, rule)
      end
    end

    test "raises on SRV with non-integer weight" do
      query = build_query("bad-srv.test", 33)
      rule = %{type: :srv, value: "10 abc 8080 target.com", ttl: 300}

      assert_raise ArgumentError, ~r/invalid SRV weight/, fn ->
        ResponseBuilder.build_intercept_response(query, rule)
      end
    end

    test "raises on SRV with only one field" do
      query = build_query("bad-srv.test", 33)
      rule = %{type: :srv, value: "10", ttl: 300}

      assert_raise ArgumentError, ~r/invalid SRV value format/, fn ->
        ResponseBuilder.build_intercept_response(query, rule)
      end
    end

    test "unknown query type returns empty answer (type mismatch path)" do
      # Query type 255 (ANY) doesn't match any rule type
      query = build_query("unknown.test", 255)
      rule = %{type: :a, value: "10.0.0.1", ttl: 60}

      response = ResponseBuilder.build_intercept_response(query, rule)
      assert response.anlist == []
      assert response.header.qr == 1
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

  describe "rewrite_txn_id/2 short binary defense" do
    test "returns empty binary unchanged" do
      assert ResponseBuilder.rewrite_txn_id(<<>>, 42) == <<>>
    end

    test "returns 1-byte binary unchanged" do
      assert ResponseBuilder.rewrite_txn_id(<<0xAB>>, 42) == <<0xAB>>
    end

    test "2-byte binary gets rewritten normally" do
      result = ResponseBuilder.rewrite_txn_id(<<0, 0>>, 0x1234)
      assert result == <<0x12, 0x34>>
    end
  end
end
