defmodule YellowDog.Netboot.Metrics do
  @moduledoc """
  Lightweight netboot metrics accumulator using ETS counters.

  Tracks transfer counts, bytes transferred, and request rates.
  Used by the dashboard to display telemetry summaries.
  """

  @table __MODULE__

  @counters [
    :tftp_requests_accepted,
    :tftp_requests_rejected,
    :tftp_transfers_started,
    :tftp_transfers_completed,
    :tftp_transfers_failed,
    :tftp_bytes_transferred,
    :devices_discovered,
    :boot_scripts_rendered
  ]

  @doc "Initialize the metrics table. Called once at app start."
  def init do
    :ets.new(@table, [:named_table, :public, :set])

    Enum.each(@counters, fn key ->
      :ets.insert(@table, {key, 0})
    end)

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Increment a counter by the given amount."
  @spec increment(atom(), non_neg_integer()) :: :ok
  def increment(key, amount \\ 1) when key in @counters do
    :ets.update_counter(@table, key, amount)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Get the current value of a counter."
  @spec get(atom()) :: non_neg_integer()
  def get(key) when key in @counters do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc "Get all metrics as a map."
  @spec all() :: map()
  def all do
    Map.new(@counters, fn key -> {key, get(key)} end)
  end

  @doc "Reset all counters to zero."
  @spec reset() :: :ok
  def reset do
    Enum.each(@counters, fn key ->
      :ets.insert(@table, {key, 0})
    end)

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "List all known counter names."
  @spec counter_names() :: [atom()]
  def counter_names, do: @counters
end
