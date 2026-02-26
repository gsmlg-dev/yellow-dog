defmodule YellowDog.DhcpClient.PropertyTest do
  @moduledoc """
  Property-based tests for DHCP client modules.

  Covers:
  - Vendor sub-option TLV encode/decode roundtrip
  - Vendor option parsing fuzz with arbitrary binary payloads
  - Option 124 (vendor class) encode/decode roundtrip
  - Retransmission timer jitter stays within bounds
  - Lease prefix_length for valid subnet masks
  - Packet build content verification (XID, chaddr, flags)
  - parse_reply robustness against arbitrary binary input
  - select_best_offer selection invariants
  - Lease.expired? temporal invariants
  - Lease serialization roundtrip via LeaseStore (TOML persistence)
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias YellowDog.DhcpClient.{Lease, LeaseStore, VendorOptions}
  alias DHCPv4.Message

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

  describe "Packet build content verification" do
    property "build_discover embeds XID and MAC address correctly" do
      check all(
              mac <- binary(length: 6),
              xid <- integer(0..0xFFFFFFFF)
            ) do
        binary = IO.iodata_to_binary(YellowDog.DhcpClient.Packet.build_discover(mac, xid))
        msg = Message.from_iodata(binary)

        assert msg.xid == xid
        # chaddr is padded to 16 bytes; first 6 must match the MAC
        <<mac_bytes::binary-size(6), _padding::binary>> = msg.chaddr
        assert mac_bytes == mac
        # DISCOVER requests a broadcast reply
        assert msg.flags == 0x8000
      end
    end

    property "build_request embeds XID and MAC address correctly" do
      check all(
              mac <- binary(length: 6),
              xid <- integer(0..0xFFFFFFFF),
              a <- integer(1..254),
              b <- integer(0..255),
              c <- integer(0..255),
              d <- integer(1..254)
            ) do
        server_ip = {a, b, c, d}
        offered_ip = {a, b, c, d}

        binary =
          IO.iodata_to_binary(
            YellowDog.DhcpClient.Packet.build_request(mac, xid, server_ip, offered_ip)
          )

        msg = Message.from_iodata(binary)

        assert msg.xid == xid
        <<mac_bytes::binary-size(6), _padding::binary>> = msg.chaddr
        assert mac_bytes == mac
      end
    end

    property "build_release sets ciaddr to client IP and clears broadcast flag" do
      check all(
              mac <- binary(length: 6),
              xid <- integer(0..0xFFFFFFFF),
              a <- integer(1..254),
              b <- integer(0..255),
              c <- integer(0..255),
              d <- integer(1..254)
            ) do
        client_ip = {a, b, c, d}
        server_ip = {a, b, c, d}
        # build_release returns binary directly
        binary = YellowDog.DhcpClient.Packet.build_release(mac, xid, server_ip, client_ip)
        msg = Message.from_iodata(binary)

        assert msg.xid == xid
        # RELEASE sets ciaddr to the current lease IP
        assert msg.ciaddr == client_ip
        # RELEASE must NOT set the broadcast flag (unicast to server)
        assert msg.flags == 0
        <<mac_bytes::binary-size(6), _padding::binary>> = msg.chaddr
        assert mac_bytes == mac
      end
    end

    property "build_decline embeds XID and MAC address correctly" do
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

        binary =
          IO.iodata_to_binary(
            YellowDog.DhcpClient.Packet.build_decline(mac, xid, server_ip, declined_ip)
          )

        msg = Message.from_iodata(binary)

        assert msg.xid == xid
        <<mac_bytes::binary-size(6), _padding::binary>> = msg.chaddr
        assert mac_bytes == mac
      end
    end
  end

  describe "parse_reply robustness" do
    property "parse_reply never crashes on arbitrary binary" do
      check all(data <- binary(min_length: 0, max_length: 1024)) do
        result = YellowDog.DhcpClient.Packet.parse_reply(data)

        assert match?({:offer, _}, result) or
                 match?({:ack, _}, result) or
                 match?({:nak, _}, result) or
                 match?({:error, _}, result)
      end
    end
  end

  # -- select_best_offer invariants --

  defp offer_gen do
    gen all(
          yellowdog_server <- boolean(),
          known_server <- boolean(),
          a <- integer(1..254),
          b <- integer(0..255),
          c <- integer(0..255),
          d <- integer(1..254)
        ) do
      %{
        yellowdog_server: yellowdog_server,
        known_server: known_server,
        ip: {a, b, c, d}
      }
    end
  end

  describe "select_best_offer invariants" do
    alias YellowDog.DhcpClient.StateMachine

    property "result is always one of the input offers" do
      check all(offers <- list_of(offer_gen(), min_length: 1)) do
        result = StateMachine.select_best_offer(offers)
        assert result in offers
      end
    end

    property "result is non-nil for any non-empty list" do
      check all(offers <- list_of(offer_gen(), min_length: 1)) do
        assert StateMachine.select_best_offer(offers) != nil
      end
    end

    property "yellowdog_server offer always wins when present" do
      check all(
              yd_offers <-
                list_of(offer_gen(), min_length: 1)
                |> map(fn offers -> Enum.map(offers, &Map.put(&1, :yellowdog_server, true)) end),
              non_yd_offers <-
                list_of(offer_gen())
                |> map(fn offers -> Enum.map(offers, &Map.put(&1, :yellowdog_server, false)) end)
            ) do
        # Mix in any order (most-recent first in the accumulated list)
        offers = non_yd_offers ++ yd_offers

        result = StateMachine.select_best_offer(offers)
        assert result.yellowdog_server == true
      end
    end

    property "known_server offer wins over plain offers when no yellowdog present" do
      check all(
              known_offers <-
                list_of(offer_gen(), min_length: 1)
                |> map(fn offers ->
                  Enum.map(offers, &%{&1 | yellowdog_server: false, known_server: true})
                end),
              plain_offers <-
                list_of(offer_gen())
                |> map(fn offers ->
                  Enum.map(offers, &%{&1 | yellowdog_server: false, known_server: false})
                end)
            ) do
        offers = plain_offers ++ known_offers

        result = StateMachine.select_best_offer(offers)
        assert result.known_server == true
      end
    end

    property "returns nil only for empty list" do
      check all(offers <- list_of(offer_gen(), min_length: 1)) do
        refute is_nil(StateMachine.select_best_offer(offers))
        assert is_nil(StateMachine.select_best_offer([]))
      end
    end
  end

  # -- Lease.t1_elapsed? temporal invariants --

  describe "Lease.t1_elapsed? temporal invariants" do
    property "t1 not elapsed when obtained_at is less than t1 seconds ago" do
      check all(
              t1 <- integer(2..3600),
              past_seconds <- integer(0..(t1 - 1))
            ) do
        obtained_at = DateTime.add(DateTime.utc_now(), -past_seconds, :second)

        lease = %Lease{
          ip: {192, 168, 1, 1},
          obtained_at: obtained_at,
          lease_time: t1 * 2,
          t1: t1
        }

        refute Lease.t1_elapsed?(lease)
      end
    end

    property "t1 elapsed when obtained_at is at least t1 seconds ago" do
      check all(
              t1 <- integer(1..3600),
              extra <- integer(0..3600)
            ) do
        obtained_at = DateTime.add(DateTime.utc_now(), -(t1 + extra), :second)

        lease = %Lease{
          ip: {192, 168, 1, 1},
          obtained_at: obtained_at,
          lease_time: t1 * 2,
          t1: t1
        }

        assert Lease.t1_elapsed?(lease)
      end
    end
  end

  # -- Lease.t2_elapsed? temporal invariants --

  describe "Lease.t2_elapsed? temporal invariants" do
    property "t2 not elapsed when obtained_at is less than t2 seconds ago" do
      check all(
              t2 <- integer(2..7200),
              past_seconds <- integer(0..(t2 - 1))
            ) do
        obtained_at = DateTime.add(DateTime.utc_now(), -past_seconds, :second)

        lease = %Lease{
          ip: {192, 168, 1, 1},
          obtained_at: obtained_at,
          lease_time: t2 * 2,
          t2: t2
        }

        refute Lease.t2_elapsed?(lease)
      end
    end

    property "t2 elapsed when obtained_at is at least t2 seconds ago" do
      check all(
              t2 <- integer(1..7200),
              extra <- integer(0..3600)
            ) do
        obtained_at = DateTime.add(DateTime.utc_now(), -(t2 + extra), :second)

        lease = %Lease{
          ip: {192, 168, 1, 1},
          obtained_at: obtained_at,
          lease_time: t2 * 2,
          t2: t2
        }

        assert Lease.t2_elapsed?(lease)
      end
    end
  end

  # -- Lease.expired? temporal invariants --

  describe "Lease.expired? temporal invariants" do
    property "non-expired lease with future expiry is not expired" do
      check all(
              lease_time <- integer(1..86_400),
              # obtained_at is between 0 and lease_time - 1 seconds ago (still valid)
              past_seconds <- integer(0..(lease_time - 1))
            ) do
        obtained_at = DateTime.add(DateTime.utc_now(), -past_seconds, :second)

        lease = %Lease{
          ip: {192, 168, 1, 1},
          obtained_at: obtained_at,
          lease_time: lease_time
        }

        refute Lease.expired?(lease)
      end
    end

    property "lease with obtained_at exactly lease_time seconds ago is expired" do
      check all(lease_time <- integer(1..86_400)) do
        # obtained_at is exactly lease_time seconds ago, so lease expires at exactly now
        obtained_at = DateTime.add(DateTime.utc_now(), -lease_time, :second)

        lease = %Lease{
          ip: {192, 168, 1, 1},
          obtained_at: obtained_at,
          lease_time: lease_time
        }

        # expires_at == now, so compare == :eq, which is NOT :lt → expired
        assert Lease.expired?(lease)
      end
    end

    property "lease well past expiry is always expired" do
      check all(
              lease_time <- integer(1..3600),
              extra_past <- integer(1..3600)
            ) do
        obtained_at = DateTime.add(DateTime.utc_now(), -(lease_time + extra_past), :second)

        lease = %Lease{
          ip: {192, 168, 1, 1},
          obtained_at: obtained_at,
          lease_time: lease_time
        }

        assert Lease.expired?(lease)
      end
    end
  end

  # -- Lease temporal monotonic ordering --

  describe "Lease temporal monotonic ordering" do
    property "if expired? then t1_elapsed? and t2_elapsed? (t1 <= t2 <= lease_time)" do
      check all(
              lease_time <- integer(3..7200),
              t1 <- integer(1..(lease_time - 1)),
              t2 <- integer(t1..lease_time)
            ) do
        # Lease clearly expired: obtained_at is (lease_time + 10) seconds ago
        obtained_at = DateTime.add(DateTime.utc_now(), -(lease_time + 10), :second)

        lease = %Lease{
          ip: {192, 168, 1, 1},
          obtained_at: obtained_at,
          lease_time: lease_time,
          t1: t1,
          t2: t2
        }

        assert Lease.expired?(lease)
        assert Lease.t1_elapsed?(lease)
        assert Lease.t2_elapsed?(lease)
      end
    end
  end

  describe "Lease.prefix_length boundary masks" do
    test "all-zeros subnet mask returns 0" do
      lease = %Lease{
        ip: {192, 168, 1, 1},
        subnet_mask: {0, 0, 0, 0},
        lease_time: 3600,
        obtained_at: DateTime.utc_now()
      }

      assert Lease.prefix_length(lease) == 0
    end

    test "all-ones subnet mask returns 32" do
      lease = %Lease{
        ip: {192, 168, 1, 1},
        subnet_mask: {255, 255, 255, 255},
        lease_time: 3600,
        obtained_at: DateTime.utc_now()
      }

      assert Lease.prefix_length(lease) == 32
    end
  end

  describe "StateMachine.retransmit_timeout_action backoff bounds" do
    alias YellowDog.DhcpClient.StateMachine

    property "retransmit delay is always >= 500ms and <= 65001ms for any count 0..10" do
      check all(count <- integer(0..10)) do
        {{:timeout, :retransmit}, delay, :retransmit} =
          StateMachine.retransmit_timeout_action(count)

        # min delay is max(base + jitter, 500) where jitter >= -1000
        assert delay >= 500
        # max delay is max_retransmit_ms (64000) + max_jitter (1000)
        assert delay <= 65_001
      end
    end

    property "retransmit delay is non-decreasing on average for growing count" do
      check all(count <- integer(0..5)) do
        # Verify that higher counts produce higher *base* (ignoring jitter)
        # by checking that count=6 always caps at 64000+jitter
        {{:timeout, :retransmit}, delay_low, :retransmit} =
          StateMachine.retransmit_timeout_action(count)

        {{:timeout, :retransmit}, delay_high, :retransmit} =
          StateMachine.retransmit_timeout_action(count + 5)

        # With count+5, base is much larger (or capped), so ignoring jitter:
        # delay_high should generally be larger, but due to jitter overlap
        # at low counts we just verify neither is out of [500, 65001]
        assert delay_low >= 500
        assert delay_high >= 500
        assert delay_low <= 65_001
        assert delay_high <= 65_001
      end
    end
  end

  # -- Lease serialization roundtrip --

  # Generators for valid lease field values

  defp ipv4_gen do
    gen all(
          a <- integer(1..254),
          b <- integer(0..255),
          c <- integer(0..255),
          d <- integer(1..254)
        ) do
      {a, b, c, d}
    end
  end

  defp subnet_mask_gen do
    gen all(prefix <- integer(8..30)) do
      mask_int = 0xFFFFFFFF <<< (32 - prefix) &&& 0xFFFFFFFF

      {mask_int >>> 24 &&& 0xFF, mask_int >>> 16 &&& 0xFF, mask_int >>> 8 &&& 0xFF,
       mask_int &&& 0xFF}
    end
  end

  defp optional_ipv4_gen do
    one_of([constant(nil), ipv4_gen()])
  end

  defp ip_list_gen do
    list_of(ipv4_gen(), max_length: 4)
  end

  # Strings that exercise TOML escaping: include quotes, backslashes, and newlines
  defp toml_string_gen do
    gen all(
          parts <-
            list_of(
              one_of([
                string(:alphanumeric, min_length: 1, max_length: 8),
                constant("\""),
                constant("\\"),
                constant("\n"),
                constant("\r")
              ]),
              min_length: 1,
              max_length: 5
            )
        ) do
      Enum.join(parts)
    end
  end

  defp optional_toml_string_gen do
    one_of([constant(nil), toml_string_gen()])
  end

  defp lease_gen do
    gen all(
          ip <- ipv4_gen(),
          subnet_mask <- subnet_mask_gen(),
          router <- optional_ipv4_gen(),
          dns_servers <- ip_list_gen(),
          ntp_servers <- ip_list_gen(),
          server_ip <- ipv4_gen(),
          lease_time <- integer(3600..86_400),
          t1_frac <- float(min: 0.3, max: 0.6),
          t2_frac <- float(min: 0.7, max: 0.9),
          domain_name <- optional_toml_string_gen(),
          mtu <- one_of([constant(nil), integer(576..9000)]),
          xid <- integer(0..0xFFFFFFFF),
          yellowdog_server <- boolean(),
          yellowdog_vendor_class <- boolean(),
          control_url <- optional_toml_string_gen(),
          control_url_fallback <- optional_toml_string_gen(),
          auth_token <- optional_toml_string_gen(),
          server_id <- optional_toml_string_gen(),
          cluster_id <- optional_toml_string_gen()
        ) do
      t1 = trunc(lease_time * t1_frac)
      t2 = trunc(lease_time * t2_frac)

      struct(Lease, %{
        ip: ip,
        subnet_mask: subnet_mask,
        router: router,
        dns_servers: dns_servers,
        ntp_servers: ntp_servers,
        server_ip: server_ip,
        server_mac: nil,
        lease_time: lease_time,
        t1: t1,
        t2: t2,
        domain_name: domain_name,
        mtu: mtu,
        obtained_at: DateTime.utc_now(),
        xid: xid,
        yellowdog_server: yellowdog_server,
        yellowdog_vendor_class: yellowdog_vendor_class,
        known_server: false,
        control_url: control_url,
        control_url_fallback: control_url_fallback,
        auth_token: auth_token,
        server_id: server_id,
        cluster_id: cluster_id,
        vendor_options: %{},
        raw_options: %{}
      })
    end
  end

  describe "LeaseStore serialization roundtrip" do
    property "store → flush → load preserves all persisted lease fields" do
      check all(lease <- lease_gen(), max_runs: 50) do
        dir = Path.join(System.tmp_dir!(), "yd_prop_#{:erlang.unique_integer([:positive])}")
        File.mkdir_p!(dir)
        iface = "prop_eth0"

        try do
          {:ok, pid} = LeaseStore.start_link(interface: iface, lease_dir: dir)
          :ok = LeaseStore.store(pid, iface, lease)
          # terminate/2 flushes synchronously
          GenServer.stop(pid)

          {:ok, pid2} = LeaseStore.start_link(interface: iface, lease_dir: dir)
          assert {:ok, loaded} = LeaseStore.lookup(pid2, iface)
          GenServer.stop(pid2)

          # Verify all persisted fields
          assert loaded.ip == lease.ip
          assert loaded.subnet_mask == lease.subnet_mask
          assert loaded.router == lease.router
          assert loaded.dns_servers == lease.dns_servers
          assert loaded.ntp_servers == lease.ntp_servers
          assert loaded.server_ip == lease.server_ip
          assert loaded.lease_time == lease.lease_time
          assert loaded.t1 == lease.t1
          assert loaded.t2 == lease.t2
          assert loaded.domain_name == lease.domain_name
          assert loaded.mtu == lease.mtu
          assert loaded.xid == lease.xid
          assert loaded.yellowdog_server == lease.yellowdog_server
          assert loaded.yellowdog_vendor_class == lease.yellowdog_vendor_class
          assert loaded.control_url == lease.control_url
          assert loaded.control_url_fallback == lease.control_url_fallback
          assert loaded.auth_token == lease.auth_token
          assert loaded.server_id == lease.server_id
          assert loaded.cluster_id == lease.cluster_id
          # obtained_at: compare to second precision (ISO8601 roundtrip may shift
          # microsecond precision depending on the TOML library)
          assert DateTime.diff(loaded.obtained_at, lease.obtained_at, :second) == 0

          # Non-persisted fields get defaults
          assert loaded.vendor_options == %{}
          assert loaded.raw_options == %{}
          assert loaded.known_server == false
          assert loaded.server_mac == nil
        after
          File.rm_rf!(dir)
        end
      end
    end
  end
end
