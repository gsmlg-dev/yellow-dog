defmodule YellowDog.Store.DynDns do
  @moduledoc """
  Dynamic DNS record storage backed by Concord.

  Manages forward (A/AAAA/CNAME) and reverse (PTR) dynamic records.
  Records carry source metadata so consumers can distinguish DHCP-originated
  entries from API-originated ones.
  """

  import Bitwise

  alias YellowDog.Store.Key

  @namespace :dyn_dns

  @type record :: %{
          type: atom(),
          rdata: term(),
          dns_ttl: integer(),
          source: atom(),
          source_ref: String.t(),
          created_at: integer(),
          updated_at: integer()
        }

  @spec put(String.t(), record(), keyword()) :: :ok | {:error, term()}
  def put(fqdn, record, opts \\ []) when is_binary(fqdn) and is_map(record) do
    key = Key.dyn_dns(fqdn)
    now = System.system_time(:second)

    record =
      record
      |> Map.put_new(:created_at, now)
      |> Map.put(:updated_at, now)

    concord_opts =
      [consistency: :strong] ++ if(ttl = Keyword.get(opts, :ttl), do: [ttl: ttl], else: [])

    timed(:put, key, fn ->
      Concord.put(key, record, concord_opts)
    end)
  end

  @spec put_ptr(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def put_ptr(arpa, fqdn, opts \\ []) when is_binary(arpa) and is_binary(fqdn) do
    key = Key.dyn_dns_ptr(arpa)
    now = System.system_time(:second)
    record = %{type: :ptr, rdata: fqdn, created_at: now, updated_at: now}

    concord_opts =
      [consistency: :strong] ++ if(ttl = Keyword.get(opts, :ttl), do: [ttl: ttl], else: [])

    timed(:put, key, fn ->
      Concord.put(key, record, concord_opts)
    end)
  end

  @spec get(String.t()) :: {:ok, record()} | {:error, :not_found}
  def get(fqdn) when is_binary(fqdn) do
    key = Key.dyn_dns(fqdn)

    timed(:get, key, fn ->
      Concord.get(key, consistency: :eventual)
    end)
  end

  @spec get_ptr(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_ptr(arpa) when is_binary(arpa) do
    key = Key.dyn_dns_ptr(arpa)

    timed(:get, key, fn ->
      Concord.get(key, consistency: :eventual)
    end)
  end

  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(fqdn) when is_binary(fqdn) do
    key = Key.dyn_dns(fqdn)

    timed(:delete, key, fn ->
      case Concord.get(key, consistency: :leader) do
        {:ok, record} ->
          :ok = Concord.delete(key)

          case ip_to_arpa(record) do
            {:ok, arpa} -> Concord.delete(Key.dyn_dns_ptr(arpa))
            :error -> :ok
          end

        {:error, :not_found} ->
          :ok
      end
    end)
  end

  @spec list_by_source(atom()) :: {:ok, [record()]}
  def list_by_source(source) when is_atom(source) do
    prefix = Key.dyn_dns_prefix()

    timed(:list, prefix, fn ->
      {:ok, entries} = Concord.prefix_scan(prefix, [])

      matches =
        entries
        |> Enum.reject(fn {k, _v} -> String.starts_with?(k, "dns:dyn:ptr:") end)
        |> Enum.filter(fn {_k, v} -> Map.get(v, :source) == source end)
        |> Enum.map(fn {_k, v} -> v end)

      {:ok, matches}
    end)
  end

  # Build reverse ARPA name from the record's rdata IP address.
  defp ip_to_arpa(%{type: type, rdata: rdata}) when type in [:a, :aaaa] do
    case parse_ip(rdata) do
      {:ok, {a, b, c, d}} ->
        {:ok, "#{d}.#{c}.#{b}.#{a}.in-addr.arpa"}

      {:ok, ipv6_tuple} when tuple_size(ipv6_tuple) == 8 ->
        nibbles =
          ipv6_tuple
          |> Tuple.to_list()
          |> Enum.flat_map(fn word ->
            [word >>> 12 &&& 0xF, word >>> 8 &&& 0xF, word >>> 4 &&& 0xF, word &&& 0xF]
          end)
          |> Enum.reverse()
          |> Enum.map(&Integer.to_string(&1, 16))
          |> Enum.join(".")

        {:ok, "#{nibbles}.ip6.arpa"}

      _other ->
        :error
    end
  end

  defp ip_to_arpa(_record), do: :error

  defp parse_ip(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, addr} -> {:ok, addr}
      {:error, _} -> :error
    end
  end

  defp parse_ip(ip) when is_tuple(ip), do: {:ok, ip}
  defp parse_ip(_), do: :error

  defp timed(operation, key, fun) do
    start = System.monotonic_time()
    result = fun.()
    duration = System.monotonic_time() - start

    YellowDog.Store.emit_telemetry(@namespace, operation, key, duration)

    result
  end
end
