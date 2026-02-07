defmodule DNS.Message.RCodeTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.RCode.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 function with integer and binary values
  - Named constructors for all standard error codes
  - extend/2 function for EDNS0 extended codes
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Extended RCODE handling (12-bit codes via OPT records)
  - RFC compliance for error code values
  """
  use ExUnit.Case, async: true

  alias DNS.Message.RCode

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(RCode)
    end

    test "exports new/1" do
      Code.ensure_loaded!(RCode)
      assert Kernel.function_exported?(RCode, :new, 1)
    end

    test "exports extend/2" do
      Code.ensure_loaded!(RCode)
      assert Kernel.function_exported?(RCode, :extend, 2)
    end

    test "exports no_error/0" do
      Code.ensure_loaded!(RCode)
      assert Kernel.function_exported?(RCode, :no_error, 0)
    end

    test "exports form_err/0" do
      Code.ensure_loaded!(RCode)
      assert Kernel.function_exported?(RCode, :form_err, 0)
    end

    test "exports serv_fail/0" do
      Code.ensure_loaded!(RCode)
      assert Kernel.function_exported?(RCode, :serv_fail, 0)
    end

    test "exports nx_domain/0" do
      Code.ensure_loaded!(RCode)
      assert Kernel.function_exported?(RCode, :nx_domain, 0)
    end

    test "exports not_imp/0" do
      Code.ensure_loaded!(RCode)
      assert Kernel.function_exported?(RCode, :not_imp, 0)
    end

    test "exports refused/0" do
      Code.ensure_loaded!(RCode)
      assert Kernel.function_exported?(RCode, :refused, 0)
    end

    test "exports yx_domain/0" do
      Code.ensure_loaded!(RCode)
      assert Kernel.function_exported?(RCode, :yx_domain, 0)
    end

    test "exports yx_rrset/0" do
      Code.ensure_loaded!(RCode)
      assert Kernel.function_exported?(RCode, :yx_rrset, 0)
    end

    test "exports nx_rrset/0" do
      Code.ensure_loaded!(RCode)
      assert Kernel.function_exported?(RCode, :nx_rrset, 0)
    end

    test "exports not_auth/0" do
      Code.ensure_loaded!(RCode)
      assert Kernel.function_exported?(RCode, :not_auth, 0)
    end

    test "exports not_zone/0" do
      Code.ensure_loaded!(RCode)
      assert Kernel.function_exported?(RCode, :not_zone, 0)
    end

    test "exports dso_type_ni/0" do
      Code.ensure_loaded!(RCode)
      assert Kernel.function_exported?(RCode, :dso_type_ni, 0)
    end

    test "defines a struct" do
      Code.ensure_loaded!(RCode)
      assert is_struct(RCode.__struct__())
    end
  end

  describe "struct fields" do
    test "has value field" do
      rcode = %RCode{}
      assert Map.has_key?(rcode, :value)
    end

    test "has extended field" do
      rcode = %RCode{}
      assert Map.has_key?(rcode, :extended)
    end

    test "default value is nil" do
      assert %RCode{}.value == nil
    end

    test "default extended is 8-bit zero" do
      assert %RCode{}.extended == <<0::8>>
    end
  end

  describe "new/1 with integer values" do
    test "creates RCode from integer 0" do
      rcode = RCode.new(0)
      assert %RCode{} = rcode
      assert rcode.value == <<0::4>>
    end

    test "creates RCode from integer 1" do
      rcode = RCode.new(1)
      assert rcode.value == <<1::4>>
    end

    test "creates RCode from integer 2" do
      rcode = RCode.new(2)
      assert rcode.value == <<2::4>>
    end

    test "creates RCode from integer 3" do
      rcode = RCode.new(3)
      assert rcode.value == <<3::4>>
    end

    test "creates RCode from integer 4" do
      rcode = RCode.new(4)
      assert rcode.value == <<4::4>>
    end

    test "creates RCode from integer 5" do
      rcode = RCode.new(5)
      assert rcode.value == <<5::4>>
    end

    test "creates RCode from all values 0-11" do
      for value <- 0..11 do
        rcode = RCode.new(value)
        assert %RCode{} = rcode
        assert rcode.value == <<value::4>>
      end
    end

    test "creates RCode from max 4-bit value 15" do
      rcode = RCode.new(15)
      assert rcode.value == <<15::4>>
    end
  end

  describe "new/1 with binary values" do
    test "creates RCode from binary value" do
      binary = <<0::4>>
      rcode = RCode.new(binary)
      assert rcode.value == binary
    end

    test "creates RCode from 4-bit binary" do
      binary = <<5::4>>
      rcode = RCode.new(binary)
      assert rcode.value == binary
    end
  end

  describe "named constructors" do
    test "no_error/0 returns RCode with value 0" do
      rcode = RCode.no_error()
      assert %RCode{} = rcode
      assert rcode.value == <<0::4>>
    end

    test "form_err/0 returns RCode with value 1" do
      rcode = RCode.form_err()
      assert rcode.value == <<1::4>>
    end

    test "serv_fail/0 returns RCode with value 2" do
      rcode = RCode.serv_fail()
      assert rcode.value == <<2::4>>
    end

    test "nx_domain/0 returns RCode with value 3" do
      rcode = RCode.nx_domain()
      assert rcode.value == <<3::4>>
    end

    test "not_imp/0 returns RCode with value 4" do
      rcode = RCode.not_imp()
      assert rcode.value == <<4::4>>
    end

    test "refused/0 returns RCode with value 5" do
      rcode = RCode.refused()
      assert rcode.value == <<5::4>>
    end

    test "yx_domain/0 returns RCode with value 6" do
      rcode = RCode.yx_domain()
      assert rcode.value == <<6::4>>
    end

    test "yx_rrset/0 returns RCode with value 7" do
      rcode = RCode.yx_rrset()
      assert rcode.value == <<7::4>>
    end

    test "nx_rrset/0 returns RCode with value 8" do
      rcode = RCode.nx_rrset()
      assert rcode.value == <<8::4>>
    end

    test "not_auth/0 returns RCode with value 9" do
      rcode = RCode.not_auth()
      assert rcode.value == <<9::4>>
    end

    test "not_zone/0 returns RCode with value 10" do
      rcode = RCode.not_zone()
      assert rcode.value == <<10::4>>
    end

    test "dso_type_ni/0 returns RCode with value 11" do
      rcode = RCode.dso_type_ni()
      assert rcode.value == <<11::4>>
    end
  end

  describe "extend/2" do
    test "extends RCode with integer value" do
      rcode = RCode.no_error()
      extended = RCode.extend(rcode, 1)
      assert extended.extended == <<1::8>>
    end

    test "extends RCode with binary value" do
      rcode = RCode.no_error()
      extended = RCode.extend(rcode, <<16::8>>)
      assert extended.extended == <<16::8>>
    end

    test "preserves original value field" do
      rcode = RCode.form_err()
      extended = RCode.extend(rcode, 5)
      assert extended.value == <<1::4>>
    end

    test "extend with 0 keeps zero extended" do
      rcode = RCode.no_error()
      extended = RCode.extend(rcode, 0)
      assert extended.extended == <<0::8>>
    end

    test "extend with max 8-bit value" do
      rcode = RCode.no_error()
      extended = RCode.extend(rcode, 255)
      assert extended.extended == <<255::8>>
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "NoError displays correctly" do
      assert to_string(RCode.no_error()) == "NoError"
    end

    test "FormErr displays correctly" do
      assert to_string(RCode.form_err()) == "FormErr"
    end

    test "ServFail displays correctly" do
      assert to_string(RCode.serv_fail()) == "ServFail"
    end

    test "NXDomain displays correctly" do
      assert to_string(RCode.nx_domain()) == "NXDomain"
    end

    test "NotImp displays correctly" do
      assert to_string(RCode.not_imp()) == "NotImp"
    end

    test "Refused displays correctly" do
      assert to_string(RCode.refused()) == "Refused"
    end

    test "YXDomain displays correctly" do
      assert to_string(RCode.yx_domain()) == "YXDomain"
    end

    test "YXRRSet displays correctly" do
      assert to_string(RCode.yx_rrset()) == "YXRRSet"
    end

    test "NXRRSet displays correctly" do
      assert to_string(RCode.nx_rrset()) == "NXRRSet"
    end

    test "NotAuth displays correctly" do
      assert to_string(RCode.not_auth()) == "NotAuth"
    end

    test "NotZone displays correctly" do
      assert to_string(RCode.not_zone()) == "NotZone"
    end

    test "DSOTYPENI displays correctly" do
      assert to_string(RCode.dso_type_ni()) == "DSOTYPENI"
    end

    test "unassigned 12 displays as 'Unassigned(12)'" do
      assert to_string(RCode.new(12)) == "Unassigned(12)"
    end

    test "unassigned 13 displays as 'Unassigned(13)'" do
      assert to_string(RCode.new(13)) == "Unassigned(13)"
    end

    test "unassigned 14 displays as 'Unassigned(14)'" do
      assert to_string(RCode.new(14)) == "Unassigned(14)"
    end

    test "unassigned 15 displays as 'Unassigned(15)'" do
      assert to_string(RCode.new(15)) == "Unassigned(15)"
    end

    test "extended RCode displays with Extended format" do
      rcode = RCode.no_error() |> RCode.extend(1)
      result = to_string(rcode)
      assert result =~ "Extended"
    end

    test "string interpolation works" do
      rcode = RCode.no_error()
      assert "RCode: #{rcode}" == "RCode: NoError"
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "to_iodata returns the value field" do
      rcode = RCode.no_error()
      iodata = DNS.Parameter.to_iodata(rcode)
      assert iodata == <<0::4>>
    end

    test "to_iodata for form_err returns 4-bit binary" do
      rcode = RCode.form_err()
      iodata = DNS.Parameter.to_iodata(rcode)
      assert iodata == <<1::4>>
    end

    test "to_iodata for serv_fail returns 4-bit binary" do
      rcode = RCode.serv_fail()
      iodata = DNS.Parameter.to_iodata(rcode)
      assert iodata == <<2::4>>
    end

    test "to_iodata for nx_domain returns 4-bit binary" do
      rcode = RCode.nx_domain()
      iodata = DNS.Parameter.to_iodata(rcode)
      assert iodata == <<3::4>>
    end

    test "to_iodata for refused returns 4-bit binary" do
      rcode = RCode.refused()
      iodata = DNS.Parameter.to_iodata(rcode)
      assert iodata == <<5::4>>
    end
  end

  describe "RFC compliance" do
    test "NoError (0) per RFC 1035" do
      assert <<0::4>> = RCode.no_error().value
    end

    test "FormErr (1) per RFC 1035" do
      assert <<1::4>> = RCode.form_err().value
    end

    test "ServFail (2) per RFC 1035" do
      assert <<2::4>> = RCode.serv_fail().value
    end

    test "NXDomain (3) per RFC 1035" do
      assert <<3::4>> = RCode.nx_domain().value
    end

    test "NotImp (4) per RFC 1035" do
      assert <<4::4>> = RCode.not_imp().value
    end

    test "Refused (5) per RFC 1035" do
      assert <<5::4>> = RCode.refused().value
    end

    test "YXDomain (6) per RFC 2136" do
      assert <<6::4>> = RCode.yx_domain().value
    end

    test "YXRRSet (7) per RFC 2136" do
      assert <<7::4>> = RCode.yx_rrset().value
    end

    test "NXRRSet (8) per RFC 2136" do
      assert <<8::4>> = RCode.nx_rrset().value
    end

    test "NotAuth (9) per RFC 2136" do
      assert <<9::4>> = RCode.not_auth().value
    end

    test "NotZone (10) per RFC 2136" do
      assert <<10::4>> = RCode.not_zone().value
    end

    test "DSOTYPENI (11) per RFC 8490" do
      assert <<11::4>> = RCode.dso_type_ni().value
    end

    test "values 12-15 are unassigned" do
      for value <- 12..15 do
        rcode = RCode.new(value)
        assert to_string(rcode) =~ "Unassigned(#{value})"
      end
    end
  end

  describe "EDNS0 extended codes" do
    test "BADVERS (16) can be represented with extended" do
      # BADVERS = 16 = (1 << 4) + 0 in 12-bit RCODE
      rcode = RCode.new(0) |> RCode.extend(1)
      # Extended field holds upper 8 bits
      assert rcode.extended == <<1::8>>
      assert rcode.value == <<0::4>>
    end

    test "extended RCode string shows Extended format" do
      rcode = RCode.new(0) |> RCode.extend(1)
      str = to_string(rcode)
      assert str =~ "Extended"
    end

    test "non-extended RCode shows standard name" do
      rcode = RCode.no_error()
      assert to_string(rcode) == "NoError"
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      rcode = RCode.no_error()
      inspect_output = inspect(rcode)
      assert is_binary(inspect_output)
      assert inspect_output =~ "RCode"
    end

    test "all base rcodes create valid structs" do
      for value <- 0..15 do
        rcode = RCode.new(value)
        assert is_struct(rcode, RCode)
      end
    end

    test "named constructors return same value as new/1" do
      assert RCode.no_error().value == RCode.new(0).value
      assert RCode.form_err().value == RCode.new(1).value
      assert RCode.serv_fail().value == RCode.new(2).value
      assert RCode.nx_domain().value == RCode.new(3).value
      assert RCode.not_imp().value == RCode.new(4).value
      assert RCode.refused().value == RCode.new(5).value
      assert RCode.yx_domain().value == RCode.new(6).value
      assert RCode.yx_rrset().value == RCode.new(7).value
      assert RCode.nx_rrset().value == RCode.new(8).value
      assert RCode.not_auth().value == RCode.new(9).value
      assert RCode.not_zone().value == RCode.new(10).value
      assert RCode.dso_type_ni().value == RCode.new(11).value
    end

    test "extended field defaults correctly for all named constructors" do
      constructors = [
        RCode.no_error(),
        RCode.form_err(),
        RCode.serv_fail(),
        RCode.nx_domain(),
        RCode.not_imp(),
        RCode.refused()
      ]

      for rcode <- constructors do
        assert rcode.extended == <<0::8>>
      end
    end
  end
end
