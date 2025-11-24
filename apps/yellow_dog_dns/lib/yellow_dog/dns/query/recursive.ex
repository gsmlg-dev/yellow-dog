defmodule YellowDog.Dns.Query.Recursive do
  @moduledoc """
  Implements recursive DNS resolution by iteratively querying nameservers
  starting from root servers.

  This module performs true recursive resolution:
  1. Start with root servers
  2. Query for the target domain
  3. Follow NS referrals down the hierarchy
  4. Handle glue records for nameserver resolution
  5. Return the final answer

  ## Algorithm

  The recursive resolver implements the standard DNS resolution algorithm:

  ```
  resolve(name, type):
    1. Start with root server IPs
    2. Query root for name
    3. If answer: return it
    4. If referral: extract NS records and glue
    5. Query referred nameservers
    6. Repeat from step 3 until answer or error
  ```

  ## Example Resolution Path

  Query: www.example.com A

  ```
  1. Query root server (.) → referral to .com servers
  2. Query .com server → referral to example.com servers
  3. Query example.com server → answer: 192.0.2.1
  ```

  ## Features

  - Follows referrals from root to authoritative servers
  - Handles glue records for in-bailiwick nameservers
  - Detects and prevents referral loops
  - Respects maximum recursion depth
  - Parallel queries to multiple nameservers for faster resolution
  - Comprehensive telemetry and logging
  """

  require Logger
  alias YellowDog.Dns.RootZone.Manager, as: RootZone
  alias YellowDog.Dns.Query.Iterator
  alias YellowDog.Dns.Query.Referral

  @max_recursion_depth 16
  @query_timeout_ms 5000
  @max_parallel_queries 3

  @type resolve_result ::
          {:ok, [any()], [any()]}
          | {:nxdomain, [], [any()]}
          | {:error, atom()}

  @doc """
  Recursively resolves a DNS query starting from root servers.

  ## Parameters
  - `query_name` - Domain name to resolve (e.g., "www.example.com" or "www.example.com.")
  - `query_type` - Record type (:A, :AAAA, :MX, :CNAME, etc.)
  - `opts` - Options keyword list

  ## Options
  - `:timeout_ms` - Timeout for each query (default: 5000)
  - `:max_depth` - Maximum recursion depth (default: 16)
  - `:max_parallel` - Maximum parallel queries (default: 3)
  - `:ip_version` - IP version for root servers (:ipv4 or :ipv6, default: :ipv4)

  ## Returns
  - `{:ok, answer_records, authority_records}` - Successful resolution
  - `{:nxdomain, [], authority_records}` - Name doesn't exist
  - `{:error, reason}` - Resolution failed

  ## Examples

      iex> Recursive.resolve("www.example.com", :A)
      {:ok, [%DNS.Message.Record{type: :a, data: {192, 0, 2, 1}, ...}], []}

      iex> Recursive.resolve("nonexistent.example.com", :A)
      {:nxdomain, [], [%DNS.Message.Record{type: :soa, ...}]}

      iex> Recursive.resolve("google.com", :A, timeout_ms: 10000)
      {:ok, [%DNS.Message.Record{...}], []}
  """
  @spec resolve(String.t(), atom(), keyword()) :: resolve_result()
  def resolve(query_name, query_type, opts \\ []) do
    # Normalize query name
    normalized_name = normalize_query_name(query_name)

    # Extract options
    max_depth = Keyword.get(opts, :max_depth, @max_recursion_depth)
    timeout_ms = Keyword.get(opts, :timeout_ms, @query_timeout_ms)
    max_parallel = Keyword.get(opts, :max_parallel, @max_parallel_queries)
    ip_version = Keyword.get(opts, :ip_version, :ipv4)

    # Initialize referral tracking
    state = Referral.new(normalized_name, query_type)

    # Get root servers from RootZone.Manager
    # Manager returns [{name, ip}] tuples, we need just the IPs
    root_servers =
      RootZone.get_root_servers()
      |> Enum.map(fn {_name, ip} -> ip end)
      |> filter_by_ip_version(ip_version)

    if length(root_servers) == 0 do
      Logger.error("No root servers available for IP version: #{ip_version}")
      {:error, :no_root_servers}
    else
      Logger.info("Starting recursive resolution",
        query: normalized_name,
        type: query_type,
        root_servers: length(root_servers)
      )

      # Emit telemetry
      :telemetry.execute(
        [:yellow_dog, :dns, :recursive, :start],
        %{},
        %{query_name: normalized_name, query_type: query_type}
      )

      start_time = System.monotonic_time(:microsecond)

      # Start iterative resolution
      result =
        resolve_iteratively(
          normalized_name,
          query_type,
          root_servers,
          state,
          max_depth,
          timeout_ms,
          max_parallel
        )

      duration = System.monotonic_time(:microsecond) - start_time

      :telemetry.execute(
        [:yellow_dog, :dns, :recursive, :complete],
        %{duration: duration},
        %{
          query_name: normalized_name,
          query_type: query_type,
          result: elem(result, 0),
          depth: state.depth
        }
      )

      result
    end
  end

  # Private functions

  defp resolve_iteratively(
         query_name,
         query_type,
         nameservers,
         state,
         max_depth,
         timeout_ms,
         max_parallel
       ) do
    # Check max depth
    if Referral.max_depth_exceeded?(state, max_depth) do
      Logger.warning("Maximum recursion depth exceeded",
        query: query_name,
        depth: state.depth,
        max: max_depth
      )

      {:error, :max_depth_exceeded}
    else
      Logger.debug("Querying nameservers",
        level: state.depth,
        ns_count: length(nameservers),
        query: query_name
      )

      # Query nameservers (try multiple in parallel)
      case query_nameservers(nameservers, query_name, query_type, timeout_ms, max_parallel) do
        {:answer, answers, authority} ->
          Logger.info("Got answer",
            query: query_name,
            type: query_type,
            answer_count: length(answers),
            depth: state.depth
          )

          {:ok, answers, authority}

        {:referral, ns_records, glue_map, queried_ip} ->
          Logger.debug("Got referral",
            query: query_name,
            ns_count: length(ns_records),
            glue_count: map_size(glue_map),
            depth: state.depth
          )

          # Determine the zone from NS records (they all should be for the same zone)
          zone = extract_zone_from_ns_records(ns_records)

          # Add referral to state
          case Referral.add_referral(state, zone, ns_records, glue_map, queried_ip) do
            {:ok, new_state} ->
              # Resolve NS names to IPs using glue
              case resolve_ns_addresses(ns_records, glue_map, new_state) do
                {:ok, ns_ips} ->
                  # Continue resolution with referred nameservers
                  resolve_iteratively(
                    query_name,
                    query_type,
                    ns_ips,
                    new_state,
                    max_depth,
                    timeout_ms,
                    max_parallel
                  )

                {:error, reason} ->
                  Logger.warning("Failed to resolve NS addresses",
                    reason: reason,
                    ns_records: length(ns_records),
                    glue_count: map_size(glue_map)
                  )

                  {:error, reason}
              end

            {:error, :loop_detected} ->
              {:error, :loop_detected}
          end

        {:nxdomain, authority} ->
          Logger.info("Got NXDOMAIN", query: query_name, depth: state.depth)
          {:nxdomain, [], authority}

        {:error, reason} ->
          Logger.warning("Query failed", query: query_name, reason: reason, depth: state.depth)
          {:error, reason}
      end
    end
  end

  defp query_nameservers(nameservers, query_name, query_type, timeout_ms, max_parallel) do
    # Select nameservers to query (up to max_parallel)
    selected_ns = Enum.take_random(nameservers, min(length(nameservers), max_parallel))

    # Query them in parallel using Task.async_stream
    tasks =
      Task.async_stream(
        selected_ns,
        fn ns_ip ->
          Iterator.query_nameserver(ns_ip, query_name, query_type, timeout_ms: timeout_ms)
        end,
        timeout: timeout_ms + 1000,
        on_timeout: :kill_task,
        max_concurrency: max_parallel
      )

    # Find first successful response
    result =
      Enum.reduce_while(tasks, {:error, :all_ns_failed}, fn task_result, _acc ->
        case task_result do
          {:ok, {:answer, answers, authority}} ->
            # Got an answer, stop and return it
            {:halt, {:answer, answers, authority}}

          {:ok, {:referral, ns_records, glue_map}} ->
            # Got a referral, use it (first referral wins)
            # Note: we don't track which NS gave us the referral in the simplified version
            {:halt, {:referral, ns_records, glue_map, nil}}

          {:ok, {:nxdomain, authority}} ->
            # NXDOMAIN is authoritative, return it
            {:halt, {:nxdomain, authority}}

          {:ok, {:error, reason}} ->
            # This NS failed, try next
            Logger.debug("Nameserver query failed", reason: reason)
            {:cont, {:error, reason}}

          {:exit, :timeout} ->
            # Task timed out, try next
            Logger.debug("Nameserver query timed out")
            {:cont, {:error, :timeout}}

          _ ->
            # Other error, try next
            {:cont, {:error, :unknown}}
        end
      end)

    result
  end

  defp resolve_ns_addresses(ns_records, glue_map, state) do
    # Extract NS names and resolve them using glue records
    ns_ips =
      ns_records
      |> Enum.flat_map(fn record ->
        ns_name = extract_ns_name(record)

        case Map.get(glue_map, ns_name) do
          nil ->
            # No glue in response, check state glue
            case Referral.get_glue(state, ns_name) do
              {:ok, ips} -> ips
              {:error, :no_glue} -> []
            end

          ips when is_list(ips) ->
            ips
        end
      end)
      |> Enum.filter(&(&1 != nil))
      |> Enum.uniq()

    if length(ns_ips) > 0 do
      {:ok, ns_ips}
    else
      Logger.warning("No glue records available for nameservers")
      {:error, :no_glue}
    end
  end

  defp extract_zone_from_ns_records([first_record | _]) do
    # The zone is the owner name of the NS record
    first_record.name.value
  end

  defp extract_zone_from_ns_records([]), do: "."

  defp extract_ns_name(ns_record) do
    case ns_record.data do
      %{data: %{value: name}} -> normalize_query_name(name)
      %{data: name} when is_binary(name) -> normalize_query_name(name)
      _ -> nil
    end
  end

  defp normalize_query_name(name) when is_binary(name) do
    name = String.downcase(name)

    if String.ends_with?(name, ".") do
      name
    else
      name <> "."
    end
  end

  defp filter_by_ip_version(servers, :ipv4) do
    Enum.filter(servers, fn ip ->
      tuple_size(ip) == 4
    end)
  end

  defp filter_by_ip_version(servers, :ipv6) do
    Enum.filter(servers, fn ip ->
      tuple_size(ip) == 8
    end)
  end
end
