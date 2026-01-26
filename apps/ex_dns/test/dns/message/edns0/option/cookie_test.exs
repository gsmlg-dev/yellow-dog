defmodule DNS.Message.EDNS0.Option.CookieTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.Option.Cookie.

  Tests cover:
  - Module structure and exports
  - Cookie creation (new/1)
  - Binary parsing (from_iodata/1)
  - DNS.Parameter protocol implementation
  - String.Chars protocol implementation
  - Client-only cookies (8 bytes)
  - Full cookies with server cookie (16-40 bytes)
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.Cookie

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Cookie)
    end

    test "exports new/1" do
      Code.ensure_loaded!(Cookie)
      assert Kernel.function_exported?(Cookie, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(Cookie)
      assert Kernel.function_exported?(Cookie, :from_iodata, 1)
    end

    test "defines struct with required fields" do
      cookie = %Cookie{}
      assert Map.has_key?(cookie, :code)
      assert Map.has_key?(cookie, :length)
      assert Map.has_key?(cookie, :data)
    end

    test "default code is 10 (COOKIE)" do
      cookie = %Cookie{}
      <<value::16>> = cookie.code.value
      assert value == 10
    end
  end

  describe "new/1 - client cookie only" do
    test "creates cookie with client cookie only" do
      client_cookie = :crypto.strong_rand_bytes(8)

      cookie = Cookie.new({client_cookie, nil})

      assert cookie.length == 8
      assert cookie.data == {client_cookie, nil}
    end

    test "stores client cookie exactly" do
      client_cookie = <<1, 2, 3, 4, 5, 6, 7, 8>>

      cookie = Cookie.new({client_cookie, nil})

      {stored_client, stored_server} = cookie.data
      assert stored_client == client_cookie
      assert stored_server == nil
    end
  end

  describe "new/1 - with server cookie" do
    test "creates cookie with 8-byte server cookie" do
      client_cookie = :crypto.strong_rand_bytes(8)
      server_cookie = :crypto.strong_rand_bytes(8)

      cookie = Cookie.new({client_cookie, server_cookie})

      assert cookie.length == 16
      assert cookie.data == {client_cookie, server_cookie}
    end

    test "creates cookie with 16-byte server cookie" do
      client_cookie = :crypto.strong_rand_bytes(8)
      server_cookie = :crypto.strong_rand_bytes(16)

      cookie = Cookie.new({client_cookie, server_cookie})

      assert cookie.length == 24
    end

    test "creates cookie with 32-byte server cookie (max)" do
      client_cookie = :crypto.strong_rand_bytes(8)
      server_cookie = :crypto.strong_rand_bytes(32)

      cookie = Cookie.new({client_cookie, server_cookie})

      assert cookie.length == 40
    end

    test "calculates length correctly for various server cookie sizes" do
      client_cookie = :crypto.strong_rand_bytes(8)

      for server_size <- [8, 12, 16, 20, 24, 28, 32] do
        server_cookie = :crypto.strong_rand_bytes(server_size)
        cookie = Cookie.new({client_cookie, server_cookie})
        assert cookie.length == 8 + server_size
      end
    end
  end

  describe "from_iodata/1 - client cookie only" do
    test "parses 8-byte cookie (client only)" do
      client_cookie = :crypto.strong_rand_bytes(8)
      data = <<10::16, 8::16, client_cookie::binary>>

      cookie = Cookie.from_iodata(data)

      assert cookie.length == 8
      {parsed_client, parsed_server} = cookie.data
      assert parsed_client == client_cookie
      assert parsed_server == nil
    end

    test "preserves client cookie bytes exactly" do
      client_cookie = <<0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE>>
      data = <<10::16, 8::16, client_cookie::binary>>

      cookie = Cookie.from_iodata(data)

      {parsed_client, _} = cookie.data
      assert parsed_client == client_cookie
    end
  end

  describe "from_iodata/1 - with server cookie" do
    test "parses 16-byte cookie (minimum with server)" do
      client_cookie = :crypto.strong_rand_bytes(8)
      server_cookie = :crypto.strong_rand_bytes(8)
      data = <<10::16, 16::16, client_cookie::binary, server_cookie::binary>>

      cookie = Cookie.from_iodata(data)

      assert cookie.length == 16
      {_, parsed_server} = cookie.data
      assert parsed_server == server_cookie
    end

    test "parses 40-byte cookie (maximum with server)" do
      client_cookie = :crypto.strong_rand_bytes(8)
      server_cookie = :crypto.strong_rand_bytes(32)
      data = <<10::16, 40::16, client_cookie::binary, server_cookie::binary>>

      cookie = Cookie.from_iodata(data)

      assert cookie.length == 40
      {parsed_client, parsed_server} = cookie.data
      assert parsed_client == client_cookie
      assert parsed_server == server_cookie
    end

    test "parses various valid server cookie sizes" do
      client_cookie = :crypto.strong_rand_bytes(8)

      for server_size <- [8, 12, 16, 20, 24, 28, 32] do
        server_cookie = :crypto.strong_rand_bytes(server_size)
        len = 8 + server_size
        data = <<10::16, len::16, client_cookie::binary, server_cookie::binary>>

        cookie = Cookie.from_iodata(data)

        assert cookie.length == len
        {_, parsed_server} = cookie.data
        assert parsed_server == server_cookie
      end
    end
  end

  describe "DNS.Parameter protocol - client only" do
    test "implements DNS.Parameter protocol" do
      client_cookie = :crypto.strong_rand_bytes(8)
      cookie = Cookie.new({client_cookie, nil})

      binary = DNS.Parameter.to_iodata(cookie)
      assert is_binary(binary)
    end

    test "serializes client-only cookie" do
      client_cookie = <<1, 2, 3, 4, 5, 6, 7, 8>>
      cookie = Cookie.new({client_cookie, nil})

      binary = DNS.Parameter.to_iodata(cookie)

      assert binary == <<10::16, 8::16, 1, 2, 3, 4, 5, 6, 7, 8>>
    end

    test "includes correct option code (10)" do
      client_cookie = :crypto.strong_rand_bytes(8)
      cookie = Cookie.new({client_cookie, nil})

      binary = DNS.Parameter.to_iodata(cookie)
      <<code::16, _rest::binary>> = binary

      assert code == 10
    end
  end

  describe "DNS.Parameter protocol - with server cookie" do
    test "serializes full cookie with server" do
      client_cookie = <<1, 2, 3, 4, 5, 6, 7, 8>>
      server_cookie = <<9, 10, 11, 12, 13, 14, 15, 16>>
      cookie = Cookie.new({client_cookie, server_cookie})

      binary = DNS.Parameter.to_iodata(cookie)

      assert binary ==
               <<10::16, 16::16, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>
    end

    test "calculates length correctly in serialization" do
      client_cookie = :crypto.strong_rand_bytes(8)
      server_cookie = :crypto.strong_rand_bytes(20)
      cookie = Cookie.new({client_cookie, server_cookie})

      binary = DNS.Parameter.to_iodata(cookie)
      <<_code::16, length::16, _rest::binary>> = binary

      assert length == 28
    end
  end

  describe "round-trip encoding/decoding" do
    test "round-trip for client-only cookie" do
      client_cookie = :crypto.strong_rand_bytes(8)
      original = Cookie.new({client_cookie, nil})

      binary = DNS.Parameter.to_iodata(original)
      decoded = Cookie.from_iodata(binary)

      assert decoded.length == original.length
      assert decoded.data == original.data
    end

    test "round-trip for full cookie" do
      client_cookie = :crypto.strong_rand_bytes(8)
      server_cookie = :crypto.strong_rand_bytes(16)
      original = Cookie.new({client_cookie, server_cookie})

      binary = DNS.Parameter.to_iodata(original)
      decoded = Cookie.from_iodata(binary)

      assert decoded.length == original.length
      assert decoded.data == original.data
    end

    test "round-trip preserves all server cookie sizes" do
      client_cookie = :crypto.strong_rand_bytes(8)

      for server_size <- [8, 12, 16, 20, 24, 28, 32] do
        server_cookie = :crypto.strong_rand_bytes(server_size)
        original = Cookie.new({client_cookie, server_cookie})

        binary = DNS.Parameter.to_iodata(original)
        decoded = Cookie.from_iodata(binary)

        assert decoded.data == original.data
      end
    end
  end

  describe "String.Chars protocol - client only" do
    test "implements String.Chars protocol" do
      client_cookie = :crypto.strong_rand_bytes(8)
      cookie = Cookie.new({client_cookie, nil})

      string = to_string(cookie)
      assert is_binary(string)
    end

    test "includes COOKIE in string" do
      client_cookie = :crypto.strong_rand_bytes(8)
      cookie = Cookie.new({client_cookie, nil})

      string = to_string(cookie)
      assert String.contains?(string, "COOKIE")
    end

    test "includes hex-encoded client cookie" do
      client_cookie = <<0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE>>
      cookie = Cookie.new({client_cookie, nil})

      string = to_string(cookie)
      assert String.contains?(string, "DEADBEEFCAFEBABE")
    end
  end

  describe "String.Chars protocol - with server cookie" do
    test "includes both cookies in string" do
      client_cookie = <<0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE>>
      server_cookie = <<0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0>>
      cookie = Cookie.new({client_cookie, server_cookie})

      string = to_string(cookie)
      assert String.contains?(string, "DEADBEEFCAFEBABE")
      assert String.contains?(string, "123456789ABCDEF0")
    end
  end

  describe "edge cases" do
    test "handles all-zero client cookie" do
      client_cookie = <<0, 0, 0, 0, 0, 0, 0, 0>>
      cookie = Cookie.new({client_cookie, nil})

      binary = DNS.Parameter.to_iodata(cookie)
      decoded = Cookie.from_iodata(binary)

      {parsed_client, _} = decoded.data
      assert parsed_client == client_cookie
    end

    test "handles all-ones client cookie" do
      client_cookie = <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
      cookie = Cookie.new({client_cookie, nil})

      binary = DNS.Parameter.to_iodata(cookie)
      decoded = Cookie.from_iodata(binary)

      {parsed_client, _} = decoded.data
      assert parsed_client == client_cookie
    end

    test "handles minimum server cookie (8 bytes)" do
      client_cookie = :crypto.strong_rand_bytes(8)
      server_cookie = :crypto.strong_rand_bytes(8)
      cookie = Cookie.new({client_cookie, server_cookie})

      assert cookie.length == 16
    end

    test "handles maximum server cookie (32 bytes)" do
      client_cookie = :crypto.strong_rand_bytes(8)
      server_cookie = :crypto.strong_rand_bytes(32)
      cookie = Cookie.new({client_cookie, server_cookie})

      assert cookie.length == 40
    end
  end
end
