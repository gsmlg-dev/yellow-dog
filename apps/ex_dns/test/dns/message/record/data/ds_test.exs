defmodule DNS.Message.Record.Data.DSTest do
  use ExUnit.Case
  alias DNS.Message.Record.Data.DS

  describe "new/1" do
    test "creates DS record with valid parameters" do
      key_tag = 12345
      # RSA/SHA-256
      algorithm = 8
      # SHA-256
      digest_type = 2

      digest =
        <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24,
          25, 26, 27, 28, 29, 30, 31, 32>>

      ds = DS.new({key_tag, algorithm, digest_type, digest})

      assert ds.type.value == <<43::16>>
      # 2 + 1 + 1 + 32
      assert ds.rdlength == 36
      assert ds.data == {key_tag, algorithm, digest_type, digest}

      expected_raw = <<key_tag::16, algorithm::8, digest_type::8, digest::binary>>
      assert ds.raw == expected_raw
    end

    test "handles shorter digest" do
      key_tag = 12345
      algorithm = 8
      # SHA-1
      digest_type = 1
      digest = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20>>

      ds = DS.new({key_tag, algorithm, digest_type, digest})

      # 2 + 1 + 1 + 20
      assert ds.rdlength == 24
      assert ds.data == {key_tag, algorithm, digest_type, digest}
    end

    test "handles minimal digest" do
      key_tag = 1
      algorithm = 1
      digest_type = 0
      digest = <<>>

      ds = DS.new({key_tag, algorithm, digest_type, digest})

      # 2 + 1 + 1 + 0
      assert ds.rdlength == 4
      assert ds.data == {key_tag, algorithm, digest_type, digest}
    end
  end

  describe "from_iodata/2" do
    test "parses DS record correctly" do
      key_tag = 12345
      algorithm = 8
      digest_type = 2

      digest =
        <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24,
          25, 26, 27, 28, 29, 30, 31, 32>>

      raw = <<key_tag::16, algorithm::8, digest_type::8, digest::binary>>

      ds = DS.from_iodata(raw)

      assert ds.type.value == <<43::16>>
      assert ds.rdlength == 36
      assert ds.data == {key_tag, algorithm, digest_type, digest}
      assert ds.raw == raw
    end

    test "parses short DS record" do
      key_tag = 1
      algorithm = 1
      digest_type = 1
      digest = <<1, 2, 3>>
      raw = <<key_tag::16, algorithm::8, digest_type::8, digest::binary>>

      ds = DS.from_iodata(raw)

      assert ds.rdlength == 7
      assert ds.data == {key_tag, algorithm, digest_type, digest}
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts DS record to iodata" do
      key_tag = 12345
      algorithm = 8
      digest_type = 2

      digest =
        <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24,
          25, 26, 27, 28, 29, 30, 31, 32>>

      ds = DS.new({key_tag, algorithm, digest_type, digest})

      iodata = DNS.Parameter.to_iodata(ds)
      expected_size = 36
      expected = <<expected_size::16, key_tag::16, algorithm::8, digest_type::8, digest::binary>>

      assert iodata == expected
    end
  end

  describe "String.Chars protocol" do
    test "converts DS record to string" do
      key_tag = 12345
      algorithm = 8
      digest_type = 2

      digest =
        <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24,
          25, 26, 27, 28, 29, 30, 31, 32>>

      ds = DS.new({key_tag, algorithm, digest_type, digest})

      str = to_string(ds)
      digest_hex = Base.encode16(digest, case: :lower)

      assert str == "#{key_tag} #{algorithm} #{digest_type} #{digest_hex}"
    end
  end
end
