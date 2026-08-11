defmodule YellowDog.Console.NetmanSocketTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YellowDog.Console.Endpoint
  alias YellowDog.Console.NetmanSocket
  alias YellowDog.ManagementCore

  @management_token "test-management-token"

  setup do
    management_only = Application.get_env(:yellow_dog_console, :management_release_only)
    token = Application.get_env(:yellow_dog_console, :netman_socket_token)
    management_token = Application.get_env(:yellow_dog_console, :management_token)

    Application.put_env(:yellow_dog_console, :management_release_only, false)
    Application.put_env(:yellow_dog_console, :netman_socket_token, "test-token")
    Application.put_env(:yellow_dog_console, :management_token, @management_token)

    on_exit(fn ->
      restore_env(:management_release_only, management_only)
      restore_env(:netman_socket_token, token)
      restore_env(:management_token, management_token)
    end)

    :ok
  end

  test "retains the legacy connection contract in a combined release" do
    socket = %Phoenix.Socket{assigns: %{}}

    assert {:ok, connected} =
             NetmanSocket.connect(
               %{"token" => "test-token", "node_id" => "netman-1"},
               socket,
               %{}
             )

    assert connected.assigns.node_id == "netman-1"
    assert connected.assigns.control_protocol == :legacy
    assert NetmanSocket.id(connected) == "netman:netman-1"

    assert :error =
             NetmanSocket.connect(
               %{"token" => "wrong-token", "node_id" => "netman-1"},
               socket,
               %{}
             )
  end

  test "accepts only exact authenticated registered typed connections" do
    netman_id = unique_id("typed")
    register_netman(netman_id)

    assert {"/netman/ws", NetmanSocket, [websocket: true]} in Endpoint.__sockets__()

    assert {:ok, connected} =
             connect(%{
               "token" => @management_token,
               "netman_id" => netman_id,
               "vsn" => "2.0.0"
             })

    assert connected.assigns.netman_id == netman_id
    assert connected.assigns.control_protocol == :typed
    assert NetmanSocket.id(connected) == nil

    for params <- [
          %{},
          %{"token" => @management_token, "netman_id" => netman_id},
          %{"token" => "", "netman_id" => netman_id, "vsn" => "2.0.0"},
          %{"token" => "wrong", "netman_id" => netman_id, "vsn" => "2.0.0"},
          %{"token" => @management_token, "netman_id" => "", "vsn" => "2.0.0"},
          %{"token" => @management_token, "netman_id" => netman_id, "vsn" => "1.0.0"},
          %{
            "token" => @management_token,
            "netman_id" => netman_id,
            "vsn" => "2.0.0",
            "extra" => true
          }
        ] do
      assert :error = connect(params)
    end
  end

  test "rejects malformed and unregistered typed IDs without logging tokens" do
    secret = "do-not-log-this-netman-token"

    log =
      capture_log(fn ->
        for netman_id <- [String.duplicate("n", 129), <<255>>, unique_id("missing")] do
          assert :error =
                   connect(%{
                     "token" => secret,
                     "netman_id" => netman_id,
                     "vsn" => "2.0.0"
                   })
        end
      end)

    refute log =~ secret
  end

  test "accepts typed control but still rejects legacy control in management-only release" do
    Application.put_env(:yellow_dog_console, :management_release_only, true)
    netman_id = unique_id("management-release")
    register_netman(netman_id)

    assert :error =
             connect(%{"token" => "test-token", "node_id" => "netman-1"})

    assert {:ok, _socket} =
             connect(%{
               "token" => @management_token,
               "netman_id" => netman_id,
               "vsn" => "2.0.0"
             })
  end

  defp connect(params), do: NetmanSocket.connect(params, %Phoenix.Socket{assigns: %{}}, %{})

  defp register_netman(netman_id) do
    assert {:ok, _netman} = ManagementCore.register_netman(%{id: netman_id, profile: :vm})
  end

  defp unique_id(prefix),
    do: "#{prefix}-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"

  defp restore_env(key, nil), do: Application.delete_env(:yellow_dog_console, key)
  defp restore_env(key, value), do: Application.put_env(:yellow_dog_console, key, value)
end
