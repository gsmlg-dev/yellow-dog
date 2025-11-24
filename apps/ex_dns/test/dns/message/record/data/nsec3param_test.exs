defmodule DNS.Message.Record.Data.NSEC3PARAMTest do
  use ExUnit.Case
  alias DNS.Message.Record.Data.NSEC3PARAM

  describe "new/1" do
    test "creates NSEC3PARAM record with valid parameters" do
      # SHA-1
      hash_algorithm = 1
      flags = 0
      iterations = 10
      salt = <<0xAB, 0xCD>>

      nsec3param = NSEC3PARAM.new({hash_algorithm, flags, iterations, salt})

      assert nsec3param.type.value == <<51::16>>
      assert nsec3param.data == {hash_algorithm, flags, iterations, salt}

      expected_raw = <<
        hash_algorithm::8,
        flags::8,
        iterations::16,
        byte_size(salt)::8,
        salt::binary
      >>

      assert nsec3param.raw == expected_raw
      assert nsec3param.rdlength == 1 + 1 + 2 + 1 + byte_size(salt)
    end

    test "handles NSEC3PARAM record without salt" do
      hash_algorithm = 1
      flags = 0
      iterations = 0
      salt = <<>>

      nsec3param = NSEC3PARAM.new({hash_algorithm, flags, iterations, salt})

      assert nsec3param.data == {hash_algorithm, flags, iterations, salt}
      # 1 + 1 + 2 + 1 + 0
      assert nsec3param.rdlength == 5
    end

    test "handles NSEC3PARAM record with longer salt" do
      hash_algorithm = 1
      # Opt-out
      flags = 1
      iterations = 100
      # 32 bytes
      salt = :binary.copy(<<0x12, 0x34>>, 16)

      nsec3param = NSEC3PARAM.new({hash_algorithm, flags, iterations, salt})

      assert nsec3param.data == {hash_algorithm, flags, iterations, salt}
      assert nsec3param.rdlength == 1 + 1 + 2 + 1 + 32
    end

    test "handles minimal NSEC3PARAM record" do
      hash_algorithm = 0
      flags = 0
      iterations = 0
      salt = <<>>

      nsec3param = NSEC3PARAM.new({hash_algorithm, flags, iterations, salt})

      assert nsec3param.type.value == <<51::16>>
      assert nsec3param.data == {hash_algorithm, flags, iterations, salt}
    end
  end

  describe "from_iodata/2" do
    test "parses NSEC3PARAM record correctly" do
      hash_algorithm = 1
      flags = 0
      iterations = 10
      salt = <<0xAB, 0xCD>>

      raw = <<
        hash_algorithm::8,
        flags::8,
        iterations::16,
        byte_size(salt)::8,
        salt::binary
      >>

      nsec3param = NSEC3PARAM.from_iodata(raw)

      assert nsec3param.type.value == <<51::16>>
      assert nsec3param.data == {hash_algorithm, flags, iterations, salt}
      assert nsec3param.raw == raw
    end

    test "parses NSEC3PARAM record with different parameters" do
      # SHA-256
      hash_algorithm = 2
      # Opt-out
      flags = 1
      iterations = 100
      salt = <<0x01, 0x02, 0x03, 0x04>>

      raw = <<
        hash_algorithm::8,
        flags::8,
        iterations::16,
        byte_size(salt)::8,
        salt::binary
      >>

      nsec3param = NSEC3PARAM.from_iodata(raw)

      assert nsec3param.data == {hash_algorithm, flags, iterations, salt}
    end

    test "parses NSEC3PARAM record with empty salt" do
      hash_algorithm = 1
      flags = 0
      iterations = 0
      salt = <<>>

      raw = <<
        hash_algorithm::8,
        flags::8,
        iterations::16,
        0::8
      >>

      nsec3param = NSEC3PARAM.from_iodata(raw)

      assert nsec3param.data == {hash_algorithm, flags, iterations, salt}
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts NSEC3PARAM record to iodata" do
      hash_algorithm = 1
      flags = 0
      iterations = 10
      salt = <<0xAB, 0xCD>>

      nsec3param = NSEC3PARAM.new({hash_algorithm, flags, iterations, salt})

      iodata = DNS.Parameter.to_iodata(nsec3param)
      expected_size = 1 + 1 + 2 + 1 + byte_size(salt)

      expected =
        <<expected_size::16, hash_algorithm::8, flags::8, iterations::16, byte_size(salt)::8,
          salt::binary>>

      assert iodata == expected
    end

    test "converts NSEC3PARAM without salt to iodata" do
      hash_algorithm = 1
      flags = 0
      iterations = 0
      salt = <<>>

      nsec3param = NSEC3PARAM.new({hash_algorithm, flags, iterations, salt})

      iodata = DNS.Parameter.to_iodata(nsec3param)
      expected = <<5::16, hash_algorithm::8, flags::8, iterations::16, 0::8>>

      assert iodata == expected
    end
  end

  describe "String.Chars protocol" do
    test "converts NSEC3PARAM record to string" do
      hash_algorithm = 1
      flags = 0
      iterations = 10
      salt = <<0xAB, 0xCD>>

      nsec3param = NSEC3PARAM.new({hash_algorithm, flags, iterations, salt})

      str = to_string(nsec3param)
      salt_hex = Base.encode16(salt, case: :lower)

      assert str == "#{hash_algorithm} #{flags} #{iterations} #{salt_hex}"
    end

    test "converts NSEC3PARAM without salt to string" do
      hash_algorithm = 1
      flags = 0
      iterations = 0
      salt = <<>>

      nsec3param = NSEC3PARAM.new({hash_algorithm, flags, iterations, salt})

      str = to_string(nsec3param)

      assert str == "#{hash_algorithm} #{flags} #{iterations} "
    end
  end
end
