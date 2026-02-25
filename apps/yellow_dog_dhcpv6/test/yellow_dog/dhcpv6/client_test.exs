defmodule YellowDog.Dhcpv6.ClientTest do
  @moduledoc """
  Tests for YellowDog.Dhcpv6.Client.

  The client wraps DHCPv6.Client message building with Abyss IPv6 UDP transport.
  Network-facing tests use short timeouts or verify error handling for
  unavailable servers.

  Note: Tests target a non-listening port on IPv6 loopback (::1). All send/receive
  operations will return {:error, _} due to no server being available. IPv6 socket
  open failures (e.g., {:error, :enotsup}) also satisfy the {:error, _} assertion.
  """
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv6.Client

  # DUID-LL: type=3, hardware_type=1 (ethernet), followed by MAC address
  @sample_duid <<0, 3, 0, 1, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
  @sample_server_duid <<0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>
  @sample_iaid 0xDEAD_BEEF
  # fd00::1 — ULA address used for tests
  @sample_addresses [{0xFD00, 0, 0, 0, 0, 0, 0, 1}]

  # IPv6 loopback (::1) with non-listening high port for fast failure
  @test_server {0, 0, 0, 0, 0, 0, 0, 1}
  @test_port 6747
  @fast_timeout 100

  # ── Module structure ────────────────────────────────────────────────

  describe "module structure" do
    test "module is loadable" do
      assert {:module, Client} = Code.ensure_loaded(Client)
    end

    test "exports all expected public functions" do
      exported = Client.__info__(:functions)

      required = [
        solicit: 1,
        request: 1,
        renew: 1,
        release: 1,
        information_request: 1,
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

  # ── solicit/1 error handling ──────────────────────────────────────

  describe "solicit/1 error handling" do
    test "returns error when no DHCPv6 server is available" do
      result =
        Client.solicit(
          duid: @sample_duid,
          iaid: @sample_iaid,
          server: @test_server,
          server_port: @test_port,
          client_port: 0,
          timeout: @fast_timeout
        )

      assert {:error, _reason} = result
    end
  end

  # ── request/1 error handling ──────────────────────────────────────

  describe "request/1 error handling" do
    test "returns error when no DHCPv6 server is available" do
      result =
        Client.request(
          duid: @sample_duid,
          server_duid: @sample_server_duid,
          iaid: @sample_iaid,
          addresses: @sample_addresses,
          server: @test_server,
          server_port: @test_port,
          client_port: 0,
          timeout: @fast_timeout
        )

      assert {:error, _reason} = result
    end
  end

  # ── renew/1 error handling ────────────────────────────────────────

  describe "renew/1 error handling" do
    test "returns error when no DHCPv6 server is available" do
      result =
        Client.renew(
          duid: @sample_duid,
          server_duid: @sample_server_duid,
          iaid: @sample_iaid,
          addresses: @sample_addresses,
          server: @test_server,
          server_port: @test_port,
          client_port: 0,
          timeout: @fast_timeout
        )

      assert {:error, _reason} = result
    end
  end

  # ── release/1 error handling ──────────────────────────────────────

  describe "release/1 error handling" do
    test "returns error when no DHCPv6 server is available" do
      result =
        Client.release(
          duid: @sample_duid,
          server_duid: @sample_server_duid,
          iaid: @sample_iaid,
          addresses: @sample_addresses,
          server: @test_server,
          server_port: @test_port,
          client_port: 0,
          timeout: @fast_timeout
        )

      assert {:error, _reason} = result
    end
  end

  # ── information_request/1 error handling ─────────────────────────

  describe "information_request/1 error handling" do
    test "returns error when no DHCPv6 server is available" do
      result =
        Client.information_request(
          duid: @sample_duid,
          server: @test_server,
          server_port: @test_port,
          client_port: 0,
          timeout: @fast_timeout
        )

      assert {:error, _reason} = result
    end
  end

  # ── send_message/2 error handling ────────────────────────────────

  describe "send_message/2 error handling" do
    test "returns error when no server available" do
      message = DHCPv6.Client.solicit(duid: @sample_duid, iaid: @sample_iaid)

      result =
        Client.send_message(message,
          server: @test_server,
          server_port: @test_port,
          client_port: 0,
          timeout: @fast_timeout
        )

      assert {:error, _reason} = result
    end

    test "accepts DHCPv6.Message struct" do
      message = DHCPv6.Client.solicit(duid: @sample_duid, iaid: @sample_iaid)
      assert is_struct(message, DHCPv6.Message)
    end
  end

  # ── send_message_async/2 (fire-and-forget) ───────────────────────

  describe "send_message_async/2 (fire-and-forget)" do
    test "returns :ok or {:error, _} — does not block" do
      message = DHCPv6.Client.solicit(duid: @sample_duid, iaid: @sample_iaid)

      result =
        Client.send_message_async(message,
          server: @test_server,
          server_port: @test_port
        )

      assert result == :ok or match?({:error, _}, result)
    end
  end

  # ── lease_cycle/1 ────────────────────────────────────────────────

  describe "lease_cycle/1 error handling" do
    test "returns error when solicit fails (no server)" do
      result =
        Client.lease_cycle(
          duid: @sample_duid,
          iaid: @sample_iaid,
          server: @test_server,
          server_port: @test_port,
          client_port: 0,
          timeout: @fast_timeout
        )

      assert {:error, _reason} = result
    end
  end

  # ── Underlying DHCPv6.Client message building ─────────────────────

  describe "underlying DHCPv6.Client message building" do
    # DHCPv6 option codes relevant here:
    # 1 = CLIENTID (client DUID)
    # 2 = SERVERID (server DUID)
    # 3 = IA_NA (Identity Association for Non-temporary Address)

    test "solicit builds a DHCPv6.Message struct" do
      message = DHCPv6.Client.solicit(duid: @sample_duid, iaid: @sample_iaid)
      assert is_struct(message, DHCPv6.Message)
    end

    test "solicit includes CLIENTID option (code 1)" do
      message = DHCPv6.Client.solicit(duid: @sample_duid, iaid: @sample_iaid)
      client_opt = Enum.find(message.options, &(&1.option_code == 1))
      assert client_opt != nil
    end

    test "solicit includes IA_NA option (code 3)" do
      message = DHCPv6.Client.solicit(duid: @sample_duid, iaid: @sample_iaid)
      ia_na_opt = Enum.find(message.options, &(&1.option_code == 3))
      assert ia_na_opt != nil
    end

    test "request builds a DHCPv6.Message struct" do
      message =
        DHCPv6.Client.request(
          duid: @sample_duid,
          server_duid: @sample_server_duid,
          iaid: @sample_iaid,
          addresses: @sample_addresses
        )

      assert is_struct(message, DHCPv6.Message)
    end

    test "request includes SERVERID option (code 2)" do
      message =
        DHCPv6.Client.request(
          duid: @sample_duid,
          server_duid: @sample_server_duid,
          iaid: @sample_iaid,
          addresses: @sample_addresses
        )

      server_opt = Enum.find(message.options, &(&1.option_code == 2))
      assert server_opt != nil
    end

    test "renew builds a DHCPv6.Message struct" do
      message =
        DHCPv6.Client.renew(
          duid: @sample_duid,
          server_duid: @sample_server_duid,
          iaid: @sample_iaid,
          addresses: @sample_addresses
        )

      assert is_struct(message, DHCPv6.Message)
    end

    test "release builds a DHCPv6.Message struct" do
      message =
        DHCPv6.Client.release(
          duid: @sample_duid,
          server_duid: @sample_server_duid,
          iaid: @sample_iaid,
          addresses: @sample_addresses
        )

      assert is_struct(message, DHCPv6.Message)
    end

    test "information_request builds a DHCPv6.Message struct" do
      message = DHCPv6.Client.information_request(duid: @sample_duid)
      assert is_struct(message, DHCPv6.Message)
    end

    test "messages can be serialized to binary via DHCPv6.Message.to_iodata/1" do
      message = DHCPv6.Client.solicit(duid: @sample_duid, iaid: @sample_iaid)
      binary = DHCPv6.Message.to_iodata(message) |> IO.iodata_to_binary()
      assert is_binary(binary)
      # DHCPv6 message header is 4 bytes: 1 msg_type + 3 transaction_id
      assert byte_size(binary) >= 4
    end
  end

  # ── Integration tests (excluded in CI via :integration tag) ──────

  describe "integration with real DHCPv6 server" do
    @tag :skip
    @tag :integration
    test "solicit returns ADVERTISE from server" do
      # Generate a random DUID-LL (type=3, hw=1, MAC) and IAID for integration testing
      duid = <<0, 3, 0, 1>> <> :crypto.strong_rand_bytes(6)
      iaid = DHCP.SecureRandom.generate_ia_id()
      assert {:ok, advertise} = Client.solicit(duid: duid, iaid: iaid, timeout: 5000)
      assert is_struct(advertise, DHCPv6.Message)
    end

    @tag :skip
    @tag :integration
    test "lease_cycle completes full SOLICIT → ADVERTISE → REQUEST → REPLY cycle" do
      duid = <<0, 3, 0, 1>> <> :crypto.strong_rand_bytes(6)
      iaid = DHCP.SecureRandom.generate_ia_id()
      assert {:ok, result} = Client.lease_cycle(duid: duid, iaid: iaid)
      assert %{solicit: _, advertise: _, request: _, reply: _} = result
    end
  end
end
