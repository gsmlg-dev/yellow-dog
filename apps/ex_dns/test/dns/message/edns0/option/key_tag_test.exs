defmodule DNS.Message.EDNS0.Option.KeyTagTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.Option.KeyTag.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with key tag list
  - from_iodata/1 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 8145)
  - DNSSEC key tag semantics
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.KeyTag
  alias DNS.Message.EDNS0.OptionCode

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(KeyTag)
    end

    test "exports new/1" do
      Code.ensure_loaded!(KeyTag)
      assert Kernel.function_exported?(KeyTag, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(KeyTag)
      assert Kernel.function_exported?(KeyTag, :from_iodata, 1)
    end

    test "defines a struct" do
      Code.ensure_loaded!(KeyTag)
      assert is_struct(KeyTag.__struct__())
    end
  end

  describe "struct fields" do
    test "has code field" do
      option = %KeyTag{}
      assert Map.has_key?(option, :code)
    end

    test "has length field" do
      option = %KeyTag{}
      assert Map.has_key?(option, :length)
    end

    test "has data field" do
      option = %KeyTag{}
      assert Map.has_key?(option, :data)
    end

    test "default code is KeyTag (14)" do
      option = %KeyTag{}
      assert option.code == OptionCode.new(14)
    end

    test "default length is nil" do
      option = %KeyTag{}
      assert option.length == nil
    end

    test "default data is empty list" do
      option = %KeyTag{}
      assert option.data == []
    end
  end

  describe "new/1" do
    test "creates KeyTag option with key tag list" do
      key_tags = [12345, 23456, 34567]
      option = KeyTag.new(key_tags)
      assert %KeyTag{} = option
    end

    test "stores key tag list" do
      key_tags = [12345, 23456, 34567]
      option = KeyTag.new(key_tags)
      assert option.data == key_tags
    end

    test "calculates length as 2 bytes per key tag" do
      key_tags = [12345, 23456, 34567]
      option = KeyTag.new(key_tags)
      assert option.length == 6  # 3 tags * 2 bytes each
    end

    test "creates KeyTag option with empty list" do
      option = KeyTag.new([])
      assert option.code.value == <<14::16>>
      assert option.length == 0
      assert option.data == []
    end

    test "creates KeyTag option with single key tag" do
      key_tags = [12345]
      option = KeyTag.new(key_tags)
      assert option.code.value == <<14::16>>
      assert option.length == 2
      assert option.data == key_tags
    end

    test "option code is KeyTag (14)" do
      option = KeyTag.new([12345])
      assert option.code.value == <<14::16>>
    end

    test "handles minimum key tag (0)" do
      option = KeyTag.new([0])
      assert 0 in option.data
    end

    test "handles maximum key tag (65535)" do
      option = KeyTag.new([65535])
      assert 65535 in option.data
    end

    test "creates KeyTag with common DNSSEC key tags" do
      # Real-world key tag examples
      key_tags = [20326, 19036]  # Example root zone KSK key tags
      option = KeyTag.new(key_tags)
      assert option.data == key_tags
      assert option.length == 4
    end

    test "creates KeyTag with many key tags" do
      key_tags = Enum.map(1..10, fn i -> i * 1000 end)
      option = KeyTag.new(key_tags)
      assert option.length == 20  # 10 tags * 2 bytes
      assert option.data == key_tags
    end
  end

  describe "from_iodata/1" do
    test "parses KeyTag option from binary" do
      binary = <<14::16, 4::16, 12345::16, 23456::16>>
      option = KeyTag.from_iodata(binary)
      assert %KeyTag{} = option
    end

    test "parses key tag list correctly" do
      key_tags = [12345, 23456]
      binary = <<14::16, 4::16, 12345::16, 23456::16>>
      option = KeyTag.from_iodata(binary)
      assert option.data == key_tags
    end

    test "parses length correctly" do
      binary = <<14::16, 4::16, 12345::16, 23456::16>>
      option = KeyTag.from_iodata(binary)
      assert option.length == 4
    end

    test "parses empty KeyTag option" do
      binary = <<14::16, 0::16>>
      option = KeyTag.from_iodata(binary)
      assert option.code.value == <<14::16>>
      assert option.length == 0
      assert option.data == []
    end

    test "parses single key tag" do
      binary = <<14::16, 2::16, 54321::16>>
      option = KeyTag.from_iodata(binary)
      assert option.data == [54321]
    end

    test "parses minimum key tag (0)" do
      binary = <<14::16, 2::16, 0::16>>
      option = KeyTag.from_iodata(binary)
      assert option.data == [0]
    end

    test "parses maximum key tag (65535)" do
      binary = <<14::16, 2::16, 65535::16>>
      option = KeyTag.from_iodata(binary)
      assert option.data == [65535]
    end

    test "parses many key tags" do
      key_tags = [1000, 2000, 3000, 4000, 5000]
      binary_data = Enum.map(key_tags, fn tag -> <<tag::16>> end) |> Enum.join()
      binary = <<14::16, 10::16, binary_data::binary>>
      option = KeyTag.from_iodata(binary)
      assert option.data == key_tags
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      key_tags = [12345, 23456]
      option = KeyTag.new(key_tags)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<14::16, 4::16, 12345::16, 23456::16>>
    end

    test "wire format starts with option code 14" do
      option = KeyTag.new([12345])
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 14
    end

    test "wire format has correct length" do
      key_tags = [12345, 23456, 34567]
      option = KeyTag.new(key_tags)
      <<_code::16, length::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert length == 6
    end

    test "encodes empty list" do
      option = KeyTag.new([])
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<14::16, 0::16>>
    end

    test "encodes key tags as 16-bit values" do
      option = KeyTag.new([12345, 54321])
      <<_code::16, _length::16, tag1::16, tag2::16>> = DNS.Parameter.to_iodata(option)
      assert tag1 == 12345
      assert tag2 == 54321
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'edns-key-tag: [tag1,tag2,...]'" do
      key_tags = [12345, 23456]
      option = KeyTag.new(key_tags)
      assert to_string(option) == "edns-key-tag: [12345,23456]"
    end

    test "formats empty list" do
      option = KeyTag.new([])
      assert to_string(option) == "edns-key-tag: []"
    end

    test "formats single key tag" do
      option = KeyTag.new([12345])
      assert to_string(option) == "edns-key-tag: [12345]"
    end

    test "includes all key tags" do
      key_tags = [1000, 2000, 3000]
      option = KeyTag.new(key_tags)
      str = to_string(option)
      assert str =~ "1000"
      assert str =~ "2000"
      assert str =~ "3000"
    end

    test "string interpolation works" do
      option = KeyTag.new([12345])
      result = "Option: #{option}"
      assert result =~ "edns-key-tag:"
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> from_iodata preserves data" do
      original = KeyTag.new([12345, 23456])
      iodata = DNS.Parameter.to_iodata(original)
      parsed = KeyTag.from_iodata(iodata)
      assert parsed.data == original.data
      assert parsed.length == original.length
    end

    test "round-trip preserves empty list" do
      original = KeyTag.new([])
      iodata = DNS.Parameter.to_iodata(original)
      parsed = KeyTag.from_iodata(iodata)
      assert parsed.data == []
    end

    test "round-trip preserves key tag order" do
      original = KeyTag.new([54321, 12345, 33333])
      iodata = DNS.Parameter.to_iodata(original)
      parsed = KeyTag.from_iodata(iodata)
      assert parsed.data == [54321, 12345, 33333]
    end

    test "round-trip preserves various configurations" do
      test_cases = [
        [12345],
        [0, 65535],
        [20326, 19036],  # Example root KSK key tags
        Enum.map(1..20, fn i -> i * 3000 end)
      ]

      for key_tags <- test_cases do
        original = KeyTag.new(key_tags)
        iodata = DNS.Parameter.to_iodata(original)
        parsed = KeyTag.from_iodata(iodata)
        assert parsed.data == key_tags
      end
    end
  end

  describe "DNSSEC key tag semantics" do
    test "key tag identifies DNSKEY" do
      # Key tags are used to identify DNSKEY records for RRSIG validation
      option = KeyTag.new([20326])
      assert 20326 in option.data
    end

    test "key tag is 16-bit value" do
      option = KeyTag.new([65535])
      assert option.length == 2  # 16 bits = 2 bytes
    end

    test "multiple key tags for trust anchors" do
      # A resolver may trust multiple keys for a zone
      key_tags = [20326, 19036, 38353]
      option = KeyTag.new(key_tags)
      assert option.data == key_tags
    end

    test "root zone KSK key tag example" do
      # KSK-2017 key tag
      option = KeyTag.new([20326])
      assert option.data == [20326]
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      option = KeyTag.new([12345])
      inspect_output = inspect(option)
      assert is_binary(inspect_output)
    end

    test "handles boundary values" do
      option = KeyTag.new([0, 1, 65534, 65535])
      assert option.data == [0, 1, 65534, 65535]
    end

    test "preserves order of key tags" do
      option = KeyTag.new([65535, 0, 32768, 1])
      assert option.data == [65535, 0, 32768, 1]
    end

    test "handles duplicate key tags" do
      option = KeyTag.new([12345, 12345, 12345])
      assert option.data == [12345, 12345, 12345]
    end

    test "handles many key tags" do
      key_tags = Enum.to_list(1..100)
      option = KeyTag.new(key_tags)
      assert option.length == 200  # 100 * 2 bytes
      assert option.data == key_tags
    end
  end
end
