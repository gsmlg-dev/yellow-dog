defmodule YellowDog.Fingerprint.Parser.V4Test do
  use ExUnit.Case, async: true

  alias YellowDog.Fingerprint.Parser.V4

  describe "extract/1" do
    test "extracts fingerprint from metadata with option 55" do
      metadata = %{
        option_55: [1, 3, 6, 15, 119, 252],
        option_60: "MSFT 5.0",
        option_12: "DESKTOP-ABC123"
      }

      assert {:ok, fp} = V4.extract(metadata)
      assert fp.protocol == :dhcpv4
      assert fp.parameter_list == [1, 3, 6, 15, 119, 252]
      assert fp.vendor_class == "MSFT 5.0"
      assert fp.hostname_pattern == "desktop-abc*"
      assert fp.hit_count == 1
      assert is_binary(fp.id)
    end

    test "returns :skip when option 55 is empty" do
      assert :skip == V4.extract(%{option_55: []})
    end

    test "returns :skip when option 55 is missing" do
      assert :skip == V4.extract(%{})
    end

    test "handles nil vendor class and hostname" do
      metadata = %{option_55: [1, 3, 6]}

      assert {:ok, fp} = V4.extract(metadata)
      assert fp.vendor_class == nil
      assert fp.hostname_pattern == nil
    end

    test "timestamps are set to current UTC time" do
      before = DateTime.utc_now()
      {:ok, fp} = V4.extract(%{option_55: [1, 3, 6]})
      after_time = DateTime.utc_now()

      assert DateTime.compare(fp.first_seen, before) in [:eq, :gt]
      assert DateTime.compare(fp.first_seen, after_time) in [:eq, :lt]
      assert fp.first_seen == fp.last_seen
    end

    test "different parameter lists produce different IDs" do
      {:ok, fp1} = V4.extract(%{option_55: [1, 3, 6]})
      {:ok, fp2} = V4.extract(%{option_55: [1, 3, 6, 15]})
      assert fp1.id != fp2.id
    end

    test "vendor class affects fingerprint ID" do
      {:ok, fp1} = V4.extract(%{option_55: [1, 3, 6], option_60: "MSFT 5.0"})
      {:ok, fp2} = V4.extract(%{option_55: [1, 3, 6], option_60: "android-dhcp-14"})
      assert fp1.id != fp2.id
    end

    test "hostname normalization replaces numbers with wildcards" do
      metadata = %{option_55: [1, 3, 6], option_12: "iPhone-12-Pro-Max"}

      assert {:ok, fp} = V4.extract(metadata)
      assert fp.hostname_pattern == "iphone-*-pro-max"
    end

    test "hostname normalization collapses consecutive wildcards" do
      metadata = %{option_55: [1, 3, 6], option_12: "host123456"}

      assert {:ok, fp} = V4.extract(metadata)
      assert fp.hostname_pattern == "host*"
    end
  end

  describe "extract_option_55/1" do
    test "extracts parameter request list from raw options" do
      options = [
        %{type: 53, value: <<1>>},
        %{type: 55, value: <<1, 3, 6, 15, 119>>},
        %{type: 60, value: "MSFT 5.0"}
      ]

      assert V4.extract_option_55(options) == [1, 3, 6, 15, 119]
    end

    test "returns empty list when option 55 missing" do
      options = [%{type: 53, value: <<1>>}]
      assert V4.extract_option_55(options) == []
    end

    test "handles empty option list" do
      assert V4.extract_option_55([]) == []
    end

    test "single byte parameter list" do
      options = [%{type: 55, value: <<42>>}]
      assert V4.extract_option_55(options) == [42]
    end

    test "large parameter list (30+ options)" do
      params = Enum.to_list(1..30)
      binary = :erlang.list_to_binary(params)
      options = [%{type: 55, value: binary}]
      assert V4.extract_option_55(options) == params
    end
  end

  describe "extract_option_60/1" do
    test "extracts vendor class identifier" do
      options = [%{type: 60, value: "android-dhcp-14\0"}]
      assert V4.extract_option_60(options) == "android-dhcp-14"
    end

    test "returns nil when missing" do
      assert V4.extract_option_60([]) == nil
    end

    test "strips null bytes from end" do
      options = [%{type: 60, value: "MSFT 5.0\0\0\0"}]
      assert V4.extract_option_60(options) == "MSFT 5.0"
    end

    test "preserves value without null bytes" do
      options = [%{type: 60, value: "dhcpcd-9.4.1"}]
      assert V4.extract_option_60(options) == "dhcpcd-9.4.1"
    end
  end

  describe "extract_option_12/1" do
    test "extracts hostname" do
      options = [%{type: 12, value: "my-laptop"}]
      assert V4.extract_option_12(options) == "my-laptop"
    end

    test "strips null bytes from hostname" do
      options = [%{type: 12, value: "my-laptop\0"}]
      assert V4.extract_option_12(options) == "my-laptop"
    end

    test "returns nil when missing" do
      assert V4.extract_option_12([]) == nil
    end
  end

  describe "extract_all_options/1" do
    test "extracts all fingerprint-relevant options" do
      options = [
        %{type: 55, value: <<1, 3, 6>>},
        %{type: 60, value: "test"},
        %{type: 12, value: "host1"},
        %{type: 61, value: <<1, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>},
        %{type: 57, value: <<5, 220>>},
        %{type: 93, value: <<0, 7>>}
      ]

      result = V4.extract_all_options(options)
      assert result.option_55 == [1, 3, 6]
      assert result.option_60 == "test"
      assert result.option_12 == "host1"
      assert result.option_61 == <<1, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
      assert result.option_57 == 1500
      assert result.option_93 == 7
    end

    test "returns defaults for missing options" do
      result = V4.extract_all_options([])
      assert result.option_55 == []
      assert result.option_60 == nil
      assert result.option_12 == nil
      assert result.option_61 == nil
      assert result.option_57 == nil
      assert result.option_93 == nil
    end

    test "option 57 parses max message size (576 bytes)" do
      options = [%{type: 57, value: <<2, 64>>}]
      result = V4.extract_all_options(options)
      assert result.option_57 == 576
    end

    test "option 93 parses client system architecture (x86 BIOS = 0)" do
      options = [%{type: 93, value: <<0, 0>>}]
      result = V4.extract_all_options(options)
      assert result.option_93 == 0
    end

    test "option 57 returns nil for invalid binary size" do
      options = [%{type: 57, value: <<1>>}]
      result = V4.extract_all_options(options)
      assert result.option_57 == nil
    end

    test "option 93 returns nil for invalid binary size" do
      options = [%{type: 93, value: <<1>>}]
      result = V4.extract_all_options(options)
      assert result.option_93 == nil
    end
  end
end
