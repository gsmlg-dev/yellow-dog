defmodule YellowDog.Console.ServerSocket do
  @moduledoc """
  Authenticated socket for registered Server control connections.
  """

  use Phoenix.Socket

  alias YellowDog.ManagementCore

  @max_id_bytes 128

  channel "server:control:*", YellowDog.Console.ServerChannel

  @impl true
  def connect(
        %{"token" => token, "server_id" => server_id} = params,
        socket,
        _connect_info
      )
      when map_size(params) == 2 do
    with true <- valid_server_id?(server_id),
         true <- valid_token?(token),
         {:ok, _server} <- registered_server(server_id) do
      {:ok, assign(socket, :server_id, server_id)}
    else
      _invalid -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: nil

  defp valid_server_id?(server_id) do
    is_binary(server_id) and server_id != "" and byte_size(server_id) <= @max_id_bytes and
      String.valid?(server_id)
  end

  defp valid_token?(token) do
    expected = Application.get_env(:yellow_dog_console, :management_token)

    if nonempty_binary?(token) and nonempty_binary?(expected) do
      provided_hash = :crypto.hash(:sha256, token)
      expected_hash = :crypto.hash(:sha256, expected)
      Plug.Crypto.secure_compare(provided_hash, expected_hash)
    else
      false
    end
  end

  defp nonempty_binary?(value), do: is_binary(value) and byte_size(value) > 0

  defp registered_server(server_id) do
    ManagementCore.get_server(server_id)
  catch
    :exit, _reason -> {:error, :not_found}
  end
end
