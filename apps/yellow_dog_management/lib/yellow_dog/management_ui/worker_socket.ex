defmodule YellowDog.ManagementUI.WorkerSocket do
  @moduledoc """
  Worker WebSocket at `/api/worker/connect`.

  The handshake carries only the UUID `worker_id` query parameter, so no credential
  reaches proxy access logs. The Worker token travels in the channel join payload
  and is authenticated when the Worker channel joins.
  """
  use Phoenix.Socket

  channel "worker:*", YellowDog.ManagementUI.WorkerChannel

  @impl true
  def connect(%{"worker_id" => id}, socket, _connect_info) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, ^id} -> {:ok, assign(socket, :worker_id, id)}
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "worker_socket:" <> socket.assigns.worker_id
end
