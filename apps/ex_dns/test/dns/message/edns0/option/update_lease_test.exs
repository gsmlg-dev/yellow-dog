defmodule DNS.Message.EDNS0.Option.UpdateLeaseTest do
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.UpdateLease

  describe "new/1" do
    test "creates UpdateLease option with valid lease time" do
      lease_time = 7200
      option = UpdateLease.new(lease_time)
      assert option.code.value == <<2::16>>
      assert option.length == 4
      assert option.data == lease_time
    end

    test "creates UpdateLease option with zero lease time" do
      option = UpdateLease.new(0)
      assert option.code.value == <<2::16>>
      assert option.length == 4
      assert option.data == 0
    end
  end

  describe "from_iodata/1" do
    test "parses UpdateLease option from binary" do
      lease_time = 3600
      binary = <<2::16, 4::16, lease_time::32>>
      option = UpdateLease.from_iodata(binary)
      assert option.code.value == <<2::16>>
      assert option.length == 4
      assert option.data == lease_time
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts UpdateLease option to iodata" do
      lease_time = 1800
      option = UpdateLease.new(lease_time)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<2::16, 4::16, lease_time::32>>
    end
  end

  describe "String.Chars protocol" do
    test "converts UpdateLease option to string" do
      lease_time = 3600
      option = UpdateLease.new(lease_time)
      assert to_string(option) == "Update Lease: 3600s"
    end
  end
end
