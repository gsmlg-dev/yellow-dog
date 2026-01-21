defmodule DNS.Message.EDNS0.Option.DHUTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.Option.DHU.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with algorithm list
  - from_iodata/1 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 6975)
  - DS Hash Understood semantics
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.DHU
  alias DNS.Message.EDNS0.OptionCode

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(DHU)
    end

    test "exports new/1" do
      Code.ensure_loaded!(DHU)
      assert Kernel.function_exported?(DHU, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(DHU)
      assert Kernel.function_exported?(DHU, :from_iodata, 1)
    end

    test "defines a struct" do
      Code.ensure_loaded!(DHU)
      assert is_struct(DHU.__struct__())
    end
  end

  describe "struct fields" do
    test "has code field" do
      option = %DHU{}
      assert Map.has_key?(option, :code)
    end

    test "has length field" do
      option = %DHU{}
      assert Map.has_key?(option, :length)
    end

    test "has data field" do
      option = %DHU{}
      assert Map.has_key?(option, :data)
    end

    test "default code is DHU (6)" do
      option = %DHU{}
      assert option.code == OptionCode.new(6)
    end

    test "default length is nil" do
      option = %DHU{}
      assert option.length == nil
    end

    test "default data is empty list" do
      assert %DHU{}.data == []
    end
  end

  describe "new/1" do
    test "creates DHU option with algorithm list" do
      option = DHU.new([1, 2, 4])
      assert %DHU{} = option
    end

    test "stores algorithm list" do
      algorithms = [1, 2, 4]
      option = DHU.new(algorithms)
      assert option.data == algorithms
    end

    test "creates option with empty list" do
      option = DHU.new([])
      assert option.data == []
    end

    test "creates option with single algorithm" do
      option = DHU.new([2])
      assert option.data == [2]
    end

    test "creates option with SHA-1 (1)" do
      option = DHU.new([1])
      assert 1 in option.data
    end

    test "creates option with SHA-256 (2)" do
      option = DHU.new([2])
      assert 2 in option.data
    end

    test "creates option with GOST R 34.11-94 (3)" do
      option = DHU.new([3])
      assert 3 in option.data
    end

    test "creates option with SHA-384 (4)" do
      option = DHU.new([4])
      assert 4 in option.data
    end

    test "option code is DHU (6)" do
      option = DHU.new([1, 2])
      assert option.code.value == <<6::16>>
    end

    test "option length matches algorithm count" do
      option = DHU.new([1, 2, 4])
      assert option.length == 3
    end

    test "empty list has zero length" do
      option = DHU.new([])
      assert option.length == 0
    end

    test "creates option with many algorithms" do
      algorithms = Enum.to_list(1..10)
      option = DHU.new(algorithms)
      assert option.data == algorithms
      assert option.length == 10
    end
  end

  describe "from_iodata/1" do
    test "parses DHU option from binary" do
      binary = <<6::16, 3::16, 1, 2, 4>>
      option = DHU.from_iodata(binary)
      assert %DHU{} = option
    end

    test "parses algorithm list correctly" do
      binary = <<6::16, 3::16, 1, 2, 4>>
      option = DHU.from_iodata(binary)
      assert option.data == [1, 2, 4]
    end

    test "parses empty algorithm list" do
      binary = <<6::16, 0::16>>
      option = DHU.from_iodata(binary)
      assert option.data == []
    end

    test "parses single algorithm" do
      binary = <<6::16, 1::16, 2>>
      option = DHU.from_iodata(binary)
      assert option.data == [2]
    end

    test "parses length correctly" do
      binary = <<6::16, 3::16, 1, 2, 4>>
      option = DHU.from_iodata(binary)
      assert option.length == 3
    end

    test "parses all standard DS algorithms" do
      binary = <<6::16, 4::16, 1, 2, 3, 4>>
      option = DHU.from_iodata(binary)
      assert option.data == [1, 2, 3, 4]
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      option = DHU.new([1, 2, 4])
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<6::16, 3::16, 1, 2, 4>>
    end

    test "wire format starts with option code 6" do
      option = DHU.new([1, 2])
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 6
    end

    test "wire format has correct length" do
      option = DHU.new([1, 2, 4])
      <<_code::16, length::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert length == 3
    end

    test "encodes empty list" do
      option = DHU.new([])
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<6::16, 0::16>>
    end

    test "encodes algorithm values as bytes" do
      option = DHU.new([1, 2, 4])
      <<_code::16, _length::16, a1, a2, a3>> = DNS.Parameter.to_iodata(option)
      assert [a1, a2, a3] == [1, 2, 4]
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'DHU: [a1,a2,...]'" do
      option = DHU.new([1, 2, 4])
      assert to_string(option) == "DHU: [1,2,4]"
    end

    test "formats empty list" do
      option = DHU.new([])
      assert to_string(option) == "DHU: []"
    end

    test "formats single algorithm" do
      option = DHU.new([2])
      assert to_string(option) == "DHU: [2]"
    end

    test "includes all algorithms" do
      option = DHU.new([1, 2, 3, 4])
      str = to_string(option)
      assert str =~ "1"
      assert str =~ "2"
      assert str =~ "3"
      assert str =~ "4"
    end

    test "string interpolation works" do
      option = DHU.new([1, 2])
      result = "Option: #{option}"
      assert result =~ "DHU:"
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> from_iodata preserves data" do
      original = DHU.new([1, 2, 4])
      iodata = DNS.Parameter.to_iodata(original)
      parsed = DHU.from_iodata(iodata)
      assert parsed.data == original.data
    end

    test "round-trip preserves empty list" do
      original = DHU.new([])
      iodata = DNS.Parameter.to_iodata(original)
      parsed = DHU.from_iodata(iodata)
      assert parsed.data == []
    end

    test "round-trip preserves algorithm order" do
      original = DHU.new([4, 2, 1])
      iodata = DNS.Parameter.to_iodata(original)
      parsed = DHU.from_iodata(iodata)
      assert parsed.data == [4, 2, 1]
    end
  end

  describe "DS Hash algorithm semantics" do
    test "algorithm 1 is SHA-1" do
      option = DHU.new([1])
      assert 1 in option.data
    end

    test "algorithm 2 is SHA-256" do
      option = DHU.new([2])
      assert 2 in option.data
    end

    test "algorithm 3 is GOST R 34.11-94" do
      option = DHU.new([3])
      assert 3 in option.data
    end

    test "algorithm 4 is SHA-384" do
      option = DHU.new([4])
      assert 4 in option.data
    end

    test "common modern configuration includes SHA-256 and SHA-384" do
      option = DHU.new([2, 4])
      assert 2 in option.data
      assert 4 in option.data
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      option = DHU.new([1, 2])
      inspect_output = inspect(option)
      assert is_binary(inspect_output)
    end

    test "handles all byte values" do
      algorithms = [0, 127, 255]
      option = DHU.new(algorithms)
      assert option.data == algorithms
    end

    test "preserves order of algorithms" do
      option = DHU.new([4, 2, 1, 3])
      assert option.data == [4, 2, 1, 3]
    end

    test "handles duplicate algorithms" do
      option = DHU.new([1, 1, 2, 2])
      assert option.data == [1, 1, 2, 2]
    end
  end

  # ============================================================================
  # RFC 6975 Compliance Tests
  # ============================================================================

  describe "RFC 6975 compliance" do
    test "DHU option code is 6" do
      option = DHU.new([2])
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 6
    end

    test "DHU stands for DS Hash Understood" do
      option = DHU.new([2])
      string = to_string(option)
      assert String.starts_with?(string, "DHU")
    end

    test "algorithm list contains 8-bit unsigned integers" do
      option = DHU.new([0, 128, 255])
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, length::16, rest::binary>> = iodata

      assert length == 3
      assert byte_size(rest) == 3

      <<a1, a2, a3>> = rest
      assert a1 == 0
      assert a2 == 128
      assert a3 == 255
    end

    test "wire format: option-code (16 bits) + option-length (16 bits) + data" do
      option = DHU.new([1, 2, 4])
      iodata = DNS.Parameter.to_iodata(option)

      # Total should be 2 + 2 + 3 = 7 bytes
      assert byte_size(iodata) == 7

      <<code::16, length::16, data::binary>> = iodata
      assert code == 6
      assert length == 3
      assert data == <<1, 2, 4>>
    end

    test "empty algorithm list is valid per RFC" do
      option = DHU.new([])
      iodata = DNS.Parameter.to_iodata(option)

      <<code::16, length::16>> = iodata
      assert code == 6
      assert length == 0
    end
  end

  # ============================================================================
  # RFC 4509 DS Hash Algorithm Tests
  # ============================================================================

  describe "RFC 4509 DS hash algorithms" do
    test "SHA-1 algorithm is value 1 (RFC 3658)" do
      option = DHU.new([1])
      assert 1 in option.data
    end

    test "SHA-256 algorithm is value 2 (RFC 4509)" do
      option = DHU.new([2])
      assert 2 in option.data
    end

    test "GOST R 34.11-94 algorithm is value 3 (RFC 5933)" do
      option = DHU.new([3])
      assert 3 in option.data
    end

    test "SHA-384 algorithm is value 4 (RFC 6605)" do
      option = DHU.new([4])
      assert 4 in option.data
    end

    test "algorithm 0 is reserved" do
      option = DHU.new([0])
      assert 0 in option.data
    end

    test "algorithms 5-255 are unassigned but can be signaled" do
      for alg <- [5, 100, 255] do
        option = DHU.new([alg])
        assert alg in option.data
      end
    end
  end

  # ============================================================================
  # Wire Format Tests
  # ============================================================================

  describe "wire format encoding" do
    test "encodes option code as big-endian 16-bit" do
      option = DHU.new([2])
      iodata = DNS.Parameter.to_iodata(option)
      <<high, low, _rest::binary>> = iodata

      assert high == 0
      assert low == 6
    end

    test "encodes length as big-endian 16-bit" do
      option = DHU.new([1, 2, 3, 4, 5])
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, high, low, _rest::binary>> = iodata

      assert high == 0
      assert low == 5
    end

    test "algorithm bytes follow length field" do
      option = DHU.new([10, 20, 30])
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, a1, a2, a3>> = iodata

      assert a1 == 10
      assert a2 == 20
      assert a3 == 30
    end

    test "encodes maximum practical number of algorithms" do
      algorithms = Enum.to_list(0..255)
      option = DHU.new(algorithms)
      iodata = DNS.Parameter.to_iodata(option)

      <<_code::16, length::16, data::binary>> = iodata
      assert length == 256
      assert byte_size(data) == 256
    end
  end

  # ============================================================================
  # Parsing Tests
  # ============================================================================

  describe "parsing from wire format" do
    test "parses minimal DHU option" do
      binary = <<6::16, 1::16, 2>>
      option = DHU.from_iodata(binary)

      assert option.code.value == <<0, 6>>
      assert option.length == 1
      assert option.data == [2]
    end

    test "parses DHU with multiple algorithms" do
      binary = <<6::16, 5::16, 1, 2, 3, 4, 5>>
      option = DHU.from_iodata(binary)

      assert option.data == [1, 2, 3, 4, 5]
    end

    test "parses DHU with all byte values" do
      binary = <<6::16, 4::16, 0, 1, 127, 255>>
      option = DHU.from_iodata(binary)

      assert option.data == [0, 1, 127, 255]
    end

    test "preserves algorithm order during parsing" do
      binary = <<6::16, 3::16, 4, 2, 1>>
      option = DHU.from_iodata(binary)

      assert option.data == [4, 2, 1]
    end

    test "parses wire format from simulated DNS traffic" do
      wire_data = <<0, 6, 0, 2, 2, 4>>  # DHU with SHA-256 and SHA-384
      option = DHU.from_iodata(wire_data)

      assert option.data == [2, 4]
    end
  end

  # ============================================================================
  # Concurrent Operations Tests
  # ============================================================================

  describe "concurrent operations" do
    test "concurrent DHU option creation" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            DHU.new([rem(i, 256)])
          end)
        end

      results = Task.await_many(tasks)
      assert length(results) == 50
      assert Enum.all?(results, &is_struct(&1, DHU))
    end

    test "concurrent serialization" do
      options = Enum.map(1..20, fn i -> DHU.new([rem(i, 256)]) end)

      tasks =
        Enum.map(options, fn opt ->
          Task.async(fn ->
            DNS.Parameter.to_iodata(opt)
          end)
        end)

      results = Task.await_many(tasks)
      assert length(results) == 20
      assert Enum.all?(results, &is_binary/1)
    end

    test "concurrent parsing" do
      binaries =
        Enum.map(1..20, fn i ->
          <<6::16, 1::16, rem(i, 256)>>
        end)

      tasks =
        Enum.map(binaries, fn binary ->
          Task.async(fn ->
            DHU.from_iodata(binary)
          end)
        end)

      results = Task.await_many(tasks)
      assert length(results) == 20
      assert Enum.all?(results, &is_struct(&1, DHU))
    end

    test "concurrent round-trip" do
      tasks =
        for i <- 1..30 do
          Task.async(fn ->
            original = DHU.new([rem(i, 256)])
            iodata = DNS.Parameter.to_iodata(original)
            parsed = DHU.from_iodata(iodata)
            {original.data, parsed.data}
          end)
        end

      results = Task.await_many(tasks)

      Enum.each(results, fn {original, parsed} ->
        assert original == parsed
      end)
    end
  end

  # ============================================================================
  # String Formatting Tests
  # ============================================================================

  describe "string formatting" do
    test "formats DHU with standard algorithms" do
      option = DHU.new([2, 4])
      assert to_string(option) == "DHU: [2,4]"
    end

    test "formats DHU with empty algorithms" do
      option = DHU.new([])
      assert to_string(option) == "DHU: []"
    end

    test "string contains all algorithm numbers" do
      option = DHU.new([1, 2, 3, 4])
      string = to_string(option)

      assert String.contains?(string, "1")
      assert String.contains?(string, "2")
      assert String.contains?(string, "3")
      assert String.contains?(string, "4")
    end

    test "algorithms are comma-separated" do
      option = DHU.new([1, 2, 4])
      string = to_string(option)

      assert string =~ ~r/1,2,4/
    end

    test "string is usable in interpolation" do
      option = DHU.new([2])
      message = "EDNS0 Option: #{option}"
      assert message =~ "DHU: [2]"
    end
  end

  # ============================================================================
  # Comparison Tests
  # ============================================================================

  describe "comparison and equality" do
    test "same algorithm list creates equal options" do
      opt1 = DHU.new([1, 2, 4])
      opt2 = DHU.new([1, 2, 4])
      assert opt1 == opt2
    end

    test "different algorithm lists create different options" do
      opt1 = DHU.new([1, 2])
      opt2 = DHU.new([1, 4])
      assert opt1 != opt2
    end

    test "order matters for equality" do
      opt1 = DHU.new([1, 2])
      opt2 = DHU.new([2, 1])
      assert opt1 != opt2
    end

    test "options can be used in MapSet" do
      options = [
        DHU.new([1]),
        DHU.new([1, 2]),
        DHU.new([1]),  # duplicate
        DHU.new([2, 1])
      ]

      unique = MapSet.new(options)
      assert MapSet.size(unique) == 3
    end
  end

  # ============================================================================
  # Practical Usage Tests
  # ============================================================================

  describe "practical DNSSEC resolver scenarios" do
    test "resolver signaling SHA-256 support" do
      option = DHU.new([2])

      iodata = DNS.Parameter.to_iodata(option)
      assert byte_size(iodata) == 5  # 2 + 2 + 1 bytes
    end

    test "resolver signaling multiple hash support" do
      option = DHU.new([1, 2, 4])  # SHA-1, SHA-256, SHA-384

      iodata = DNS.Parameter.to_iodata(option)
      <<code::16, length::16, _data::binary>> = iodata

      assert code == 6
      assert length == 3
    end

    test "building DHU for EDNS0 OPT record" do
      dhu = DHU.new([2, 4])  # SHA-256 and SHA-384

      wire_data = DNS.Parameter.to_iodata(dhu)

      assert byte_size(wire_data) > 0
      assert byte_size(wire_data) == 2 + 2 + 2  # code + length + 2 algorithms
    end

    test "parsing DHU from received DNS response" do
      wire_data = <<0, 6, 0, 2, 2, 4>>  # DHU with SHA-256 and SHA-384
      option = DHU.from_iodata(wire_data)

      assert option.data == [2, 4]
      assert to_string(option) == "DHU: [2,4]"
    end
  end

  # ============================================================================
  # Performance Tests
  # ============================================================================

  describe "performance" do
    test "creating many DHU options is efficient" do
      {time, options} =
        :timer.tc(fn ->
          Enum.map(1..1000, fn i ->
            DHU.new([rem(i, 256)])
          end)
        end)

      assert length(options) == 1000
      assert time < 50000
    end

    test "serializing many options is efficient" do
      options = Enum.map(1..1000, fn i -> DHU.new([rem(i, 256)]) end)

      {time, _results} =
        :timer.tc(fn ->
          Enum.map(options, &DNS.Parameter.to_iodata/1)
        end)

      assert time < 50000
    end

    test "parsing many options is efficient" do
      binaries = Enum.map(1..1000, fn i -> <<6::16, 1::16, rem(i, 256)>> end)

      {time, _results} =
        :timer.tc(fn ->
          Enum.map(binaries, &DHU.from_iodata/1)
        end)

      assert time < 50000
    end

    test "round-trip performance" do
      {time, _} =
        :timer.tc(fn ->
          Enum.each(1..500, fn i ->
            original = DHU.new([rem(i, 256)])
            iodata = DNS.Parameter.to_iodata(original)
            _parsed = DHU.from_iodata(iodata)
          end)
        end)

      assert time < 50000
    end
  end

  # ============================================================================
  # Extended Edge Cases
  # ============================================================================

  describe "extended edge cases" do
    test "handles maximum number of algorithms (255)" do
      algorithms = Enum.to_list(1..255)
      option = DHU.new(algorithms)

      assert length(option.data) == 255
      assert option.length == 255
    end

    test "handles all possible byte values" do
      algorithms = Enum.to_list(0..255)
      option = DHU.new(algorithms)

      assert length(option.data) == 256
      assert Enum.all?(0..255, &(&1 in option.data))
    end

    test "handles repeated algorithms" do
      algorithms = [2, 2, 2, 2, 2]
      option = DHU.new(algorithms)

      assert option.data == [2, 2, 2, 2, 2]
      assert option.length == 5
    end

    test "struct fields are accessible" do
      option = DHU.new([1, 2, 4])

      assert option.code == OptionCode.new(6)
      assert option.length == 3
      assert option.data == [1, 2, 4]
    end

    test "default struct values" do
      default = %DHU{}

      assert default.code == OptionCode.new(6)
      assert default.length == nil
      assert default.data == []
    end
  end
end
