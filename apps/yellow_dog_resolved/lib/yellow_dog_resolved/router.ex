defmodule YellowDog.Resolved.Router do
  @moduledoc """
  Query routing engine for the resolved DNS stub resolver.

  Resolution order:
  1. Intercept rules — match domain against configured rules, return static response
  2. Cache lookup — check ETS cache for non-expired entry
  3. Forward — send to upstream via Forwarder, cache result, return to client
  """

  alias YellowDog.Resolved.{Cache, Config, Forwarder, Intercept, ResponseBuilder}

  require Logger

  @doc """
  Route a DNS query through the resolution pipeline.
  Returns `{:ok, response_binary}` or `{:error, reason}`.
  """
  @spec resolve(DNS.Message.t(), binary()) :: {:ok, binary()} | {:error, term()}
  def resolve(query, raw_query) do
    question = List.first(query.qdlist)

    if question == nil do
      response = ResponseBuilder.build_formerr(query.header.id)
      {:ok, encode(response)}
    else
      domain = to_string(question.name)
      query_type = to_string(question.type) |> String.downcase() |> String.to_atom()

      metadata = %{domain: domain, type: query_type}
      start_time = System.monotonic_time()

      :telemetry.execute(
        [:yellow_dog, :resolved, :query, :start],
        %{},
        metadata
      )

      result = resolve_pipeline(query, raw_query, domain, query_type)

      duration = System.monotonic_time() - start_time
      source = result_source(result)

      :telemetry.execute(
        [:yellow_dog, :resolved, :query, :stop],
        %{duration: duration},
        Map.put(metadata, :source, source)
      )

      result
    end
  rescue
    e ->
      Logger.error("Query resolution failed: #{inspect(e)}")

      :telemetry.execute(
        [:yellow_dog, :resolved, :query, :exception],
        %{duration: 0},
        %{domain: "unknown", type: :unknown, reason: e}
      )

      response = ResponseBuilder.build_servfail(query)
      {:ok, encode(response)}
  catch
    kind, reason ->
      Logger.error("Query resolution crashed (#{kind}): #{inspect(reason)}")

      :telemetry.execute(
        [:yellow_dog, :resolved, :query, :exception],
        %{duration: 0},
        %{domain: "unknown", type: :unknown, reason: reason}
      )

      response = ResponseBuilder.build_servfail(query)
      {:ok, encode(response)}
  end

  # Private functions

  defp resolve_pipeline(query, raw_query, domain, query_type) do
    rules = Config.get_intercept_rules()

    case Intercept.match(domain, query_type, rules) do
      {:match, rule} ->
        response = ResponseBuilder.build_intercept_response(query, rule)
        {:ok, encode(response), :intercept}

      :no_match ->
        resolve_cache_or_forward(query, raw_query, domain, query_type)
    end
  end

  defp resolve_cache_or_forward(query, raw_query, domain, query_type) do
    case Cache.lookup(domain, query_type) do
      {:hit, cached_response} ->
        # Rewrite the txn_id to match the current query
        response = ResponseBuilder.rewrite_txn_id(cached_response, query.header.id)
        {:ok, response, :cache}

      :miss ->
        forward_and_cache(query, raw_query, domain, query_type)
    end
  end

  defp forward_and_cache(query, _raw_query, domain, query_type) do
    case Forwarder.forward(query) do
      {:ok, response_binary} ->
        # Extract TTL from response for caching
        ttl = extract_ttl(response_binary)
        response_msg = DNS.Message.from_iodata(response_binary)

        if response_msg.header.rcode == DNS.Message.RCode.nx_domain() do
          # NXDOMAIN — cache as negative
          Cache.store_negative(domain, query_type, response_binary)
        else
          Cache.store(domain, query_type, response_binary, ttl)
        end

        # Rewrite txn_id back to client's original
        final = ResponseBuilder.rewrite_txn_id(response_binary, query.header.id)
        {:ok, final, :forward}

      {:error, reason} ->
        Logger.warning("All upstreams failed for #{domain}: #{inspect(reason)}")
        response = ResponseBuilder.build_servfail(query)
        {:ok, encode(response), :forward}
    end
  end

  defp extract_ttl(response_binary) do
    try do
      msg = DNS.Message.from_iodata(response_binary)

      msg.anlist
      |> Enum.map(& &1.ttl)
      |> Enum.min(fn -> 300 end)
    rescue
      _ -> 300
    end
  end

  defp encode(message) do
    DNS.to_iodata(message) |> IO.iodata_to_binary()
  end

  defp result_source({:ok, _response, source}), do: source
  defp result_source(_), do: :error
end
