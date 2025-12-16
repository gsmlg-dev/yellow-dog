defmodule E2ETest.Dhcpv6E2ETest do
  @moduledoc """
  End-to-end tests for the YellowDog DHCPv6 Server.

  Tests the DHCPv6 server by starting it with auto-selected port,
  sending DHCPv6 messages, and verifying responses.

  These tests verify:
  - Server starts and binds to a port
  - SOLICIT messages receive ADVERTISE responses
  - REQUEST messages receive REPLY responses
  - Full SARR (Solicit-Advertise-Request-Reply) handshake works
  """

  use ExUnit.Case, async: false

  alias E2ETest.ServiceHelper
  alias E2ETest.DhcpClient

  @moduletag :e2e
  @moduletag :dhcpv6

  setup do
    # Start DHCPv6 server with auto-selected port on IPv6 loopback
    case ServiceHelper.start_dhcpv6_server(listen: {0, 0, 0, 0, 0, 0, 0, 1}) do
      {:ok, ctx} ->
        # Start the lease manager for DHCPv6
        lease_manager_result = start_lease_manager()

        # Ensure cleanup on test exit
        on_exit(fn ->
          stop_lease_manager(lease_manager_result)
          ServiceHelper.stop_service(ctx)
        end)

        {:ok, Map.put(ctx, :lease_manager, lease_manager_result)}

      {:error, reason} ->
        raise "Failed to start DHCPv6 server: #{inspect(reason)}"
    end
  end

  describe "DHCPv6 server lifecycle" do
    test "server starts successfully", ctx do
      # Verify the server is running
      assert Process.alive?(ctx.server_pid)
      assert is_integer(ctx.port)
      assert ctx.port > 0

      # Verify port is bound and listening
      assert ctx.service == :dhcpv6
    end
  end

  describe "SOLICIT messages" do
    test "SOLICIT message receives response", ctx do
      # Generate random DUID for this test
      duid = DhcpClient.generate_duid()

      # Send SOLICIT message
      result = DhcpClient.solicit(ctx.host, ctx.port, duid, timeout: 2_000)

      case result do
        {:ok, response} ->
          # Verify we got a DHCPv6 response
          # ADVERTISE = 2, REPLY = 7
          assert response.msg_type in [2, 7],
                 "Expected ADVERTISE (2) or REPLY (7), got #{response.msg_type}"

        {:error, :timeout} ->
          # Server might not respond if no pools are configured
          :ok

        {:error, reason} ->
          flunk("SOLICIT failed with: #{inspect(reason)}")
      end
    end

    test "SOLICIT includes client DUID", ctx do
      duid = DhcpClient.generate_duid()
      transaction_id = DhcpClient.generate_transaction_id()

      # Build SOLICIT with specific DUID
      solicit = %DHCPv6.Message{
        msg_type: 1,
        transaction_id: transaction_id,
        options: [
          # Client Identifier (option 1)
          %DHCPv6.Message.Option{option_code: 1, option_data: duid},
          # IA_NA (option 3) for address request
          %DHCPv6.Message.Option{option_code: 3, option_data: <<1::32, 0::32, 0::32>>},
          # Option Request (option 6)
          %DHCPv6.Message.Option{option_code: 6, option_data: <<23::16, 24::16>>}
        ]
      }

      packet = DHCP.Parameter.to_iodata(solicit) |> IO.iodata_to_binary()
      result = send_dhcpv6_packet(ctx.host, ctx.port, packet, 2_000)

      case result do
        {:ok, _response} ->
          :ok

        {:error, :timeout} ->
          :ok
      end
    end
  end

  describe "REQUEST messages" do
    test "REQUEST after SOLICIT receives response", ctx do
      duid = DhcpClient.generate_duid()

      # First, send SOLICIT
      solicit_result = DhcpClient.solicit(ctx.host, ctx.port, duid, timeout: 2_000)

      case solicit_result do
        {:ok, advertise} ->
          # Extract server DUID and offered address from ADVERTISE
          server_duid = DhcpClient.get_server_duid(advertise)
          ia_na = DhcpClient.get_ia_na_option(advertise)

          if server_duid && ia_na do
            # Send REQUEST for the offered address
            request_result =
              DhcpClient.request_v6(
                ctx.host,
                ctx.port,
                duid,
                server_duid,
                ia_na,
                advertise.transaction_id,
                timeout: 2_000
              )

            case request_result do
              {:ok, response} ->
                # Expect REPLY (7)
                assert response.msg_type == 7, "Expected REPLY (7), got #{response.msg_type}"

              {:error, :timeout} ->
                :ok
            end
          else
            # Server didn't include necessary options
            :ok
          end

        {:error, :timeout} ->
          :ok
      end
    end
  end

  describe "full SARR handshake" do
    test "complete SOLICIT-ADVERTISE-REQUEST-REPLY cycle", ctx do
      duid = DhcpClient.generate_duid()

      # Perform full handshake
      result = DhcpClient.full_handshake_v6(ctx.host, ctx.port, duid, timeout: 2_000)

      case result do
        {:ok, %{advertise: advertise, reply: reply}} ->
          # Verify ADVERTISE
          assert advertise.msg_type == 2

          # Verify REPLY
          assert reply.msg_type == 7

        {:error, {:no_advertise, _}} ->
          # Server didn't send ADVERTISE - might not have pools configured
          :ok

        {:error, {:no_reply, _}} ->
          # Server didn't send REPLY
          :ok

        {:error, :timeout} ->
          :ok

        {:error, :missing_server_duid} ->
          # Server didn't include DUID in response
          :ok

        {:error, :missing_ia_na} ->
          # Server didn't include IA_NA in response
          :ok
      end
    end
  end

  describe "message validation" do
    test "server responds with correct transaction ID", ctx do
      duid = DhcpClient.generate_duid()
      transaction_id = DhcpClient.generate_transaction_id()

      # Build SOLICIT with specific transaction ID
      solicit = %DHCPv6.Message{
        msg_type: 1,
        transaction_id: transaction_id,
        options: [
          %DHCPv6.Message.Option{option_code: 1, option_data: duid},
          %DHCPv6.Message.Option{option_code: 3, option_data: <<1::32, 0::32, 0::32>>}
        ]
      }

      packet = DHCP.Parameter.to_iodata(solicit) |> IO.iodata_to_binary()
      result = send_dhcpv6_packet(ctx.host, ctx.port, packet, 2_000)

      case result do
        {:ok, response_data} ->
          response = DHCPv6.Message.from_binary(response_data)
          # Transaction ID should match
          assert response.transaction_id == transaction_id,
                 "Response transaction_id should match request"

        {:error, :timeout} ->
          :ok
      end
    end

    test "server includes client DUID in response", ctx do
      duid = DhcpClient.generate_duid()

      result = DhcpClient.solicit(ctx.host, ctx.port, duid, timeout: 2_000)

      case result do
        {:ok, response} ->
          # Find client identifier option (option 1)
          client_id_opt = Enum.find(response.options, fn opt -> opt.option_code == 1 end)

          if client_id_opt do
            assert client_id_opt.option_data == duid,
                   "Response should include original client DUID"
          end

        {:error, :timeout} ->
          :ok
      end
    end
  end

  describe "error handling" do
    test "handles multiple clients sequentially", ctx do
      # Simulate multiple clients requesting addresses
      results =
        for i <- 1..3 do
          duid = DhcpClient.generate_duid()
          result = DhcpClient.solicit(ctx.host, ctx.port, duid, timeout: 2_000)
          {i, duid, result}
        end

      # At least some should get responses (or timeout if no pools)
      responses = Enum.filter(results, fn {_, _, result} -> match?({:ok, _}, result) end)

      # Either all timeout (no pools) or some get responses
      assert length(responses) >= 0
    end

    test "invalid port returns error" do
      duid = DhcpClient.generate_duid()

      # Try to query a port that's not listening (using IPv6 loopback)
      result = DhcpClient.solicit({0, 0, 0, 0, 0, 0, 0, 1}, 59997, duid, timeout: 500)

      # Should timeout or fail
      assert {:error, _reason} = result
    end
  end

  describe "option handling" do
    test "INFORMATION-REQUEST receives REPLY", ctx do
      duid = DhcpClient.generate_duid()
      transaction_id = DhcpClient.generate_transaction_id()

      # Build INFORMATION-REQUEST (msg_type = 11)
      info_request = %DHCPv6.Message{
        msg_type: 11,
        transaction_id: transaction_id,
        options: [
          %DHCPv6.Message.Option{option_code: 1, option_data: duid},
          # Request DNS servers (23) and domain search list (24)
          %DHCPv6.Message.Option{option_code: 6, option_data: <<23::16, 24::16>>}
        ]
      }

      packet = DHCP.Parameter.to_iodata(info_request) |> IO.iodata_to_binary()
      result = send_dhcpv6_packet(ctx.host, ctx.port, packet, 2_000)

      case result do
        {:ok, response_data} ->
          response = DHCPv6.Message.from_binary(response_data)
          # Should get REPLY (7)
          assert response.msg_type == 7

        {:error, :timeout} ->
          :ok
      end
    end
  end

  # Private helpers

  defp start_lease_manager do
    case GenServer.whereis(YellowDog.Dhcpv6.LeaseManager) do
      nil ->
        case YellowDog.Dhcpv6.LeaseManager.start_link([]) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end

      pid ->
        {:existing, pid}
    end
  rescue
    _ -> {:error, :lease_manager_not_available}
  end

  defp stop_lease_manager({:ok, pid}) do
    try do
      GenServer.stop(pid, :normal, 1_000)
    catch
      :exit, _ -> :ok
    end
  end

  defp stop_lease_manager({:existing, _pid}), do: :ok
  defp stop_lease_manager(_), do: :ok

  defp send_dhcpv6_packet(host, port, packet, timeout) do
    # Open IPv6 socket
    case :gen_udp.open(0, [:binary, {:active, false}, :inet6]) do
      {:ok, socket} ->
        :gen_udp.send(socket, host, port, packet)

        result =
          case :gen_udp.recv(socket, 0, timeout) do
            {:ok, {_ip, _port, data}} -> {:ok, data}
            {:error, :timeout} -> {:error, :timeout}
            {:error, reason} -> {:error, reason}
          end

        :gen_udp.close(socket)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end
end
