defmodule YellowDog.Console.NetmanSocketTest do
  use ExUnit.Case, async: false

  alias YellowDog.Console.NetmanSocket

  setup do
    management_only = Application.get_env(:yellow_dog_console, :management_release_only)
    token = Application.get_env(:yellow_dog_console, :netman_socket_token)

    Application.put_env(:yellow_dog_console, :management_release_only, false)
    Application.put_env(:yellow_dog_console, :netman_socket_token, "test-token")

    on_exit(fn ->
      restore_env(:management_release_only, management_only)
      restore_env(:netman_socket_token, token)
    end)

    :ok
  end

  test "accepts configured token only" do
    socket = %Phoenix.Socket{assigns: %{}}

    assert {:ok, connected} =
             NetmanSocket.connect(
               %{"token" => "test-token", "node_id" => "netman-1"},
               socket,
               %{}
             )

    assert connected.assigns.node_id == "netman-1"

    assert :error =
             NetmanSocket.connect(
               %{"token" => "wrong-token", "node_id" => "netman-1"},
               socket,
               %{}
             )
  end

  test "rejects all Netman socket connections in management-only release" do
    Application.put_env(:yellow_dog_console, :management_release_only, true)
    socket = %Phoenix.Socket{assigns: %{}}

    assert :error =
             NetmanSocket.connect(
               %{"token" => "test-token", "node_id" => "netman-1"},
               socket,
               %{}
             )
  end

  defp restore_env(key, nil), do: Application.delete_env(:yellow_dog_console, key)
  defp restore_env(key, value), do: Application.put_env(:yellow_dog_console, key, value)
end
