defmodule YellowDog.Console.NetmanSocket do
  @moduledoc """
  Socket for remote Netman service connections.

  Remote Netman instances connect to this socket via WebSocket at `/netman/ws`.
  Authentication is done via a token passed in the connect params.
  """

  use Phoenix.Socket

  alias YellowDog.Console.Plugs.ManagementReleaseOnly
  alias YellowDog.ManagementCore

  channel "netman:control", YellowDog.Console.NetmanChannel
  channel "netman:control:*", YellowDog.Console.NetmanControlChannel

  @max_id_bytes 128
  @supported_vsn "2.0.0"

  @impl true
  def connect(
        %{"token" => token, "netman_id" => netman_id, "vsn" => @supported_vsn} = params,
        socket,
        _connect_info
      )
      when map_size(params) == 3 do
    with true <- valid_id?(netman_id),
         true <- valid_token?(token, :management_token),
         {:ok, _netman} <- registered_netman(netman_id) do
      {:ok,
       socket
       |> assign(:netman_id, netman_id)
       |> assign(:control_protocol, :typed)}
    else
      _invalid -> :error
    end
  end

  @impl true
  def connect(%{"token" => token, "node_id" => node_id} = params, socket, _connect_info) do
    if not ManagementReleaseOnly.management_release_only?() and valid_id?(node_id) and
         valid_token?(token, :netman_socket_token) do
      {:ok,
       socket
       |> assign(:node_id, node_id)
       |> assign(:hostname, params["hostname"] || node_id)
       |> assign(:version, params["version"] || "unknown")
       |> assign(:control_protocol, :legacy)}
    else
      :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(%{assigns: %{control_protocol: :typed}}), do: nil
  def id(socket), do: "netman:#{socket.assigns.node_id}"

  defp valid_token?(token, config_key) do
    expected = Application.get_env(:yellow_dog_console, config_key)

    if nonempty_binary?(token) and nonempty_binary?(expected) do
      provided_hash = :crypto.hash(:sha256, token)
      expected_hash = :crypto.hash(:sha256, expected)
      Plug.Crypto.secure_compare(provided_hash, expected_hash)
    else
      false
    end
  end

  defp valid_id?(value) do
    is_binary(value) and value != "" and byte_size(value) <= @max_id_bytes and
      String.valid?(value)
  end

  defp nonempty_binary?(value), do: is_binary(value) and byte_size(value) > 0

  defp registered_netman(netman_id) do
    ManagementCore.get_netman(netman_id)
  catch
    :exit, _reason -> {:error, :not_found}
  end
end
