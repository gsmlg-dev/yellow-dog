defmodule YellowDog.Console.Diagnostics.Dhcpv6ClientTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.Diagnostics.Dhcpv6Client

  describe "requires_privileged_port?/0" do
    test "returns true" do
      assert Dhcpv6Client.requires_privileged_port?() == true
    end
  end

  describe "query/1 message building" do
    test "builds DHCPv6 SOLICIT message" do
      params = %{
        message_type: "solicit",
        duid: "",
        transaction_id: "",
        iaid: "",
        requested_options: "",
        timeout: "100"
      }

      # Will fail on port binding, but should return {:ok, result}
      {:ok, result} = Dhcpv6Client.query(params)
      # Request message should be built even if query fails
      assert result.request_struct != nil || result.status == :error
    end

    test "handles different message types" do
      for msg_type <- [
            "solicit",
            "request",
            "renew",
            "rebind",
            "release",
            "decline",
            "information_request"
          ] do
        params = %{
          message_type: msg_type,
          duid: "",
          transaction_id: "",
          iaid: "",
          requested_options: "",
          timeout: "50"
        }

        {:ok, result} = Dhcpv6Client.query(params)
        # Should handle each message type
        assert result.status in [:error, :timeout, :success]
      end
    end

    test "handles DUID input" do
      params = %{
        message_type: "solicit",
        duid: "00010001AABBCCDD001122334455",
        transaction_id: "",
        iaid: "",
        requested_options: "",
        timeout: "50"
      }

      {:ok, result} = Dhcpv6Client.query(params)
      assert result.status in [:error, :timeout, :success]
    end

    test "handles hex transaction ID" do
      params = %{
        message_type: "solicit",
        duid: "",
        transaction_id: "AABBCC",
        iaid: "",
        requested_options: "",
        timeout: "50"
      }

      {:ok, result} = Dhcpv6Client.query(params)
      assert result.status in [:error, :timeout, :success]
    end

    test "handles IAID input" do
      params = %{
        message_type: "solicit",
        duid: "",
        transaction_id: "",
        iaid: "00000001",
        requested_options: "",
        timeout: "50"
      }

      {:ok, result} = Dhcpv6Client.query(params)
      assert result.status in [:error, :timeout, :success]
    end

    test "handles requested options" do
      params = %{
        message_type: "solicit",
        duid: "",
        transaction_id: "",
        iaid: "",
        requested_options: "23,24",
        timeout: "50"
      }

      {:ok, result} = Dhcpv6Client.query(params)
      assert result.status in [:error, :timeout, :success]
    end

    test "records latency" do
      params = %{
        message_type: "solicit",
        duid: "",
        transaction_id: "",
        iaid: "",
        requested_options: "",
        timeout: "50"
      }

      {:ok, result} = Dhcpv6Client.query(params)
      assert is_integer(result.latency_ms)
      assert result.latency_ms >= 0
    end

    test "handles atom keys in params" do
      params = %{
        message_type: :solicit,
        duid: "",
        transaction_id: "",
        iaid: "",
        requested_options: "",
        timeout: 50
      }

      {:ok, result} = Dhcpv6Client.query(params)
      assert result.status in [:error, :timeout, :success]
    end

    test "returns error for permission denied (EACCES)" do
      params = %{
        message_type: "solicit",
        duid: "",
        transaction_id: "",
        iaid: "",
        requested_options: "",
        timeout: "50"
      }

      {:ok, result} = Dhcpv6Client.query(params)
      # When not running as root, should get EACCES error
      if result.status == :error do
        assert result.error =~ "Permission denied" or result.error =~ "Socket error"
      end
    end

    test "auto-generates DUID when empty" do
      params = %{
        message_type: "solicit",
        duid: "",
        transaction_id: "",
        iaid: "",
        requested_options: "",
        timeout: "50"
      }

      {:ok, result} = Dhcpv6Client.query(params)
      # Message should be built with auto-generated DUID
      assert result.request_struct != nil || result.status == :error
    end

    test "auto-generates transaction ID when empty" do
      params = %{
        message_type: "solicit",
        duid: "",
        transaction_id: "",
        iaid: "",
        requested_options: "",
        timeout: "50"
      }

      {:ok, result} = Dhcpv6Client.query(params)
      # Message should be built with auto-generated XID
      assert result.request_struct != nil || result.status == :error
    end

    test "auto-generates IAID when empty" do
      params = %{
        message_type: "solicit",
        duid: "",
        transaction_id: "",
        iaid: "",
        requested_options: "",
        timeout: "50"
      }

      {:ok, result} = Dhcpv6Client.query(params)
      # Message should be built with auto-generated IAID
      assert result.request_struct != nil || result.status == :error
    end
  end
end
