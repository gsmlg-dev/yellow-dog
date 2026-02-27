defmodule YellowDog.Dhcpv4.ClientTest do
  @moduledoc """
  Tests for YellowDog.Dhcpv4.Client.

  The client wraps DHCPv4.Client message building with Abyss UDP broadcast.
  Network-facing tests use short timeouts or verify error handling for
  unavailable servers.

  Note: release/1 and decline/1 are fire-and-forget (no response expected)
  and may return :ok or {:error, _} depending on the OS/network config.
  """
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv4.Client

  @sample_mac <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>

  # ── Module structure ────────────────────────────────────────────────

  describe "module structure" do
    test "module is loadable" do
      assert {:module, Client} = Code.ensure_loaded(Client)
    end

    test "exports all expected public functions" do
      exported = Client.__info__(:functions)

      required = [
        discover: 1,
        request: 1,
        release: 1,
        decline: 1,
        send_message: 1,
        send_message: 2,
        send_message_async: 1,
        send_message_async: 2,
        lease_cycle: 1
      ]

      Enum.each(required, fn {name, arity} ->
        assert {name, arity} in exported,
               "Expected #{name}/#{arity} to be exported from #{Client}"
      end)
    end
  end

  # ── discover/1 error handling ────────────────────────────────────

  describe "discover/1 error handling" do
    # Without a DHCP server running, discover times out or fails to bind.
    # We use server: {127,0,0,1} (unicast to loopback) and a high test port
    # to avoid needing root (port 67) or broadcast (255.255.255.255).

    test "returns error when no DHCP server is available" do
      result =
        Client.discover(
          mac: @sample_mac,
          server: {127, 0, 0, 1},
          server_port: 6767,
          client_port: 0,
          timeout: 100
        )

      assert {:error, _reason} = result
    end
  end

  # ── request/1 error handling ──────────────────────────────────────

  describe "request/1 error handling" do
    test "returns error when no DHCP server is available" do
      result =
        Client.request(
          mac: @sample_mac,
          server_ip: {127, 0, 0, 1},
          requested_ip: {192, 168, 1, 100},
          server: {127, 0, 0, 1},
          server_port: 6767,
          client_port: 0,
          timeout: 100
        )

      assert {:error, _reason} = result
    end
  end

  # ── send_message/2 error handling ────────────────────────────────

  describe "send_message/2 error handling" do
    test "returns error when no server available" do
      message = DHCPv4.Client.discover(mac: @sample_mac)

      result =
        Client.send_message(message,
          server: {127, 0, 0, 1},
          server_port: 6767,
          client_port: 0,
          timeout: 100
        )

      assert {:error, _reason} = result
    end

    test "accepts DHCPv4.Message struct" do
      message = DHCPv4.Client.discover(mac: @sample_mac)
      assert is_struct(message, DHCPv4.Message)
    end
  end

  # ── release/1 and decline/1 (fire-and-forget) ───────────────────

  describe "release/1 (fire-and-forget)" do
    test "returns :ok or {:error, _} — does not crash" do
      result =
        Client.release(
          mac: @sample_mac,
          server_ip: {127, 0, 0, 1},
          leased_ip: {192, 168, 1, 100},
          server: {127, 0, 0, 1},
          server_port: 6767
        )

      # release is send-only: :ok means the packet was sent,
      # {:error, _} means the socket/network failed
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "decline/1 (fire-and-forget)" do
    test "returns :ok or {:error, _} — does not crash" do
      result =
        Client.decline(
          mac: @sample_mac,
          server_ip: {127, 0, 0, 1},
          declined_ip: {192, 168, 1, 100},
          server: {127, 0, 0, 1},
          server_port: 6767
        )

      assert result == :ok or match?({:error, _}, result)
    end
  end

  # ── send_message_async/2 (fire-and-forget) ───────────────────────

  describe "send_message_async/2 (fire-and-forget)" do
    test "returns :ok or {:error, _} — does not block" do
      message = DHCPv4.Client.discover(mac: @sample_mac)

      result =
        Client.send_message_async(message,
          server: {127, 0, 0, 1},
          server_port: 6767
        )

      assert result == :ok or match?({:error, _}, result)
    end
  end

  # ── lease_cycle/1 ───────────────────────────────────────────────

  describe "lease_cycle/1 error handling" do
    test "returns error when discover fails (no server)" do
      result =
        Client.lease_cycle(
          mac: @sample_mac,
          server: {127, 0, 0, 1},
          server_port: 6767,
          client_port: 0,
          timeout: 100
        )

      assert {:error, _reason} = result
    end
  end

  # ── Underlying message building (via DHCPv4.Client library) ──────

  describe "underlying DHCPv4.Client message building" do
    # DHCP option 53 (message type) values are encoded as 1-byte binaries:
    # 1=DISCOVER, 2=OFFER, 3=REQUEST, 4=DECLINE, 5=ACK, 6=NAK, 7=RELEASE

    test "discover builds a DHCP_DISCOVER message (msg_type option = 1)" do
      message = DHCPv4.Client.discover(mac: @sample_mac)
      assert %DHCPv4.Message{} = message
      # Option 53 carries the DHCP message type as a binary value
      discover_opt = Enum.find(message.options, &(&1.type == 53))
      assert discover_opt != nil
      assert :binary.decode_unsigned(discover_opt.value) == 1
    end

    test "discover includes client MAC in chaddr" do
      message = DHCPv4.Client.discover(mac: @sample_mac)
      # chaddr is padded to 16 bytes; first 6 are the MAC
      assert binary_part(message.chaddr, 0, 6) == @sample_mac
    end

    test "request builds a DHCP_REQUEST message (msg_type option = 3)" do
      message =
        DHCPv4.Client.request(
          mac: @sample_mac,
          server_ip: {192, 168, 1, 1},
          requested_ip: {192, 168, 1, 100}
        )

      assert %DHCPv4.Message{} = message
      request_opt = Enum.find(message.options, &(&1.type == 53))
      assert request_opt != nil
      assert :binary.decode_unsigned(request_opt.value) == 3
    end

    test "release builds a DHCP_RELEASE message (msg_type option = 7)" do
      message =
        DHCPv4.Client.release(
          mac: @sample_mac,
          server_ip: {192, 168, 1, 1},
          leased_ip: {192, 168, 1, 100}
        )

      assert %DHCPv4.Message{} = message
      release_opt = Enum.find(message.options, &(&1.type == 53))
      assert release_opt != nil
      assert :binary.decode_unsigned(release_opt.value) == 7
    end

    test "decline builds a DHCP_DECLINE message (msg_type option = 4)" do
      message =
        DHCPv4.Client.decline(
          mac: @sample_mac,
          server_ip: {192, 168, 1, 1},
          declined_ip: {192, 168, 1, 100}
        )

      assert %DHCPv4.Message{} = message
      decline_opt = Enum.find(message.options, &(&1.type == 53))
      assert decline_opt != nil
      assert :binary.decode_unsigned(decline_opt.value) == 4
    end

    test "messages can be serialized to binary via DHCP.to_iodata/1" do
      message = DHCPv4.Client.discover(mac: @sample_mac)
      binary = DHCP.to_iodata(message) |> IO.iodata_to_binary()
      assert is_binary(binary)
      # Minimum DHCP message size is 236 bytes (fixed header)
      assert byte_size(binary) >= 236
    end
  end

  # ── Integration tests (excluded in CI via :integration tag) ──────

  describe "integration with real DHCP server" do
    @tag :integration
    test "discover returns DHCP OFFER from server" do
      # Requires a DHCPv4 server running on default ports
      assert {:ok, offer} = Client.discover(mac: @sample_mac, timeout: 5000)
      assert %DHCPv4.Message{} = offer
      # DHCP OFFER = msg_type 2
      offer_opt = Enum.find(offer.options, &(&1.type == 53))
      assert :binary.decode_unsigned(offer_opt.value) == 2
    end

    @tag :integration
    test "lease_cycle completes full DISCOVER → OFFER → REQUEST → ACK cycle" do
      assert {:ok, result} = Client.lease_cycle(mac: @sample_mac)
      assert %{discover: _, offer: _, request: _, ack: _} = result
    end
  end
end
