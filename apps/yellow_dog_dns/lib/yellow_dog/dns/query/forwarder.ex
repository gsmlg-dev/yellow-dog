defmodule YellowDog.Dns.Query.Forwarder do
  @moduledoc """
  Forwards DNS queries to upstream resolvers with caching support.

  This module implements a DNS client that sends queries to upstream
  DNS servers and returns the responses. It supports:
  - Automatic cache lookup before forwarding
  - Caching of successful responses
  - Multiple upstream forwarders with automatic failover
  - Configurable timeouts and retries
  - UDP transport with automatic TCP fallback for truncated responses
  - Response validation and decoding
  - Telemetry events for monitoring

  ## Caching

  The forwarder integrates with Cache.Manager to:
  - Check cache before forwarding (reduces upstream queries)
  - Store successful responses with appropriate TTL
  - Skip caching with `:use_cache false` option

  ## TCP Fallback

  When a UDP response has the TC (truncated) bit set, the query is
  automatically retried over TCP. This is required by RFC 1035 when
  responses exceed the UDP size limit (typically 512 bytes).

  ## Usage

      iex> forwarders = [{8, 8, 8, 8}, {1, 1, 1, 1}]
      iex> Forwarder.forward_query("example.com", :A, forwarders)
      {:ok, [%Record{...}]}

      iex> Forwarder.forward_query("nonexistent.invalid", :A, forwarders)
      {:nxdomain, []}

      iex> # Disable caching for this query
      iex> Forwarder.forward_query("example.com", :A, forwarders, use_cache: false)
      {:ok, [%Record{...}]}
  """

  require Logger
  alias DNS.Message
  alias DNS.Message.Record
  alias YellowDog.Dns.Query.Cache.Manager, as: CacheManager

  @default_timeout 5000
  @default_max_retries 2
  @dns_port 53

  @type forward_result ::
          {:ok, [Record.t()]}
          | {:nxdomain, []}
          | {:servfail, []}
          | {:error, atom()}

  @doc """
  Forwards a DNS query to upstream resolvers.

  Checks the cache first and returns cached results if available. If not
  cached or cache is disabled, forwards the query to upstream servers and
  stores successful responses in the cache.

  ## Parameters
  - `query_name` - The domain name to query (e.g., "example.com")
  - `query_type` - The DNS record type atom (e.g., :A, :AAAA, :MX)
  - `forwarders` - List of IP address tuples to try
  - `opts` - Optional configuration

  ## Options
  - `:timeout_ms` - Timeout in milliseconds (default: 5000)
  - `:max_retries` - Maximum retry attempts per forwarder (default: 2)
  - `:query_id` - Custom query ID (default: random)
  - `:use_cache` - Enable cache lookup and storage (default: true)
  - `:query_class` - DNS class for cache lookups (default: :IN)

  ## Returns
  - `{:ok, records}` - Successful response with answer records
  - `{:nxdomain, []}` - Name does not exist
  - `{:servfail, []}` - Server failure from upstream
  - `{:error, reason}` - Communication or parsing error

  ## Examples

      iex> forwarders = [{8, 8, 8, 8}, {1, 1, 1, 1}]
      iex> Forwarder.forward_query("google.com", :A, forwarders)
      {:ok, [%Record{name: "google.com.", type: :a, ...}]}

      iex> Forwarder.forward_query("example.com", :A, [])
      {:error, :no_forwarders}

      iex> # Skip cache for fresh query
      iex> Forwarder.forward_query("example.com", :A, forwarders, use_cache: false)
      {:ok, [%Record{...}]}
  """
  @spec forward_query(String.t(), atom(), [:inet.ip_address()], keyword()) :: forward_result()
  def forward_query(query_name, query_type, forwarders, opts \\ [])

  def forward_query(_query_name, _query_type, [], _opts) do
    {:error, :no_forwarders}
  end

  def forward_query(query_name, query_type, forwarders, opts) when is_list(forwarders) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout)
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    use_cache = Keyword.get(opts, :use_cache, true)
    query_class = Keyword.get(opts, :query_class, :IN)

    # Normalize query name
    normalized_name = normalize_query_name(query_name)
    normalized_type = normalize_type(query_type)

    # Check cache first (if enabled)
    result =
      if use_cache do
        case CacheManager.get(normalized_name, normalized_type, query_class) do
          {:ok, records, _authority} ->
            # Cache hit
            Logger.debug("Cache hit for #{normalized_name} #{query_type}")

            :telemetry.execute(
              [:yellow_dog, :dns, :forward, :cache_hit],
              %{count: 1},
              %{name: normalized_name, type: query_type}
            )

            {:ok, records}

          {:error, :not_found} ->
            # Cache miss, forward to upstream
            Logger.debug("Cache miss for #{normalized_name} #{query_type}")

            :telemetry.execute(
              [:yellow_dog, :dns, :forward, :cache_miss],
              %{count: 1},
              %{name: normalized_name, type: query_type}
            )

            forward_and_cache(
              normalized_name,
              normalized_type,
              query_class,
              forwarders,
              timeout_ms,
              max_retries,
              opts
            )

          {:error, :disabled} ->
            # Cache disabled, forward directly
            forward_upstream(
              normalized_name,
              query_type,
              forwarders,
              timeout_ms,
              max_retries,
              opts
            )
        end
      else
        # Cache disabled via option, forward directly
        forward_upstream(normalized_name, query_type, forwarders, timeout_ms, max_retries, opts)
      end

    result
  end

  # Forward to upstream without caching
  defp forward_upstream(query_name, query_type, forwarders, timeout_ms, max_retries, opts) do
    # Emit telemetry event
    :telemetry.execute(
      [:yellow_dog, :dns, :forward, :start],
      %{count: length(forwarders)},
      %{name: query_name, type: query_type}
    )

    start_time = System.monotonic_time(:microsecond)

    # Try each forwarder in sequence
    result = try_forwarders(query_name, query_type, forwarders, timeout_ms, max_retries, opts)

    # Emit completion telemetry
    duration = System.monotonic_time(:microsecond) - start_time

    :telemetry.execute(
      [:yellow_dog, :dns, :forward, :complete],
      %{duration: duration},
      %{name: query_name, type: query_type, result: elem(result, 0)}
    )

    result
  end

  # Forward to upstream and cache the result
  defp forward_and_cache(
         query_name,
         query_type,
         query_class,
         forwarders,
         timeout_ms,
         max_retries,
         opts
       ) do
    result = forward_upstream(query_name, query_type, forwarders, timeout_ms, max_retries, opts)

    # Store successful responses in cache
    case result do
      {:ok, records} when is_list(records) and records != [] ->
        # Extract minimum TTL from records
        ttl = extract_min_ttl(records)

        # Store in cache
        CacheManager.put(query_name, query_type, records, [], ttl,
          query_class: query_class,
          response_type: :answer
        )

        Logger.debug("Cached response for #{query_name} #{query_type} with TTL #{ttl}")
        result

      {:nxdomain, _} ->
        # Cache negative responses with configured TTL
        CacheManager.put(query_name, query_type, [], [], 0,
          query_class: query_class,
          response_type: :nxdomain
        )

        result

      _ ->
        # Don't cache errors or servfail
        result
    end
  end

  # Extract minimum TTL from a list of records
  defp extract_min_ttl([]), do: 300

  defp extract_min_ttl(records) when is_list(records) do
    records
    |> Enum.map(fn record ->
      case record do
        %{ttl: ttl} when is_integer(ttl) -> ttl
        _ -> 300
      end
    end)
    |> Enum.min()
    # Ensure minimum TTL of 60 seconds
    |> max(60)
  end

  # Private Functions

  defp try_forwarders(query_name, query_type, [forwarder | rest], timeout_ms, max_retries, opts) do
    case send_to_upstream(query_name, query_type, forwarder, timeout_ms, max_retries, opts) do
      {:ok, _records} = success ->
        success

      {:nxdomain, _} = nxdomain ->
        # NXDOMAIN is a valid response, don't try other forwarders
        nxdomain

      {:servfail, _} = servfail ->
        # SERVFAIL from upstream, try next forwarder
        Logger.debug("SERVFAIL from upstream #{format_ip(forwarder)}, trying next forwarder")
        try_next_forwarder(query_name, query_type, rest, timeout_ms, max_retries, opts, servfail)

      {:error, reason} ->
        # Communication error, try next forwarder
        Logger.debug(
          "Error from upstream #{format_ip(forwarder)}: #{inspect(reason)}, trying next"
        )

        try_next_forwarder(
          query_name,
          query_type,
          rest,
          timeout_ms,
          max_retries,
          opts,
          {:error, reason}
        )
    end
  end

  defp try_forwarders(_query_name, _query_type, [], _timeout_ms, _max_retries, _opts) do
    # No forwarders left
    {:error, :all_forwarders_failed}
  end

  defp try_next_forwarder(
         query_name,
         query_type,
         remaining,
         timeout_ms,
         max_retries,
         opts,
         _last_error
       ) do
    case remaining do
      [] ->
        # No more forwarders, all have failed
        {:error, :all_forwarders_failed}

      _ ->
        # Try next forwarder
        try_forwarders(query_name, query_type, remaining, timeout_ms, max_retries, opts)
    end
  end

  defp send_to_upstream(query_name, query_type, forwarder_ip, timeout_ms, max_retries, opts) do
    # Create DNS query message
    query_id = Keyword.get(opts, :query_id, :rand.uniform(65535))
    query_message = create_query_message(query_name, query_type, query_id)

    # Encode the query
    case encode_query(query_message) do
      {:ok, query_data} ->
        # Send with retries
        send_with_retries(forwarder_ip, query_data, query_id, timeout_ms, max_retries)

      {:error, reason} ->
        {:error, {:encode_failed, reason}}
    end
  end

  defp send_with_retries(forwarder_ip, query_data, query_id, timeout_ms, retries_left) do
    case query_upstream(forwarder_ip, @dns_port, query_data, query_id, timeout_ms) do
      {:ok, _records} = success ->
        success

      {:nxdomain, _} = nxdomain ->
        nxdomain

      {:servfail, _} = servfail ->
        servfail

      {:error, :timeout} when retries_left > 0 ->
        Logger.debug(
          "Timeout querying #{format_ip(forwarder_ip)}, retrying (#{retries_left} left)"
        )

        send_with_retries(forwarder_ip, query_data, query_id, timeout_ms, retries_left - 1)

      {:error, _} = error ->
        error
    end
  end

  defp create_query_message(query_name, query_type, query_id) do
    # Ensure trailing dot
    normalized_name = normalize_query_name(query_name)

    # Convert type to ex_dns format (lowercase atom)
    dns_type = normalize_type(query_type)

    # Create DNS message manually since ex_dns doesn't have new_query helper
    message = Message.new()

    # Set query ID and flags
    message = Message.update_header_attr(message, :id, query_id)
    # 0 = query
    message = Message.update_header_attr(message, :qr, 0)
    # 1 = recursion desired
    message = Message.update_header_attr(message, :rd, 1)

    # Create question
    question = DNS.Message.Question.new(normalized_name, dns_type, :in)

    # Add question to message
    Message.add_question(message, question)
  end

  defp encode_query(query_message) do
    try do
      data = DNS.Parameter.to_iodata(query_message)
      {:ok, IO.iodata_to_binary(data)}
    rescue
      error ->
        {:error, error}
    end
  end

  defp query_upstream(ip, port, query_data, expected_id, timeout_ms) do
    # Try UDP first
    case query_upstream_udp(ip, port, query_data, expected_id, timeout_ms) do
      {:ok, response_data} ->
        # Decode and check for truncation
        case decode_response(response_data, expected_id) do
          {:ok, records, truncated: true} ->
            # Response was truncated, retry over TCP
            Logger.debug("Response truncated, retrying over TCP for #{format_ip(ip)}")

            :telemetry.execute(
              [:yellow_dog, :dns, :forward, :tcp_fallback],
              %{count: 1},
              %{ip: format_ip(ip)}
            )

            query_upstream_tcp(ip, port, query_data, expected_id, timeout_ms)

          result ->
            # Not truncated or error, return as-is
            result
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp query_upstream_udp(ip, port, query_data, expected_id, timeout_ms) do
    # Open UDP socket
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        try do
          # Send query
          case :gen_udp.send(socket, ip, port, query_data) do
            :ok ->
              # Receive response with timeout
              case :gen_udp.recv(socket, 0, timeout_ms) do
                {:ok, {^ip, ^port, response_data}} ->
                  {:ok, response_data}

                {:ok, {other_ip, other_port, _data}} ->
                  # Unexpected source, ignore
                  Logger.warning(
                    "Received response from unexpected source: #{format_ip(other_ip)}:#{other_port}"
                  )

                  {:error, :unexpected_source}

                {:error, :timeout} ->
                  {:error, :timeout}

                {:error, reason} ->
                  {:error, reason}
              end

            {:error, reason} ->
              # Send failed (e.g., :eafnosupport for IPv6 on IPv4-only systems)
              {:error, reason}
          end
        after
          :gen_udp.close(socket)
        end

      {:error, reason} ->
        {:error, {:socket_open_failed, reason}}
    end
  end

  defp query_upstream_tcp(ip, port, query_data, expected_id, timeout_ms) do
    # TCP DNS uses 2-byte length prefix (big-endian)
    length = byte_size(query_data)
    tcp_query = <<length::16>> <> query_data

    # Open TCP connection
    case :gen_tcp.connect(ip, port, [:binary, active: false], timeout_ms) do
      {:ok, socket} ->
        try do
          # Send query with length prefix
          :ok = :gen_tcp.send(socket, tcp_query)

          # Receive response length (2 bytes)
          case :gen_tcp.recv(socket, 2, timeout_ms) do
            {:ok, <<response_length::16>>} ->
              # Receive full response
              case :gen_tcp.recv(socket, response_length, timeout_ms) do
                {:ok, response_data} ->
                  decode_response(response_data, expected_id)

                {:error, reason} ->
                  {:error, {:tcp_recv_failed, reason}}
              end

            {:error, reason} ->
              {:error, {:tcp_recv_length_failed, reason}}
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, reason} ->
        {:error, {:tcp_connect_failed, reason}}
    end
  end

  defp decode_response(response_data, expected_id) do
    try do
      response = Message.from_iodata(response_data)

      # Verify query ID matches
      if response.header.id == expected_id do
        parse_response(response)
      else
        Logger.warning("Query ID mismatch: expected #{expected_id}, got #{response.header.id}")
        {:error, :id_mismatch}
      end
    rescue
      error ->
        Logger.error("Failed to decode DNS response: #{inspect(error)}")
        {:error, :decode_failed}
    catch
      :throw, error ->
        Logger.error("Failed to parse DNS response: #{inspect(error)}")
        {:error, :parse_failed}
    end
  end

  defp parse_response(response) do
    rcode_value = response.header.rcode.value
    # Check TC (truncated) bit
    tc = response.header.tc == 1

    case rcode_value do
      <<0>> ->
        # NOERROR - extract answer records
        records = response.anlist || []

        if tc do
          # Return truncation flag
          {:ok, records, truncated: true}
        else
          {:ok, records}
        end

      <<3>> ->
        # NXDOMAIN (truncation doesn't matter for NXDOMAIN)
        {:nxdomain, []}

      <<2>> ->
        # SERVFAIL
        {:servfail, []}

      _ ->
        # Other error codes
        Logger.debug("Received DNS error code: #{inspect(rcode_value)}")
        {:error, :dns_error}
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

  defp normalize_type(type) when is_atom(type) do
    # Convert uppercase atoms to lowercase for ex_dns
    type
    |> Atom.to_string()
    |> String.downcase()
    |> String.to_atom()
  end

  defp format_ip({a, b, c, d}) do
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp format_ip({a, b, c, d, e, f, g, h}) do
    parts = [a, b, c, d, e, f, g, h]
    hex_parts = Enum.map(parts, &Integer.to_string(&1, 16))
    Enum.join(hex_parts, ":")
  end
end
