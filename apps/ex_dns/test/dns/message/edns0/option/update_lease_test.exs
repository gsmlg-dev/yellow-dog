defmodule DNS.Message.EDNS0.Option.UpdateLeaseTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.Option.UpdateLease.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with lease_time integer
  - from_iodata/1 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC draft)
  - DNS-SD Update Lease semantics
  - RFC compliance verification
  - Concurrent operations
  - Performance and edge cases
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.UpdateLease
  alias DNS.Message.EDNS0.OptionCode

  # ============================================================================
  # Common Time Constants (in seconds)
  # ============================================================================

  @one_minute 60
  @five_minutes 300
  @thirty_minutes 1800
  @one_hour 3600
  @two_hours 7200
  @dns_sd_default 4500       # 75 minutes - DNS-SD recommended default
  @one_day 86400
  @one_week 604800
  @max_lease 0xFFFFFFFF      # ~136 years

  # ============================================================================
  # Module Structure Tests
  # ============================================================================

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(UpdateLease)
    end

    test "exports new/1" do
      Code.ensure_loaded!(UpdateLease)
      assert Kernel.function_exported?(UpdateLease, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(UpdateLease)
      assert Kernel.function_exported?(UpdateLease, :from_iodata, 1)
    end

    test "defines a struct" do
      Code.ensure_loaded!(UpdateLease)
      assert is_struct(UpdateLease.__struct__())
    end
  end

  describe "struct fields" do
    test "has code field" do
      option = %UpdateLease{}
      assert Map.has_key?(option, :code)
    end

    test "has length field" do
      option = %UpdateLease{}
      assert Map.has_key?(option, :length)
    end

    test "has data field" do
      option = %UpdateLease{}
      assert Map.has_key?(option, :data)
    end

    test "default code is UpdateLease (2)" do
      option = %UpdateLease{}
      assert option.code == OptionCode.new(2)
    end

    test "default length is 4" do
      option = %UpdateLease{}
      assert option.length == 4
    end

    test "default data is nil" do
      assert %UpdateLease{}.data == nil
    end
  end

  describe "new/1" do
    test "creates UpdateLease option with valid lease time" do
      option = UpdateLease.new(7200)
      assert %UpdateLease{} = option
    end

    test "stores lease_time field" do
      option = UpdateLease.new(7200)
      assert option.data == 7200
    end

    test "creates option with zero lease time" do
      option = UpdateLease.new(0)
      assert option.data == 0
    end

    test "creates option with 1 hour (3600s)" do
      option = UpdateLease.new(3600)
      assert option.data == 3600
    end

    test "creates option with 2 hours (7200s)" do
      option = UpdateLease.new(7200)
      assert option.data == 7200
    end

    test "creates option with 1 day (86400s)" do
      option = UpdateLease.new(86400)
      assert option.data == 86400
    end

    test "creates option with max value (4294967295)" do
      max_time = 0xFFFFFFFF
      option = UpdateLease.new(max_time)
      assert option.data == max_time
    end

    test "option code is UpdateLease (2)" do
      option = UpdateLease.new(7200)
      assert option.code.value == <<2::16>>
    end

    test "option length is 4" do
      option = UpdateLease.new(7200)
      assert option.length == 4
    end
  end

  describe "from_iodata/1" do
    test "parses UpdateLease option from binary" do
      binary = <<2::16, 4::16, 3600::32>>
      option = UpdateLease.from_iodata(binary)
      assert %UpdateLease{} = option
    end

    test "parses lease_time correctly" do
      binary = <<2::16, 4::16, 3600::32>>
      option = UpdateLease.from_iodata(binary)
      assert option.data == 3600
    end

    test "parses zero lease_time" do
      binary = <<2::16, 4::16, 0::32>>
      option = UpdateLease.from_iodata(binary)
      assert option.data == 0
    end

    test "parses max lease_time" do
      binary = <<2::16, 4::16, 0xFFFFFFFF::32>>
      option = UpdateLease.from_iodata(binary)
      assert option.data == 0xFFFFFFFF
    end

    test "parses 1 hour lease time" do
      binary = <<2::16, 4::16, 3600::32>>
      option = UpdateLease.from_iodata(binary)
      assert option.data == 3600
    end

    test "parses length correctly" do
      binary = <<2::16, 4::16, 7200::32>>
      option = UpdateLease.from_iodata(binary)
      assert option.length == 4
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      option = UpdateLease.new(1800)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<2::16, 4::16, 1800::32>>
    end

    test "wire format starts with option code 2" do
      option = UpdateLease.new(7200)
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 2
    end

    test "wire format has length 4" do
      option = UpdateLease.new(7200)
      <<_code::16, length::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert length == 4
    end

    test "encodes lease_time as 32-bit unsigned" do
      option = UpdateLease.new(86400)
      <<_code::16, _length::16, lease_time::32>> = DNS.Parameter.to_iodata(option)
      assert lease_time == 86400
    end

    test "encodes zero correctly" do
      option = UpdateLease.new(0)
      <<_code::16, _length::16, lease_time::32>> = DNS.Parameter.to_iodata(option)
      assert lease_time == 0
    end

    test "encodes max value correctly" do
      option = UpdateLease.new(0xFFFFFFFF)
      <<_code::16, _length::16, lease_time::32>> = DNS.Parameter.to_iodata(option)
      assert lease_time == 0xFFFFFFFF
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'Update Lease: Ns'" do
      option = UpdateLease.new(3600)
      assert to_string(option) == "Update Lease: 3600s"
    end

    test "includes lease_time value" do
      option = UpdateLease.new(7200)
      str = to_string(option)
      assert str =~ "7200"
    end

    test "includes seconds suffix" do
      option = UpdateLease.new(3600)
      str = to_string(option)
      assert str =~ "s"
    end

    test "formats zero value" do
      option = UpdateLease.new(0)
      assert to_string(option) == "Update Lease: 0s"
    end

    test "string interpolation works" do
      option = UpdateLease.new(7200)
      result = "Option: #{option}"
      assert result =~ "Update Lease:"
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> from_iodata preserves data" do
      original = UpdateLease.new(7200)
      iodata = DNS.Parameter.to_iodata(original)
      parsed = UpdateLease.from_iodata(iodata)
      assert parsed.data == original.data
    end

    test "round-trip preserves various time values" do
      for time <- [0, 300, 3600, 7200, 86400, 0xFFFFFFFF] do
        original = UpdateLease.new(time)
        iodata = DNS.Parameter.to_iodata(original)
        parsed = UpdateLease.from_iodata(iodata)
        assert parsed.data == time
      end
    end
  end

  describe "DNS-SD Update Lease semantics" do
    test "lease time 0 means immediate deletion" do
      option = UpdateLease.new(0)
      assert option.data == 0
    end

    test "typical mDNS service lease (2 hours)" do
      option = UpdateLease.new(7200)
      assert option.data == 7200
    end

    test "short-lived service (30 minutes)" do
      option = UpdateLease.new(1800)
      assert option.data == 1800
    end

    test "long-lived service (1 day)" do
      option = UpdateLease.new(86400)
      assert option.data == 86400
    end

    test "default recommended lease (75 minutes)" do
      # DNS-SD recommends 75 minutes as default
      option = UpdateLease.new(4500)
      assert option.data == 4500
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      option = UpdateLease.new(@two_hours)
      inspect_output = inspect(option)
      assert is_binary(inspect_output)
    end

    test "handles common time intervals" do
      intervals = [
        @one_minute,
        @five_minutes,
        @thirty_minutes,
        @one_hour,
        @two_hours,
        @one_day,
        @one_week
      ]

      for interval <- intervals do
        option = UpdateLease.new(interval)
        assert option.data == interval
      end
    end

    test "handles max 32-bit value" do
      option = UpdateLease.new(@max_lease)
      assert option.data == @max_lease
    end
  end

  # ============================================================================
  # RFC Compliance Tests (draft-ietf-dnssd-update-lease)
  # ============================================================================

  describe "RFC compliance" do
    test "Update Lease option code is 2" do
      option = UpdateLease.new(@two_hours)
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 2
    end

    test "option data is 32-bit unsigned integer" do
      option = UpdateLease.new(0x12345678)
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, value::32>> = iodata
      assert value == 0x12345678
    end

    test "option length is always 4 bytes" do
      for time <- [0, 1, 1000, @one_day, @max_lease] do
        option = UpdateLease.new(time)
        <<_code::16, length::16, _data::binary>> = DNS.Parameter.to_iodata(option)
        assert length == 4
      end
    end

    test "wire format: code (16) + length (16) + lease (32)" do
      option = UpdateLease.new(@two_hours)
      iodata = DNS.Parameter.to_iodata(option)

      assert byte_size(iodata) == 8  # 2 + 2 + 4 bytes

      <<code::16, length::16, lease::32>> = iodata
      assert code == 2
      assert length == 4
      assert lease == @two_hours
    end

    test "zero lease indicates deregistration" do
      option = UpdateLease.new(0)
      assert option.data == 0
    end
  end

  # ============================================================================
  # DNS-SD Service Lease Semantics
  # ============================================================================

  describe "DNS-SD service lease semantics" do
    test "default lease is 75 minutes (4500 seconds)" do
      option = UpdateLease.new(@dns_sd_default)
      assert option.data == 4500
    end

    test "zero lease deregisters service immediately" do
      option = UpdateLease.new(0)
      assert option.data == 0
    end

    test "short-lived service (5 minutes)" do
      option = UpdateLease.new(@five_minutes)
      assert option.data == @five_minutes
    end

    test "typical mDNS service lease (2 hours)" do
      option = UpdateLease.new(@two_hours)
      assert option.data == @two_hours
    end

    test "long-lived service (1 day)" do
      option = UpdateLease.new(@one_day)
      assert option.data == @one_day
    end

    test "permanent service (max lease)" do
      option = UpdateLease.new(@max_lease)
      # Max lease ~136 years - effectively permanent
      assert option.data == @max_lease
    end

    test "service renewal with same lease" do
      original = UpdateLease.new(@two_hours)
      renewed = UpdateLease.new(@two_hours)
      assert original.data == renewed.data
    end
  end

  # ============================================================================
  # Wire Format Tests
  # ============================================================================

  describe "wire format encoding" do
    test "encodes option code as big-endian 16-bit" do
      option = UpdateLease.new(@two_hours)
      iodata = DNS.Parameter.to_iodata(option)
      <<high, low, _rest::binary>> = iodata

      assert high == 0
      assert low == 2
    end

    test "encodes length as big-endian 16-bit" do
      option = UpdateLease.new(@two_hours)
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, high, low, _rest::binary>> = iodata

      assert high == 0
      assert low == 4
    end

    test "encodes lease time as big-endian 32-bit" do
      option = UpdateLease.new(0x01020304)
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, b1, b2, b3, b4>> = iodata

      assert b1 == 1
      assert b2 == 2
      assert b3 == 3
      assert b4 == 4
    end

    test "total wire format is 8 bytes" do
      option = UpdateLease.new(@two_hours)
      iodata = DNS.Parameter.to_iodata(option)
      assert byte_size(iodata) == 8
    end

    test "encodes minimum value (0)" do
      option = UpdateLease.new(0)
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, value::32>> = iodata
      assert value == 0
    end

    test "encodes maximum value (0xFFFFFFFF)" do
      option = UpdateLease.new(@max_lease)
      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, value::32>> = iodata
      assert value == @max_lease
    end
  end

  # ============================================================================
  # Parsing Tests
  # ============================================================================

  describe "parsing from wire format" do
    test "parses minimal UpdateLease option" do
      binary = <<2::16, 4::16, 7200::32>>
      option = UpdateLease.from_iodata(binary)

      assert option.code.value == <<0, 2>>
      assert option.length == 4
      assert option.data == 7200
    end

    test "parses common time values" do
      for time <- [@one_minute, @one_hour, @one_day, @one_week] do
        binary = <<2::16, 4::16, time::32>>
        option = UpdateLease.from_iodata(binary)
        assert option.data == time
      end
    end

    test "parses boundary values" do
      for time <- [0, 1, @max_lease - 1, @max_lease] do
        binary = <<2::16, 4::16, time::32>>
        option = UpdateLease.from_iodata(binary)
        assert option.data == time
      end
    end

    test "preserves value exactly during parsing" do
      binary = <<2::16, 4::16, 0xDEADBEEF::32>>
      option = UpdateLease.from_iodata(binary)
      assert option.data == 0xDEADBEEF
    end

    test "parses wire format from simulated DNS traffic" do
      # Simulated wire data: UpdateLease with 2 hours
      wire_data = <<0, 2, 0, 4, 0, 0, 28, 32>>  # 7200 in big-endian
      option = UpdateLease.from_iodata(wire_data)
      assert option.data == @two_hours
    end
  end

  # ============================================================================
  # Concurrent Operations Tests
  # ============================================================================

  describe "concurrent operations" do
    test "concurrent UpdateLease option creation" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            UpdateLease.new(i * 1000)
          end)
        end

      results = Task.await_many(tasks)
      assert length(results) == 50
      assert Enum.all?(results, &is_struct(&1, UpdateLease))
    end

    test "concurrent serialization" do
      options = Enum.map(1..20, fn i -> UpdateLease.new(i * 3600) end)

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
          <<2::16, 4::16, (i * 3600)::32>>
        end)

      tasks =
        Enum.map(binaries, fn binary ->
          Task.async(fn ->
            UpdateLease.from_iodata(binary)
          end)
        end)

      results = Task.await_many(tasks)
      assert length(results) == 20
      assert Enum.all?(results, &is_struct(&1, UpdateLease))
    end

    test "concurrent round-trip" do
      tasks =
        for i <- 1..30 do
          Task.async(fn ->
            original = UpdateLease.new(i * 1000)
            iodata = DNS.Parameter.to_iodata(original)
            parsed = UpdateLease.from_iodata(iodata)
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
    test "formats UpdateLease with typical value" do
      option = UpdateLease.new(@two_hours)
      assert to_string(option) == "Update Lease: 7200s"
    end

    test "formats UpdateLease with zero" do
      option = UpdateLease.new(0)
      assert to_string(option) == "Update Lease: 0s"
    end

    test "formats UpdateLease with max value" do
      option = UpdateLease.new(@max_lease)
      string = to_string(option)
      assert String.contains?(string, "4294967295")
    end

    test "string contains seconds suffix" do
      option = UpdateLease.new(@one_day)
      string = to_string(option)
      assert String.ends_with?(string, "s")
    end

    test "string is usable in interpolation" do
      option = UpdateLease.new(@two_hours)
      message = "EDNS0 Option: #{option}"
      assert message =~ "Update Lease: 7200s"
    end

    test "string starts with Update Lease:" do
      option = UpdateLease.new(@two_hours)
      assert String.starts_with?(to_string(option), "Update Lease:")
    end
  end

  # ============================================================================
  # Comparison Tests
  # ============================================================================

  describe "comparison and equality" do
    test "same value creates equal options" do
      opt1 = UpdateLease.new(@two_hours)
      opt2 = UpdateLease.new(@two_hours)
      assert opt1 == opt2
    end

    test "different values create different options" do
      opt1 = UpdateLease.new(@one_hour)
      opt2 = UpdateLease.new(@two_hours)
      assert opt1 != opt2
    end

    test "options can be used in MapSet" do
      options = [
        UpdateLease.new(@one_hour),
        UpdateLease.new(@two_hours),
        UpdateLease.new(@one_hour),  # duplicate
        UpdateLease.new(@one_day)
      ]

      unique = MapSet.new(options)
      assert MapSet.size(unique) == 3
    end

    test "options can be compared numerically via data" do
      short = UpdateLease.new(@one_hour)
      medium = UpdateLease.new(@two_hours)
      long = UpdateLease.new(@one_day)

      assert short.data < medium.data
      assert medium.data < long.data
    end
  end

  # ============================================================================
  # Practical Usage Tests
  # ============================================================================

  describe "practical DNS-SD scenarios" do
    test "registering new service with default lease" do
      option = UpdateLease.new(@dns_sd_default)

      iodata = DNS.Parameter.to_iodata(option)
      assert byte_size(iodata) == 8
    end

    test "renewing service registration" do
      # Renewal extends the lease
      option = UpdateLease.new(@two_hours)
      wire_data = DNS.Parameter.to_iodata(option)

      <<code::16, length::16, lease::32>> = wire_data
      assert code == 2
      assert length == 4
      assert lease == @two_hours
    end

    test "deregistering service" do
      # Lease of 0 removes the registration
      option = UpdateLease.new(0)
      assert option.data == 0
    end

    test "parsing service lease from mDNS response" do
      wire_data = <<0, 2, 0, 4, 0, 0, 28, 32>>  # 7200 seconds
      option = UpdateLease.from_iodata(wire_data)

      assert option.data == @two_hours
      assert to_string(option) == "Update Lease: 7200s"
    end

    test "different service types with different leases" do
      printer_lease = UpdateLease.new(@two_hours)      # Printer
      speaker_lease = UpdateLease.new(@one_hour)       # Speaker
      temp_lease = UpdateLease.new(@five_minutes)      # Temp service

      assert printer_lease.data > speaker_lease.data
      assert speaker_lease.data > temp_lease.data
    end
  end

  # ============================================================================
  # Boundary Value Tests
  # ============================================================================

  describe "boundary values" do
    test "minimum value (0)" do
      option = UpdateLease.new(0)
      assert option.data == 0

      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, value::32>> = iodata
      assert value == 0
    end

    test "maximum value (0xFFFFFFFF)" do
      option = UpdateLease.new(@max_lease)
      assert option.data == @max_lease

      iodata = DNS.Parameter.to_iodata(option)
      <<_code::16, _length::16, value::32>> = iodata
      assert value == @max_lease
    end

    test "power of 2 values" do
      for exp <- 0..31 do
        value = :math.pow(2, exp) |> trunc()
        option = UpdateLease.new(value)
        assert option.data == value
      end
    end

    test "values near byte boundaries" do
      boundary_values = [
        255,        # 1 byte max
        256,        # 2 bytes
        65535,      # 2 bytes max
        65536,      # 3 bytes
        16777215,   # 3 bytes max
        16777216    # 4 bytes
      ]

      for value <- boundary_values do
        option = UpdateLease.new(value)
        assert option.data == value
      end
    end
  end

  # ============================================================================
  # Performance Tests
  # ============================================================================

  describe "performance" do
    test "creating many UpdateLease options is efficient" do
      {time, options} =
        :timer.tc(fn ->
          Enum.map(0..999, fn i -> UpdateLease.new(i * 100) end)
        end)

      assert length(options) == 1000
      assert time < 50000
    end

    test "serializing many options is efficient" do
      options = Enum.map(0..999, fn i -> UpdateLease.new(i * 100) end)

      {time, _results} =
        :timer.tc(fn ->
          Enum.map(options, &DNS.Parameter.to_iodata/1)
        end)

      assert time < 50000
    end

    test "parsing many options is efficient" do
      binaries = Enum.map(0..999, fn i -> <<2::16, 4::16, (i * 100)::32>> end)

      {time, _results} =
        :timer.tc(fn ->
          Enum.map(binaries, &UpdateLease.from_iodata/1)
        end)

      assert time < 50000
    end

    test "round-trip performance" do
      {time, _} =
        :timer.tc(fn ->
          Enum.each(0..499, fn i ->
            original = UpdateLease.new(i * 1000)
            iodata = DNS.Parameter.to_iodata(original)
            _parsed = UpdateLease.from_iodata(iodata)
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
      option = UpdateLease.new(@two_hours)

      assert option.code == OptionCode.new(2)
      assert option.length == 4
      assert option.data == @two_hours
    end

    test "default struct values" do
      default = %UpdateLease{}

      assert default.code == OptionCode.new(2)
      assert default.length == 4
      assert default.data == nil
    end

    test "option is inspectable" do
      option = UpdateLease.new(@two_hours)
      inspect_str = inspect(option)

      assert is_binary(inspect_str)
      assert String.contains?(inspect_str, "UpdateLease")
    end

    test "all values in 32-bit range work" do
      test_values = [0, 1, 255, 256, 65535, 65536, 16777215, 16777216,
                     @max_lease - 1, @max_lease]

      for value <- test_values do
        option = UpdateLease.new(value)
        iodata = DNS.Parameter.to_iodata(option)
        parsed = UpdateLease.from_iodata(iodata)
        assert parsed.data == value
      end
    end
  end
end
