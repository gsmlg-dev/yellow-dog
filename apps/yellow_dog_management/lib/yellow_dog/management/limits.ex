defmodule YellowDog.Management.Limits do
  @moduledoc "Bounded concurrent integration calls and per-principal synchronization admission."
  use GenServer
  require Logger
  alias YellowDog.Management.Caller

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_) do
    Process.send_after(self(), :summarize_denials, 60_000)
    {:ok, %{active: %{}, sync: %{}, denials: %{}}}
  end

  def denied(source, code)
      when source in [:ui, :http, :mcp] and
             code in ~w(authentication_required invalid_token forbidden adapters_disabled) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:denied, source, code})
    :ok
  end

  def denied(_, _), do: :ok

  def run(caller, operation, fun) do
    limited_operation = if caller.source in [:http, :mcp], do: operation, else: :ui

    case GenServer.call(__MODULE__, {:acquire, self(), Caller.actor(caller), limited_operation}) do
      {:ok, ref} ->
        try do
          fun.()
        after
          GenServer.call(__MODULE__, {:release, ref})
        end

      :limited ->
        {:error,
         %{code: "rate_limited", message: "Management request limit reached; retry later"}}
    end
  end

  def handle_call({:acquire, pid, actor, operation}, _from, state) do
    now = System.monotonic_time(:second)
    sync = Map.reject(state.sync, fn {_id, {start, _count}} -> now - start >= 60 end)
    {_start, count} = Map.get(sync, actor, {now, 0})

    limited =
      map_size(state.active) >= 32 or
        (operation == "ip_database_sync" and
           (count >= 10 or (not Map.has_key?(sync, actor) and map_size(sync) >= 1024)))

    if limited do
      {:reply, :limited, %{state | sync: sync}}
    else
      ref = Process.monitor(pid)

      sync =
        if operation == "ip_database_sync",
          do: Map.update(sync, actor, {now, 1}, fn {start, n} -> {start, n + 1} end),
          else: sync

      {:reply, {:ok, ref}, %{state | active: Map.put(state.active, ref, pid), sync: sync}}
    end
  end

  def handle_call({:release, ref}, _from, state) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, %{state | active: Map.delete(state.active, ref)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | active: Map.delete(state.active, ref)}}

  def handle_info(:summarize_denials, state) do
    if map_size(state.denials) > 0 do
      counts =
        Map.new(state.denials, fn {{source, code}, count} -> {"#{source}:#{code}", count} end)

      Logger.warning("Management authorization denied requests", authorization_denials: counts)
    end

    Process.send_after(self(), :summarize_denials, 60_000)
    {:noreply, %{state | denials: %{}}}
  end

  def handle_cast({:denied, source, code}, state),
    do:
      {:noreply,
       %{state | denials: Map.update(state.denials, {source, code}, 1, &min(&1 + 1, 1_000_000))}}
end
