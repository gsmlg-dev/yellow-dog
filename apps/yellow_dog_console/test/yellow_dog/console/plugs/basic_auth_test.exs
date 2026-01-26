defmodule YellowDog.Console.Plugs.BasicAuthTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias YellowDog.Console.Plugs.BasicAuth

  describe "init/1" do
    test "returns options unchanged" do
      opts = [foo: :bar]
      assert BasicAuth.init(opts) == opts
    end
  end

  describe "call/2 when authentication is disabled" do
    setup do
      # Store original config to restore later
      original_config = Application.get_env(:yellow_dog_console, BasicAuth)

      on_exit(fn ->
        if original_config do
          Application.put_env(:yellow_dog_console, BasicAuth, original_config)
        else
          Application.delete_env(:yellow_dog_console, BasicAuth)
        end
      end)

      :ok
    end

    test "passes through when disabled via config" do
      Application.put_env(:yellow_dog_console, BasicAuth, enabled: false)

      conn = conn(:get, "/")
      result = BasicAuth.call(conn, [])

      refute result.halted
      assert result.status == nil
    end
  end

  describe "call/2 when authentication is enabled" do
    setup do
      original_config = Application.get_env(:yellow_dog_console, BasicAuth)

      on_exit(fn ->
        if original_config do
          Application.put_env(:yellow_dog_console, BasicAuth, original_config)
        else
          Application.delete_env(:yellow_dog_console, BasicAuth)
        end
      end)

      :ok
    end

    test "returns 401 when no credentials provided" do
      Application.put_env(:yellow_dog_console, BasicAuth,
        enabled: true,
        username: "admin",
        password: "secret123",
        realm: "Test Realm"
      )

      conn = conn(:get, "/")
      result = BasicAuth.call(conn, [])

      assert result.halted
      assert result.status == 401
      assert get_resp_header(result, "www-authenticate") == [~s(Basic realm="Test Realm")]
    end

    test "returns 401 when credentials are invalid" do
      Application.put_env(:yellow_dog_console, BasicAuth,
        enabled: true,
        username: "admin",
        password: "secret123"
      )

      credentials = Base.encode64("admin:wrongpassword")

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Basic #{credentials}")

      result = BasicAuth.call(conn, [])

      assert result.halted
      assert result.status == 401
    end

    test "returns 401 when username is wrong" do
      Application.put_env(:yellow_dog_console, BasicAuth,
        enabled: true,
        username: "admin",
        password: "secret123"
      )

      credentials = Base.encode64("wronguser:secret123")

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Basic #{credentials}")

      result = BasicAuth.call(conn, [])

      assert result.halted
      assert result.status == 401
    end

    test "passes through when credentials are valid" do
      Application.put_env(:yellow_dog_console, BasicAuth,
        enabled: true,
        username: "admin",
        password: "secret123"
      )

      credentials = Base.encode64("admin:secret123")

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Basic #{credentials}")

      result = BasicAuth.call(conn, [])

      refute result.halted
      assert result.status == nil
    end

    test "handles colons in password correctly" do
      Application.put_env(:yellow_dog_console, BasicAuth,
        enabled: true,
        username: "admin",
        password: "secret:with:colons"
      )

      credentials = Base.encode64("admin:secret:with:colons")

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Basic #{credentials}")

      result = BasicAuth.call(conn, [])

      refute result.halted
      assert result.status == nil
    end

    @tag :capture_log
    test "passes through when password is not configured" do
      Application.put_env(:yellow_dog_console, BasicAuth,
        enabled: true,
        username: "admin",
        password: nil
      )

      conn = conn(:get, "/")
      result = BasicAuth.call(conn, [])

      # Should pass through with a warning logged
      refute result.halted
      assert result.status == nil
    end

    @tag :capture_log
    test "passes through when password is empty string" do
      Application.put_env(:yellow_dog_console, BasicAuth,
        enabled: true,
        username: "admin",
        password: ""
      )

      conn = conn(:get, "/")
      result = BasicAuth.call(conn, [])

      # Should pass through with a warning logged
      refute result.halted
      assert result.status == nil
    end

    test "handles invalid base64 encoding gracefully" do
      Application.put_env(:yellow_dog_console, BasicAuth,
        enabled: true,
        username: "admin",
        password: "secret123"
      )

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Basic not-valid-base64!!!")

      result = BasicAuth.call(conn, [])

      assert result.halted
      assert result.status == 401
    end

    test "handles non-Basic auth scheme" do
      Application.put_env(:yellow_dog_console, BasicAuth,
        enabled: true,
        username: "admin",
        password: "secret123"
      )

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer sometoken")

      result = BasicAuth.call(conn, [])

      assert result.halted
      assert result.status == 401
    end

    test "uses default realm when not configured" do
      Application.put_env(:yellow_dog_console, BasicAuth,
        enabled: true,
        username: "admin",
        password: "secret123"
      )

      conn = conn(:get, "/")
      result = BasicAuth.call(conn, [])

      assert result.halted
      assert get_resp_header(result, "www-authenticate") == [~s(Basic realm="YellowDog Console")]
    end

    test "uses default username when not configured" do
      Application.put_env(:yellow_dog_console, BasicAuth,
        enabled: true,
        password: "secret123"
      )

      # Default username is "admin"
      credentials = Base.encode64("admin:secret123")

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Basic #{credentials}")

      result = BasicAuth.call(conn, [])

      refute result.halted
    end
  end

  describe "timing attack protection" do
    setup do
      original_config = Application.get_env(:yellow_dog_console, BasicAuth)

      on_exit(fn ->
        if original_config do
          Application.put_env(:yellow_dog_console, BasicAuth, original_config)
        else
          Application.delete_env(:yellow_dog_console, BasicAuth)
        end
      end)

      :ok
    end

    test "uses constant-time comparison for credentials" do
      # This test verifies the function exists and works correctly
      # Actual timing verification would require more sophisticated testing
      Application.put_env(:yellow_dog_console, BasicAuth,
        enabled: true,
        username: "admin",
        password: "secret123"
      )

      # Same length, wrong content
      credentials1 = Base.encode64("admin:secret124")
      # Different length
      credentials2 = Base.encode64("admin:x")

      conn1 =
        conn(:get, "/")
        |> put_req_header("authorization", "Basic #{credentials1}")

      conn2 =
        conn(:get, "/")
        |> put_req_header("authorization", "Basic #{credentials2}")

      result1 = BasicAuth.call(conn1, [])
      result2 = BasicAuth.call(conn2, [])

      # Both should fail with 401
      assert result1.halted
      assert result1.status == 401
      assert result2.halted
      assert result2.status == 401
    end
  end
end
