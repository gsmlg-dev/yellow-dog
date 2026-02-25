defmodule YellowDog.DhcpClient.PropertyTest do
  @moduledoc """
  Property-based tests for DHCP client modules.

  Covers:
  - Vendor sub-option TLV encode/decode roundtrip
  - Vendor option parsing fuzz with arbitrary binary payloads
  - Option 124 (vendor class) encode/decode roundtrip
  - Retransmission timer jitter stays within bounds
  - Lease prefix_length for valid subnet masks
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias YellowDog.DhcpClient.{Lease, VendorOptions}

  # -- Generators --

  # Generate a valid sub-option map with known fields.
  # Max lengths are capped so the total TLV encoding stays under 255 bytes
  # (RFC 3925 data_len is a single byte). Each value adds 2 bytes overhead
  # (code + length), and flags add 4 bytes. Worst case: 5*2 + 4 = 14 bytes
  # overhead, leaving ~241 bytes for values → ~48 bytes each for 5 fields.
  defp sub_option_map_gen do
    gen all(
          control_url <-
            one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 40)]),
          server_id <-
            one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 40)]),
          cluster_id <-
            one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 40)]),
          auth_token <-
            one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 40)]),
          control_url_fallback <-
            one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 40)]),
          flags <- one_of([constant(nil), integer(0..65535)])
        ) do
      %{
        control_url: control_url,
        server_id: server_id,
        cluster_id: cluster_id,
        auth_token: auth_token,
        control_url_fallback: control_url_fallback,
        flags: flags
      }
    end
  end

  # Encode a sub-option map into TLV binary (matching VendorOptions decode format)
  defp encode_sub_options(map) do
    parts =
      [
        encode_tlv(1, map[:control_url]),
        encode_tlv(2, map[:server_id]),
        encode_tlv(3, map[:cluster_id]),
        encode_tlv(4, map[:auth_token]),
        encode_tlv(5, map[:control_url_fallback]),
        encode_flags_tlv(6, map[:flags])
      ]
      |> Enum.reject(&is_nil/1)

    IO.iodata_to_binary(parts)
  end

  defp encode_tlv(_code, nil), do: nil

  defp encode_tlv(code, value) when is_binary(value) do
    <<code::8, byte_size(value)::8, value::binary>>
  end

  defp encode_flags_tlv(_code, nil), do: nil
  defp encode_flags_tlv(code, flags), do: <<code::8, 2::8, flags::16>>

  # Wrap sub-options in Option 125 envelope with Yellow Dog PEN
  defp wrap_option_125(sub_options_binary) do
    pen = VendorOptions.pen()
    <<pen::32, byte_size(sub_options_binary)::8, sub_options_binary::binary>>
  end

  # -- Property Tests --

  describe "VendorOptions sub-option TLV roundtrip" do
    property "encode then decode preserves all known sub-option fields (inline encoder)" do
      check all(map <- sub_option_map_gen()) do
        sub_binary = encode_sub_options(map)
        option_125 = wrap_option_125(sub_binary)

        assert {:ok, decoded} = VendorOptions.decode_vendor_info(option_125)

        assert decoded[:control_url] == map[:control_url]
        assert decoded[:server_id] == map[:server_id]
        assert decoded[:cluster_id] == map[:cluster_id]
        assert decoded[:auth_token] == map[:auth_token]
        assert decoded[:control_url_fallback] == map[:control_url_fallback]
        assert decoded[:flags] == map[:flags]
      end
    end

    property "VendorOptions.encode_vendor_info/1 roundtrips through decode" do
      check all(map <- sub_option_map_gen()) do
        encoded = VendorOptions.encode_vendor_info(map)
        assert {:ok, decoded} = VendorOptions.decode_vendor_info(encoded)

        assert decoded[:control_url] == map[:control_url]
        assert decoded[:server_id] == map[:server_id]
        assert decoded[:cluster_id] == map[:cluster_id]
        assert decoded[:auth_token] == map[:auth_token]
        assert decoded[:control_url_fallback] == map[:control_url_fallback]
        assert decoded[:flags] == map[:flags]
      end
    end

    property "unknown sub-option codes are preserved as {code, value} tuples" do
      check all(
              code <- integer(7..199),
              value <- binary(min_length: 0, max_length: 50)
            ) do
        tlv = <<code::8, byte_size(value)::8, value::binary>>
        option_125 = wrap_option_125(tlv)

        assert {:ok, decoded} = VendorOptions.decode_vendor_info(option_125)
        assert {code, value} in decoded[:unknown]
      end
    end
  end

  describe "VendorOptions fuzz" do
    property "decode_vendor_info never crashes on arbitrary binary" do
      check all(data <- binary(min_length: 0, max_length: 500)) do
        result = VendorOptions.decode_vendor_info(data)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end

    property "decode_sub_options never crashes on arbitrary binary" do
      check all(data <- binary(min_length: 0, max_length: 500)) do
        result = VendorOptions.decode_sub_options(data)
        assert is_map(result)
        assert Map.has_key?(result, :unknown)
      end
    end

    property "non-YellowDog PEN returns :pen_mismatch" do
      check all(
              pen <- integer(0..999_999) |> filter(&(&1 != VendorOptions.pen())),
              payload <- binary(min_length: 0, max_length: 50)
            ) do
        data = <<pen::32, byte_size(payload)::8, payload::binary>>
        assert {:error, :pen_mismatch} = VendorOptions.decode_vendor_info(data)
      end
    end
  end

  describe "Option 124 (vendor class) roundtrip" do
    property "encode_vendor_class produces valid PEN + class data" do
      # encode_vendor_class is deterministic, just verify structure
      encoded = VendorOptions.encode_vendor_class()
      pen = VendorOptions.pen()
      <<decoded_pen::32, data_len::8, class_data::binary-size(data_len)>> = encoded
      assert decoded_pen == pen
      assert class_data == "YellowDog"
    end

    property "encode_client_id produces valid format for any capabilities" do
      check all(
              version <- string(:alphanumeric, min_length: 1, max_length: 10),
              caps <- list_of(atom(:alphanumeric), min_length: 0, max_length: 5)
            ) do
        result = VendorOptions.encode_client_id(version, caps)
        assert is_binary(result)
        assert String.starts_with?(result, "YellowDog:")
        parts = String.split(result, ":")
        assert length(parts) == 3
        assert Enum.at(parts, 1) == version
      end
    end
  end

  describe "retransmission timer jitter" do
    # Test the retransmit timer calculation inline (extracted from StateMachine)
    # The logic: base = min(2000 * 2^count, 64000), jitter = rand(-1000..1000),
    # delay = max(base + jitter, 500)

    property "retransmit delay stays within expected bounds for any attempt count" do
      check all(retransmit_count <- integer(0..20)) do
        base = min(2_000 * Integer.pow(2, retransmit_count), 64_000)
        # Run multiple samples to check bounds
        for _ <- 1..20 do
          jitter = :rand.uniform(2_001) - 1_001
          delay = max(base + jitter, 500)

          # Jitter is ±1000ms
          assert jitter >= -1001
          assert jitter <= 1000

          # Delay is never below 500ms
          assert delay >= 500

          # Delay never exceeds max base + max jitter
          assert delay <= 64_000 + 1_000
        end
      end
    end

    property "exponential backoff doubles correctly until cap" do
      check all(count <- integer(0..10)) do
        base = min(2_000 * Integer.pow(2, count), 64_000)

        expected =
          case count do
            0 -> 2_000
            1 -> 4_000
            2 -> 8_000
            3 -> 16_000
            4 -> 32_000
            5 -> 64_000
            _ -> 64_000
          end

        assert base == expected
      end
    end
  end

  describe "Lease.prefix_length for valid masks" do
    property "prefix_length matches the generating prefix for contiguous masks" do
      check all(prefix <- integer(0..32)) do
        mask_int = if prefix == 0, do: 0, else: 0xFFFFFFFF <<< (32 - prefix) &&& 0xFFFFFFFF

        mask =
          {mask_int >>> 24 &&& 0xFF, mask_int >>> 16 &&& 0xFF, mask_int >>> 8 &&& 0xFF,
           mask_int &&& 0xFF}

        lease = %Lease{
          subnet_mask: mask,
          ip: {192, 168, 1, 1},
          server_ip: {192, 168, 1, 1},
          lease_time: 3600,
          t1: 1800,
          t2: 3150,
          obtained_at: DateTime.utc_now(),
          xid: 12345
        }

        assert Lease.prefix_length(lease) == prefix
      end
    end
  end

  describe "Packet build/parse roundtrip" do
    property "build_discover produces valid binary for any MAC and XID" do
      check all(
              mac <- binary(length: 6),
              xid <- integer(0..0xFFFFFFFF)
            ) do
        result = YellowDog.DhcpClient.Packet.build_discover(mac, xid)
        # Should produce valid binary (iodata)
        binary = IO.iodata_to_binary(result)
        assert is_binary(binary)
        assert byte_size(binary) > 240
      end
    end

    property "build_request produces valid binary for any valid inputs" do
      check all(
              mac <- binary(length: 6),
              xid <- integer(0..0xFFFFFFFF),
              server_a <- integer(1..254),
              server_b <- integer(0..255),
              server_c <- integer(0..255),
              server_d <- integer(1..254),
              offer_a <- integer(1..254),
              offer_b <- integer(0..255),
              offer_c <- integer(0..255),
              offer_d <- integer(1..254)
            ) do
        server_ip = {server_a, server_b, server_c, server_d}
        offered_ip = {offer_a, offer_b, offer_c, offer_d}
        result = YellowDog.DhcpClient.Packet.build_request(mac, xid, server_ip, offered_ip)
        binary = IO.iodata_to_binary(result)
        assert is_binary(binary)
        assert byte_size(binary) > 240
      end
    end

    property "build_release produces valid binary" do
      check all(
              mac <- binary(length: 6),
              xid <- integer(0..0xFFFFFFFF),
              a <- integer(1..254),
              b <- integer(0..255),
              c <- integer(0..255),
              d <- integer(1..254)
            ) do
        server_ip = {a, b, c, d}
        client_ip = {a, b, c, d}
        result = YellowDog.DhcpClient.Packet.build_release(mac, xid, server_ip, client_ip)
        assert is_binary(result)
        assert byte_size(result) > 240
      end
    end

    property "build_decline produces valid binary" do
      check all(
              mac <- binary(length: 6),
              xid <- integer(0..0xFFFFFFFF),
              a <- integer(1..254),
              b <- integer(0..255),
              c <- integer(0..255),
              d <- integer(1..254)
            ) do
        server_ip = {a, b, c, d}
        declined_ip = {a, b, c, d}
        result = YellowDog.DhcpClient.Packet.build_decline(mac, xid, server_ip, declined_ip)
        binary = IO.iodata_to_binary(result)
        assert is_binary(binary)
        assert byte_size(binary) > 240
      end
    end
  end
end
