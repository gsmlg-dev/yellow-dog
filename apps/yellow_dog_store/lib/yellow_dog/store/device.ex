defmodule YellowDog.Store.Device do
  @moduledoc """
  Device fingerprint registry backed by Concord.

  Stores passive DHCP fingerprint data keyed by normalized MAC address.
  Supports upsert-merge semantics so multiple fingerprint sources
  (option 55, vendor class, hostname) accumulate over time.
  """

  alias YellowDog.Store.{Backend, Key}

  @namespace :device

  @spec upsert(String.t(), map()) :: :ok | {:error, term()}
  def upsert(mac, attrs) when is_binary(mac) and is_map(attrs) do
    key = Key.device(mac)
    now = System.system_time(:second)

    timed(:put, key, fn ->
      case Backend.active().get(key, consistency: :leader) do
        {:ok, existing} ->
          merged =
            Map.merge(existing, attrs)
            |> Map.put(:last_seen, now)

          Backend.active().put_if(key, merged, expected: existing)

        {:error, :not_found} ->
          record =
            attrs
            |> Map.put(:mac, Key.normalize_mac(mac))
            |> Map.put(:first_seen, now)
            |> Map.put(:last_seen, now)

          Backend.active().put_if(key, record, expected: nil)
      end
    end)
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
      {:ok, entries} = Backend.active().prefix_scan(prefix, [])

      matches =
        entries
        |> Enum.filter(fn {_k, v} -> Map.get(v, :vendor_class) == vendor_class end)
        |> Enum.map(fn {_k, v} -> v end)

      {:ok, matches}
    end)
  end

  @spec list_recent(integer()) :: {:ok, [map()]}
  def list_recent(since_timestamp) when is_integer(since_timestamp) do
    prefix = Key.device_prefix()

    timed(:list, prefix, fn ->
      {:ok, entries} = Backend.active().prefix_scan(prefix, [])

      matches =
        entries
        |> Enum.filter(fn {_k, v} -> Map.get(v, :last_seen, 0) >= since_timestamp end)
        |> Enum.map(fn {_k, v} -> v end)

      {:ok, matches}
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
