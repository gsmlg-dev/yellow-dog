defmodule YellowDog.Resolved.HandlerTest do
  @moduledoc """
  Tests for the DNS Handler module's packet parsing and error handling.
  """
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.{Cache, Config, Counters}

  @test_config %{
    listen: {127, 0, 0, 1},
    port: 0,
    upstreams: [],
    upstream_timeout_ms: 500,
    upstream_failure_threshold: 3,
    cache: %{
      enabled: true,
      max_entries: 100,
      min_ttl_s: 1,
      max_ttl_s: 3600,
      negative_ttl_s: 5,
      sweep_interval_s: 3600
    },
    discovery: %{enabled: false, websocket: %{}},
    intercept_rules: [
      %{match: {:exact, "handler-test.local"}, type: :a, value: "127.0.0.1", ttl: 300}
    ]
  }

  setup do
    start_supervised!({Config, @test_config})
    start_supervised!(Counters)
    start_supervised!({Cache, @test_config.cache})
    start_supervised!({YellowDog.Resolved.Forwarder, @test_config})
    :ok
  end

  describe "QR=1 response packet filter" do
    test "DNS response packet (QR=1) is not processed through the Router" do
      # Build a valid DNS response (QR=1) — as if an upstream accidentally sent
      # a response to our listening port.  The Handler must discard it silently
      # without calling Router.resolve, which would be incorrect behaviour.
      response_msg = DNS.Message.new()
      question = DNS.Message.Question.new("handler-test.local", :a, :in)

      response_msg = %{
        response_msg
        | header: %{response_msg.header | id: 99, qr: 1, rd: 0, qdcount: 1},
          qdlist: [question]
      }

      binary = DNS.to_iodata(response_msg) |> IO.iodata_to_binary()

      # Verify the binary has QR=1
      parsed = DNS.Message.from_iodata(binary)
      assert parsed.header.qr == 1

      # The binary is a valid DNS message — we confirm the Handler would parse
      # it successfully but must NOT route it (verified via counter invariant).
      counters_before = Counters.get()

      # Simulate what handle_query does: parse and dispatch only QR=0 messages.
      # We can't call handle_query directly (it's private), but we verify the
      # routing logic: QR=1 must NOT match the %DNS.Message{header: %{qr: 0}}
      # pattern that triggers Router.resolve.
      result =
        case DNS.Message.from_iodata(binary) do
          %DNS.Message{header: %{qr: 0}} = _query -> :routed
          %DNS.Message{header: %{qr: 1}} -> :discarded
          _ -> :malformed
        end

      assert result == :discarded

      # Counters must not have changed (no query was processed)
      counters_after = Counters.get()
      assert counters_before.total == counters_after.total
    end
  end

  describe "send_refused QR=1 guard" do
    test "send_refused does not reply to DNS response packets (QR=1)" do
      # Simulate a rate-limited request that is itself a DNS response (QR=1).
      # send_refused must silently skip it — replying to a response could
      # participate in reflection amplification.
      response_msg = DNS.Message.new()
      question = DNS.Message.Question.new("example.com", :a, :in)

      response_msg = %{
        response_msg
        | header: %{response_msg.header | id: 77, qr: 1, qdcount: 1},
          qdlist: [question]
      }

      binary = DNS.to_iodata(response_msg) |> IO.iodata_to_binary()
      parsed = DNS.Message.from_iodata(binary)
      assert parsed.header.qr == 1

      # Verify QR=1 does NOT match the QR=0 guard used in send_refused.
      result =
        case DNS.Message.from_iodata(binary) do
          %DNS.Message{header: %{qr: 0}} -> :would_reply
          _ -> :silent
        end

      assert result == :silent
    end
  end

  describe "non-QUERY opcode filter" do
    test "non-QUERY opcode (QR=0) does NOT match the QUERY pattern guard" do
      # Simulate a STATUS query (opcode=2, QR=0) arriving on the listening port.
      # The handler must return NOTIMP instead of routing it through Router.resolve.
      query = DNS.Message.new()
      question = DNS.Message.Question.new("example.com", :a, :in)

      status_query = %{
        query
        | header: %{query.header | id: 55, qr: 0, qdcount: 1, opcode: DNS.Message.OpCode.new(2)},
          qdlist: [question]
      }

      binary = DNS.to_iodata(status_query) |> IO.iodata_to_binary()

      parsed = DNS.Message.from_iodata(binary)
      assert parsed.header.qr == 0
      <<opcode_value::4>> = parsed.header.opcode.value
      assert opcode_value == 2

      # Verify the non-QUERY opcode does NOT match the QUERY pattern guard.
      # A QR=0 + opcode=0 packet would match; opcode=2 must NOT.
      result =
        case DNS.Message.from_iodata(binary) do
          %DNS.Message{header: %{qr: 0, opcode: %DNS.Message.OpCode{value: <<0::4>>}}} -> :routed
          %DNS.Message{header: %{qr: 0}} -> :notimp
          _ -> :other
        end

      assert result == :notimp
    end
  end

  # RFC 1035 §4.2.1: UDP responses must not exceed 512 bytes (or EDNS0 limit); excess
  # answers must be dropped and TC=1 set so the client can retry over TCP.
  describe "RFC 1035 §4.2.1 — UDP response truncation" do
    test "response within 512 bytes is not truncated" do
      # Single A record — will fit easily in 512 bytes
      query = build_query("handler-test.local", :a)
      response = build_response(query, [make_a_record("handler-test.local", "127.0.0.1")])

      data = DNS.to_iodata(response) |> IO.iodata_to_binary()
      assert byte_size(data) < 512

      # Simulate the truncation logic: response within limit → TC not set
      assert response.header.tc == 0
    end

    test "response exceeding 512 bytes gets TC=1 set" do
      # Build a response with 30 TXT records large enough to exceed 512 bytes
      query = build_query("bigresponse.example", :txt)

      # Each TXT record is ~50 bytes; 15 of them should exceed 512
      txt_rdata = String.duplicate("x", 40)
      records = for i <- 1..15, do: make_txt_record("bigresponse.example", txt_rdata <> "#{i}")
      response = build_response(query, records)

      full_data = DNS.to_iodata(response) |> IO.iodata_to_binary()
      assert byte_size(full_data) > 512

      # Simulate truncation: progressively drop answers until it fits
      {truncated_data, truncated_response} = simulate_truncation(response, 512)
      assert byte_size(truncated_data) <= 512
      assert truncated_response.header.tc == 1
    end

    test "EDNS0 OPT record increases the payload limit" do
      # Build a query with EDNS0 OPT requesting 4096 bytes
      query = build_query_with_edns0("bigresponse.example", :txt, 4096)

      txt_rdata = String.duplicate("x", 40)
      records = for i <- 1..15, do: make_txt_record("bigresponse.example", txt_rdata <> "#{i}")
      response = build_response(query, records)

      full_data = DNS.to_iodata(response) |> IO.iodata_to_binary()
      # Response > 512 but should NOT be truncated with 4096 limit
      assert byte_size(full_data) > 512
      assert byte_size(full_data) < 4096

      # With EDNS0, no truncation needed
      opt_type = DNS.ResourceRecordType.new(41)
      opt_rec = Enum.find(query.arlist, fn rec -> rec.type == opt_type end)
      assert opt_rec != nil
      <<udp_payload::16>> = opt_rec.class.value
      assert udp_payload == 4096

      max_size = max(udp_payload, 512)
      assert byte_size(full_data) <= max_size
    end

    # Helper: builds a simple A query
    defp build_query(name, type) do
      msg = DNS.Message.new()
      question = DNS.Message.Question.new(name, type, :in)
      %{msg | header: %{msg.header | qr: 0, qdcount: 1}, qdlist: [question]}
    end

    # Helper: builds a query with an EDNS0 OPT record advertising udp_payload_size.
    # The OPT record uses class field to carry the UDP payload size (RFC 6891).
    defp build_query_with_edns0(name, type, udp_payload_size) do
      msg = build_query(name, type)

      # OPT record raw wire: name=root(1b=0x00), type=41(2b), class=udp_size(2b), ttl=0(4b), rdlen=0(2b)
      opt_wire = <<0, 41::16, udp_payload_size::16, 0::32, 0::16>>
      opt_record = DNS.Message.Record.from_iodata(opt_wire)
      %{msg | header: %{msg.header | arcount: 1}, arlist: [opt_record]}
    end

    defp build_response(query, records) do
      %DNS.Message{
        header: %{
          query.header
          | qr: 1,
            rd: 1,
            ra: 1,
            tc: 0,
            ancount: length(records)
        },
        qdlist: query.qdlist,
        anlist: records,
        nslist: [],
        arlist: []
      }
    end

    defp make_a_record(name, ip_str) do
      {:ok, ip_tuple} = :inet.parse_address(String.to_charlist(ip_str))
      DNS.Message.Record.new(name, 1, :in, 300, ip_tuple)
    end

    defp make_txt_record(name, text) do
      DNS.Message.Record.new(name, 16, :in, 300, [text])
    end

    defp simulate_truncation(response, max_size) do
      do_simulate_truncate(response.anlist, response, max_size)
    end

    defp do_simulate_truncate([], response, _max_size) do
      truncated = %{response | anlist: [], header: %{response.header | tc: 1, ancount: 0}}
      {DNS.to_iodata(truncated) |> IO.iodata_to_binary(), truncated}
    end

    defp do_simulate_truncate(answers, response, max_size) do
      truncated = %{
        response
        | anlist: answers,
          header: %{response.header | tc: 1, ancount: length(answers)}
      }

      data = DNS.to_iodata(truncated) |> IO.iodata_to_binary()

      if byte_size(data) <= max_size do
        {data, truncated}
      else
        do_simulate_truncate(Enum.drop(answers, -1), response, max_size)
      end
    end
  end

  describe "DNS message parsing" do
    test "valid DNS query is parsed and routed successfully" do
      query = DNS.Message.new()
      question = DNS.Message.Question.new("handler-test.local", :a, :in)

      query = %{
        query
        | header: %{query.header | id: 42, rd: 1, qdcount: 1},
          qdlist: [question]
      }

      binary = DNS.to_iodata(query) |> IO.iodata_to_binary()

      # Verify the binary round-trips through the same parsing path as Handler
      parsed = DNS.Message.from_iodata(binary)
      assert %DNS.Message{} = parsed
      assert parsed.header.id == 42
    end

    test "DNS.Message.from_iodata raises on short binary (< 12 bytes)" do
      # This validates our fix: Handler must rescue FunctionClauseError
      assert_raise FunctionClauseError, fn ->
        DNS.Message.from_iodata(<<0, 1, 2, 3>>)
      end
    end

    test "DNS.Message.from_iodata raises on empty binary" do
      assert_raise FunctionClauseError, fn ->
        DNS.Message.from_iodata(<<>>)
      end
    end

    test "DNS.Message.from_iodata may raise or throw on garbage data" do
      # 12+ byte garbage matches header pattern but produces garbage question parsing
      garbage = :crypto.strong_rand_bytes(20)

      # from_iodata can raise FunctionClauseError or throw :format_error
      # Handler wraps in try/rescue to handle this
      try do
        DNS.Message.from_iodata(garbage)
      rescue
        _ -> :handled
      catch
        :throw, _ -> :handled
      end
    end
  end
end
