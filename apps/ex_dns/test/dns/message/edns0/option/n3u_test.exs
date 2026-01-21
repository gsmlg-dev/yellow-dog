defmodule DNS.Message.EDNS0.Option.N3UTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.Option.N3U.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with algorithm list
  - from_iodata/1 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 6975)
  - NSEC3 Hash Understood semantics
  - RFC compliance verification
  - Concurrent operations
  - Performance and edge cases
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.N3U
  alias DNS.Message.EDNS0.OptionCode

  # ============================================================================
  # NSEC3 Hash Algorithm Constants (RFC 5155)
  # ============================================================================

  # SHA-1 is the only currently defined NSEC3 hash algorithm
  @sha1_algorithm 1

  # Reserved/unassigned algorithm numbers for testing
  @unassigned_algorithms [0, 2, 127, 255]

  # ============================================================================
  # Module Structure Tests
  # ============================================================================

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(N3U)
    end

    test "exports new/1" do
      Code.ensure_loaded!(N3U)
      assert Kernel.function_exported?(N3U, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(N3U)
      assert Kernel.function_exported?(N3U, :from_iodata, 1)
    end

    test "defines a struct" do
      Code.ensure_loaded!(N3U)
      assert is_struct(N3U.__struct__())
    end
  end

  describe "struct fields" do
    test "has code field" do
      option = %N3U{}
      assert Map.has_key?(option, :code)
    end

    test "has length field" do
      option = %N3U{}
      assert Map.has_key?(option, :length)
    end

    test "has data field" do
      option = %N3U{}
      assert Map.has_key?(option, :data)
    end

    test "default code is N3U (7)" do
      option = %N3U{}
      assert option.code == OptionCode.new(7)
    end

    test "default length is nil" do
      option = %N3U{}
      assert option.length == nil
    end

    test "default data is empty list" do
      assert %N3U{}.data == []
    end
  end

  describe "new/1" do
    test "creates N3U option with algorithm list" do
      option = N3U.new([1, 2])
      assert %N3U{} = option
    end

    test "stores algorithm list" do
      algorithms = [1, 2]
      option = N3U.new(algorithms)
      assert option.data == algorithms
    end

    test "creates option with empty list" do
      option = N3U.new([])
      assert option.data == []
    end

    test "creates option with single algorithm" do
      option = N3U.new([1])
      assert option.data == [1]
    end

    test "creates option with SHA-1 (1)" do
      option = N3U.new([1])
      assert 1 in option.data
    end

    test "option code is N3U (7)" do
      option = N3U.new([1, 2])
      assert option.code.value == <<7::16>>
    end

    test "option length matches algorithm count" do
      option = N3U.new([1, 2])
      assert option.length == 2
    end

    test "empty list has zero length" do
      option = N3U.new([])
      assert option.length == 0
    end

    test "creates option with many algorithms" do
      algorithms = Enum.to_list(1..5)
      option = N3U.new(algorithms)
      assert option.data == algorithms
      assert option.length == 5
    end
  end

  describe "from_iodata/1" do
    test "parses N3U option from binary" do
      binary = <<7::16, 2::16, 1, 2>>
      option = N3U.from_iodata(binary)
      assert %N3U{} = option
    end

    test "parses algorithm list correctly" do
      binary = <<7::16, 2::16, 1, 2>>
      option = N3U.from_iodata(binary)
      assert option.data == [1, 2]
    end

    test "parses empty algorithm list" do
      binary = <<7::16, 0::16>>
      option = N3U.from_iodata(binary)
      assert option.data == []
    end

    test "parses single algorithm" do
      binary = <<7::16, 1::16, 1>>
      option = N3U.from_iodata(binary)
      assert option.data == [1]
    end

    test "parses length correctly" do
      binary = <<7::16, 2::16, 1, 2>>
      option = N3U.from_iodata(binary)
      assert option.length == 2
    end

    test "parses multiple algorithms" do
      binary = <<7::16, 3::16, 1, 2, 3>>
      option = N3U.from_iodata(binary)
      assert option.data == [1, 2, 3]
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      option = N3U.new([1, 2])
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<7::16, 2::16, 1, 2>>
    end

    test "wire format starts with option code 7" do
      option = N3U.new([1, 2])
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 7
    end

    test "wire format has correct length" do
      option = N3U.new([1, 2])
      <<_code::16, length::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert length == 2
    end

    test "encodes empty list" do
      option = N3U.new([])
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<7::16, 0::16>>
    end

    test "encodes algorithm values as bytes" do
      option = N3U.new([1, 2])
      <<_code::16, _length::16, a1, a2>> = DNS.Parameter.to_iodata(option)
      assert [a1, a2] == [1, 2]
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'N3U: [a1,a2,...]'" do
      option = N3U.new([1, 2])
      assert to_string(option) == "N3U: [1,2]"
    end

    test "formats empty list" do
      option = N3U.new([])
      assert to_string(option) == "N3U: []"
    end

    test "formats single algorithm" do
      option = N3U.new([1])
      assert to_string(option) == "N3U: [1]"
    end

    test "includes all algorithms" do
      option = N3U.new([1, 2, 3])
      str = to_string(option)
      assert str =~ "1"
      assert str =~ "2"
      assert str =~ "3"
    end

    test "string interpolation works" do
      option = N3U.new([1, 2])
      result = "Option: #{option}"
      assert result =~ "N3U:"
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> from_iodata preserves data" do
      original = N3U.new([1, 2])
      iodata = DNS.Parameter.to_iodata(original)
      parsed = N3U.from_iodata(iodata)
      assert parsed.data == original.data
    end

    test "round-trip preserves empty list" do
      original = N3U.new([])
      iodata = DNS.Parameter.to_iodata(original)
      parsed = N3U.from_iodata(iodata)
      assert parsed.data == []
    end

    test "round-trip preserves algorithm order" do
      original = N3U.new([2, 1])
      iodata = DNS.Parameter.to_iodata(original)
      parsed = N3U.from_iodata(iodata)
      assert parsed.data == [2, 1]
    end
  end

  describe "NSEC3 Hash algorithm semantics" do
    test "algorithm 1 is SHA-1" do
      option = N3U.new([1])
      assert 1 in option.data
    end

    test "SHA-1 is currently the only defined NSEC3 hash" do
      # Per RFC 5155, SHA-1 (1) is the only defined hash algorithm
      option = N3U.new([1])
      assert option.data == [1]
    end

    test "common configuration includes SHA-1" do
      option = N3U.new([1])
      assert 1 in option.data
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      option = N3U.new([1, 2])
      inspect_output = inspect(option)
      assert is_binary(inspect_output)
    end

    test "handles all byte values" do
      algorithms = [0, 127, 255]
      option = N3U.new(algorithms)
      assert option.data == algorithms
    end

    test "preserves order of algorithms" do
      option = N3U.new([2, 1])
      assert option.data == [2, 1]
    end

    test "handles duplicate algorithms" do
      option = N3U.new([1, 1])
      assert option.data == [1, 1]
    end
  end

  # ============================================================================
  # RFC 6975 Compliance Tests
  # ============================================================================

  describe "RFC 6975 compliance" do
    test "N3U option code is 7" do
      option = N3U.new([@sha1_algorithm])
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 7
    end

    test "N3U stands for NSEC3 Hash Understood" do
      option = N3U.new([@sha1_algorithm])
      string = to_string(option)
      assert String.starts_with?(string, "N3U")
    end

    test "algorithm list contains 8-bit unsigned integers" do
      # RFC 6975 specifies algorithms as 8-bit values
      option = N3U.new([0, 128, 255])
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, length::16, rest::binary>> = iodata

      assert length == 3
      assert byte_size(rest) == 3

      # Each algorithm is 1 byte
      <<a1, a2, a3>> = rest
      assert a1 == 0
      assert a2 == 128
      assert a3 == 255
    end

    test "wire format: option-code (16 bits) + option-length (16 bits) + data" do
      option = N3U.new([@sha1_algorithm, 2])
      iodata = DNS.Parameter.to_iodata(option)

      # Total should be 2 + 2 + 2 = 6 bytes
      assert byte_size(iodata) == 6

      <<code::16, length::16, data::binary>> = iodata
      assert code == 7
      assert length == 2
      assert data == <<1, 2>>
    end

    test "empty algorithm list is valid per RFC" do
      option = N3U.new([])
      iodata = DNS.Parameter.to_iodata(option)

      <<code::16, length::16>> = iodata
      assert code == 7
      assert length == 0
    end
  end

  # ============================================================================
  # RFC 5155 NSEC3 Hash Algorithm Tests
  # ============================================================================

  describe "RFC 5155 NSEC3 hash algorithms" do
    test "SHA-1 algorithm is value 1" do
      option = N3U.new([@sha1_algorithm])
      assert @sha1_algorithm in option.data
    end

    test "SHA-1 is the standard NSEC3 hash algorithm" do
      # Per RFC 5155, SHA-1 is the only defined hash algorithm
      option = N3U.new([@sha1_algorithm])
      iodata = DNS.Parameter.to_iodata(option)

      <<_code::16, _length::16, algorithm>> = iodata
      assert algorithm == 1
    end

    test "algorithm 0 is reserved" do
      option = N3U.new([0])
      assert 0 in option.data
    end

    test "algorithms 2-255 are unassigned but can be signaled" do
      # Resolvers can signal support for future algorithms
      for alg <- @unassigned_algorithms do
        option = N3U.new([alg])
        assert alg in option.data
      end
    end
  end

  # ============================================================================
  # Wire Format Tests
  # ============================================================================

  describe "wire format encoding" do
    test "encodes option code as big-endian 16-bit" do
      option = N3U.new([@sha1_algorithm])
      iodata = DNS.Parameter.to_iodata(option)
      <<high, low, _rest::binary>> = iodata

      assert high == 0
      assert low == 7
    end

    test "encodes length as big-endian 16-bit" do
      option = N3U.new([1, 2, 3, 4, 5])
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, high, low, _rest::binary>> = iodata

      assert high == 0
      assert low == 5
    end

    test "algorithm bytes follow length field" do
      option = N3U.new([10, 20, 30])
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, a1, a2, a3>> = iodata

      assert a1 == 10
      assert a2 == 20
      assert a3 == 30
    end

    test "length of 255 algorithms" do
      algorithms = Enum.to_list(0..254)
      option = N3U.new(algorithms)
      iodata = DNS.Parameter.to_iodata(option)

      <<_code::16, length::16, _data::binary>> = iodata
      assert length == 255
    end

    test "maximum length encoding" do
      # Test with maximum practical number of algorithms
      algorithms = Enum.to_list(0..255)
      option = N3U.new(algorithms)
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
    test "parses minimal N3U option" do
      binary = <<7::16, 1::16, 1>>
      option = N3U.from_iodata(binary)

      assert option.code.value == <<0, 7>>
      assert option.length == 1
      assert option.data == [1]
    end

    test "parses N3U with multiple algorithms" do
      binary = <<7::16, 5::16, 1, 2, 3, 4, 5>>
      option = N3U.from_iodata(binary)

      assert option.data == [1, 2, 3, 4, 5]
    end

    test "parses N3U with all byte values" do
      # Include edge byte values
      binary = <<7::16, 4::16, 0, 1, 127, 255>>
      option = N3U.from_iodata(binary)

      assert option.data == [0, 1, 127, 255]
    end

    test "preserves algorithm order during parsing" do
      binary = <<7::16, 3::16, 3, 1, 2>>
      option = N3U.from_iodata(binary)

      assert option.data == [3, 1, 2]
    end

    test "parses wire format captured from DNS traffic" do
      # Simulated wire data for N3U with SHA-1
      wire_data = <<0, 7, 0, 1, 1>>
      option = N3U.from_iodata(wire_data)

      assert option.data == [1]
    end
  end

  # ============================================================================
  # Concurrent Operations Tests
  # ============================================================================

  describe "concurrent operations" do
    test "concurrent N3U option creation" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            N3U.new([rem(i, 256)])
          end)
        end

      results = Task.await_many(tasks)
      assert length(results) == 50
      assert Enum.all?(results, &is_struct(&1, N3U))
    end

    test "concurrent serialization" do
      options = Enum.map(1..20, fn i -> N3U.new([rem(i, 256)]) end)

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
          <<7::16, 1::16, rem(i, 256)>>
        end)

      tasks =
        Enum.map(binaries, fn binary ->
          Task.async(fn ->
            N3U.from_iodata(binary)
          end)
        end)

      results = Task.await_many(tasks)
      assert length(results) == 20
      assert Enum.all?(results, &is_struct(&1, N3U))
    end

    test "concurrent round-trip" do
      tasks =
        for i <- 1..30 do
          Task.async(fn ->
            original = N3U.new([rem(i, 256)])
            iodata = DNS.Parameter.to_iodata(original)
            parsed = N3U.from_iodata(iodata)
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
    test "formats N3U with standard algorithm" do
      option = N3U.new([@sha1_algorithm])
      assert to_string(option) == "N3U: [1]"
    end

    test "formats N3U with multiple algorithms" do
      option = N3U.new([1, 2, 3])
      assert to_string(option) == "N3U: [1,2,3]"
    end

    test "formats N3U with empty algorithms" do
      option = N3U.new([])
      assert to_string(option) == "N3U: []"
    end

    test "string contains all algorithm numbers" do
      option = N3U.new([5, 10, 15, 20])
      string = to_string(option)

      assert String.contains?(string, "5")
      assert String.contains?(string, "10")
      assert String.contains?(string, "15")
      assert String.contains?(string, "20")
    end

    test "algorithms are comma-separated" do
      option = N3U.new([1, 2, 3])
      string = to_string(option)

      # Should have commas between numbers
      assert string =~ ~r/1,2,3/
    end

    test "string is usable in interpolation" do
      option = N3U.new([@sha1_algorithm])
      message = "EDNS0 Option: #{option}"
      assert message =~ "N3U: [1]"
    end
  end

  # ============================================================================
  # Comparison Tests
  # ============================================================================

  describe "comparison and equality" do
    test "same algorithm list creates equal options" do
      opt1 = N3U.new([1, 2])
      opt2 = N3U.new([1, 2])
      assert opt1 == opt2
    end

    test "different algorithm lists create different options" do
      opt1 = N3U.new([1, 2])
      opt2 = N3U.new([1, 3])
      assert opt1 != opt2
    end

    test "order matters for equality" do
      opt1 = N3U.new([1, 2])
      opt2 = N3U.new([2, 1])
      assert opt1 != opt2
    end

    test "options can be used in MapSet" do
      options = [
        N3U.new([1]),
        N3U.new([1, 2]),
        N3U.new([1]),  # duplicate
        N3U.new([2, 1])
      ]

      unique = MapSet.new(options)
      assert MapSet.size(unique) == 3
    end
  end

  # ============================================================================
  # Practical Usage Tests
  # ============================================================================

  describe "practical DNSSEC resolver scenarios" do
    test "resolver signaling SHA-1 support" do
      # Standard resolver signals NSEC3 with SHA-1 support
      option = N3U.new([@sha1_algorithm])

      iodata = DNS.Parameter.to_iodata(option)
      assert byte_size(iodata) == 5  # 2 + 2 + 1 bytes
    end

    test "resolver signaling multiple algorithm support" do
      # Hypothetical resolver supporting multiple hash algorithms
      option = N3U.new([1, 2])  # SHA-1 and hypothetical algorithm 2

      iodata = DNS.Parameter.to_iodata(option)
      <<code::16, length::16, _data::binary>> = iodata

      assert code == 7
      assert length == 2
    end

    test "building N3U for EDNS0 OPT record" do
      # Create N3U option for inclusion in OPT record
      n3u = N3U.new([@sha1_algorithm])

      # Serialize for wire format
      wire_data = DNS.Parameter.to_iodata(n3u)

      # Verify it can be included in a larger message
      assert byte_size(wire_data) > 0
      assert byte_size(wire_data) == 2 + 2 + 1  # code + length + 1 algorithm
    end

    test "parsing N3U from received DNS response" do
      # Simulate parsing N3U from a received EDNS0 option
      wire_data = <<0, 7, 0, 1, 1>>  # N3U with SHA-1
      option = N3U.from_iodata(wire_data)

      assert option.data == [1]
      assert to_string(option) == "N3U: [1]"
    end
  end

  # ============================================================================
  # Performance Tests
  # ============================================================================

  describe "performance" do
    test "creating many N3U options is efficient" do
      {time, options} =
        :timer.tc(fn ->
          Enum.map(1..1000, fn i ->
            N3U.new([rem(i, 256)])
          end)
        end)

      assert length(options) == 1000
      # Should complete in under 50ms
      assert time < 50000
    end

    test "serializing many options is efficient" do
      options = Enum.map(1..1000, fn i -> N3U.new([rem(i, 256)]) end)

      {time, _results} =
        :timer.tc(fn ->
          Enum.map(options, &DNS.Parameter.to_iodata/1)
        end)

      # Should complete in under 50ms
      assert time < 50000
    end

    test "parsing many options is efficient" do
      binaries = Enum.map(1..1000, fn i -> <<7::16, 1::16, rem(i, 256)>> end)

      {time, _results} =
        :timer.tc(fn ->
          Enum.map(binaries, &N3U.from_iodata/1)
        end)

      # Should complete in under 50ms
      assert time < 50000
    end

    test "round-trip performance" do
      {time, _} =
        :timer.tc(fn ->
          Enum.each(1..500, fn i ->
            original = N3U.new([rem(i, 256)])
            iodata = DNS.Parameter.to_iodata(original)
            _parsed = N3U.from_iodata(iodata)
          end)
        end)

      # 500 round-trips should complete in under 50ms
      assert time < 50000
    end
  end

  # ============================================================================
  # Extended Edge Cases
  # ============================================================================

  describe "extended edge cases" do
    test "handles maximum number of algorithms (255)" do
      algorithms = Enum.to_list(1..255)
      option = N3U.new(algorithms)

      assert length(option.data) == 255
      assert option.length == 255
    end

    test "handles all possible byte values" do
      algorithms = Enum.to_list(0..255)
      option = N3U.new(algorithms)

      assert length(option.data) == 256
      assert Enum.all?(0..255, &(&1 in option.data))
    end

    test "handles repeated algorithms" do
      algorithms = [1, 1, 1, 1, 1]
      option = N3U.new(algorithms)

      assert option.data == [1, 1, 1, 1, 1]
      assert option.length == 5
    end

    test "struct fields are accessible" do
      option = N3U.new([1, 2, 3])

      assert option.code == OptionCode.new(7)
      assert option.length == 3
      assert option.data == [1, 2, 3]
    end

    test "default struct values" do
      default = %N3U{}

      assert default.code == OptionCode.new(7)
      assert default.length == nil
      assert default.data == []
    end
  end
end
