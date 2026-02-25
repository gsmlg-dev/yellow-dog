defmodule YellowDog.DhcpClient.VendorOptionsTest do
  use ExUnit.Case, async: true

  alias YellowDog.DhcpClient.VendorOptions

  @yellowdog_pen 99_999

  # ── pen/0 ──

  test "pen/0 returns the Yellow Dog PEN" do
    assert VendorOptions.pen() == 99_999
  end

  # ── encode_client_id/2 ──

  test "encodes client ID with version and capabilities" do
    result = VendorOptions.encode_client_id("1.0", [:dns, :telemetry])
    assert result == "YellowDog:1.0:dns,telemetry"
  end

  test "encodes client ID with single capability" do
    result = VendorOptions.encode_client_id("2.1", [:dhcp])
    assert result == "YellowDog:2.1:dhcp"
  end

  test "encodes client ID with empty capabilities" do
    result = VendorOptions.encode_client_id("1.0", [])
    assert result == "YellowDog:1.0:"
  end

  test "encodes client ID with many capabilities" do
    result = VendorOptions.encode_client_id("1.0", [:dns, :dhcp, :mdns, :netboot])
    assert result == "YellowDog:1.0:dns,dhcp,mdns,netboot"
  end

  # ── encode_vendor_class/0 ──

  test "encodes vendor class with PEN 99999 and YellowDog string" do
    result = VendorOptions.encode_vendor_class()
    expected = <<@yellowdog_pen::32, 9::8, "YellowDog">>
    assert result == expected
  end

  test "vendor class binary has correct total length" do
    result = VendorOptions.encode_vendor_class()
    # 4 bytes PEN + 1 byte length + 9 bytes "YellowDog"
    assert byte_size(result) == 14
  end

  test "vendor class starts with PEN in big-endian" do
    <<pen::32, _rest::binary>> = VendorOptions.encode_vendor_class()
    assert pen == @yellowdog_pen
  end

  # ── decode_vendor_info/1 ──

  test "decodes vendor info with matching PEN and sub-options" do
    sub_opts = <<1, 24, "https://example.com:8443">>
    data = <<@yellowdog_pen::32, byte_size(sub_opts)::8, sub_opts::binary>>

    assert {:ok, result} = VendorOptions.decode_vendor_info(data)
    assert result.control_url == "https://example.com:8443"
  end

  test "decodes vendor info with all sub-option types" do
    sub_opts =
      <<1, 21, "http://localhost:4270">> <>
        <<2, 6, "srv-01">> <>
        <<3, 8, "cluster1">> <>
        <<4, 16, "tok-abcdef123456">> <>
        <<5, 23, "http://fallback.yd:4270">> <>
        <<6, 2, 0::8, 3::8>>

    data = <<@yellowdog_pen::32, byte_size(sub_opts)::8, sub_opts::binary>>

    assert {:ok, result} = VendorOptions.decode_vendor_info(data)
    assert result.control_url == "http://localhost:4270"
    assert result.server_id == "srv-01"
    assert result.cluster_id == "cluster1"
    assert result.auth_token == "tok-abcdef123456"
    assert result.control_url_fallback == "http://fallback.yd:4270"
    assert result.flags == 3
    assert result.unknown == []
  end

  test "returns :pen_mismatch for wrong PEN" do
    wrong_pen = 12_345
    sub_opts = <<1, 3, "foo">>
    data = <<wrong_pen::32, byte_size(sub_opts)::8, sub_opts::binary>>

    assert {:error, :pen_mismatch} = VendorOptions.decode_vendor_info(data)
  end

  test "returns :malformed for empty binary" do
    assert {:error, :malformed} = VendorOptions.decode_vendor_info(<<>>)
  end

  test "returns :malformed for truncated binary" do
    assert {:error, :malformed} = VendorOptions.decode_vendor_info(<<1, 2, 3>>)
  end

  test "returns :pen_mismatch for string that parses as wrong PEN" do
    # "short" is 5 bytes, which is enough for <<pen::32, data_len::8, ...>>
    # but the decoded PEN won't match Yellow Dog's
    assert {:error, :pen_mismatch} = VendorOptions.decode_vendor_info("short")
  end

  test "returns :malformed for 4-byte binary (no data_len)" do
    assert {:error, :malformed} = VendorOptions.decode_vendor_info(<<0, 0, 0, 1>>)
  end

  test "decode_vendor_info ignores trailing data after declared length" do
    sub_opts = <<2, 4, "test">>
    trailing = <<0xFF, 0xFF, 0xFF>>
    data = <<@yellowdog_pen::32, byte_size(sub_opts)::8, sub_opts::binary, trailing::binary>>

    assert {:ok, result} = VendorOptions.decode_vendor_info(data)
    assert result.server_id == "test"
  end

  # ── decode_sub_options/1 ──

  test "decodes all known sub-option codes" do
    data =
      <<1, 3, "url">> <>
        <<2, 3, "sid">> <>
        <<3, 3, "cid">> <>
        <<4, 3, "tok">> <>
        <<5, 4, "fall">> <>
        <<6, 2, 0x00, 0x0F>>

    result = VendorOptions.decode_sub_options(data)

    assert result.control_url == "url"
    assert result.server_id == "sid"
    assert result.cluster_id == "cid"
    assert result.auth_token == "tok"
    assert result.control_url_fallback == "fall"
    assert result.flags == 15
    assert result.unknown == []
  end

  test "preserves unknown sub-option codes" do
    data = <<99, 3, "abc", 100, 2, "de">>
    result = VendorOptions.decode_sub_options(data)

    assert result.unknown == [{99, "abc"}, {100, "de"}]
  end

  test "handles empty sub-options" do
    result = VendorOptions.decode_sub_options(<<>>)
    assert result == %{unknown: []}
  end

  test "handles flags as uint16" do
    data = <<6, 2, 0x01, 0x00>>
    result = VendorOptions.decode_sub_options(data)
    assert result.flags == 256
  end

  test "ignores flags with invalid length" do
    # flags sub-option with 3 bytes instead of 2 should be ignored
    data = <<6, 3, 0x01, 0x00, 0x00>>
    result = VendorOptions.decode_sub_options(data)
    refute Map.has_key?(result, :flags)
  end

  test "stops parsing at 0xFF end marker" do
    data = <<1, 3, "url", 255, 2, 3, "sid">>
    result = VendorOptions.decode_sub_options(data)
    assert result.control_url == "url"
    refute Map.has_key?(result, :server_id)
  end

  test "skips padding bytes (code 0)" do
    data = <<0, 0, 1, 3, "url">>
    result = VendorOptions.decode_sub_options(data)
    assert result.control_url == "url"
  end

  test "handles malformed trailing data gracefully" do
    # Truncated TLV: code=1, len=10 but only 3 bytes follow
    data = <<1, 10, "abc">>
    result = VendorOptions.decode_sub_options(data)
    # Should return what was parsed so far without crashing
    assert is_map(result)
  end

  # ── Roundtrip ──

  test "encode/decode roundtrip for Option 124 vendor class" do
    encoded = VendorOptions.encode_vendor_class()

    <<pen::32, data_len::8, class_data::binary-size(data_len)>> = encoded

    assert pen == @yellowdog_pen
    assert class_data == "YellowDog"
  end

  test "encode/decode roundtrip for Option 125 vendor info" do
    # Encode sub-options manually
    sub_opts =
      <<1, 21, "http://localhost:4270">> <>
        <<2, 6, "srv-01">> <>
        <<4, 8, "mytoken!">>

    encoded = <<@yellowdog_pen::32, byte_size(sub_opts)::8, sub_opts::binary>>

    assert {:ok, decoded} = VendorOptions.decode_vendor_info(encoded)
    assert decoded.control_url == "http://localhost:4270"
    assert decoded.server_id == "srv-01"
    assert decoded.auth_token == "mytoken!"
    assert decoded.unknown == []
  end
end
