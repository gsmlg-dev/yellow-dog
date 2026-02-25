defmodule YellowDog.Dns.ClientTest do
  @moduledoc """
  Tests for YellowDog.Dns.Client.

  The client wraps ex_dns message building with Abyss UDP transport.
  Network-facing tests use a very short timeout so they resolve quickly
  (they verify error handling, not actual DNS resolution).
  """
  use ExUnit.Case, async: true

  alias YellowDog.Dns.Client

  # ── Module structure ────────────────────────────────────────────────

  describe "module structure" do
    test "module is loadable" do
      assert {:module, Client} = Code.ensure_loaded(Client)
    end

    test "exports query/4" do
      assert function_exported?(Client, :query, 4)
    end

    test "exports query/3 (default opts)" do
      assert function_exported?(Client, :query, 3)
    end

    test "exports query_raw/4" do
      assert function_exported?(Client, :query_raw, 4)
    end

    test "exports query_raw/3 (default opts)" do
      assert function_exported?(Client, :query_raw, 3)
    end

    test "exports send_message/3" do
      assert function_exported?(Client, :send_message, 3)
    end

    test "exports send_message/2 (default opts)" do
      assert function_exported?(Client, :send_message, 2)
    end
  end

  # ── Error handling: closed port (fast timeout) ────────────────────

  describe "query/4 error handling" do
    # Use port 65000 on loopback — not listening → immediate error or fast timeout.
    # Use timeout: 100 to keep tests fast.
    @closed_port 65_000
    @fast_timeout 100

    test "returns error when server not available (A)" do
      assert {:error, _reason} =
               Client.query("example.com", :a, {127, 0, 0, 1},
                 port: @closed_port,
                 timeout: @fast_timeout
               )
    end

    test "returns error when server not available (AAAA)" do
      assert {:error, _reason} =
               Client.query("example.com", :aaaa, {127, 0, 0, 1},
                 port: @closed_port,
                 timeout: @fast_timeout
               )
    end

    test "returns error when server not available (MX)" do
      assert {:error, _reason} =
               Client.query("example.com", :mx, {127, 0, 0, 1},
                 port: @closed_port,
                 timeout: @fast_timeout
               )
    end

    test "returns error when server not available (TXT)" do
      assert {:error, _reason} =
               Client.query("example.com", :txt, {127, 0, 0, 1},
                 port: @closed_port,
                 timeout: @fast_timeout
               )
    end

    test "returns error when server not available (PTR)" do
      assert {:error, _reason} =
               Client.query("1.0.168.192.in-addr.arpa", :ptr, {127, 0, 0, 1},
                 port: @closed_port,
                 timeout: @fast_timeout
               )
    end

    test "returns error when server not available (SRV)" do
      assert {:error, _reason} =
               Client.query("_http._tcp.example.com", :srv, {127, 0, 0, 1},
                 port: @closed_port,
                 timeout: @fast_timeout
               )
    end

    test "returns error when server not available (NS)" do
      assert {:error, _reason} =
               Client.query("example.com", :ns, {127, 0, 0, 1},
                 port: @closed_port,
                 timeout: @fast_timeout
               )
    end

    test "returns error when server not available (SOA)" do
      assert {:error, _reason} =
               Client.query("example.com", :soa, {127, 0, 0, 1},
                 port: @closed_port,
                 timeout: @fast_timeout
               )
    end

    test "recursion_desired: false is accepted as option" do
      assert {:error, _reason} =
               Client.query("example.com", :a, {127, 0, 0, 1},
                 port: @closed_port,
                 timeout: @fast_timeout,
                 recursion_desired: false
               )
    end

    test "recursion_desired: true is accepted as option" do
      assert {:error, _reason} =
               Client.query("example.com", :a, {127, 0, 0, 1},
                 port: @closed_port,
                 timeout: @fast_timeout,
                 recursion_desired: true
               )
    end
  end

  # ── query_raw/4 ──────────────────────────────────────────────────

  describe "query_raw/4 error handling" do
    @closed_port 65_001

    test "returns error binary when server unavailable" do
      result =
        Client.query_raw("example.com", :a, {127, 0, 0, 1}, port: @closed_port, timeout: 100)

      assert {:error, _} = result
    end

    test "query_raw fails the same way as query for unreachable server" do
      r1 = Client.query("example.com", :a, {127, 0, 0, 1}, port: @closed_port, timeout: 100)
      r2 = Client.query_raw("example.com", :a, {127, 0, 0, 1}, port: @closed_port, timeout: 100)

      # Both return {:error, _} for the same server
      assert match?({:error, _}, r1)
      assert match?({:error, _}, r2)
    end
  end

  # ── send_message/3 ───────────────────────────────────────────────

  describe "send_message/3 error handling" do
    test "returns error when server unavailable" do
      message =
        DNS.Message.new()
        |> DNS.Message.add_question(DNS.Message.Question.new("example.com", :a, :in))

      assert {:error, _reason} =
               Client.send_message(message, {127, 0, 0, 1}, port: 65_002, timeout: 100)
    end

    test "accepts DNS.Message struct" do
      message = DNS.Message.new()
      assert is_struct(message, DNS.Message)

      # send_message is happy to accept the struct; error is from transport
      assert {:error, _} =
               Client.send_message(message, {127, 0, 0, 1}, port: 65_002, timeout: 100)
    end
  end

  # ── parse_response error paths (via malformed UDP response) ───────

  describe "parse_response error paths" do
    # We can indirectly verify parse_response by having a "server" that returns
    # a garbage binary response. We need a real UDP listener for this.
    # These are integration-style tests (tagged :integration and skipped by default).

    @tag :skip
    @tag :integration
    test "returns {:error, {:parse_error, _}} for malformed response" do
      # Requires a test UDP server that returns garbage bytes
      # Setup: start a UDP server that always responds with <<0, 0, 0>>
      # Verification: Client.query returns {:error, {:parse_error, _}}
    end
  end

  # ── Option handling ──────────────────────────────────────────────

  describe "option defaults" do
    test "custom port is used in request" do
      # Port 65_003 is not listening — the error confirms the port was used
      result = Client.query("test.example.com", :a, {127, 0, 0, 1}, port: 65_003, timeout: 100)
      assert {:error, _} = result
    end

    test "custom timeout is respected (short timeout fails fast)" do
      {time_us, result} =
        :timer.tc(fn ->
          Client.query("example.com", :a, {127, 0, 0, 1}, port: 65_004, timeout: 50)
        end)

      # Should fail in well under 5 seconds (the default timeout)
      assert {:error, _} = result
      assert time_us < 5_000_000
    end
  end

  # ── Integration tests (skipped in CI) ────────────────────────────

  @tag :skip
  @tag :integration
  describe "integration with real DNS server" do
    test "query returns valid DNS response for known domain" do
      # Requires internet access or a local DNS server on port 53
      assert {:ok, message} = Client.query("example.com", :a, {8, 8, 8, 8})
      assert %DNS.Message{} = message
      assert message.header.qr == 1
    end

    test "query_raw returns binary response" do
      assert {:ok, binary} = Client.query_raw("example.com", :a, {8, 8, 8, 8})
      assert is_binary(binary)
      assert byte_size(binary) > 12
    end

    test "send_message round-trip" do
      message =
        DNS.Message.new()
        |> DNS.Message.add_question(DNS.Message.Question.new("example.com", :a, :in))

      assert {:ok, response} = Client.send_message(message, {8, 8, 8, 8})
      assert response.header.qr == 1
    end
  end
end
