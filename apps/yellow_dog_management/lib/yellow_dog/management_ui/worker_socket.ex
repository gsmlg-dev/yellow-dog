defmodule YellowDog.ManagementUI.WorkerSocket do
  @moduledoc """
  Worker WebSocket at `/api/worker/connect`.

  The handshake only checks credential shape: the Worker token travels in the
  `x-yellow-dog-worker-token` header (never the URL) and `worker_id` is a UUID
  query parameter. Authentication happens when the Worker channel joins.
  """
  use Phoenix.Socket

  channel "worker:*", YellowDog.ManagementUI.WorkerChannel

  @header "x-yellow-dog-worker-token"

  @impl true
  def connect(%{"worker_id" => id}, socket, %{x_headers: headers})
      when is_binary(id) and is_list(headers) do
    with {:ok, ^id} <- Ecto.UUID.cast(id),
         [token] when byte_size(token) == 43 <- for({@header, value} <- headers, do: value) do
      # A closure keeps the raw credential out of inspected socket state and crash reports.
      {:ok, assign(socket, worker_id: id, worker_token: fn -> token end)}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "worker_socket:" <> socket.assigns.worker_id
end
