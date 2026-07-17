defmodule YellowDog.Console.ServerSocketTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YellowDog.Console.Endpoint
  alias YellowDog.Console.ServerSocket
  alias YellowDog.ManagementCore

  @token "test-management-token"

  setup do
    previous_token = Application.get_env(:yellow_dog_console, :management_token)
    previous_management_only = Application.get_env(:yellow_dog_console, :management_release_only)

    Application.put_env(:yellow_dog_console, :management_token, @token)
    Application.put_env(:yellow_dog_console, :management_release_only, true)

    on_exit(fn ->
      restore_env(:management_token, previous_token)
      restore_env(:management_release_only, previous_management_only)
    end)

    :ok
  end

  test "endpoint mounts the Server socket at the fixed websocket path" do
    assert {"/server/ws", ServerSocket, [websocket: true]} in Endpoint.__sockets__()
    assert "/server/ws/websocket" == "/server/ws" <> "/websocket"
  end

  test "requires exact nonempty token and server_id params" do
    server_id = unique_id("socket-auth")
    register_server(server_id)

    assert {:ok, socket} = connect(%{"token" => @token, "server_id" => server_id})
    assert socket.assigns.server_id == server_id
    assert ServerSocket.id(socket) == nil

    for params <- [
          %{},
          %{"token" => @token},
          %{"server_id" => server_id},
          %{"token" => "", "server_id" => server_id},
          %{"token" => "wrong", "server_id" => server_id},
          %{"token" => @token, "server_id" => ""},
          %{"token" => @token, "server_id" => server_id, "extra" => true}
        ] do
      assert :error = connect(params)
    end

    Application.put_env(:yellow_dog_console, :management_token, "")
    assert :error = connect(%{"token" => @token, "server_id" => server_id})

    Application.delete_env(:yellow_dog_console, :management_token)
    assert :error = connect(%{"token" => @token, "server_id" => server_id})
  end

  test "rejects malformed and unregistered concrete IDs" do
    for server_id <- [
          String.duplicate("s", 129),
          <<255>>,
          unique_id("unregistered")
        ] do
      assert :error = connect(%{"token" => @token, "server_id" => server_id})
    end
  end

  test "does not reject a registered server in a management-only release" do
    server_id = unique_id("management-release")
    register_server(server_id)

    assert {:ok, _socket} = connect(%{"token" => @token, "server_id" => server_id})
  end

  test "never logs provided token values" do
    server_id = unique_id("token-log")
    register_server(server_id)
    secret = "do-not-log-this-management-token"

    log =
      capture_log(fn ->
        assert :error = connect(%{"token" => secret, "server_id" => server_id})
      end)

    refute log =~ secret
  end

  defp connect(params) do
    ServerSocket.connect(params, %Phoenix.Socket{assigns: %{}}, %{})
  end

  defp register_server(server_id) do
    assert {:ok, _server} =
             ManagementCore.register_server(%{id: server_id, profile: :dns_only})
  end

  defp unique_id(prefix),
    do: "#{prefix}-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"

  defp restore_env(key, nil), do: Application.delete_env(:yellow_dog_console, key)
  defp restore_env(key, value), do: Application.put_env(:yellow_dog_console, key, value)
end
