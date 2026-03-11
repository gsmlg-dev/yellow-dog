defmodule YellowDog.Resolved.Router do
  @moduledoc """
  Query routing: intercept → cache → forward.
  """

  alias YellowDog.Resolved.{Cache, Config, Counters, Forwarder, Intercept, ResponseBuilder}

  require Logger

  @doc """
  Route a DNS query through the resolution pipeline.
  Returns a DNS response message.
  """
  @spec resolve(DNS.Message.t()) :: DNS.Message.t()
  # RFC 1035 §4.1.2: every query MUST have at least one question.
  # Reject malformed messages before touching the pipeline.
  def resolve(%DNS.Message{qdlist: []} = query) do
    Logger.debug("[Resolved] Received query with empty question section (RFC violation)")

    :telemetry.execute(
      [:yellow_dog, :resolved, :query, :malformed],
      %{},
      %{client: nil}
    )

    Counters.increment(:error)
    ResponseBuilder.build_response(query, [], DNS.Message.RCode.form_err())
  end

  def resolve(query) do
    start_time = System.monotonic_time()
    domain = query_domain(query)
    type = query_type(query)

    :telemetry.execute(
      [:yellow_dog, :resolved, :query, :start],
      %{},
      %{domain: domain, type: type, client: nil}
    )

    try do
      result = do_resolve(query, domain, type)

      source =
        case result do
          {:intercept, _} ->
            Counters.increment(:intercepted)
            :intercept

          {:cache, _} ->
            Counters.increment(:cached)
            :cache

          {:forward, _} ->
            Counters.increment(:forwarded)
            :forward

          {:error, _} ->
            Counters.increment(:error)
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
    rescue
      e ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:yellow_dog, :resolved, :query, :exception],
          %{duration: duration},
          %{domain: domain, type: type, reason: Exception.message(e)}
        )

        Logger.error("[Resolved] Query resolution failed: #{Exception.message(e)}")
        Counters.increment(:error)
        ResponseBuilder.servfail_response(query)
    catch
      :exit, reason ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:yellow_dog, :resolved, :query, :exception],
          %{duration: duration},
          %{domain: domain, type: type, reason: inspect(reason)}
        )

        Logger.error("[Resolved] Query resolution exited: #{inspect(reason)}")
        Counters.increment(:error)
        ResponseBuilder.servfail_response(query)
    end
  end

  # Private

  defp do_resolve(query, domain, type) do
    # RFC 1035 §4.1.1: non-QUERY opcodes (IQUERY, STATUS, NOTIFY, UPDATE, …)
    # are not handled by this stub resolver — return NOTIMP immediately.
    if query.header.opcode != DNS.Message.OpCode.query() do
      Logger.debug("[Resolved] Non-QUERY opcode #{query.header.opcode} — returning NOTIMP (domain=#{domain})")
      {:error, ResponseBuilder.build_response(query, [], DNS.Message.RCode.not_imp())}
    else
      config = Config.get()
      rules = Map.get(config, :intercept_rules, [])

      # 1. Check intercept rules (match by both domain pattern and query type)
      case Intercept.match(domain, type, rules) do
        %{} = rule ->
          {:intercept, ResponseBuilder.intercept_response(query, rule)}

        nil ->
          # 2. Check cache
          cache_config = Map.get(config, :cache, %{enabled: true})

          if Map.get(cache_config, :enabled, true) do
            case Cache.lookup(domain, type) do
              {:hit, cached_response, remaining_ttl} ->
                # Rewrite the response header to match the current query's txn_id,
                # echo the RD bit from the current query (RFC 1035 §4.1.1: RD is
                # copied into the response), and set TTLs to remaining cache TTL
                # (RFC 1035 §4.1.3).
                response = %{
                  cached_response
                  | header: %{cached_response.header | id: query.header.id, rd: query.header.rd},
                    anlist: set_ttls(cached_response.anlist, remaining_ttl),
                    nslist: set_ttls(cached_response.nslist, remaining_ttl),
                    arlist: set_ttls(cached_response.arlist, remaining_ttl)
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
  end

  defp forward_and_cache(query, domain, type, config) do
    case forward_query(query, domain, type, config) do
      {:forward, response} ->
        cache_config = Map.get(config, :cache, %{})
        ttl = extract_ttl(response)

        cond do
          # Truncated response — incomplete data must not be cached (RFC 1035 §4.2.1).
          # The client will retry over TCP to get the full answer.
          response.header.tc == 1 ->
            :ok

          # NXDOMAIN — cache with negative TTL
          response.header.rcode == DNS.Message.RCode.nx_domain() ->
            negative_ttl = Map.get(cache_config, :negative_ttl_s, 60)
            Cache.store(domain, type, response, negative_ttl)

          # Positive response — only cache NOERROR with answers.
          # SERVFAIL / REFUSED responses must NOT be cached, even if they
          # happen to carry records with TTL > 0 (RFC 2308 §7).
          response.header.rcode == DNS.Message.RCode.no_error() and ttl > 0 ->
            Cache.store(domain, type, response, ttl)

          # NOERROR with no answers (NODATA), SERVFAIL, REFUSED, etc. — don't cache
          true ->
            :ok
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
      [] -> 0
      records -> records |> Enum.map(& &1.ttl) |> Enum.min()
    end
  end

  defp set_ttls(records, remaining_ttl) do
    Enum.map(records, fn record ->
      %{record | ttl: min(record.ttl, remaining_ttl)}
    end)
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
