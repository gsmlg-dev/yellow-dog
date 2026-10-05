defmodule YellowDog.Management.LogStream do
  @moduledoc """
  Bounded observations of the actual Management VM's OTP Logger events.

  The replay buffer is process-local and resets on restart. It is not a Worker
  log source or durable task history. Logger producers never wait on this server.
  """
  use GenServer

  @topic "management:logs"
  @levels ~w(debug info notice warning error critical alert emergency)a
  @metadata_keys ~w(mfa file line pid request_id domain)a
  @capacity 1000
  @handler_id :yellow_dog_management_log_stream

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    server_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  def topic, do: @topic
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @doc false
  def adding_handler(config), do: {:ok, config}

  @doc false
  def removing_handler(_config), do: :ok

  @doc false
  def log(event, %{config: %{target: target}}) when is_pid(target) do
    send(target, {:logger_event, event})
    :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    handler_id = Keyword.get(opts, :handler_id, @handler_id)
    release_stale_handler(handler_id)

    case :logger.add_handler(handler_id, __MODULE__, %{
           level: :debug,
           config: %{target: self()}
         }) do
      :ok ->
        {:ok,
         %{
           handler_id: handler_id,
           pubsub: Keyword.get(opts, :pubsub, YellowDog.ManagementUI.PubSub),
           entries: :queue.new(),
           count: 0
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, state.entries |> :queue.to_list() |> Enum.reverse(), state}
  end

  @impl true
  def handle_info({:logger_event, event}, state) do
    case normalize(event) do
      {:ok, entry} ->
        entries = :queue.in(entry, state.entries)
        count = min(state.count + 1, @capacity)

        entries =
          if state.count == @capacity, do: entries |> :queue.out() |> elem(1), else: entries

        if state.pubsub do
          Phoenix.PubSub.broadcast(state.pubsub, @topic, {:management_log, entry})
        end

        {:noreply, %{state | entries: entries, count: count}}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :logger.remove_handler(state.handler_id)
    :ok
  end

  defp release_stale_handler(handler_id) do
    case :logger.get_handler_config(handler_id) do
      {:ok, %{module: __MODULE__, config: %{target: target}}} when is_pid(target) ->
        if not Process.alive?(target), do: :logger.remove_handler(handler_id)

      _ ->
        :ok
    end
  end

  defp normalize(%{level: level, msg: _message, meta: meta} = event)
       when level in @levels and is_map(meta) do
    message =
      event
      |> :logger_formatter.format(%{template: [:msg], single_line: false, chars_limit: 2048})
      |> IO.chardata_to_string()
      |> String.slice(0, 2048)

    {:ok,
     %{
       id: System.unique_integer([:positive, :monotonic]),
       timestamp: timestamp(meta[:time]),
       level: level,
       app: application(meta),
       message: message,
       metadata:
         meta
         |> Map.take(@metadata_keys)
         |> Map.new(fn {key, value} ->
           {Atom.to_string(key), inspect(value, limit: 20, printable_limit: 512)}
         end)
     }}
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp normalize(_event), do: :error

  defp timestamp(microseconds) when is_integer(microseconds) do
    case DateTime.from_unix(microseconds, :microsecond) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> DateTime.utc_now()
    end
  end

  defp timestamp(_value), do: DateTime.utc_now()

  defp application(%{application: application})
       when is_atom(application) and not is_nil(application),
       do: Atom.to_string(application)

  defp application(%{application: application}) when is_binary(application),
    do: String.slice(application, 0, 64)

  defp application(%{mfa: {module, _function, _arity}}) when is_atom(module) do
    case :application.get_application(module) do
      {:ok, application} -> Atom.to_string(application)
      :undefined -> "runtime"
    end
  end

  defp application(_metadata), do: "runtime"
end
