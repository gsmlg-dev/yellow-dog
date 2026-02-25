defmodule YellowDog.Resolved.DiscoveryTest do
  use ExUnit.Case, async: true

  alias YellowDog.Resolved.Discovery

  describe "encode_edns_option/1" do
    test "encodes EDNS option with instance ID" do
      instance_id = :crypto.strong_rand_bytes(16)
      encoded = Discovery.encode_edns_option(instance_id)

      # Option code 65321 (2 bytes) + length (2 bytes) + version (1 byte) + instance_id (16 bytes)
      assert byte_size(encoded) == 2 + 2 + 1 + 16

      <<code::16, length::16, version::8, id::binary-size(16)>> = encoded
      assert code == 65321
      assert length == 17
      assert version == 1
      assert id == instance_id
    end

    test "encoded size is consistent across different IDs" do
      ids = for _ <- 1..10, do: :crypto.strong_rand_bytes(16)
      sizes = Enum.map(ids, fn id -> byte_size(Discovery.encode_edns_option(id)) end)
      assert Enum.uniq(sizes) == [21]
    end
  end

  describe "decode_edns_option/1" do
    test "decodes a valid option" do
      instance_id = :crypto.strong_rand_bytes(16)
      encoded = Discovery.encode_edns_option(instance_id)

      assert {:ok, decoded} = Discovery.decode_edns_option(encoded)
      assert decoded.version == 1
      assert decoded.data == instance_id
    end

    test "encode/decode roundtrip preserves instance ID" do
      for _ <- 1..10 do
        original_id = :crypto.strong_rand_bytes(16)
        encoded = Discovery.encode_edns_option(original_id)
        assert {:ok, decoded} = Discovery.decode_edns_option(encoded)
        assert decoded.data == original_id
      end
    end

    test "returns error for invalid data" do
      assert :error = Discovery.decode_edns_option(<<0, 0, 0, 0>>)
    end

    test "returns error for empty binary" do
      assert :error = Discovery.decode_edns_option(<<>>)
    end

    test "returns error for wrong option code" do
      # Valid structure but wrong option code (65320 instead of 65321)
      data = <<1::8, :crypto.strong_rand_bytes(16)::binary>>

      assert :error =
               Discovery.decode_edns_option(<<65320::16, byte_size(data)::16, data::binary>>)
    end

    test "returns error for truncated data" do
      # Correct option code but truncated payload
      assert :error = Discovery.decode_edns_option(<<65321::16, 5::16, 1::8>>)
    end
  end

  describe "status/0 via GenServer" do
    setup do
      # Start Discovery with discovery disabled (no actual probes)
      config = %{
        upstreams: [{198, 51, 100, 1}],
        upstream_timeout_ms: 200,
        discovery: %{
          enabled: true,
          websocket: %{heartbeat_interval_s: 30, reconnect_base_s: 5, reconnect_max_s: 60}
        }
      }

      # Use a unique name to avoid conflicts
      name = :"discovery_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(Discovery, config, name: name)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      %{pid: pid}
    end

    test "returns instance_id as hex string", %{pid: pid} do
      status = GenServer.call(pid, :status)

      assert is_binary(status.instance_id)
      assert String.length(status.instance_id) == 32
      # Should be valid hex
      assert String.match?(status.instance_id, ~r/^[0-9a-f]{32}$/)
    end

    test "ws_endpoint is nil before discovery completes", %{pid: pid} do
      status = GenServer.call(pid, :status)
      assert status.ws_endpoint == nil
    end

    test "connected is false when no management connection", %{pid: pid} do
      status = GenServer.call(pid, :status)
      assert status.connected == false
    end
  end

  describe "parse_discovery_response/1" do
    test "returns :not_found for non-YellowDog response" do
      # Build a basic DNS response without EDNS option 65321
      query = DNS.Message.new()
      query = DNS.Message.update_header_attr(query, :id, 1)
      query = DNS.Message.update_header_attr(query, :qr, 1)
      binary = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert :not_found = Discovery.parse_discovery_response(binary)
    end

    test "returns :not_found for invalid binary" do
      assert :not_found = Discovery.parse_discovery_response(<<0, 0, 0>>)
    end

    test "returns :not_found for empty binary" do
      assert :not_found = Discovery.parse_discovery_response(<<>>)
    end

    test "returns :not_found for random garbage" do
      assert :not_found = Discovery.parse_discovery_response(:crypto.strong_rand_bytes(50))
    end

    test "returns :not_found when EDNS option present but no SRV record" do
      # Build a response with OPT record containing EDNS 65321 but no SRV answer
      response = DNS.Message.new()
      response = DNS.Message.update_header_attr(response, :id, 100)
      response = DNS.Message.update_header_attr(response, :qr, 1)

      # Add OPT record with yellowdog EDNS option (version 1 + ws path)
      ws_path = "/ws/manage"
      edns_data = <<1::8, ws_path::binary>>

      opt_record = DNS.Message.Record.new(".", 41, 4096, 0, edns_data)

      response = Map.update(response, :arlist, [opt_record], &[opt_record | &1])
      response = DNS.Message.update_header_attr(response, :arcount, 1)

      binary = DNS.to_iodata(response) |> IO.iodata_to_binary()
      assert :not_found = Discovery.parse_discovery_response(binary)
    end
  end
end
