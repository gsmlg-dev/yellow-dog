defmodule DNS.Message.EDNS0.Option.ChainTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.Option.Chain.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with start_hash integer
  - from_iodata/1 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 7901)
  - DNSSEC chain query semantics
  - RFC compliance verification
  - Concurrent operations
  - Performance and edge cases
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.Chain
  alias DNS.Message.EDNS0.OptionCode

  # ============================================================================
  # DNSSEC DS Hash Algorithm Constants (RFC 4509, RFC 6605)
  # ============================================================================

  # SHA-1 (RFC 3658)
  @sha1_algo 1
  # SHA-256 (RFC 4509)
  @sha256_algo 2
  # GOST R 34.11-94 (RFC 5933)
  @gost_algo 3
  # SHA-384 (RFC 6605)
  @sha384_algo 4

  # Common DS algorithm values used in practice
  @common_algorithms [@sha1_algo, @sha256_algo, @sha384_algo]

  # ============================================================================
  # Module Structure Tests
  # ============================================================================

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Chain)
    end

    test "exports new/1" do
      Code.ensure_loaded!(Chain)
      assert Kernel.function_exported?(Chain, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(Chain)
      assert Kernel.function_exported?(Chain, :from_iodata, 1)
    end

    test "defines a struct" do
      Code.ensure_loaded!(Chain)
      assert is_struct(Chain.__struct__())
    end
  end

  describe "struct fields" do
    test "has code field" do
      option = %Chain{}
      assert Map.has_key?(option, :code)
    end

    test "has length field" do
      option = %Chain{}
      assert Map.has_key?(option, :length)
    end

    test "has data field" do
      option = %Chain{}
      assert Map.has_key?(option, :data)
    end

    test "default code is CHAIN (13)" do
      option = %Chain{}
      assert option.code == OptionCode.new(13)
    end

    test "default length is 2" do
      option = %Chain{}
      assert option.length == 2
    end

    test "default data is nil" do
      assert %Chain{}.data == nil
    end
  end

  describe "new/1" do
    test "creates Chain option with start hash" do
      option = Chain.new(8)
      assert %Chain{} = option
    end

    test "stores start_hash field" do
      option = Chain.new(8)
      assert option.data == 8
    end

    test "creates option with zero start hash" do
      option = Chain.new(0)
      assert option.data == 0
    end

    test "creates option with SHA-1 algorithm (1)" do
      option = Chain.new(1)
      assert option.data == 1
    end

    test "creates option with SHA-256 algorithm (2)" do
      option = Chain.new(2)
      assert option.data == 2
    end

    test "creates option with GOST R 34.11-94 algorithm (3)" do
      option = Chain.new(3)
      assert option.data == 3
    end

    test "creates option with SHA-384 algorithm (4)" do
      option = Chain.new(4)
      assert option.data == 4
    end

    test "creates option with max value (65535)" do
      option = Chain.new(65535)
      assert option.data == 65535
    end

    test "option code is CHAIN (13)" do
      option = Chain.new(8)
      assert option.code.value == <<13::16>>
    end

    test "option length is 2" do
      option = Chain.new(8)
      assert option.length == 2
    end
  end

  describe "from_iodata/1" do
    test "parses Chain option from binary" do
      binary = <<13::16, 2::16, 8::16>>
      option = Chain.from_iodata(binary)
      assert %Chain{} = option
    end

    test "parses start_hash correctly" do
      binary = <<13::16, 2::16, 8::16>>
      option = Chain.from_iodata(binary)
      assert option.data == 8
    end

    test "parses zero start_hash" do
      binary = <<13::16, 2::16, 0::16>>
      option = Chain.from_iodata(binary)
      assert option.data == 0
    end

    test "parses max start_hash" do
      binary = <<13::16, 2::16, 65535::16>>
      option = Chain.from_iodata(binary)
      assert option.data == 65535
    end

    test "parses SHA-1 algorithm" do
      binary = <<13::16, 2::16, 1::16>>
      option = Chain.from_iodata(binary)
      assert option.data == 1
    end

    test "parses SHA-256 algorithm" do
      binary = <<13::16, 2::16, 2::16>>
      option = Chain.from_iodata(binary)
      assert option.data == 2
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      option = Chain.new(10)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<13::16, 2::16, 10::16>>
    end

    test "wire format starts with option code 13" do
      option = Chain.new(8)
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 13
    end

    test "wire format has length 2" do
      option = Chain.new(8)
      <<_code::16, length::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert length == 2
    end

    test "encodes start_hash field" do
      option = Chain.new(100)
      <<_code::16, _length::16, start_hash::16>> = DNS.Parameter.to_iodata(option)
      assert start_hash == 100
    end

    test "encodes zero start_hash" do
      option = Chain.new(0)
      <<_code::16, _length::16, start_hash::16>> = DNS.Parameter.to_iodata(option)
      assert start_hash == 0
    end

    test "encodes max start_hash" do
      option = Chain.new(65535)
      <<_code::16, _length::16, start_hash::16>> = DNS.Parameter.to_iodata(option)
      assert start_hash == 65535
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'CHAIN: N'" do
      option = Chain.new(8)
      assert to_string(option) == "CHAIN: 8"
    end

    test "includes start_hash value" do
      option = Chain.new(100)
      str = to_string(option)
      assert str =~ "100"
    end

    test "formats zero value" do
      option = Chain.new(0)
      assert to_string(option) == "CHAIN: 0"
    end

    test "formats max value" do
      option = Chain.new(65535)
      assert to_string(option) == "CHAIN: 65535"
    end

    test "string interpolation works" do
      option = Chain.new(8)
      result = "Option: #{option}"
      assert result =~ "CHAIN:"
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> from_iodata preserves data" do
      original = Chain.new(8)
      iodata = DNS.Parameter.to_iodata(original)
      parsed = Chain.from_iodata(iodata)
      assert parsed.data == original.data
    end

    test "round-trip preserves algorithm values" do
      for algo <- [0, 1, 2, 3, 4, 8, 255, 65535] do
        original = Chain.new(algo)
        iodata = DNS.Parameter.to_iodata(original)
        parsed = Chain.from_iodata(iodata)
        assert parsed.data == algo
      end
    end
  end

  describe "DNSSEC chain semantics" do
    test "start_hash 0 means unspecified" do
      option = Chain.new(0)
      assert option.data == 0
    end

    test "start_hash 1 is SHA-1" do
      option = Chain.new(1)
      assert option.data == 1
    end

    test "start_hash 2 is SHA-256" do
      option = Chain.new(2)
      assert option.data == 2
    end

    test "start_hash 3 is GOST R 34.11-94" do
      option = Chain.new(3)
      assert option.data == 3
    end

    test "start_hash 4 is SHA-384" do
      option = Chain.new(4)
      assert option.data == 4
    end

    test "start_hash 8 is common DS algorithm" do
      option = Chain.new(8)
      assert option.data == 8
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      option = Chain.new(8)
      inspect_output = inspect(option)
      assert is_binary(inspect_output)
    end

    test "handles all standard algorithm values" do
      for algo <- [0, 1, 2, 3, 4] do
        option = Chain.new(algo)
        assert option.data == algo
      end
    end

    test "handles large algorithm values" do
      option = Chain.new(1000)
      assert option.data == 1000
    end
  end

  # ============================================================================
  # RFC 7901 Compliance Tests
  # ============================================================================

  describe "RFC 7901 compliance" do
    test "CHAIN option code is 13" do
      option = Chain.new(@sha256_algo)
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 13
    end

    test "option data is 16-bit unsigned integer" do
      # > 8 bits, fits in 16
      option = Chain.new(256)
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, value::16>> = iodata
      assert value == 256
    end

    test "option length is always 2 bytes" do
      for algo <- [0, 1, 100, 1000, 65535] do
        option = Chain.new(algo)
        <<_code::16, length::16, _data::binary>> = DNS.Parameter.to_iodata(option)
        assert length == 2
      end
    end

    test "wire format: code (16) + length (16) + closest trust point (16)" do
      option = Chain.new(@sha256_algo)
      iodata = DNS.Parameter.to_iodata(option)

      # 2 + 2 + 2 bytes
      assert byte_size(iodata) == 6

      <<code::16, length::16, trust_point::16>> = iodata
      assert code == 13
      assert length == 2
      assert trust_point == @sha256_algo
    end

    test "CHAIN is used in queries to request trust chain" do
      # Per RFC 7901, CHAIN is sent in queries
      query_option = Chain.new(@sha256_algo)
      assert query_option.data == @sha256_algo
    end
  end

  # ============================================================================
  # DS Hash Algorithm Tests (RFC 4509, 6605)
  # ============================================================================

  describe "DS hash algorithms" do
    test "SHA-1 algorithm value is 1 (RFC 3658)" do
      option = Chain.new(@sha1_algo)
      assert option.data == 1
    end

    test "SHA-256 algorithm value is 2 (RFC 4509)" do
      option = Chain.new(@sha256_algo)
      assert option.data == 2
    end

    test "GOST R 34.11-94 algorithm value is 3 (RFC 5933)" do
      option = Chain.new(@gost_algo)
      assert option.data == 3
    end

    test "SHA-384 algorithm value is 4 (RFC 6605)" do
      option = Chain.new(@sha384_algo)
      assert option.data == 4
    end

    test "algorithm 0 is reserved" do
      option = Chain.new(0)
      assert option.data == 0
    end

    test "all common algorithms can be encoded" do
      for algo <- @common_algorithms do
        option = Chain.new(algo)
        iodata = DNS.Parameter.to_iodata(option)
        <<_code::16, _length::16, value::16>> = iodata
        assert value == algo
      end
    end
  end

  # ============================================================================
  # Wire Format Tests
  # ============================================================================

  describe "wire format encoding" do
    test "encodes option code as big-endian 16-bit" do
      option = Chain.new(@sha256_algo)
      iodata = DNS.Parameter.to_iodata(option)
      <<high, low, _rest::binary>> = iodata

      assert high == 0
      assert low == 13
    end

    test "encodes length as big-endian 16-bit" do
      option = Chain.new(@sha256_algo)
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, high, low, _rest::binary>> = iodata

      assert high == 0
      assert low == 2
    end

    test "encodes trust point as big-endian 16-bit" do
      # 258 decimal
      option = Chain.new(0x0102)
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, high, low>> = iodata

      assert high == 1
      assert low == 2
    end

    test "total wire format is 6 bytes" do
      option = Chain.new(@sha256_algo)
      iodata = DNS.Parameter.to_iodata(option)
      assert byte_size(iodata) == 6
    end

    test "encodes minimum value (0)" do
      option = Chain.new(0)
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, value::16>> = iodata
      assert value == 0
    end

    test "encodes maximum value (65535)" do
      option = Chain.new(65535)
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, value::16>> = iodata
      assert value == 65535
    end
  end

  # ============================================================================
  # Parsing Tests
  # ============================================================================

  describe "parsing from wire format" do
    test "parses minimal CHAIN option" do
      binary = <<13::16, 2::16, 2::16>>
      option = Chain.from_iodata(binary)

      assert option.code.value == <<0, 13>>
      assert option.length == 2
      assert option.data == 2
    end

    test "parses all standard algorithm values" do
      for algo <- [0, 1, 2, 3, 4] do
        binary = <<13::16, 2::16, algo::16>>
        option = Chain.from_iodata(binary)
        assert option.data == algo
      end
    end

    test "parses large algorithm values" do
      for algo <- [100, 1000, 10000, 65535] do
        binary = <<13::16, 2::16, algo::16>>
        option = Chain.from_iodata(binary)
        assert option.data == algo
      end
    end

    test "preserves value exactly during parsing" do
      # Test with high byte set
      binary = <<13::16, 2::16, 0xFF00::16>>
      option = Chain.from_iodata(binary)
      assert option.data == 0xFF00
    end

    test "parses wire format from simulated DNS traffic" do
      # Simulated wire data: CHAIN with SHA-256
      wire_data = <<0, 13, 0, 2, 0, 2>>
      option = Chain.from_iodata(wire_data)
      assert option.data == 2
    end
  end

  # ============================================================================
  # Concurrent Operations Tests
  # ============================================================================

  describe "concurrent operations" do
    test "concurrent CHAIN option creation" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            Chain.new(rem(i, 65536))
          end)
        end

      results = Task.await_many(tasks)
      assert length(results) == 50
      assert Enum.all?(results, &is_struct(&1, Chain))
    end

    test "concurrent serialization" do
      options = Enum.map(1..20, fn i -> Chain.new(rem(i, 65536)) end)

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
          <<13::16, 2::16, rem(i, 65536)::16>>
        end)

      tasks =
        Enum.map(binaries, fn binary ->
          Task.async(fn ->
            Chain.from_iodata(binary)
          end)
        end)

      results = Task.await_many(tasks)
      assert length(results) == 20
      assert Enum.all?(results, &is_struct(&1, Chain))
    end

    test "concurrent round-trip" do
      tasks =
        for i <- 1..30 do
          Task.async(fn ->
            original = Chain.new(rem(i * 100, 65536))
            iodata = DNS.Parameter.to_iodata(original)
            parsed = Chain.from_iodata(iodata)
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
    test "formats CHAIN with SHA-256" do
      option = Chain.new(@sha256_algo)
      assert to_string(option) == "CHAIN: 2"
    end

    test "formats CHAIN with SHA-1" do
      option = Chain.new(@sha1_algo)
      assert to_string(option) == "CHAIN: 1"
    end

    test "formats CHAIN with zero" do
      option = Chain.new(0)
      assert to_string(option) == "CHAIN: 0"
    end

    test "formats CHAIN with max value" do
      option = Chain.new(65535)
      assert to_string(option) == "CHAIN: 65535"
    end

    test "string contains trust point value" do
      option = Chain.new(12345)
      string = to_string(option)
      assert String.contains?(string, "12345")
    end

    test "string is usable in interpolation" do
      option = Chain.new(@sha256_algo)
      message = "EDNS0 Option: #{option}"
      assert message =~ "CHAIN: 2"
    end

    test "string starts with CHAIN:" do
      option = Chain.new(@sha256_algo)
      assert String.starts_with?(to_string(option), "CHAIN:")
    end
  end

  # ============================================================================
  # Comparison Tests
  # ============================================================================

  describe "comparison and equality" do
    test "same value creates equal options" do
      opt1 = Chain.new(@sha256_algo)
      opt2 = Chain.new(@sha256_algo)
      assert opt1 == opt2
    end

    test "different values create different options" do
      opt1 = Chain.new(@sha1_algo)
      opt2 = Chain.new(@sha256_algo)
      assert opt1 != opt2
    end

    test "options can be used in MapSet" do
      options = [
        Chain.new(1),
        Chain.new(2),
        # duplicate
        Chain.new(1),
        Chain.new(3)
      ]

      unique = MapSet.new(options)
      assert MapSet.size(unique) == 3
    end

    test "options can be used as map keys" do
      opt = Chain.new(@sha256_algo)
      map = %{opt => "SHA-256"}
      assert map[opt] == "SHA-256"
    end
  end

  # ============================================================================
  # Practical Usage Tests
  # ============================================================================

  describe "practical DNSSEC scenarios" do
    test "requesting DNSSEC chain with SHA-256 trust anchor" do
      # Client requesting chain validation starting from SHA-256 DS
      option = Chain.new(@sha256_algo)

      iodata = DNS.Parameter.to_iodata(option)
      assert byte_size(iodata) == 6
    end

    test "building CHAIN for EDNS0 OPT record" do
      # Create CHAIN option for inclusion in query
      chain = Chain.new(@sha256_algo)
      wire_data = DNS.Parameter.to_iodata(chain)

      # Verify structure for OPT record
      <<code::16, length::16, data::binary>> = wire_data
      assert code == 13
      assert length == 2
      assert byte_size(data) == 2
    end

    test "parsing CHAIN from received DNS response" do
      # Simulate parsing CHAIN from received message
      # CHAIN with SHA-256
      wire_data = <<0, 13, 0, 2, 0, 2>>
      option = Chain.from_iodata(wire_data)

      assert option.data == @sha256_algo
      assert to_string(option) == "CHAIN: 2"
    end

    test "multiple CHAIN options with different algorithms" do
      # Different trust anchors may use different algorithms
      sha1_chain = Chain.new(@sha1_algo)
      sha256_chain = Chain.new(@sha256_algo)
      sha384_chain = Chain.new(@sha384_algo)

      assert sha1_chain.data == 1
      assert sha256_chain.data == 2
      assert sha384_chain.data == 4
    end
  end

  # ============================================================================
  # Boundary Value Tests
  # ============================================================================

  describe "boundary values" do
    test "minimum value (0)" do
      option = Chain.new(0)
      assert option.data == 0

      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, value::16>> = iodata
      assert value == 0
    end

    test "maximum value (65535)" do
      option = Chain.new(65535)
      assert option.data == 65535

      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, value::16>> = iodata
      assert value == 65535
    end

    test "single byte values (0-255)" do
      for value <- [0, 1, 127, 128, 255] do
        option = Chain.new(value)
        assert option.data == value
      end
    end

    test "two byte values (256-65535)" do
      for value <- [256, 1000, 32768, 65534, 65535] do
        option = Chain.new(value)
        assert option.data == value
      end
    end

    test "power of 2 values" do
      for exp <- 0..15 do
        value = :math.pow(2, exp) |> trunc()
        option = Chain.new(value)
        assert option.data == value
      end
    end
  end

  # ============================================================================
  # Performance Tests
  # ============================================================================

  describe "performance" do
    test "creating many CHAIN options is efficient" do
      {time, options} =
        :timer.tc(fn ->
          Enum.map(0..999, &Chain.new/1)
        end)

      assert length(options) == 1000
      # Should complete in under 50ms
      assert time < 50000
    end

    test "serializing many options is efficient" do
      options = Enum.map(0..999, &Chain.new/1)

      {time, _results} =
        :timer.tc(fn ->
          Enum.map(options, &DNS.Parameter.to_iodata/1)
        end)

      # Should complete in under 50ms
      assert time < 50000
    end

    test "parsing many options is efficient" do
      binaries = Enum.map(0..999, fn i -> <<13::16, 2::16, i::16>> end)

      {time, _results} =
        :timer.tc(fn ->
          Enum.map(binaries, &Chain.from_iodata/1)
        end)

      # Should complete in under 50ms
      assert time < 50000
    end

    test "round-trip performance" do
      {time, _} =
        :timer.tc(fn ->
          Enum.each(0..499, fn i ->
            original = Chain.new(i)
            iodata = DNS.Parameter.to_iodata(original)
            _parsed = Chain.from_iodata(iodata)
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
    test "struct fields are accessible" do
      option = Chain.new(@sha256_algo)

      assert option.code == OptionCode.new(13)
      assert option.length == 2
      assert option.data == @sha256_algo
    end

    test "default struct values" do
      default = %Chain{}

      assert default.code == OptionCode.new(13)
      assert default.length == 2
      assert default.data == nil
    end

    test "option is inspectable" do
      option = Chain.new(@sha256_algo)
      inspect_str = inspect(option)

      assert is_binary(inspect_str)
      assert String.contains?(inspect_str, "Chain")
    end

    test "all values in 16-bit range work" do
      # Sample across the full range
      test_values = [0, 1, 255, 256, 1000, 10000, 32767, 32768, 65534, 65535]

      for value <- test_values do
        option = Chain.new(value)
        iodata = DNS.Parameter.to_iodata(option)
        parsed = Chain.from_iodata(iodata)
        assert parsed.data == value
      end
    end
  end
end
