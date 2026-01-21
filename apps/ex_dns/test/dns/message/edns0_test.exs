defmodule DNS.Message.EDNS0Test do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/0 and new/1 for creating EDNS0 structures
  - from_iodata/1 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 6891)
  - Options handling
  - DO bit and flags
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(EDNS0)
    end

    test "exports new/0" do
      Code.ensure_loaded!(EDNS0)
      assert Kernel.function_exported?(EDNS0, :new, 0)
    end

    test "exports new/1" do
      Code.ensure_loaded!(EDNS0)
      assert Kernel.function_exported?(EDNS0, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(EDNS0)
      assert Kernel.function_exported?(EDNS0, :from_iodata, 1)
    end

    test "exports add_option/2" do
      Code.ensure_loaded!(EDNS0)
      assert Kernel.function_exported?(EDNS0, :add_option, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(EDNS0)
      assert is_struct(EDNS0.__struct__())
    end
  end

  describe "struct fields" do
    test "has udp_payload field" do
      edns0 = %EDNS0{}
      assert Map.has_key?(edns0, :udp_payload)
    end

    test "has extended_rcode field" do
      edns0 = %EDNS0{}
      assert Map.has_key?(edns0, :extended_rcode)
    end

    test "has version field" do
      edns0 = %EDNS0{}
      assert Map.has_key?(edns0, :version)
    end

    test "has do_bit field" do
      edns0 = %EDNS0{}
      assert Map.has_key?(edns0, :do_bit)
    end

    test "has flags field" do
      edns0 = %EDNS0{}
      assert Map.has_key?(edns0, :flags)
    end

    test "has options field" do
      edns0 = %EDNS0{}
      assert Map.has_key?(edns0, :options)
    end

    test "default udp_payload is 0" do
      edns0 = %EDNS0{}
      assert edns0.udp_payload == 0
    end

    test "default extended_rcode is 0" do
      edns0 = %EDNS0{}
      assert edns0.extended_rcode == 0
    end

    test "default version is 0" do
      edns0 = %EDNS0{}
      assert edns0.version == 0
    end

    test "default do_bit is 0" do
      edns0 = %EDNS0{}
      assert edns0.do_bit == 0
    end

    test "default flags is 0" do
      edns0 = %EDNS0{}
      assert edns0.flags == 0
    end

    test "default options is empty list" do
      edns0 = %EDNS0{}
      assert edns0.options == []
    end
  end

  describe "new/0" do
    test "creates default EDNS0" do
      edns0 = EDNS0.new()
      assert %EDNS0{} = edns0
    end

    test "default values are zero" do
      edns0 = EDNS0.new()
      assert edns0.udp_payload == 0
      assert edns0.extended_rcode == 0
      assert edns0.version == 0
      assert edns0.do_bit == 0
      assert edns0.flags == 0
    end

    test "default options is empty" do
      edns0 = EDNS0.new()
      assert edns0.options == []
    end
  end

  describe "new/1" do
    test "creates EDNS0 from tuple" do
      edns0 = EDNS0.new({4096, 0, 0, 1, 0, []})
      assert %EDNS0{} = edns0
    end

    test "sets udp_payload" do
      edns0 = EDNS0.new({4096, 0, 0, 0, 0, []})
      assert edns0.udp_payload == 4096
    end

    test "sets extended_rcode" do
      edns0 = EDNS0.new({4096, 1, 0, 0, 0, []})
      assert edns0.extended_rcode == 1
    end

    test "sets version" do
      edns0 = EDNS0.new({4096, 0, 1, 0, 0, []})
      assert edns0.version == 1
    end

    test "sets do_bit" do
      edns0 = EDNS0.new({4096, 0, 0, 1, 0, []})
      assert edns0.do_bit == 1
    end

    test "sets flags" do
      edns0 = EDNS0.new({4096, 0, 0, 0, 0x7FFF, []})
      assert edns0.flags == 0x7FFF
    end

    test "sets options" do
      options = [:some_option]
      edns0 = EDNS0.new({4096, 0, 0, 0, 0, options})
      assert edns0.options == options
    end

    test "creates EDNS0 with DNSSEC OK" do
      edns0 = EDNS0.new({4096, 0, 0, 1, 0, []})
      assert edns0.do_bit == 1
    end

    test "creates EDNS0 with typical requestor payload" do
      edns0 = EDNS0.new({1232, 0, 0, 0, 0, []})
      assert edns0.udp_payload == 1232
    end

    test "creates EDNS0 with large payload" do
      edns0 = EDNS0.new({65535, 0, 0, 0, 0, []})
      assert edns0.udp_payload == 65535
    end
  end

  describe "from_iodata/1" do
    test "parses EDNS0 from binary" do
      # OPT RR: name=root, type=41, class=4096, ttl=0x00800000, rdlength=0
      binary = <<0, 41::16, 4096::16, 0, 0, 1::1, 0::15, 0::16>>
      edns0 = EDNS0.from_iodata(binary)
      assert %EDNS0{} = edns0
    end

    test "parses udp_payload" do
      binary = <<0, 41::16, 4096::16, 0, 0, 0::1, 0::15, 0::16>>
      edns0 = EDNS0.from_iodata(binary)
      assert edns0.udp_payload == 4096
    end

    test "parses extended_rcode" do
      binary = <<0, 41::16, 4096::16, 1, 0, 0::1, 0::15, 0::16>>
      edns0 = EDNS0.from_iodata(binary)
      assert edns0.extended_rcode == 1
    end

    test "parses version" do
      binary = <<0, 41::16, 4096::16, 0, 1, 0::1, 0::15, 0::16>>
      edns0 = EDNS0.from_iodata(binary)
      assert edns0.version == 1
    end

    test "parses do_bit" do
      binary = <<0, 41::16, 4096::16, 0, 0, 1::1, 0::15, 0::16>>
      edns0 = EDNS0.from_iodata(binary)
      assert edns0.do_bit == 1
    end

    test "parses flags" do
      binary = <<0, 41::16, 4096::16, 0, 0, 0::1, 0x100::15, 0::16>>
      edns0 = EDNS0.from_iodata(binary)
      assert edns0.flags == 0x100
    end

    test "parses with empty options" do
      binary = <<0, 41::16, 4096::16, 0, 0, 0::1, 0::15, 0::16>>
      edns0 = EDNS0.from_iodata(binary)
      assert edns0.options == []
    end
  end

  describe "add_option/2" do
    test "adds option to empty list" do
      edns0 = EDNS0.new()
      option = :test_option
      result = EDNS0.add_option(edns0, option)
      assert option in result.options
    end

    test "prepends option to existing options" do
      edns0 = EDNS0.new({4096, 0, 0, 0, 0, [:existing]})
      result = EDNS0.add_option(edns0, :new)
      assert result.options == [:new, :existing]
    end

    test "preserves other fields" do
      edns0 = EDNS0.new({4096, 1, 0, 1, 0, []})
      result = EDNS0.add_option(edns0, :option)
      assert result.udp_payload == 4096
      assert result.extended_rcode == 1
      assert result.do_bit == 1
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      edns0 = EDNS0.new({4096, 0, 0, 0, 0, []})
      iodata = DNS.Parameter.to_iodata(edns0)
      assert is_binary(iodata)
    end

    test "wire format starts with root name (0)" do
      edns0 = EDNS0.new({4096, 0, 0, 0, 0, []})
      <<name::8, _rest::binary>> = DNS.Parameter.to_iodata(edns0)
      assert name == 0
    end

    test "wire format has OPT type (41)" do
      edns0 = EDNS0.new({4096, 0, 0, 0, 0, []})
      <<_name::8, type::16, _rest::binary>> = DNS.Parameter.to_iodata(edns0)
      assert type == 41
    end

    test "wire format includes udp_payload as CLASS" do
      edns0 = EDNS0.new({4096, 0, 0, 0, 0, []})
      <<_name::8, _type::16, udp_payload::16, _rest::binary>> = DNS.Parameter.to_iodata(edns0)
      assert udp_payload == 4096
    end

    test "wire format encodes extended_rcode" do
      edns0 = EDNS0.new({4096, 5, 0, 0, 0, []})
      <<_::8, _::16, _::16, extended_rcode::8, _rest::binary>> = DNS.Parameter.to_iodata(edns0)
      assert extended_rcode == 5
    end

    test "wire format encodes version" do
      edns0 = EDNS0.new({4096, 0, 1, 0, 0, []})
      <<_::8, _::16, _::16, _::8, version::8, _rest::binary>> = DNS.Parameter.to_iodata(edns0)
      assert version == 1
    end

    test "wire format encodes DO bit" do
      edns0 = EDNS0.new({4096, 0, 0, 1, 0, []})
      <<_::8, _::16, _::16, _::8, _::8, do_bit::1, _rest::bitstring>> = DNS.Parameter.to_iodata(edns0)
      assert do_bit == 1
    end

    test "wire format has zero rdlength for no options" do
      edns0 = EDNS0.new({4096, 0, 0, 0, 0, []})
      iodata = DNS.Parameter.to_iodata(edns0)
      # Structure: name(1) + type(2) + class(2) + ttl(4) + rdlength(2) = 11 bytes
      <<_::binary-size(9), rdlength::16>> = iodata
      assert rdlength == 0
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as EDNS comment" do
      edns0 = EDNS0.new()
      str = to_string(edns0)
      assert str =~ "; EDNS:"
    end

    test "includes version" do
      edns0 = EDNS0.new({4096, 0, 1, 0, 0, []})
      str = to_string(edns0)
      assert str =~ "version: 1"
    end

    test "includes DO flag when set" do
      edns0 = EDNS0.new({4096, 0, 0, 1, 0, []})
      str = to_string(edns0)
      assert str =~ "DO"
    end

    test "includes UDP payload size" do
      edns0 = EDNS0.new({4096, 0, 0, 0, 0, []})
      str = to_string(edns0)
      assert str =~ "udp: 4096"
    end

    test "string interpolation works" do
      edns0 = EDNS0.new()
      result = "OPT: #{edns0}"
      assert result =~ "EDNS:"
    end

    test "formats default EDNS0" do
      edns0 = EDNS0.new()
      assert to_string(edns0) == "; EDNS: version: 0, flags:  udp: 0\n"
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> from_iodata preserves data" do
      original = EDNS0.new({4096, 0, 0, 1, 0, []})
      iodata = DNS.Parameter.to_iodata(original)
      parsed = EDNS0.from_iodata(iodata)
      assert parsed.udp_payload == original.udp_payload
      assert parsed.do_bit == original.do_bit
      assert parsed.version == original.version
    end

    test "round-trip preserves udp_payload values" do
      for payload <- [512, 1232, 4096, 65535] do
        original = EDNS0.new({payload, 0, 0, 0, 0, []})
        iodata = DNS.Parameter.to_iodata(original)
        parsed = EDNS0.from_iodata(iodata)
        assert parsed.udp_payload == payload
      end
    end

    test "round-trip preserves do_bit" do
      for do_bit <- [0, 1] do
        original = EDNS0.new({4096, 0, 0, do_bit, 0, []})
        iodata = DNS.Parameter.to_iodata(original)
        parsed = EDNS0.from_iodata(iodata)
        assert parsed.do_bit == do_bit
      end
    end
  end

  describe "DNSSEC support" do
    test "DO bit indicates DNSSEC OK" do
      edns0 = EDNS0.new({4096, 0, 0, 1, 0, []})
      assert edns0.do_bit == 1
    end

    test "DO bit disabled by default" do
      edns0 = EDNS0.new()
      assert edns0.do_bit == 0
    end
  end

  describe "common configurations" do
    test "typical recursive resolver" do
      edns0 = EDNS0.new({4096, 0, 0, 1, 0, []})
      assert edns0.udp_payload == 4096
      assert edns0.do_bit == 1
    end

    test "minimal UDP payload (512)" do
      edns0 = EDNS0.new({512, 0, 0, 0, 0, []})
      assert edns0.udp_payload == 512
    end

    test "recommended UDP payload (1232)" do
      edns0 = EDNS0.new({1232, 0, 0, 0, 0, []})
      assert edns0.udp_payload == 1232
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      edns0 = EDNS0.new()
      inspect_output = inspect(edns0)
      assert is_binary(inspect_output)
    end

    test "handles max udp_payload" do
      edns0 = EDNS0.new({65535, 0, 0, 0, 0, []})
      assert edns0.udp_payload == 65535
    end

    test "handles max extended_rcode" do
      edns0 = EDNS0.new({4096, 255, 0, 0, 0, []})
      assert edns0.extended_rcode == 255
    end

    test "handles max version" do
      edns0 = EDNS0.new({4096, 0, 255, 0, 0, []})
      assert edns0.version == 255
    end

    test "handles max flags" do
      edns0 = EDNS0.new({4096, 0, 0, 0, 0x7FFF, []})
      assert edns0.flags == 0x7FFF
    end
  end
end
