defmodule YellowDog.Worker.Connection.Channel do
  @moduledoc false
  # Phoenix channel process for `worker:<id>` plus the socket adapter used by
  # `YellowDog.Worker.Connection` (replaceable through its `:socket_impl` option).
  # Every inbound channel event is forwarded to the joining Connection process
  # as `{__MODULE__, channel_pid, event, payload}`.
  use Phoenix.SocketClient.Channel

  @join_timeout 4_000
  @max_message_bytes 1_048_576

  @impl true
  def handle_message(event, payload, state) do
    send(state.caller, {__MODULE__, self(), event, payload})
    {:noreply, state}
  end

  @doc false
  # The client never reconnects on its own: Connection owns retries and backoff.
  def open(options) do
    with {:ok, socket} <-
           Phoenix.SocketClient.start_link(
             name: Keyword.fetch!(options, :name),
             url: Keyword.fetch!(options, :url),
             params: Keyword.fetch!(options, :params),
             default_channel_module: __MODULE__,
             reconnect?: false,
             auto_connect: false,
             json_library: Jason,
             transport_opts: [
               ssl: Keyword.get(options, :tls, []),
               connect_timeout: 5_000,
               max_message_size: @max_message_bytes
             ]
           ),
         :ok <- Phoenix.SocketClient.connect(socket) do
      {:ok, socket}
    end
  end

  @doc false
  def status(socket) do
    case Phoenix.SocketClient.connection_info(socket) do
      %{status: :connected} -> :connected
      %{status: :disconnected, attempt_ref: ref} when ref != nil -> {:error, :disconnected}
      %{} -> :connecting
      _ -> {:error, :no_socket}
    end
  end

  @doc false
  def join(socket, topic, payload) do
    case Phoenix.SocketClient.Channel.join(socket, topic, payload, @join_timeout) do
      {:ok, _reply, channel} -> {:ok, channel}
      {:error, %{"code" => code}} when is_binary(code) -> {:error, code}
      {:error, _} -> {:error, :request_failed}
    end
  end

  @doc false
  def push(channel, event, payload),
    do: Phoenix.SocketClient.Channel.push_async(channel, event, payload)

  @doc false
  def close(socket) do
    if Process.alive?(socket), do: Supervisor.stop(socket, :normal, 5_000)
    :ok
  catch
    :exit, _ -> :ok
  end
end
