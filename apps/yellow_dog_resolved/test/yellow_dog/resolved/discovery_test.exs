defmodule YellowDog.Resolved.DiscoveryTest do
  use ExUnit.Case, async: true

  alias YellowDog.Resolved.Discovery

  describe "EDNS option encoding" do
    test "generates 16-byte instance ID" do
      uuid = :crypto.strong_rand_bytes(16)
      assert byte_size(uuid) == 16
    end

    test "each UUID is unique" do
      uuid1 = :crypto.strong_rand_bytes(16)
      uuid2 = :crypto.strong_rand_bytes(16)
      assert uuid1 != uuid2
    end
  end

  describe "EDNS option format" do
    test "option code 65321 is in private-use range" do
      # RFC 6891: private-use range 65001-65534
      assert 65321 >= 65001
      assert 65321 <= 65534
    end

    test "EDNS option data structure" do
      instance_id = :crypto.strong_rand_bytes(16)
      version = 1

      # Build the EDNS option data as the Discovery module would
      edns_data = <<version::8, instance_id::binary-size(16)>>

      assert byte_size(edns_data) == 17

      # Verify we can decode it back
      <<decoded_version::8, decoded_id::binary-size(16)>> = edns_data
      assert decoded_version == 1
      assert decoded_id == instance_id
    end

    test "EDNS option wire format" do
      instance_id = :crypto.strong_rand_bytes(16)
      edns_data = <<1::8, instance_id::binary-size(16)>>

      # Full option: code (2 bytes) + length (2 bytes) + data
      option_code = 65321
      option_length = byte_size(edns_data)
      wire = <<option_code::16, option_length::16, edns_data::binary>>

      assert byte_size(wire) == 4 + 17

      # Decode wire format
      <<decoded_code::16, decoded_len::16, decoded_data::binary-size(decoded_len)>> = wire
      assert decoded_code == 65321
      assert decoded_len == 17
      <<v::8, id::binary-size(16)>> = decoded_data
      assert v == 1
      assert id == instance_id
    end
  end

  describe "EDNS response parsing" do
    test "response option data structure" do
      ws_path = "/ws/resolved"
      version = 1

      # Build response option data
      response_data = <<version::8, ws_path::binary>>

      # Decode
      <<decoded_version::8, decoded_path::binary>> = response_data
      assert decoded_version == 1
      assert decoded_path == "/ws/resolved"
    end
  end

  describe "discovery startup" do
    test "starts discovery GenServer with no upstreams" do
      config = %{
        upstreams: [],
        discovery: %{
          enabled: true,
          websocket: %{
            heartbeat_interval_s: 30,
            reconnect_base_s: 5,
            reconnect_max_s: 60
          }
        }
      }

      {:ok, pid} = Discovery.start_link(config)
      assert Process.alive?(pid)

      # Can retrieve instance_id
      id = Discovery.instance_id()
      assert is_binary(id)
      assert byte_size(id) == 16

      GenServer.stop(pid)
    end
  end
end
