defmodule YellowDog.Resolved.Router do
  @moduledoc """
  Query routing: intercept → cache → forward.
  """

  alias YellowDog.Resolved.{Cache, Config, Forwarder, Intercept, ResponseBuilder}

  require Logger

  @doc """
  Route a DNS query through the resolution pipeline.
  Returns a DNS response message.
  """
  @spec resolve(DNS.Message.t()) :: DNS.Message.t()
  def resolve(query) do
    start_time = System.monotonic_time()
    domain = query_domain(query)
    type = query_type(query)

    :telemetry.execute(
      [:yellow_dog, :resolved, :query, :start],
      %{},
      %{domain: domain, type: type, client: nil}
    )

    result = do_resolve(query, domain, type)

    source =
      case result do
        {:intercept, _} ->
          Cache.increment_intercepted()
          :intercept

        {:cache, _} ->
          :cache

        {:forward, _} ->
          Cache.increment_forwarded()
          :forward

        {:error, _} ->
          :error
      end

    response = elem(result, 1)
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:yellow_dog, :resolved, :query, :stop],
      %{duration: duration},
      %{domain: domain, type: type, source: source}
    )

    response
  end

  # Private

  defp do_resolve(query, domain, type) do
    config = Config.get()
    rules = Map.get(config, :intercept_rules, [])

    # 1. Check intercept rules
    case Intercept.match(domain, rules) do
      %{} = rule ->
        {:intercept, ResponseBuilder.intercept_response(query, rule)}

      nil ->
        # 2. Check cache
        cache_config = Map.get(config, :cache, %{enabled: true})

        if Map.get(cache_config, :enabled, true) do
          case Cache.lookup(domain, type) do
            {:hit, cached_response} ->
              # Rewrite the response header to match the current query's txn_id
              response = %{
                cached_response
                | header: %{cached_response.header | id: query.header.id}
              }

              {:cache, response}

            :miss ->
              forward_and_cache(query, domain, type, config)
          end
        else
          forward_query(query, domain, type, config)
        end
    end
  end

  defp forward_and_cache(query, domain, type, config) do
    case forward_query(query, domain, type, config) do
      {:forward, response} ->
        # Cache the response
        ttl = extract_ttl(response)

        if ttl > 0 do
          # Check for NXDOMAIN — use negative TTL
          cache_config = Map.get(config, :cache, %{})

          actual_ttl =
            if response.header.rcode == DNS.Message.RCode.nx_domain() do
              Map.get(cache_config, :negative_ttl_s, 60)
            else
              ttl
            end

          Cache.store(domain, type, response, actual_ttl)
        end

        {:forward, response}

      other ->
        other
    end
  end

  defp forward_query(query, domain, type, config) do
    timeout = Map.get(config, :upstream_timeout_ms, 3000)

    case Forwarder.forward(query, timeout) do
      {:ok, response} ->
        {:forward, response}

      {:error, :timeout} ->
        Logger.warning("[Resolved] All upstreams timed out for #{domain}/#{type}")
        {:error, ResponseBuilder.servfail_response(query)}
    end
  end

  defp extract_ttl(response) do
    case response.anlist do
      [record | _] -> record.ttl
      [] -> 0
    end
  end

  defp query_domain(query) do
    case query.qdlist do
      [q | _] -> to_string(q.name)
      _ -> "unknown"
    end
  end

  defp query_type(query) do
    case query.qdlist do
      [q | _] -> q.type
      _ -> :unknown
    end
  end
end
