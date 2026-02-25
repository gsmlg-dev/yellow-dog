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
  end
end
