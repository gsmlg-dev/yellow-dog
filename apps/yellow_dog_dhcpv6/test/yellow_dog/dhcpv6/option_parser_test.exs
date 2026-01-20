defmodule YellowDog.Dhcpv6.OptionParserTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv6.OptionParser

  # DHCPv6 option codes
  @option_client_id 1
  @option_server_id 2
  @option_ia_na 3
  @option_ia_ta 4
  @option_ia_addr 5
  @option_ia_pd 25
  @option_ia_prefix 26

  describe "extract_common/1" do
    test "returns default values for empty options" do
      assert OptionParser.extract_common([]) == %{
               client_id: nil,
               server_id: nil,
               ia_na: nil,
               ia_ta: nil,
               ia_pd: nil
             }
    end

    test "extracts client_id option" do
      client_duid = <<0, 1, 0, 1, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC>>

      options = [
        %{option_code: @option_client_id, option_data: client_duid}
      ]

      result = OptionParser.extract_common(options)
      assert result.client_id == client_duid
    end

    test "extracts server_id option" do
      server_duid = <<0, 3, 0, 1, 0x00, 0x00, 0x5E, 0x00, 0x53, 0xFF>>

      options = [
        %{option_code: @option_server_id, option_data: server_duid}
      ]

      result = OptionParser.extract_common(options)
      assert result.server_id == server_duid
    end

    test "extracts IA_NA option with IAID" do
      iaid = 12345

      # IA_NA: IAID (4 bytes) + T1 (4 bytes) + T2 (4 bytes)
      ia_na_data = <<iaid::32, 3600::32, 5400::32>>

      options = [
        %{option_code: @option_ia_na, option_data: ia_na_data}
      ]

      result = OptionParser.extract_common(options)
      assert result.ia_na != nil
      assert result.ia_na.iaid == iaid
      assert result.ia_na.type == :ia_na
    end

    test "extracts IA_NA with embedded IA_ADDR" do
      iaid = 67890
      ipv6_addr = {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0x0001}
      preferred_lifetime = 3600
      valid_lifetime = 7200

      # IA_ADDR: IPv6 (16 bytes) + preferred (4 bytes) + valid (4 bytes)
      ia_addr_data =
        <<0x2001::16, 0x0DB8::16, 0::16, 0::16, 0::16, 0::16, 0::16, 0x0001::16,
          preferred_lifetime::32, valid_lifetime::32>>

      # IA_ADDR option: code (2) + len (2) + data
      ia_addr_option = <<@option_ia_addr::16, byte_size(ia_addr_data)::16, ia_addr_data::binary>>

      # IA_NA: IAID + T1 + T2 + IA_ADDR option
      ia_na_data = <<iaid::32, 3600::32, 5400::32, ia_addr_option::binary>>

      options = [
        %{option_code: @option_ia_na, option_data: ia_na_data}
      ]

      result = OptionParser.extract_common(options)
      assert result.ia_na != nil
      assert result.ia_na.iaid == iaid
      assert result.ia_na.ia_addr == ipv6_addr
    end

    test "extracts IA_TA option" do
      iaid = 99999

      # IA_TA: IAID (4 bytes) only (no T1/T2)
      ia_ta_data = <<iaid::32>>

      options = [
        %{option_code: @option_ia_ta, option_data: ia_ta_data}
      ]

      result = OptionParser.extract_common(options)
      assert result.ia_ta != nil
      assert result.ia_ta.iaid == iaid
      assert result.ia_ta.type == :ia_ta
    end

    test "extracts IA_PD option with prefix" do
      iaid = 55555
      prefix_addr = {0xFD00, 0x0001, 0, 0, 0, 0, 0, 0}
      prefix_len = 56
      preferred = 3600
      valid = 7200

      # IA_PREFIX: preferred (4) + valid (4) + prefix_len (1) + prefix (16)
      ia_prefix_data =
        <<preferred::32, valid::32, prefix_len::8, 0xFD00::16, 0x0001::16, 0::16, 0::16, 0::16,
          0::16, 0::16, 0::16>>

      # IA_PREFIX option: code (2) + len (2) + data
      ia_prefix_option =
        <<@option_ia_prefix::16, byte_size(ia_prefix_data)::16, ia_prefix_data::binary>>

      # IA_PD: IAID + T1 + T2 + IA_PREFIX option
      ia_pd_data = <<iaid::32, 3600::32, 5400::32, ia_prefix_option::binary>>

      options = [
        %{option_code: @option_ia_pd, option_data: ia_pd_data}
      ]

      result = OptionParser.extract_common(options)
      assert result.ia_pd != nil
      assert result.ia_pd.iaid == iaid
      assert result.ia_pd.ia_prefix == {prefix_addr, prefix_len}
      assert result.ia_pd.type == :ia_pd
    end

    test "extracts multiple options in single pass" do
      client_duid = <<0, 1, 0, 1, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
      server_duid = <<0, 3, 0, 1, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>
      iaid = 12345

      options = [
        %{option_code: @option_client_id, option_data: client_duid},
        %{option_code: @option_server_id, option_data: server_duid},
        %{option_code: @option_ia_na, option_data: <<iaid::32, 3600::32, 5400::32>>}
      ]

      result = OptionParser.extract_common(options)
      assert result.client_id == client_duid
      assert result.server_id == server_duid
      assert result.ia_na.iaid == iaid
    end

    test "ignores unknown option codes" do
      options = [
        %{option_code: 999, option_data: <<"unknown">>},
        %{option_code: 1000, option_data: <<"also unknown">>}
      ]

      result = OptionParser.extract_common(options)

      assert result == %{
               client_id: nil,
               server_id: nil,
               ia_na: nil,
               ia_ta: nil,
               ia_pd: nil
             }
    end

    test "handles malformed IA_NA data gracefully" do
      # Too short - missing T1/T2
      options = [
        %{option_code: @option_ia_na, option_data: <<123::32>>}
      ]

      result = OptionParser.extract_common(options)
      assert result.ia_na == nil
    end

    test "handles malformed IA_TA data gracefully" do
      # Empty data
      options = [
        %{option_code: @option_ia_ta, option_data: <<>>}
      ]

      result = OptionParser.extract_common(options)
      assert result.ia_ta == nil
    end

    test "handles malformed IA_PD data gracefully" do
      # Too short
      options = [
        %{option_code: @option_ia_pd, option_data: <<1, 2, 3>>}
      ]

      result = OptionParser.extract_common(options)
      assert result.ia_pd == nil
    end
  end

  describe "extract_client_id/1" do
    test "returns nil for empty options" do
      assert OptionParser.extract_client_id([]) == nil
    end

    test "extracts client_id from options" do
      client_duid = <<0, 1, 0, 1, 0x12, 0x34, 0x56, 0x78>>

      options = [
        %{option_code: 99, option_data: <<"other">>},
        %{option_code: @option_client_id, option_data: client_duid},
        %{option_code: 100, option_data: <<"another">>}
      ]

      assert OptionParser.extract_client_id(options) == client_duid
    end

    test "returns nil when client_id not present" do
      options = [
        %{option_code: @option_server_id, option_data: <<"server">>},
        %{option_code: @option_ia_na, option_data: <<1::32, 2::32, 3::32>>}
      ]

      assert OptionParser.extract_client_id(options) == nil
    end
  end
end
