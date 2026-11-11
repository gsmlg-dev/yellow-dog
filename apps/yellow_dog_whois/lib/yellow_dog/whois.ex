defmodule YellowDog.Whois do
  @moduledoc """
  WHOIS and RDAP lookup facade.

  Supports two protocols:

  - **WHOIS** (`lookup_raw/2`) — raw TCP lookups (RFC 3912), returns unstructured text
  - **RDAP** (`rdap_lookup/2`) — HTTPS lookups (RFC 9082/9083), returns structured JSON

  Both functions support optional caching via the configured `YellowDog.Whois.Cache` backend.

  ## WHOIS

      {:ok, [{server, raw_text}, ...]} = YellowDog.Whois.lookup_raw("example.com")

  ## RDAP

      {:ok, %{"objectClassName" => "domain", ...}} = YellowDog.Whois.rdap_lookup("example.com")
      {:ok, data} = YellowDog.Whois.rdap_lookup("8.8.8.8", type: :ip)
      {:ok, data} = YellowDog.Whois.rdap_lookup("64496", type: :asn)

  ## Options (both functions)

    - `:cache` — enable/disable caching for this request (default: `true`)
    - `:type`  — lookup type for cache TTL: `:domain`, `:ip`, `:asn` (default: `:domain`)

  ## Additional WHOIS options

    - `:timeout` — total WHOIS deadline in milliseconds (default: configured timeout or 30,000)
    - `:server` — override the initial WHOIS server (binary hostname or `%YellowDog.Whois.Server{}`)

  ## Telemetry

  WHOIS events:

  - `[:yellow_dog, :whois, :lookup, :start]`
  - `[:yellow_dog, :whois, :lookup, :stop]`
  - `[:yellow_dog, :whois, :lookup, :exception]`

  RDAP events:

  - `[:yellow_dog, :whois, :rdap, :lookup, :start]`
  - `[:yellow_dog, :whois, :rdap, :lookup, :stop]`
  - `[:yellow_dog, :whois, :rdap, :lookup, :exception]`

  Cache events (both protocols):

  - `[:yellow_dog, :whois, :cache, :hit]`
  - `[:yellow_dog, :whois, :cache, :miss]`
  """

  require Logger

  alias YellowDog.Whois.{Cache, RDAPProtocol, Server, WhoisProtocol}

  @type lookup_type :: :domain | :ip | :asn
  @type whois_opts :: [
          server: binary() | Server.t(),
          timeout: non_neg_integer(),
          cache: boolean(),
          type: lookup_type()
        ]
  @type rdap_opts :: [
          cache: boolean(),
          type: lookup_type() | :rdap
        ]

  # ---------------------------------------------------------------------------
  # WHOIS
  # ---------------------------------------------------------------------------

  @doc """
  Looks up raw WHOIS information for a domain, IP address, or ASN.

  Returns a list of `{server, raw_text}` pairs, one per WHOIS server contacted.
  The root server (e.g. `whois.iana.org`) is listed first; referral servers follow.
  """
  @spec lookup_raw(binary(), whois_opts()) ::
          {:ok, [{binary(), binary()}]} | {:error, term()}
  def lookup_raw(query, opts \\ []) do
    cache_enabled = Keyword.get(opts, :cache, true)
    lookup_type = Keyword.get(opts, :type, :domain)
    cache_key = "whois:#{query}"

    case cache_enabled && Cache.get(cache_key) do
      {:ok, cached} ->
        emit_cache_event(:hit, query, lookup_type)
        {:ok, cached}

      _ ->
        if cache_enabled, do: emit_cache_event(:miss, query, lookup_type)

        :telemetry.span(
          [:yellow_dog, :whois, :lookup],
          %{query: query, type: lookup_type},
          fn ->
            server = resolve_server(opts)
            result = WhoisProtocol.lookup(query, server, opts)

            if cache_enabled, do: cache_on_ok(result, cache_key, lookup_type)

            {result, %{query: query, type: lookup_type}}
          end
        )
    end
  end

  # ---------------------------------------------------------------------------
  # RDAP
  # ---------------------------------------------------------------------------

  @doc """
  Looks up RDAP registration data for a domain, IP address, or ASN.

  Returns the parsed JSON map from the authoritative RDAP server.
  The response structure follows RFC 9083.
  """
  @spec rdap_lookup(binary(), rdap_opts()) :: {:ok, map()} | {:error, term()}
  def rdap_lookup(query, opts \\ []) do
    cache_enabled = Keyword.get(opts, :cache, true)
    lookup_type = Keyword.get(opts, :type, :domain)
    cache_key = "rdap:#{query}"

    case cache_enabled && Cache.get(cache_key) do
      {:ok, cached} ->
        emit_cache_event(:hit, query, lookup_type)
        {:ok, cached}

      _ ->
        if cache_enabled, do: emit_cache_event(:miss, query, lookup_type)

        :telemetry.span(
          [:yellow_dog, :whois, :rdap, :lookup],
          %{query: query, type: lookup_type},
          fn ->
            rdap_type = normalize_rdap_type(lookup_type)
            result = RDAPProtocol.lookup(query, rdap_type)

            if cache_enabled, do: cache_on_ok(result, cache_key, :rdap)

            {result, %{query: query, type: lookup_type}}
          end
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp resolve_server(opts) do
    case Keyword.fetch(opts, :server) do
      {:ok, host} when is_binary(host) -> %Server{host: host}
      {:ok, %Server{} = s} -> s
      :error -> Server.root()
    end
  end

  defp normalize_rdap_type(:asn), do: :asn
  defp normalize_rdap_type(:ip), do: :ip
  defp normalize_rdap_type(_), do: :domain

  defp cache_on_ok({:ok, value}, key, type), do: Cache.put(key, value, type)
  defp cache_on_ok(_, _key, _type), do: :ok

  defp emit_cache_event(event, query, type) do
    :telemetry.execute([:yellow_dog, :whois, :cache, event], %{}, %{query: query, type: type})
  rescue
    _ -> :ok
  end
end
