defmodule YellowDog.Console.NetmanSocket do
  @moduledoc """
  Socket for remote Netman service connections.

  Remote Netman instances connect to this socket via WebSocket at `/netman/ws`.
  Authentication is done via a token passed in the connect params.
  """

  use Phoenix.Socket

  alias YellowDog.Console.Plugs.ManagementReleaseOnly

  channel "netman:control", YellowDog.Console.NetmanChannel

  @impl true
  def connect(%{"token" => token, "node_id" => node_id} = params, socket, _connect_info) do
    if not ManagementReleaseOnly.management_release_only?() and valid_token?(token) do
      {:ok,
       socket
       |> assign(:node_id, node_id)
       |> assign(:hostname, params["hostname"] || node_id)
       |> assign(:version, params["version"] || "unknown")}
    else
      :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "netman:#{socket.assigns.node_id}"

  defp valid_token?(token) do
    expected = Application.get_env(:yellow_dog_console, :netman_socket_token)

    is_binary(token) and is_binary(expected) and byte_size(expected) > 0 and
      Plug.Crypto.secure_compare(token, expected)
  end
end
