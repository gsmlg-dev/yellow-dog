defmodule DNS.Message.EDNS0.Option.ExpireTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.Option.Expire.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with expire_time integer
  - from_iodata/1 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 7314)
  - EDNS EXPIRE semantics
  - RFC compliance verification
  - Concurrent operations
  - Performance and edge cases
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.Expire
  alias DNS.Message.EDNS0.OptionCode

  # ============================================================================
  # Common Time Constants (in seconds)
  # ============================================================================

  @one_minute 60
  @five_minutes 300
  @fifteen_minutes 900
  @one_hour 3600
  @one_day 86400
  @one_week 604_800
  @thirty_days 2_592_000
  @one_year 31_536_000
  # ~136 years
  @max_expire 0xFFFFFFFF

  # Common SOA timer values
  @typical_refresh @one_hour
  @typical_retry @fifteen_minutes
  @typical_expire @one_week
  @typical_minimum @one_day

  # ============================================================================
  # Module Structure Tests
  # ============================================================================

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Expire)
    end

    test "exports new/1" do
      Code.ensure_loaded!(Expire)
      assert Kernel.function_exported?(Expire, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(Expire)
      assert Kernel.function_exported?(Expire, :from_iodata, 1)
    end

    test "defines a struct" do
      Code.ensure_loaded!(Expire)
      assert is_struct(Expire.__struct__())
    end
  end

  describe "struct fields" do
    test "has code field" do
      option = %Expire{}
      assert Map.has_key?(option, :code)
    end

    test "has length field" do
      option = %Expire{}
      assert Map.has_key?(option, :length)
    end

    test "has data field" do
      option = %Expire{}
      assert Map.has_key?(option, :data)
    end

    test "default code is EXPIRE (9)" do
      option = %Expire{}
      assert option.code == OptionCode.new(9)
    end

    test "default length is 4" do
      option = %Expire{}
      assert option.length == 4
    end

    test "default data is nil" do
      assert %Expire{}.data == nil
    end
  end

  describe "new/1" do
    test "creates Expire option with valid expire time" do
      option = Expire.new(3600)
      assert %Expire{} = option
    end

    test "stores expire_time field" do
      option = Expire.new(3600)
      assert option.data == 3600
    end

    test "creates option with zero expire time" do
      option = Expire.new(0)
      assert option.data == 0
    end

    test "creates option with 1 hour (3600s)" do
      option = Expire.new(3600)
      assert option.data == 3600
    end

    test "creates option with 1 day (86400s)" do
      option = Expire.new(86400)
      assert option.data == 86400
    end

    test "creates option with 1 week (604800s)" do
      option = Expire.new(604_800)
      assert option.data == 604_800
    end

    test "creates option with max value (4294967295)" do
      max_time = 0xFFFFFFFF
      option = Expire.new(max_time)
      assert option.data == max_time
    end

    test "option code is EXPIRE (9)" do
      option = Expire.new(3600)
      assert option.code.value == <<9::16>>
    end

    test "option length is 4" do
      option = Expire.new(3600)
      assert option.length == 4
    end
  end

  describe "from_iodata/1" do
    test "parses Expire option from binary" do
      binary = <<9::16, 4::16, 7200::32>>
      option = Expire.from_iodata(binary)
      assert %Expire{} = option
    end

    test "parses expire_time correctly" do
      binary = <<9::16, 4::16, 7200::32>>
      option = Expire.from_iodata(binary)
      assert option.data == 7200
    end

    test "parses zero expire_time" do
      binary = <<9::16, 4::16, 0::32>>
      option = Expire.from_iodata(binary)
      assert option.data == 0
    end

    test "parses max expire_time" do
      binary = <<9::16, 4::16, 0xFFFFFFFF::32>>
      option = Expire.from_iodata(binary)
      assert option.data == 0xFFFFFFFF
    end

    test "parses 1 day expire time" do
      binary = <<9::16, 4::16, 86400::32>>
      option = Expire.from_iodata(binary)
      assert option.data == 86400
    end

    test "parses length correctly" do
      binary = <<9::16, 4::16, 3600::32>>
      option = Expire.from_iodata(binary)
      assert option.length == 4
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      option = Expire.new(1800)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<9::16, 4::16, 1800::32>>
    end

    test "wire format starts with option code 9" do
      option = Expire.new(3600)
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 9
    end

    test "wire format has length 4" do
      option = Expire.new(3600)
      <<_code::16, length::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert length == 4
    end

    test "encodes expire_time as 32-bit unsigned" do
      option = Expire.new(86400)
      <<_code::16, _length::16, expire_time::32>> = DNS.Parameter.to_iodata(option)
      assert expire_time == 86400
    end

    test "encodes zero correctly" do
      option = Expire.new(0)
      <<_code::16, _length::16, expire_time::32>> = DNS.Parameter.to_iodata(option)
      assert expire_time == 0
    end

    test "encodes max value correctly" do
      option = Expire.new(0xFFFFFFFF)
      <<_code::16, _length::16, expire_time::32>> = DNS.Parameter.to_iodata(option)
      assert expire_time == 0xFFFFFFFF
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'EDNS EXPIRE: Ns'" do
      option = Expire.new(3600)
      assert to_string(option) == "EDNS EXPIRE: 3600s"
    end

    test "includes expire_time value" do
      option = Expire.new(7200)
      str = to_string(option)
      assert str =~ "7200"
    end

    test "includes seconds suffix" do
      option = Expire.new(3600)
      str = to_string(option)
      assert str =~ "s"
    end

    test "formats zero value" do
      option = Expire.new(0)
      assert to_string(option) == "EDNS EXPIRE: 0s"
    end

    test "string interpolation works" do
      option = Expire.new(3600)
      result = "Option: #{option}"
      assert result =~ "EDNS EXPIRE:"
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> from_iodata preserves data" do
      original = Expire.new(3600)
      iodata = DNS.Parameter.to_iodata(original)
      parsed = Expire.from_iodata(iodata)
      assert parsed.data == original.data
    end

    test "round-trip preserves various time values" do
      for time <- [0, 300, 3600, 86400, 604_800, 0xFFFFFFFF] do
        original = Expire.new(time)
        iodata = DNS.Parameter.to_iodata(original)
        parsed = Expire.from_iodata(iodata)
        assert parsed.data == time
      end
    end
  end

  describe "EDNS EXPIRE semantics" do
    test "expire time 0 means expired" do
      option = Expire.new(0)
      assert option.data == 0
    end

    test "typical zone refresh time (1 hour)" do
      option = Expire.new(3600)
      assert option.data == 3600
    end

    test "typical zone retry time (15 minutes)" do
      option = Expire.new(900)
      assert option.data == 900
    end

    test "typical zone expire time (1 week)" do
      option = Expire.new(604_800)
      assert option.data == 604_800
    end

    test "typical minimum TTL (1 day)" do
      option = Expire.new(86400)
      assert option.data == 86400
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      option = Expire.new(3600)
      inspect_output = inspect(option)
      assert is_binary(inspect_output)
    end

    test "handles common time intervals" do
      intervals = [
        @one_minute,
        @five_minutes,
        @fifteen_minutes,
        @one_hour,
        @one_day,
        @one_week,
        @thirty_days
      ]

      for interval <- intervals do
        option = Expire.new(interval)
        assert option.data == interval
      end
    end

    test "handles max 32-bit value" do
      option = Expire.new(@max_expire)
      assert option.data == @max_expire
    end
  end

  # ============================================================================
  # RFC 7314 Compliance Tests
  # ============================================================================

  describe "RFC 7314 compliance" do
    test "EXPIRE option code is 9" do
      option = Expire.new(@one_hour)
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 9
    end

    test "option data is 32-bit unsigned integer" do
      option = Expire.new(0x12345678)
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, value::32>> = iodata
      assert value == 0x12345678
    end

    test "option length is always 4 bytes" do
      for time <- [0, 1, 1000, @one_day, @max_expire] do
        option = Expire.new(time)
        <<_code::16, length::16, _data::binary>> = DNS.Parameter.to_iodata(option)
        assert length == 4
      end
    end

    test "wire format: code (16) + length (16) + expire (32)" do
      option = Expire.new(@one_week)
      iodata = DNS.Parameter.to_iodata(option)

      # 2 + 2 + 4 bytes
      assert byte_size(iodata) == 8

      <<code::16, length::16, expire::32>> = iodata
      assert code == 9
      assert length == 4
      assert expire == @one_week
    end

    test "EXPIRE is used in zone transfer responses" do
      # Per RFC 7314, EXPIRE indicates time until zone data expires
      option = Expire.new(@typical_expire)
      assert option.data == @one_week
    end

    test "zero value indicates zone has expired" do
      option = Expire.new(0)
      assert option.data == 0
    end
  end

  # ============================================================================
  # SOA Timer Relationship Tests
  # ============================================================================

  describe "SOA timer relationships" do
    test "typical refresh time (1 hour)" do
      option = Expire.new(@typical_refresh)
      assert option.data == @one_hour
    end

    test "typical retry time (15 minutes)" do
      option = Expire.new(@typical_retry)
      assert option.data == @fifteen_minutes
    end

    test "typical expire time (1 week)" do
      option = Expire.new(@typical_expire)
      assert option.data == @one_week
    end

    test "typical minimum TTL (1 day)" do
      option = Expire.new(@typical_minimum)
      assert option.data == @one_day
    end

    test "expire should be greater than refresh" do
      refresh = Expire.new(@typical_refresh)
      expire = Expire.new(@typical_expire)
      assert expire.data > refresh.data
    end

    test "refresh should be greater than retry" do
      retry_opt = Expire.new(@typical_retry)
      refresh_opt = Expire.new(@typical_refresh)
      assert refresh_opt.data > retry_opt.data
    end
  end

  # ============================================================================
  # Wire Format Tests
  # ============================================================================

  describe "wire format encoding" do
    test "encodes option code as big-endian 16-bit" do
      option = Expire.new(@one_hour)
      iodata = DNS.Parameter.to_iodata(option)
      <<high, low, _rest::binary>> = iodata

      assert high == 0
      assert low == 9
    end

    test "encodes length as big-endian 16-bit" do
      option = Expire.new(@one_hour)
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, high, low, _rest::binary>> = iodata

      assert high == 0
      assert low == 4
    end

    test "encodes expire time as big-endian 32-bit" do
      option = Expire.new(0x01020304)
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, b1, b2, b3, b4>> = iodata

      assert b1 == 1
      assert b2 == 2
      assert b3 == 3
      assert b4 == 4
    end

    test "total wire format is 8 bytes" do
      option = Expire.new(@one_hour)
      iodata = DNS.Parameter.to_iodata(option)
      assert byte_size(iodata) == 8
    end

    test "encodes minimum value (0)" do
      option = Expire.new(0)
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, value::32>> = iodata
      assert value == 0
    end

    test "encodes maximum value (0xFFFFFFFF)" do
      option = Expire.new(@max_expire)
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, value::32>> = iodata
      assert value == @max_expire
    end
  end

  # ============================================================================
  # Parsing Tests
  # ============================================================================

  describe "parsing from wire format" do
    test "parses minimal EXPIRE option" do
      binary = <<9::16, 4::16, 3600::32>>
      option = Expire.from_iodata(binary)

      assert option.code.value == <<0, 9>>
      assert option.length == 4
      assert option.data == 3600
    end

    test "parses common time values" do
      for time <- [@one_minute, @one_hour, @one_day, @one_week] do
        binary = <<9::16, 4::16, time::32>>
        option = Expire.from_iodata(binary)
        assert option.data == time
      end
    end

    test "parses boundary values" do
      for time <- [0, 1, @max_expire - 1, @max_expire] do
        binary = <<9::16, 4::16, time::32>>
        option = Expire.from_iodata(binary)
        assert option.data == time
      end
    end

    test "preserves value exactly during parsing" do
      # Test with specific byte pattern
      binary = <<9::16, 4::16, 0xDEADBEEF::32>>
      option = Expire.from_iodata(binary)
      assert option.data == 0xDEADBEEF
    end

    test "parses wire format from simulated DNS traffic" do
      # Simulated wire data: EXPIRE with 1 week
      # 604800 in big-endian
      wire_data = <<0, 9, 0, 4, 0, 9, 58, 128>>
      option = Expire.from_iodata(wire_data)
      assert option.data == @one_week
    end
  end

  # ============================================================================
  # Concurrent Operations Tests
  # ============================================================================

  describe "concurrent operations" do
    test "concurrent EXPIRE option creation" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            Expire.new(i * 1000)
          end)
        end

      results = Task.await_many(tasks)
      assert length(results) == 50
      assert Enum.all?(results, &is_struct(&1, Expire))
    end

    test "concurrent serialization" do
      options = Enum.map(1..20, fn i -> Expire.new(i * 3600) end)

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
          <<9::16, 4::16, i * 3600::32>>
        end)

      tasks =
        Enum.map(binaries, fn binary ->
          Task.async(fn ->
            Expire.from_iodata(binary)
          end)
        end)

      results = Task.await_many(tasks)
      assert length(results) == 20
      assert Enum.all?(results, &is_struct(&1, Expire))
    end

    test "concurrent round-trip" do
      tasks =
        for i <- 1..30 do
          Task.async(fn ->
            original = Expire.new(i * 1000)
            iodata = DNS.Parameter.to_iodata(original)
            parsed = Expire.from_iodata(iodata)
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
    test "formats EXPIRE with typical value" do
      option = Expire.new(@one_hour)
      assert to_string(option) == "EDNS EXPIRE: 3600s"
    end

    test "formats EXPIRE with zero" do
      option = Expire.new(0)
      assert to_string(option) == "EDNS EXPIRE: 0s"
    end

    test "formats EXPIRE with max value" do
      option = Expire.new(@max_expire)
      string = to_string(option)
      assert string =~ "4294967295"
    end

    test "string contains seconds suffix" do
      option = Expire.new(@one_day)
      string = to_string(option)
      assert String.ends_with?(string, "s")
    end

    test "string is usable in interpolation" do
      option = Expire.new(@one_hour)
      message = "EDNS0 Option: #{option}"
      assert message =~ "EDNS EXPIRE: 3600s"
    end

    test "string starts with EDNS EXPIRE:" do
      option = Expire.new(@one_hour)
      assert String.starts_with?(to_string(option), "EDNS EXPIRE:")
    end
  end

  # ============================================================================
  # Comparison Tests
  # ============================================================================

  describe "comparison and equality" do
    test "same value creates equal options" do
      opt1 = Expire.new(@one_hour)
      opt2 = Expire.new(@one_hour)
      assert opt1 == opt2
    end

    test "different values create different options" do
      opt1 = Expire.new(@one_hour)
      opt2 = Expire.new(@one_day)
      assert opt1 != opt2
    end

    test "options can be used in MapSet" do
      options = [
        Expire.new(@one_hour),
        Expire.new(@one_day),
        # duplicate
        Expire.new(@one_hour),
        Expire.new(@one_week)
      ]

      unique = MapSet.new(options)
      assert MapSet.size(unique) == 3
    end

    test "options can be compared numerically via data" do
      hour = Expire.new(@one_hour)
      day = Expire.new(@one_day)
      week = Expire.new(@one_week)

      assert hour.data < day.data
      assert day.data < week.data
    end
  end

  # ============================================================================
  # Practical Usage Tests
  # ============================================================================

  describe "practical zone transfer scenarios" do
    test "secondary server receives expire time in AXFR" do
      # EXPIRE option in zone transfer response
      option = Expire.new(@one_week)

      iodata = DNS.Parameter.to_iodata(option)
      assert byte_size(iodata) == 8
    end

    test "building EXPIRE for EDNS0 OPT record" do
      expire = Expire.new(@typical_expire)
      wire_data = DNS.Parameter.to_iodata(expire)

      <<code::16, length::16, data::binary>> = wire_data
      assert code == 9
      assert length == 4
      assert byte_size(data) == 4
    end

    test "parsing EXPIRE from received zone transfer" do
      # 604800 seconds
      wire_data = <<0, 9, 0, 4, 0, 9, 58, 128>>
      option = Expire.from_iodata(wire_data)

      assert option.data == @one_week
      assert to_string(option) == "EDNS EXPIRE: 604800s"
    end

    test "tracking zone freshness with different expire times" do
      fresh_zone = Expire.new(@one_week)
      stale_zone = Expire.new(@one_hour)
      expired_zone = Expire.new(0)

      assert fresh_zone.data > stale_zone.data
      assert stale_zone.data > expired_zone.data
    end
  end

  # ============================================================================
  # Time Calculation Tests
  # ============================================================================

  describe "time calculations" do
    test "seconds to minutes conversion" do
      option = Expire.new(@one_hour)
      minutes = div(option.data, 60)
      assert minutes == 60
    end

    test "seconds to hours conversion" do
      option = Expire.new(@one_day)
      hours = div(option.data, 3600)
      assert hours == 24
    end

    test "seconds to days conversion" do
      option = Expire.new(@one_week)
      days = div(option.data, 86400)
      assert days == 7
    end

    test "maximum expire time in years" do
      option = Expire.new(@max_expire)
      years = div(option.data, @one_year)
      # 4294967295 / 31536000 ≈ 136 years
      assert years >= 136
    end
  end

  # ============================================================================
  # Boundary Value Tests
  # ============================================================================

  describe "boundary values" do
    test "minimum value (0)" do
      option = Expire.new(0)
      assert option.data == 0

      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, value::32>> = iodata
      assert value == 0
    end

    test "maximum value (0xFFFFFFFF)" do
      option = Expire.new(@max_expire)
      assert option.data == @max_expire

      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, value::32>> = iodata
      assert value == @max_expire
    end

    test "power of 2 values" do
      for exp <- 0..31 do
        value = :math.pow(2, exp) |> trunc()
        option = Expire.new(value)
        assert option.data == value
      end
    end

    test "values near byte boundaries" do
      boundary_values = [
        # 1 byte max
        255,
        # 2 bytes
        256,
        # 2 bytes max
        65535,
        # 3 bytes
        65536,
        # 3 bytes max
        16_777_215,
        # 4 bytes
        16_777_216
      ]

      for value <- boundary_values do
        option = Expire.new(value)
        assert option.data == value
      end
    end
  end

  # ============================================================================
  # Performance Tests
  # ============================================================================

  describe "performance" do
    test "creating many EXPIRE options is efficient" do
      {time, options} =
        :timer.tc(fn ->
          Enum.map(0..999, fn i -> Expire.new(i * 100) end)
        end)

      assert length(options) == 1000
      assert time < 50000
    end

    test "serializing many options is efficient" do
      options = Enum.map(0..999, fn i -> Expire.new(i * 100) end)

      {time, _results} =
        :timer.tc(fn ->
          Enum.map(options, &DNS.Parameter.to_iodata/1)
        end)

      assert time < 50000
    end

    test "parsing many options is efficient" do
      binaries = Enum.map(0..999, fn i -> <<9::16, 4::16, i * 100::32>> end)

      {time, _results} =
        :timer.tc(fn ->
          Enum.map(binaries, &Expire.from_iodata/1)
        end)

      assert time < 50000
    end

    test "round-trip performance" do
      {time, _} =
        :timer.tc(fn ->
          Enum.each(0..499, fn i ->
            original = Expire.new(i * 1000)
            iodata = DNS.Parameter.to_iodata(original)
            _parsed = Expire.from_iodata(iodata)
          end)
        end)

      assert time < 50000
    end
  end

  # ============================================================================
  # Extended Edge Cases
  # ============================================================================

  describe "extended edge cases" do
    test "struct fields are accessible" do
      option = Expire.new(@one_hour)

      assert option.code == OptionCode.new(9)
      assert option.length == 4
      assert option.data == @one_hour
    end

    test "default struct values" do
      default = %Expire{}

      assert default.code == OptionCode.new(9)
      assert default.length == 4
      assert default.data == nil
    end

    test "option is inspectable" do
      option = Expire.new(@one_hour)
      inspect_str = inspect(option)

      assert is_binary(inspect_str)
      assert inspect_str =~ "Expire"
    end

    test "all values in 32-bit range work" do
      test_values = [
        0,
        1,
        255,
        256,
        65535,
        65536,
        16_777_215,
        16_777_216,
        @max_expire - 1,
        @max_expire
      ]

      for value <- test_values do
        option = Expire.new(value)
        iodata = DNS.Parameter.to_iodata(option)
        parsed = Expire.from_iodata(iodata)
        assert parsed.data == value
      end
    end
  end
end
