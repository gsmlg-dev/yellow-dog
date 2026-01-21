defmodule DNS.Message.EDNS0.Option.TcpKeepaliveTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.Option.TcpKeepalive.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/0 and new/1 with optional timeout
  - from_iodata/1 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 7828)
  - TCP Keepalive semantics
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.TcpKeepalive
  alias DNS.Message.EDNS0.OptionCode

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(TcpKeepalive)
    end

    test "exports new/0" do
      Code.ensure_loaded!(TcpKeepalive)
      assert Kernel.function_exported?(TcpKeepalive, :new, 0)
    end

    test "exports new/1" do
      Code.ensure_loaded!(TcpKeepalive)
      assert Kernel.function_exported?(TcpKeepalive, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(TcpKeepalive)
      assert Kernel.function_exported?(TcpKeepalive, :from_iodata, 1)
    end

    test "defines a struct" do
      Code.ensure_loaded!(TcpKeepalive)
      assert is_struct(TcpKeepalive.__struct__())
    end
  end

  describe "struct fields" do
    test "has code field" do
      option = %TcpKeepalive{}
      assert Map.has_key?(option, :code)
    end

    test "has length field" do
      option = %TcpKeepalive{}
      assert Map.has_key?(option, :length)
    end

    test "has data field" do
      option = %TcpKeepalive{}
      assert Map.has_key?(option, :data)
    end

    test "default code is TcpKeepalive (11)" do
      option = %TcpKeepalive{}
      assert option.code == OptionCode.new(11)
    end

    test "default length is nil" do
      option = %TcpKeepalive{}
      assert option.length == nil
    end

    test "default data is nil" do
      option = %TcpKeepalive{}
      assert option.data == nil
    end
  end

  describe "new/0" do
    test "creates TcpKeepalive option with default nil" do
      option = TcpKeepalive.new()
      assert %TcpKeepalive{} = option
    end

    test "sets length to 0 for no timeout" do
      option = TcpKeepalive.new()
      assert option.length == 0
    end

    test "sets data to nil for no timeout" do
      option = TcpKeepalive.new()
      assert option.data == nil
    end

    test "option code is TcpKeepalive (11)" do
      option = TcpKeepalive.new()
      assert option.code.value == <<11::16>>
    end
  end

  describe "new/1 with timeout" do
    test "creates TcpKeepalive option with timeout" do
      timeout = 120
      option = TcpKeepalive.new(timeout)
      assert %TcpKeepalive{} = option
    end

    test "stores timeout value" do
      option = TcpKeepalive.new(120)
      assert option.data == 120
    end

    test "sets length to 2 for timeout" do
      option = TcpKeepalive.new(120)
      assert option.length == 2
    end

    test "option code is TcpKeepalive (11)" do
      option = TcpKeepalive.new(120)
      assert option.code.value == <<11::16>>
    end

    test "creates TcpKeepalive option with nil timeout" do
      option = TcpKeepalive.new(nil)
      assert option.code.value == <<11::16>>
      assert option.length == 0
      assert option.data == nil
    end

    test "handles zero timeout" do
      option = TcpKeepalive.new(0)
      assert option.data == 0
      assert option.length == 2
    end

    test "handles max timeout (65535)" do
      option = TcpKeepalive.new(65535)
      assert option.data == 65535
      assert option.length == 2
    end

    test "handles common timeout values" do
      # 100 = 10 seconds, 600 = 60 seconds, 1200 = 120 seconds
      for timeout <- [100, 300, 600, 1200, 3000] do
        option = TcpKeepalive.new(timeout)
        assert option.data == timeout
      end
    end
  end

  describe "from_iodata/1" do
    test "parses TcpKeepalive option with timeout from binary" do
      timeout = 120
      binary = <<11::16, 2::16, timeout::16>>
      option = TcpKeepalive.from_iodata(binary)
      assert %TcpKeepalive{} = option
    end

    test "parses timeout correctly" do
      binary = <<11::16, 2::16, 600::16>>
      option = TcpKeepalive.from_iodata(binary)
      assert option.data == 600
    end

    test "parses length correctly with timeout" do
      binary = <<11::16, 2::16, 120::16>>
      option = TcpKeepalive.from_iodata(binary)
      assert option.length == 2
    end

    test "parses TcpKeepalive option without timeout from binary" do
      binary = <<11::16, 0::16>>
      option = TcpKeepalive.from_iodata(binary)
      assert option.code.value == <<11::16>>
      assert option.length == 0
      assert option.data == nil
    end

    test "parses zero timeout" do
      binary = <<11::16, 2::16, 0::16>>
      option = TcpKeepalive.from_iodata(binary)
      assert option.data == 0
    end

    test "parses max timeout (65535)" do
      binary = <<11::16, 2::16, 65535::16>>
      option = TcpKeepalive.from_iodata(binary)
      assert option.data == 65535
    end

    test "parses various timeout values" do
      for timeout <- [1, 100, 600, 1200, 10000, 65534] do
        binary = <<11::16, 2::16, timeout::16>>
        option = TcpKeepalive.from_iodata(binary)
        assert option.data == timeout
      end
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format with timeout" do
      option = TcpKeepalive.new(120)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<11::16, 2::16, 120::16>>
    end

    test "wire format starts with option code 11" do
      option = TcpKeepalive.new(120)
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 11
    end

    test "wire format has length 2 with timeout" do
      option = TcpKeepalive.new(120)
      <<_code::16, length::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert length == 2
    end

    test "converts TcpKeepalive option without timeout to iodata" do
      option = TcpKeepalive.new(nil)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<11::16, 0::16>>
    end

    test "wire format has length 0 without timeout" do
      option = TcpKeepalive.new()
      <<_code::16, length::16>> = DNS.Parameter.to_iodata(option)
      assert length == 0
    end

    test "encodes timeout as 16-bit unsigned" do
      option = TcpKeepalive.new(12345)
      <<_code::16, _length::16, timeout::16>> = DNS.Parameter.to_iodata(option)
      assert timeout == 12345
    end

    test "encodes zero timeout" do
      option = TcpKeepalive.new(0)
      <<_code::16, _length::16, timeout::16>> = DNS.Parameter.to_iodata(option)
      assert timeout == 0
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'edns-tcp-keepalive: Nms' with timeout" do
      option = TcpKeepalive.new(120)
      # 120 * 100 = 12000ms
      assert to_string(option) == "edns-tcp-keepalive: 12000ms"
    end

    test "converts timeout to milliseconds" do
      option = TcpKeepalive.new(10)
      # 10 * 100 = 1000ms
      assert to_string(option) == "edns-tcp-keepalive: 1000ms"
    end

    test "formats without timeout as 'not specified'" do
      option = TcpKeepalive.new(nil)
      assert to_string(option) == "edns-tcp-keepalive: not specified"
    end

    test "formats zero timeout" do
      option = TcpKeepalive.new(0)
      assert to_string(option) == "edns-tcp-keepalive: 0ms"
    end

    test "string interpolation works" do
      option = TcpKeepalive.new(120)
      result = "Option: #{option}"
      assert result =~ "edns-tcp-keepalive:"
    end

    test "formats large timeout value" do
      option = TcpKeepalive.new(65535)
      # 65535 * 100 = 6553500ms
      assert to_string(option) == "edns-tcp-keepalive: 6553500ms"
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> from_iodata preserves timeout" do
      original = TcpKeepalive.new(600)
      iodata = DNS.Parameter.to_iodata(original)
      parsed = TcpKeepalive.from_iodata(iodata)
      assert parsed.data == original.data
      assert parsed.length == original.length
    end

    test "round-trip preserves nil timeout" do
      original = TcpKeepalive.new(nil)
      iodata = DNS.Parameter.to_iodata(original)
      parsed = TcpKeepalive.from_iodata(iodata)
      assert parsed.data == nil
      assert parsed.length == 0
    end

    test "round-trip preserves zero timeout" do
      original = TcpKeepalive.new(0)
      iodata = DNS.Parameter.to_iodata(original)
      parsed = TcpKeepalive.from_iodata(iodata)
      assert parsed.data == 0
    end

    test "round-trip preserves various timeout values" do
      for timeout <- [1, 100, 600, 1200, 3000, 65535] do
        original = TcpKeepalive.new(timeout)
        iodata = DNS.Parameter.to_iodata(original)
        parsed = TcpKeepalive.from_iodata(iodata)
        assert parsed.data == timeout
      end
    end
  end

  describe "TCP Keepalive semantics" do
    test "timeout is in 100ms units" do
      # 120 units = 12 seconds
      option = TcpKeepalive.new(120)
      assert option.data == 120
      # String shows it in ms: 12000ms
      assert to_string(option) =~ "12000ms"
    end

    test "1 second timeout" do
      # 10 units = 1 second
      option = TcpKeepalive.new(10)
      assert to_string(option) =~ "1000ms"
    end

    test "1 minute timeout" do
      # 600 units = 60 seconds
      option = TcpKeepalive.new(600)
      assert to_string(option) =~ "60000ms"
    end

    test "nil means timeout not specified (client query)" do
      option = TcpKeepalive.new(nil)
      assert option.length == 0
      assert to_string(option) =~ "not specified"
    end

    test "zero timeout means immediate close suggested" do
      option = TcpKeepalive.new(0)
      assert option.data == 0
      assert option.length == 2
    end

    test "maximum keepalive (6553.5 seconds)" do
      option = TcpKeepalive.new(65535)
      # 65535 * 100 = 6553500ms = 6553.5 seconds ≈ 109 minutes
      assert option.data == 65535
    end

    test "common server-suggested keepalive (2 minutes)" do
      # 1200 units = 120 seconds = 2 minutes
      option = TcpKeepalive.new(1200)
      assert option.data == 1200
      assert to_string(option) =~ "120000ms"
    end

    test "RFC 7828 recommended minimum (10 seconds)" do
      # 100 units = 10 seconds
      option = TcpKeepalive.new(100)
      assert option.data == 100
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      option = TcpKeepalive.new(120)
      inspect_output = inspect(option)
      assert is_binary(inspect_output)
    end

    test "handles boundary timeout values" do
      # Minimum meaningful value
      option = TcpKeepalive.new(1)
      assert option.data == 1

      # Maximum value
      option = TcpKeepalive.new(65535)
      assert option.data == 65535
    end

    test "option code value is consistent" do
      option1 = TcpKeepalive.new()
      option2 = TcpKeepalive.new(120)
      assert option1.code.value == option2.code.value
    end

    test "length differs based on timeout presence" do
      without_timeout = TcpKeepalive.new(nil)
      with_timeout = TcpKeepalive.new(120)
      assert without_timeout.length == 0
      assert with_timeout.length == 2
    end

    test "handles various short timeout values" do
      for timeout <- 1..10 do
        option = TcpKeepalive.new(timeout)
        assert option.data == timeout
        assert option.length == 2
      end
    end

    test "wire format is consistent with timeout presence" do
      without_timeout = DNS.Parameter.to_iodata(TcpKeepalive.new())
      with_timeout = DNS.Parameter.to_iodata(TcpKeepalive.new(100))

      assert byte_size(without_timeout) == 4  # code(2) + length(2)
      assert byte_size(with_timeout) == 6     # code(2) + length(2) + timeout(2)
    end
  end
end
