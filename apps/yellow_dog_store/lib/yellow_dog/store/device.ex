defmodule YellowDog.Store.Device do
  @moduledoc """
  Device fingerprint registry backed by Concord.

  Stores passive DHCP fingerprint data keyed by normalized MAC address.
  Supports upsert-merge semantics so multiple fingerprint sources
  (option 55, vendor class, hostname) accumulate over time.
  """

  alias YellowDog.Store.{Backend, Key}

  @namespace :device

  @max_upsert_retries 5

  @spec upsert(String.t(), map()) :: :ok | {:error, term()}
  def upsert(mac, attrs) when is_binary(mac) and is_map(attrs) do
    key = Key.device(mac)

    timed(:put, key, fn ->
      do_upsert(key, mac, attrs, @max_upsert_retries)
    end)
  end

  defp do_upsert(_key, _mac, _attrs, 0), do: {:error, :max_retries}

  defp do_upsert(key, mac, attrs, retries) do
    now = System.system_time(:second)

    case Backend.active().get(key, consistency: :leader) do
      {:ok, existing} ->
        merged =
          Map.merge(existing, attrs)
          |> Map.put(:last_seen, now)

        case Backend.active().put_if(key, merged, expected: existing) do
          :ok -> :ok
          {:error, :condition_failed} -> do_upsert(key, mac, attrs, retries - 1)
          error -> error
        end

      {:error, :not_found} ->
        record =
          attrs
          |> Map.put(:mac, Key.normalize_mac(mac))
          |> Map.put(:first_seen, now)
          |> Map.put(:last_seen, now)

        case Backend.active().put_if(key, record, expected: nil) do
          :ok -> :ok
          {:error, :condition_failed} -> do_upsert(key, mac, attrs, retries - 1)
          error -> error
        end
    end
  end

  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(mac) when is_binary(mac) do
    key = Key.device(mac)

    timed(:get, key, fn ->
      Backend.active().get(key, consistency: :eventual)
    end)
  end

  @spec by_vendor(String.t()) :: {:ok, [map()]}
  def by_vendor(vendor_class) when is_binary(vendor_class) do
    prefix = Key.device_prefix()

    timed(:list, prefix, fn ->
      case Backend.active().prefix_scan(prefix, []) do
        {:ok, entries} ->
          matches =
            entries
            |> Enum.filter(fn {_k, v} -> Map.get(v, :vendor_class) == vendor_class end)
            |> Enum.map(fn {_k, v} -> v end)

          {:ok, matches}

        {:error, _} ->
          {:ok, []}
      end
    end)
  end

  @spec list_recent(integer()) :: {:ok, [map()]}
  def list_recent(since_timestamp) when is_integer(since_timestamp) do
    prefix = Key.device_prefix()

    timed(:list, prefix, fn ->
      case Backend.active().prefix_scan(prefix, []) do
        {:ok, entries} ->
          matches =
            entries
            |> Enum.filter(fn {_k, v} -> Map.get(v, :last_seen, 0) >= since_timestamp end)
            |> Enum.map(fn {_k, v} -> v end)

          {:ok, matches}

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
