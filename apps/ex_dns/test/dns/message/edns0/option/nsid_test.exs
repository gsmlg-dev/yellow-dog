defmodule DNS.Message.EDNS0.Option.NSIDTest do
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.NSID

  describe "new/1" do
    test "creates NSID option with binary data" do
      nsid_data = "example-nsid"
      option = NSID.new(nsid_data)
      assert option.code.value == <<3::16>>
      assert option.length == byte_size(nsid_data)
      assert option.data == nsid_data
    end

    test "creates NSID option with empty data" do
      option = NSID.new("")
      assert option.code.value == <<3::16>>
      assert option.length == 0
      assert option.data == ""
    end
  end

  describe "from_iodata/1" do
    test "parses NSID option from binary" do
      nsid_data = "test-nsid"
      binary = <<3::16, byte_size(nsid_data)::16, nsid_data::binary>>
      option = NSID.from_iodata(binary)
      assert option.code.value == <<3::16>>
      assert option.length == byte_size(nsid_data)
      assert option.data == nsid_data
    end

    test "parses empty NSID option" do
      binary = <<3::16, 0::16>>
      option = NSID.from_iodata(binary)
      assert option.code.value == <<3::16>>
      assert option.length == 0
      assert option.data == ""
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts NSID option to iodata" do
      nsid_data = "test-nsid-data"
      option = NSID.new(nsid_data)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<3::16, byte_size(nsid_data)::16, nsid_data::binary>>
    end
  end

  describe "String.Chars protocol" do
    test "converts NSID option to string" do
      nsid_data = "test-nsid"
      option = NSID.new(nsid_data)
      expected_hex = Base.encode16(nsid_data)
      assert to_string(option) == "NSID: #{expected_hex}"
    end
  end
end
