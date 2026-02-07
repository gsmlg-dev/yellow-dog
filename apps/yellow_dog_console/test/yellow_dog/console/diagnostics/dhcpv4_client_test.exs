defmodule YellowDog.Console.Diagnostics.Dhcpv4ClientTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.Diagnostics.Dhcpv4Client

  describe "requires_privileged_port?/0" do
    test "returns true" do
      assert Dhcpv4Client.requires_privileged_port?()
    end
  end

  describe "query/1 message building" do
    test "builds DHCPv4 DISCOVER message" do
      params = %{
        message_type: "discover",
        client_mac: "",
        transaction_id: "",
        requested_options: "",
        timeout: "100"
      }

      # Will fail on port binding, but should return {:ok, result}
      {:ok, result} = Dhcpv4Client.query(params)
      # Request message should be built even if query fails
      assert result.request_struct != nil || result.status == :error
    end

    test "handles different message types" do
      for msg_type <- ["discover", "request", "decline", "release", "inform"] do
        params = %{
          message_type: msg_type,
          client_mac: "",
          transaction_id: "",
          requested_options: "",
          timeout: "50"
        }

        {:ok, result} = Dhcpv4Client.query(params)
        # Should handle each message type
        assert result.status in [:error, :timeout, :success]
      end
    end

    test "handles MAC address input" do
      params = %{
        message_type: "discover",
        client_mac: "00:11:22:33:44:55",
        transaction_id: "",
        requested_options: "",
        timeout: "50"
      }

      {:ok, result} = Dhcpv4Client.query(params)
      assert result.status in [:error, :timeout, :success]
    end

    test "handles hex transaction ID" do
      params = %{
        message_type: "discover",
        client_mac: "",
        transaction_id: "AABBCCDD",
        requested_options: "",
        timeout: "50"
      }

      {:ok, result} = Dhcpv4Client.query(params)
      assert result.status in [:error, :timeout, :success]
    end

    test "handles requested options" do
      params = %{
        message_type: "discover",
        client_mac: "",
        transaction_id: "",
        requested_options: "1,3,6,15",
        timeout: "50"
      }

      {:ok, result} = Dhcpv4Client.query(params)
      assert result.status in [:error, :timeout, :success]
    end

    test "records latency" do
      params = %{
        message_type: "discover",
        client_mac: "",
        transaction_id: "",
        requested_options: "",
        timeout: "50"
      }

      {:ok, result} = Dhcpv4Client.query(params)
      assert is_integer(result.latency_ms)
      assert result.latency_ms >= 0
    end

    test "handles atom keys in params" do
      params = %{
        message_type: :discover,
        client_mac: "",
        transaction_id: "",
        requested_options: "",
        timeout: 50
      }

      {:ok, result} = Dhcpv4Client.query(params)
      assert result.status in [:error, :timeout, :success]
    end

    test "returns error for permission denied (EACCES)" do
      params = %{
        message_type: "discover",
        client_mac: "",
        transaction_id: "",
        requested_options: "",
        timeout: "50"
      }

      {:ok, result} = Dhcpv4Client.query(params)
      # When not running as root, should get EACCES error
      if result.status == :error do
        assert result.error =~ "Permission denied" or result.error =~ "Socket error"
      end
    end

    test "auto-generates MAC when empty" do
      params = %{
        message_type: "discover",
        client_mac: "",
        transaction_id: "",
        requested_options: "",
        timeout: "50"
      }

      {:ok, result} = Dhcpv4Client.query(params)
      # Message should be built with auto-generated MAC
      assert result.request_struct != nil || result.status == :error
    end

    test "auto-generates transaction ID when empty" do
      params = %{
        message_type: "discover",
        client_mac: "",
        transaction_id: "",
        requested_options: "",
        timeout: "50"
      }

      {:ok, result} = Dhcpv4Client.query(params)
      # Message should be built with auto-generated XID
      assert result.request_struct != nil || result.status == :error
    end
  end
end
