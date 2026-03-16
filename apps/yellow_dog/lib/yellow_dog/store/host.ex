defmodule YellowDog.Store.Host do
  @moduledoc """
  Host identity registry backed by Concord.

  Each host is keyed by hostname and stores SSH public keys,
  MAC correlation, and attestation timestamps. Registration uses
  CAS with `expected: nil` to prevent hostname squatting.
  """

  alias YellowDog.Store.{Backend, Key}

  @namespace :host

  @spec register(String.t(), map()) :: :ok | {:error, :already_registered} | {:error, term()}
  def register(hostname, attrs) when is_binary(hostname) and is_map(attrs) do
    key = Key.host(hostname)
    now = System.system_time(:second)

    record =
      attrs
      |> Map.put(:hostname, hostname)
      |> Map.put(:registered_at, now)
      |> Map.put(:last_attested, now)

    timed(:put, key, fn ->
      case Backend.active().put_if(key, record, expected: nil, consistency: :strong) do
        :ok -> :ok
        {:error, :condition_failed} -> {:error, :already_registered}
        error -> error
      end
    end)
  end

  @spec update_keys(String.t(), [String.t()]) :: :ok | {:error, :not_found} | {:error, term()}
  def update_keys(hostname, pubkeys) when is_binary(hostname) and is_list(pubkeys) do
    key = Key.host(hostname)
    now = System.system_time(:second)

    timed(:put, key, fn ->
      case Backend.active().put_if(key, nil,
             consistency: :strong,
             condition: fn old ->
               if old do
                 updated =
                   old
                   |> Map.put(:pubkeys, pubkeys)
                   |> Map.put(:keys_updated_at, now)

                 {:update, updated}
               else
                 false
               end
             end
           ) do
        :ok -> :ok
        {:error, :condition_failed} -> {:error, :not_found}
        error -> error
      end
    end)
  end

  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(hostname) when is_binary(hostname) do
    key = Key.host(hostname)

    timed(:get, key, fn ->
      Backend.active().get(key, consistency: :eventual)
    end)
  end

  @spec by_mac(String.t()) :: {:ok, map() | nil}
  def by_mac(mac) when is_binary(mac) do
    normalized = Key.normalize_mac(mac)
    prefix = "host:"

    timed(:list, prefix, fn ->
      {:ok, entries} = Backend.active().prefix_scan(prefix, [])

      match =
        Enum.find_value(entries, fn {_k, v} ->
          if Map.get(v, :mac) == normalized, do: v
        end)

      {:ok, match}
    end)
  end

  @spec attest(String.t()) :: :ok | {:error, :not_found} | {:error, term()}
  def attest(hostname) when is_binary(hostname) do
    key = Key.host(hostname)
    now = System.system_time(:second)

    timed(:put, key, fn ->
      case Backend.active().put_if(key, nil,
             consistency: :strong,
             condition: fn
               nil ->
                 false

               record ->
                 updated = Map.put(record, :last_attested, now)
                 ttl_opts = if ttl = Map.get(record, :attestation_ttl), do: [ttl: ttl], else: []
                 {:update, updated, ttl_opts}
             end
           ) do
        :ok -> :ok
        {:error, :condition_failed} -> {:error, :not_found}
        error -> error
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
