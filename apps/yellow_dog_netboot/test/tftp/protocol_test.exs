defmodule YellowDog.Netboot.TFTP.ProtocolTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netboot.TFTP.Protocol

  describe "decode/1 RRQ" do
    test "decodes basic RRQ packet" do
      packet = <<1::16, "test.bin", 0, "octet", 0>>
      assert {:ok, {:rrq, "test.bin", "octet", %{}}} = Protocol.decode(packet)
    end

    test "decodes RRQ with options" do
      packet = <<1::16, "file.img", 0, "octet", 0, "blksize", 0, "1468", 0, "tsize", 0, "0", 0>>
      assert {:ok, {:rrq, "file.img", "octet", opts}} = Protocol.decode(packet)
      assert opts["blksize"] == "1468"
      assert opts["tsize"] == "0"
    end

    test "normalizes mode to lowercase" do
      packet = <<1::16, "test.bin", 0, "OCTET", 0>>
      assert {:ok, {:rrq, "test.bin", "octet", %{}}} = Protocol.decode(packet)
    end

    test "rejects empty filename" do
      packet = <<1::16, 0, "octet", 0>>
      assert {:error, :invalid_packet} = Protocol.decode(packet)
    end
  end

  describe "decode/1 WRQ" do
    test "decodes WRQ packet" do
      packet = <<2::16, "upload.bin", 0, "octet", 0>>
      assert {:ok, {:wrq, "upload.bin", "octet", %{}}} = Protocol.decode(packet)
    end
  end

  describe "decode/1 DATA" do
    test "decodes DATA packet" do
      data = :crypto.strong_rand_bytes(512)
      packet = <<3::16, 1::16, data::binary>>
      assert {:ok, {:data, 1, ^data}} = Protocol.decode(packet)
    end

    test "decodes DATA with block number > 1" do
      packet = <<3::16, 42::16, "hello">>
      assert {:ok, {:data, 42, "hello"}} = Protocol.decode(packet)
    end
  end

  describe "decode/1 ACK" do
    test "decodes ACK packet" do
      packet = <<4::16, 5::16>>
      assert {:ok, {:ack, 5}} = Protocol.decode(packet)
    end

    test "decodes ACK with block 0" do
      packet = <<4::16, 0::16>>
      assert {:ok, {:ack, 0}} = Protocol.decode(packet)
    end
  end

  describe "decode/1 ERROR" do
    test "decodes ERROR packet" do
      packet = <<5::16, 1::16, "File not found", 0>>
      assert {:ok, {:error, 1, "File not found"}} = Protocol.decode(packet)
    end
  end

  describe "decode/1 OACK" do
    test "decodes OACK packet" do
      packet = <<6::16, "blksize", 0, "1468", 0>>
      assert {:ok, {:oack, %{"blksize" => "1468"}}} = Protocol.decode(packet)
    end

    test "decodes OACK with multiple options" do
      packet = <<6::16, "blksize", 0, "1468", 0, "tsize", 0, "524288", 0>>
      assert {:ok, {:oack, opts}} = Protocol.decode(packet)
      assert opts["blksize"] == "1468"
      assert opts["tsize"] == "524288"
    end
  end

  describe "decode/1 invalid" do
    test "rejects empty binary" do
      assert {:error, :invalid_packet} = Protocol.decode(<<>>)
    end

    test "rejects single byte" do
      assert {:error, :invalid_packet} = Protocol.decode(<<1>>)
    end

    test "rejects unknown opcode" do
      assert {:error, :invalid_packet} = Protocol.decode(<<99::16, 0, 0>>)
    end
  end

  describe "encode/1" do
    test "encodes DATA packet" do
      encoded = Protocol.encode({:data, 1, "hello"})
      assert <<3::16, 1::16, "hello">> = encoded
    end

    test "encodes ACK packet" do
      assert <<4::16, 7::16>> = Protocol.encode({:ack, 7})
    end

    test "encodes ERROR packet" do
      encoded = Protocol.encode({:error, 1, "File not found"})
      assert <<5::16, 1::16, "File not found", 0>> = encoded
    end

    test "encodes OACK packet" do
      encoded = Protocol.encode({:oack, %{"blksize" => "1468"}})
      assert <<6::16, rest::binary>> = encoded
      assert String.contains?(rest, "blksize")
      assert String.contains?(rest, "1468")
    end
  end

  describe "encode/decode round-trip" do
    test "DATA round-trips correctly" do
      original = {:data, 42, "test data"}
      assert {:ok, ^original} = original |> Protocol.encode() |> Protocol.decode()
    end

    test "ACK round-trips correctly" do
      original = {:ack, 99}
      assert {:ok, ^original} = original |> Protocol.encode() |> Protocol.decode()
    end

    test "ERROR round-trips correctly" do
      original = {:error, 2, "Access violation"}
      assert {:ok, ^original} = original |> Protocol.encode() |> Protocol.decode()
    end
  end

  describe "error_packet/1" do
    test "builds file not found error" do
      packet = Protocol.error_packet(1)
      assert {:ok, {:error, 1, "File not found"}} = Protocol.decode(packet)
    end

    test "builds access violation error" do
      packet = Protocol.error_packet(2)
      assert {:ok, {:error, 2, "Access violation"}} = Protocol.decode(packet)
    end
  end

  test "default_block_size/0 returns 512" do
    assert Protocol.default_block_size() == 512
  end
end
