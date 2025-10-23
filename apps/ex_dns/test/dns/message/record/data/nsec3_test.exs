defmodule DNS.Message.Record.Data.NSEC3Test do
  use ExUnit.Case
  alias DNS.Message.Record.Data.NSEC3

  describe "new/1" do
    test "creates NSEC3 record with valid parameters" do
      # SHA-1
      hash_algorithm = 1
      flags = 0
      iterations = 10
      salt = <<0xAB, 0xCD>>
      next_hashed_owner_name = "GJEB7TG3VGQ3TQEGK7VJ9K3CD7A6T9T9"
      # A, AAAA, TXT
      type_bit_maps = <<0x00, 0x06, 0x40>>

      nsec3 =
        NSEC3.new(
          {hash_algorithm, flags, iterations, salt, next_hashed_owner_name, type_bit_maps}
        )

      assert nsec3.type.value == <<50::16>>

      assert nsec3.data ==
               {hash_algorithm, flags, iterations, salt, next_hashed_owner_name, type_bit_maps}

      expected_raw = <<
        hash_algorithm::8,
        flags::8,
        iterations::16,
        byte_size(salt)::8,
        salt::binary,
        byte_size(next_hashed_owner_name)::8,
        next_hashed_owner_name::binary,
        type_bit_maps::binary
      >>

      assert nsec3.raw == expected_raw
    end

    test "handles NSEC3 record without salt" do
      hash_algorithm = 1
      # Opt-out
      flags = 1
      iterations = 0
      salt = <<>>
      next_hashed_owner_name = "GJEB7TG3VGQ3TQEGK7VJ9K3CD7A6T9T9"
      # A
      type_bit_maps = <<0x00, 0x01>>

      nsec3 =
        NSEC3.new(
          {hash_algorithm, flags, iterations, salt, next_hashed_owner_name, type_bit_maps}
        )

      assert nsec3.data ==
               {hash_algorithm, flags, iterations, salt, next_hashed_owner_name, type_bit_maps}
    end

    test "handles NSEC3 record with longer salt" do
      hash_algorithm = 1
      flags = 0
      iterations = 100
      # 32 bytes
      salt = :binary.copy(<<0x12, 0x34>>, 16)
      next_hashed_owner_name = "GJEB7TG3VGQ3TQEGK7VJ9K3CD7A6T9T9"
      type_bit_maps = <<0x00, 0x06, 0x40>>

      nsec3 =
        NSEC3.new(
          {hash_algorithm, flags, iterations, salt, next_hashed_owner_name, type_bit_maps}
        )

      assert nsec3.data ==
               {hash_algorithm, flags, iterations, salt, next_hashed_owner_name, type_bit_maps}
    end

    test "handles minimal NSEC3 record" do
      hash_algorithm = 0
      flags = 0
      iterations = 0
      salt = <<>>
      next_hashed_owner_name = ""
      type_bit_maps = <<>>

      nsec3 =
        NSEC3.new(
          {hash_algorithm, flags, iterations, salt, next_hashed_owner_name, type_bit_maps}
        )

      assert nsec3.type.value == <<50::16>>

      assert nsec3.data ==
               {hash_algorithm, flags, iterations, salt, next_hashed_owner_name, type_bit_maps}
    end
  end

  describe "from_iodata/2" do
    test "parses NSEC3 record correctly" do
      hash_algorithm = 1
      flags = 0
      iterations = 10
      salt = <<0xAB, 0xCD>>
      next_hashed_owner_name = "GJEB7TG3VGQ3TQEGK7VJ9K3CD7A6T9T9"
      type_bit_maps = <<0x00, 0x06, 0x40>>

      raw = <<
        hash_algorithm::8,
        flags::8,
        iterations::16,
        byte_size(salt)::8,
        salt::binary,
        byte_size(next_hashed_owner_name)::8,
        next_hashed_owner_name::binary,
        type_bit_maps::binary
      >>

      nsec3 = NSEC3.from_iodata(raw)

      assert nsec3.type.value == <<50::16>>

      assert nsec3.data ==
               {hash_algorithm, flags, iterations, salt, next_hashed_owner_name, type_bit_maps}

      assert nsec3.raw == raw
    end

    test "parses NSEC3 record with different parameters" do
      # SHA-256
      hash_algorithm = 2
      # Opt-out
      flags = 1
      iterations = 100
      salt = <<0x01, 0x02, 0x03, 0x04>>
      next_hashed_owner_name = "GJEB7TG3VGQ3TQEGK7VJ9K3CD7A6T9T9"
      # NS
      type_bit_maps = <<0x00, 0x02, 0x00>>

      raw = <<
        hash_algorithm::8,
        flags::8,
        iterations::16,
        byte_size(salt)::8,
        salt::binary,
        byte_size(next_hashed_owner_name)::8,
        next_hashed_owner_name::binary,
        type_bit_maps::binary
      >>

      nsec3 = NSEC3.from_iodata(raw)

      assert nsec3.data ==
               {hash_algorithm, flags, iterations, salt, next_hashed_owner_name, type_bit_maps}
    end

    test "parses NSEC3 record with empty salt" do
      hash_algorithm = 1
      flags = 0
      iterations = 0
      salt = <<>>
      next_hashed_owner_name = "GJEB7TG3VGQ3TQEGK7VJ9K3CD7A6T9T9"
      type_bit_maps = <<0x00, 0x01>>

      next_name_binary = next_hashed_owner_name

      raw = <<
        hash_algorithm::8,
        flags::8,
        iterations::16,
        0::8,
        byte_size(next_hashed_owner_name)::8,
        next_name_binary::binary,
        type_bit_maps::binary
      >>

      nsec3 = NSEC3.from_iodata(raw)

      assert nsec3.data ==
               {hash_algorithm, flags, iterations, salt, next_hashed_owner_name, type_bit_maps}
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts NSEC3 record to iodata" do
      hash_algorithm = 1
      flags = 0
      iterations = 10
      salt = <<0xAB, 0xCD>>
      next_hashed_owner_name = "GJEB7TG3VGQ3TQEGK7VJ9K3CD7A6T9T9"
      type_bit_maps = <<0x00, 0x06, 0x40>>

      nsec3 =
        NSEC3.new(
          {hash_algorithm, flags, iterations, salt, next_hashed_owner_name, type_bit_maps}
        )

      iodata = DNS.Parameter.to_iodata(nsec3)

      next_name_binary = next_hashed_owner_name

      expected_size =
        1 + 1 + 2 + 1 + byte_size(salt) + 1 + byte_size(next_name_binary) +
          byte_size(type_bit_maps)

      expected =
        <<expected_size::16, hash_algorithm::8, flags::8, iterations::16, byte_size(salt)::8,
          salt::binary, byte_size(next_hashed_owner_name)::8, next_name_binary::binary,
          type_bit_maps::binary>>

      assert iodata == expected
    end
  end

  describe "String.Chars protocol" do
    test "converts NSEC3 record to string" do
      hash_algorithm = 1
      flags = 0
      iterations = 10
      salt = <<0xAB, 0xCD>>
      next_hashed_owner_name = "GJEB7TG3VGQ3TQEGK7VJ9K3CD7A6T9T9"
      type_bit_maps = <<0x00, 0x06, 0x40>>

      nsec3 =
        NSEC3.new(
          {hash_algorithm, flags, iterations, salt, next_hashed_owner_name, type_bit_maps}
        )

      str = to_string(nsec3)
      salt_hex = Base.encode16(salt, case: :lower)
      next_hex = Base.encode16(next_hashed_owner_name, case: :lower)
      assert str == "#{hash_algorithm} #{flags} #{iterations} #{salt_hex} #{next_hex}"
    end
  end
end
