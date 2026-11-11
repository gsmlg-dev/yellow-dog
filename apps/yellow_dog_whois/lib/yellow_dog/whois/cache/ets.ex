defmodule YellowDog.Whois.Cache.ETS do
  @moduledoc """
  ETS-backed cache backend for YellowDog.Whois.

  This is the default backend. It requires the GenServer to be running
  (to own the ETS table and perform periodic TTL cleanup). Add it to
  your supervision tree:

      children = [YellowDog.Whois.Cache.ETS]
      Supervisor.start_link(children, strategy: :one_for_one)

  The ETS table is public with read concurrency enabled, so `get/1` and
  `put/4` bypass the GenServer for low-latency access.
  """

  @behaviour YellowDog.Whois.Cache

  use GenServer
  require Logger

  @table :yellow_dog_whois_cache

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl YellowDog.Whois.Cache
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, value}
        else
          :ets.delete(@table, key)
          :miss
        end

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @impl YellowDog.Whois.Cache
  def put(key, value, _type, ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {key, value, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl YellowDog.Whois.Cache
  def delete(key) do
    :ets.delete(@table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl YellowDog.Whois.Cache
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, 300_000)
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    expired =
      :ets.foldl(
        fn {key, _value, expires_at}, acc ->
          if now >= expires_at, do: [key | acc], else: acc
        end,
        [],
        @table
      )

    Enum.each(expired, &:ets.delete(@table, &1))

    if expired != [] do
      Logger.debug("YellowDog.Whois.Cache.ETS: removed #{length(expired)} expired entries")
    end
  end
end
