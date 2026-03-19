defmodule YellowDog.Store.Rpz do
  @moduledoc """
  Response Policy Zone (RPZ) rule storage backed by Concord.

  RPZ rules are keyed by `{zone_name, domain_trigger}` and support
  per-zone listing and cross-zone zone enumeration.
  """

  alias YellowDog.Store.{Backend, Key}

  @namespace :rpz

  @spec put(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put(zone, trigger, rule) when is_binary(zone) and is_binary(trigger) and is_map(rule) do
    key = Key.rpz(zone, trigger)

    timed(:put, key, fn ->
      Backend.active().put(key, rule, consistency: :strong)
    end)
  end

  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(zone, trigger) when is_binary(zone) and is_binary(trigger) do
    key = Key.rpz(zone, trigger)

    timed(:get, key, fn ->
      Backend.active().get(key, consistency: :eventual)
    end)
  end

  @spec list(String.t()) :: {:ok, [{String.t(), map()}]}
  def list(zone) when is_binary(zone) do
    prefix = Key.rpz_prefix(zone)

    timed(:list, prefix, fn ->
      Backend.active().prefix_scan(prefix, consistency: :eventual)
    end)
  end

  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(zone, trigger) when is_binary(zone) and is_binary(trigger) do
    key = Key.rpz(zone, trigger)

    timed(:delete, key, fn ->
      Backend.active().delete(key)
    end)
  end

  @spec zones() :: {:ok, [String.t()]}
  def zones do
    prefix = Key.rpz_all_prefix()

    timed(:list, prefix, fn ->
      case Backend.active().prefix_scan(prefix, consistency: :eventual) do
        {:ok, entries} ->
          zone_names =
            entries
            |> Enum.map(fn {k, _v} ->
              k
              |> String.trim_leading(prefix)
              |> String.split(":", parts: 2)
              |> List.first()
            end)
            |> Enum.uniq()
            |> Enum.sort()

          {:ok, zone_names}

        {:error, _} ->
          {:ok, []}
      end
    end)
  end

  defp timed(operation, key, fun) do
    start = System.monotonic_time()
    result = fun.()
    duration = System.monotonic_time() - start

    YellowDog.Store.emit_telemetry(@namespace, operation, key, duration)

    result
  end
end
