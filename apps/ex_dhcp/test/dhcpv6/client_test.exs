defmodule DHCPv6.ClientTest do
  @moduledoc """
  Unit tests for DHCPv6.Client message-building functions.

  Network-dependent functions (send_message/1, test_lease_cycle/1) are skipped.
  """
  use ExUnit.Case, async: true

  alias DHCPv6.Client
  alias DHCPv6.Message

  # Sample DUID-LL (link-layer) for testing
  @sample_duid <<0x00, 0x03, 0x00, 0x01, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
  @sample_server_duid <<0x00, 0x01, 0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x11, 0x22, 0x33,
                        0x44, 0x55>>
  @sample_iaid 0x0A0B0C0D
  @sample_addresses [{0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}]

  defp option_with_code(message, code) do
    Enum.find(message.options, fn opt -> opt.option_code == code end)
  end

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Client)
    end

    test "exports solicit/1" do
      assert Kernel.function_exported?(Client, :solicit, 1)
    end

    test "exports request/1" do
      assert Kernel.function_exported?(Client, :request, 1)
    end

    test "exports renew/1" do
      assert Kernel.function_exported?(Client, :renew, 1)
    end

    test "exports release/1" do
      assert Kernel.function_exported?(Client, :release, 1)
    end

    test "exports information_request/1" do
      assert Kernel.function_exported?(Client, :information_request, 1)
    end

    test "exports send_message/1" do
      assert Kernel.function_exported?(Client, :send_message, 1)
    end

    test "exports test_lease_cycle/1" do
      assert Kernel.function_exported?(Client, :test_lease_cycle, 1)
    end
  end

  describe "solicit/1" do
    test "creates SOLICIT message (msg_type 1)" do
      message = Client.solicit(duid: @sample_duid, iaid: @sample_iaid)

      assert %Message{} = message
      assert message.msg_type == 1
    end

    test "transaction_id is a 3-byte binary" do
      message = Client.solicit(duid: @sample_duid, iaid: @sample_iaid)

      assert is_binary(message.transaction_id)
      assert byte_size(message.transaction_id) == 3
    end

    test "uses provided transaction_id" do
      xid = 0x112233
      message = Client.solicit(duid: @sample_duid, iaid: @sample_iaid, transaction_id: xid)

      assert message.transaction_id == <<0x11, 0x22, 0x33>>
    end

    test "includes CLIENTID option (code 1)" do
      message = Client.solicit(duid: @sample_duid, iaid: @sample_iaid)

      opt = option_with_code(message, 1)
      assert opt != nil
      assert opt.option_data == @sample_duid
    end

    test "includes IA_NA option (code 3)" do
      message = Client.solicit(duid: @sample_duid, iaid: @sample_iaid)

      opt = option_with_code(message, 3)
      assert opt != nil
    end

    test "includes ORO option by default (code 6)" do
      message = Client.solicit(duid: @sample_duid, iaid: @sample_iaid)

      opt = option_with_code(message, 6)
      assert opt != nil
    end

    test "omits ORO option when dns_servers: false" do
      message = Client.solicit(duid: @sample_duid, iaid: @sample_iaid, dns_servers: false)

      opt = option_with_code(message, 6)
      assert opt == nil
    end

    test "includes RAPID_COMMIT option when rapid_commit: true (code 14)" do
      message = Client.solicit(duid: @sample_duid, iaid: @sample_iaid, rapid_commit: true)

      opt = option_with_code(message, 14)
      assert opt != nil
    end

    test "omits RAPID_COMMIT option by default" do
      message = Client.solicit(duid: @sample_duid, iaid: @sample_iaid)

      opt = option_with_code(message, 14)
      assert opt == nil
    end

    test "raises when duid not provided" do
      assert_raise KeyError, fn ->
        Client.solicit(iaid: @sample_iaid)
      end
    end

    test "raises when iaid not provided" do
      assert_raise KeyError, fn ->
        Client.solicit(duid: @sample_duid)
      end
    end

    test "each call generates unique transaction_id" do
      msg1 = Client.solicit(duid: @sample_duid, iaid: @sample_iaid)
      msg2 = Client.solicit(duid: @sample_duid, iaid: @sample_iaid)

      assert msg1.transaction_id != msg2.transaction_id
    end
  end

  describe "request/1" do
    test "creates REQUEST message (msg_type 3)" do
      message =
        Client.request(
          duid: @sample_duid,
          server_duid: @sample_server_duid,
          iaid: @sample_iaid,
          addresses: @sample_addresses
        )

      assert %Message{} = message
      assert message.msg_type == 3
    end

    test "includes CLIENTID option (code 1)" do
      message =
        Client.request(
          duid: @sample_duid,
          server_duid: @sample_server_duid,
          iaid: @sample_iaid,
          addresses: @sample_addresses
        )

      opt = option_with_code(message, 1)
      assert opt != nil
      assert opt.option_data == @sample_duid
    end

    test "includes SERVERID option (code 2)" do
      message =
        Client.request(
          duid: @sample_duid,
          server_duid: @sample_server_duid,
          iaid: @sample_iaid,
          addresses: @sample_addresses
        )

      opt = option_with_code(message, 2)
      assert opt != nil
      assert opt.option_data == @sample_server_duid
    end

    test "includes IA_NA option (code 3)" do
      message =
        Client.request(
          duid: @sample_duid,
          server_duid: @sample_server_duid,
          iaid: @sample_iaid,
          addresses: @sample_addresses
        )

      opt = option_with_code(message, 3)
      assert opt != nil
    end

    test "raises when duid missing" do
      assert_raise KeyError, fn ->
        Client.request(server_duid: @sample_server_duid, iaid: @sample_iaid, addresses: [])
      end
    end

    test "raises when server_duid missing" do
      assert_raise KeyError, fn ->
        Client.request(duid: @sample_duid, iaid: @sample_iaid, addresses: [])
      end
    end

    test "raises when iaid missing" do
      assert_raise KeyError, fn ->
        Client.request(duid: @sample_duid, server_duid: @sample_server_duid, addresses: [])
      end
    end

    test "raises when addresses missing" do
      assert_raise KeyError, fn ->
        Client.request(duid: @sample_duid, server_duid: @sample_server_duid, iaid: @sample_iaid)
      end
    end
  end

  describe "renew/1" do
    test "creates RENEW message (msg_type 5)" do
      message =
        Client.renew(
          duid: @sample_duid,
          server_duid: @sample_server_duid,
          iaid: @sample_iaid,
          addresses: @sample_addresses
        )

      assert %Message{} = message
      assert message.msg_type == 5
    end

    test "includes SERVERID option (code 2)" do
      message =
        Client.renew(
          duid: @sample_duid,
          server_duid: @sample_server_duid,
          iaid: @sample_iaid,
          addresses: @sample_addresses
        )

      opt = option_with_code(message, 2)
      assert opt != nil
    end

    test "raises when required field missing" do
      assert_raise KeyError, fn ->
        Client.renew(duid: @sample_duid, server_duid: @sample_server_duid, iaid: @sample_iaid)
      end
    end
  end

  describe "release/1" do
    test "creates RELEASE message (msg_type 8)" do
      message =
        Client.release(
          duid: @sample_duid,
          server_duid: @sample_server_duid,
          iaid: @sample_iaid,
          addresses: @sample_addresses
        )

      assert %Message{} = message
      assert message.msg_type == 8
    end

    test "includes CLIENTID and SERVERID options" do
      message =
        Client.release(
          duid: @sample_duid,
          server_duid: @sample_server_duid,
          iaid: @sample_iaid,
          addresses: @sample_addresses
        )

      assert option_with_code(message, 1) != nil
      assert option_with_code(message, 2) != nil
    end

    test "raises when required field missing" do
      assert_raise KeyError, fn ->
        Client.release(duid: @sample_duid, server_duid: @sample_server_duid, iaid: @sample_iaid)
      end
    end
  end

  describe "information_request/1" do
    test "creates INFORMATION-REQUEST message (msg_type 10)" do
      message = Client.information_request(duid: @sample_duid)

      assert %Message{} = message
      assert message.msg_type == 10
    end

    test "includes CLIENTID option (code 1)" do
      message = Client.information_request(duid: @sample_duid)

      opt = option_with_code(message, 1)
      assert opt != nil
      assert opt.option_data == @sample_duid
    end

    test "includes ORO option by default" do
      message = Client.information_request(duid: @sample_duid)

      opt = option_with_code(message, 6)
      assert opt != nil
    end

    test "omits ORO option when dns_servers: false" do
      message = Client.information_request(duid: @sample_duid, dns_servers: false)

      opt = option_with_code(message, 6)
      assert opt == nil
    end

    test "uses provided transaction_id" do
      xid = 0xABCDEF
      message = Client.information_request(duid: @sample_duid, transaction_id: xid)

      assert message.transaction_id == <<0xAB, 0xCD, 0xEF>>
    end

    test "raises when duid not provided" do
      assert_raise KeyError, fn ->
        Client.information_request([])
      end
    end
  end

  describe "send_message/1" do
    @tag :skip
    @tag :integration
    test "requires network connectivity" do
      message = Client.solicit(duid: @sample_duid, iaid: @sample_iaid)
      result = Client.send_message(message: message)

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "test_lease_cycle/1" do
    @tag :skip
    @tag :integration
    test "requires DHCPv6 server and network" do
      result =
        Client.test_lease_cycle(
          duid: @sample_duid,
          iaid: @sample_iaid,
          server_duid: @sample_server_duid
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
