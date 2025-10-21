defmodule YellowDog.Dns.Handler.UDP do
  @moduledoc """
  UDP DNS message handler implementing the Abyss.Handler behaviour.

  Processes DNS queries over UDP with support for:
  - Authoritative responses from loaded zones
  - Recursive resolution
  - Forwarding to upstream servers
  - Response caching
  - Telemetry events for monitoring

  ## DNS Resolution Flow

  1. Parse incoming DNS query
  2. Check cache → if hit, return cached response
  3. Check loaded zones (authoritative) → if found, return authoritative answer
  4. If mode is `:recursive` → perform recursive DNS resolution
  5. If mode is `:forward` → forward to upstream DNS servers
  6. Cache successful responses
  7. Send response to client
  8. Emit telemetry events
  """

  use Abyss.Handler

  alias YellowDog.Telemetry
  alias DNS.Zone.Manager, as: ZoneManager
  alias DNS.Zone.Recursive, as: RecursiveDNS
  alias DNS.Message
  alias DNS.Message.Record

  ## Abyss.Handler Callbacks

  @impl true
  def init(state) do
    Telemetry.span("dns.handler.init", %{}, fn ->
      # Initialize handler state with DNS-specific data
      Telemetry.info("Initializing DNS handler")

      # Get configuration from application config or defaults
      mode = get_config(:mode, :authoritative)
      upstream_servers = get_config(:upstream_servers, ["8.8.8.8", "1.1.1.1"])
      cache_ttl = get_config(:cache_ttl, 300)
      zone_files = get_config(:zone_files, [])

      # Load zones into the zone manager
      loaded_zones = load_zones(zone_files)
      Telemetry.info("Loaded #{length(loaded_zones)} DNS zones", %{zone_count: length(loaded_zones)})

      # Initialize cache (using a simple map for now - could be ETS for production)
      cache = %{}

      # Add DNS-specific state
      dns_state = %{
        mode: mode,
        upstream_servers: parse_upstream_servers(upstream_servers),
        cache: cache,
        cache_ttl: cache_ttl,
        loaded_zones: loaded_zones,
        stats: %{
          queries: 0,
          cache_hits: 0,
          authoritative: 0,
          recursive: 0,
          forwarded: 0,
          errors: 0
        }
      }

      {:ok, Map.merge(state, dns_state)}
    end)
  end

  @impl true
  def handle_data({client_ip, client_port, data}, state) do
    Telemetry.span("dns.query.handle", %{client_ip: format_ip(client_ip), client_port: client_port}, fn ->
      start_time = System.monotonic_time(:microsecond)

      # Update query counter
      state = update_in(state, [:stats, :queries], &(&1 + 1))

      try do
        # Parse incoming DNS message
        query = Message.from_iodata(data)
        Telemetry.debug("Received DNS query", %{
          client_ip: format_ip(client_ip),
          client_port: client_port,
          query: inspect_query(query)
        })

        # Emit telemetry for query received
        :telemetry.execute(
          [:yellow_dog, :dns, :query_received],
          %{duration: System.monotonic_time(:microsecond) - start_time},
          %{client_ip: client_ip, client_port: client_port, query: inspect_query(query)}
        )

        # Process the DNS query
        {response, new_state} = process_dns_query(query, client_ip, state, start_time)

        # Send response back to client
        send_response(response, client_ip, client_port, state.socket)

        {:close, new_state}
      rescue
        error ->
          Telemetry.error("Error handling DNS query", %{
            client_ip: format_ip(client_ip),
            client_port: client_port,
            error: inspect(error)
          })

          # Update error counter
          state = update_in(state, [:stats, :errors], &(&1 + 1))

          # Emit telemetry for error
          :telemetry.execute(
            [:yellow_dog, :dns, :query_error],
            %{duration: System.monotonic_time(:microsecond) - start_time},
            %{client_ip: client_ip, client_port: client_port, error: Exception.message(error)}
          )

          {:close, state}
      end
    end)
  end

  @impl true
  def handle_error(error, state) do
    Telemetry.error("DNS handler error", %{error: inspect(error)})
    {:continue, state}
  end

  @impl true
  def handle_timeout(state) do
    Telemetry.debug("DNS handler timeout")
    {:continue, state}
  end

  ## Private Functions - Query Processing

  defp process_dns_query(query, client_ip, state, start_time) do
    case query.header do
      %{qdcount: 1} when length(query.qdlist) == 1 ->
        question = List.first(query.qdlist)
        process_single_question(query, question, client_ip, state, start_time)

      _ ->
        # Unsupported query (multiple questions or malformed)
        Telemetry.warning("Unsupported DNS query format", %{client_ip: format_ip(client_ip)})
        response = create_error_response(query, :format_error)
        {response, state}
    end
  end

  defp process_single_question(query, question, _client_ip, state, start_time) do
    cache_key = {question.name.value, question.type}

    # 1. Check cache first
    case Map.get(state.cache, cache_key) do
      {cached_response, cached_at} when is_map(cached_response) ->
        # Check if cache entry is still valid
        if System.monotonic_time(:second) - cached_at < state.cache_ttl do
          Telemetry.debug("Cache hit", %{
            name: question.name.value,
            type: to_string(question.type)
          })
          state = update_in(state, [:stats, :cache_hits], &(&1 + 1))

          # Update query ID and emit telemetry
          response = %{cached_response | header: %{cached_response.header | id: query.header.id}}

          :telemetry.execute(
            [:yellow_dog, :dns, :cache_hit],
            %{duration: System.monotonic_time(:microsecond) - start_time},
            %{name: question.name.value, type: to_string(question.type)}
          )

          {response, state}
        else
          # Cache expired, remove and continue
          state = update_in(state, [:cache], &Map.delete(&1, cache_key))
          resolve_question(query, question, state, start_time)
        end

      _ ->
        # Not in cache, resolve
        resolve_question(query, question, state, start_time)
    end
  end

  defp resolve_question(query, question, state, start_time) do
    # 2. Check authoritative zones
    case lookup_in_zones(question.name.value, question.type, state.loaded_zones) do
      {:ok, records} ->
        Telemetry.debug("Authoritative answer", %{
          name: question.name.value,
          type: to_string(question.type),
          record_count: length(records)
        })
        state = update_in(state, [:stats, :authoritative], &(&1 + 1))

        response = create_response(query, question, records, :no_error)
        state = cache_response(response, question, state)

        :telemetry.execute(
          [:yellow_dog, :dns, :authoritative_response],
          %{duration: System.monotonic_time(:microsecond) - start_time},
          %{name: question.name.value, type: to_string(question.type), record_count: length(records)}
        )

        {response, state}

      {:nxdomain, _} ->
        # Name exists in our zone but no records of this type
        handle_not_found(query, question, state, start_time)

      {:error, :not_found} ->
        # Not in our zones, try recursive/forward
        handle_not_found(query, question, state, start_time)
    end
  end

  defp handle_not_found(query, question, state, start_time) do
    case state.mode do
      :recursive ->
        # Perform recursive DNS resolution
        perform_recursive_resolution(query, question, state, start_time)

      :forward ->
        # Forward to upstream DNS servers
        perform_forward(query, question, state, start_time)

      :authoritative ->
        # We're authoritative-only, return NXDOMAIN
        Telemetry.debug("NXDOMAIN", %{
          name: question.name.value,
          type: to_string(question.type)
        })
        response = create_response(query, question, [], :nxdomain)
        {response, state}
    end
  end

  defp perform_recursive_resolution(query, question, state, start_time) do
    Telemetry.span("dns.recursive.resolve", %{name: question.name.value, type: to_string(question.type)}, fn ->
      Telemetry.debug("Performing recursive resolution", %{
        name: question.name.value,
        type: to_string(question.type)
      })
      state = update_in(state, [:stats, :recursive], &(&1 + 1))

      # Use DNS.Zone.Recursive to resolve
      case RecursiveDNS.resolve(question.name.value, question.type) do
        {:ok, records} when is_list(records) ->
          # Convert zone records to message records
          dns_records = convert_recursive_records_to_message_records(records)
          response = create_response(query, question, dns_records, :no_error)
          state = cache_response(response, question, state)

          :telemetry.execute(
            [:yellow_dog, :dns, :recursive_response],
            %{duration: System.monotonic_time(:microsecond) - start_time},
            %{name: question.name.value, type: to_string(question.type), record_count: length(dns_records)}
          )

          {response, state}

        {:error, reason} ->
          Telemetry.warning("Recursive resolution failed", %{
            name: question.name.value,
            reason: inspect(reason)
          })
          response = create_response(query, question, [], :servfail)
          {response, state}

        _ ->
          Telemetry.warning("Unexpected recursive resolution result", %{name: question.name.value})
          response = create_response(query, question, [], :servfail)
          {response, state}
      end
    end)
  end

  defp perform_forward(query, question, state, start_time) do
    Telemetry.span("dns.forward.query", %{name: question.name.value, type: to_string(question.type)}, fn ->
      Telemetry.debug("Forwarding query to upstream", %{
        name: question.name.value,
        type: to_string(question.type)
      })
      state = update_in(state, [:stats, :forwarded], &(&1 + 1))

      # Forward to upstream servers (try first available)
      case forward_to_upstream(query, state.upstream_servers) do
        {:ok, response} ->
          state = cache_response(response, question, state)

          :telemetry.execute(
            [:yellow_dog, :dns, :forward_response],
            %{duration: System.monotonic_time(:microsecond) - start_time},
            %{name: question.name.value, type: to_string(question.type)}
          )

          {response, state}

        {:error, reason} ->
          Telemetry.warning("Forward failed", %{
            name: question.name.value,
            reason: inspect(reason)
          })
          response = create_response(query, question, [], :servfail)
          {response, state}
      end
    end)
  end

  ## Private Functions - Zone Management

  defp load_zones(zone_files) when is_list(zone_files) do
    Enum.flat_map(zone_files, fn zone_file ->
      case ZoneManager.load_zone_from_file(zone_file, zone_file) do
        {:ok, zone} ->
          Telemetry.info("Loaded zone", %{
            zone_name: zone.name.value,
            zone_file: zone_file
          })
          [zone]

        {:error, reason} ->
          Telemetry.error("Failed to load zone", %{
            zone_file: zone_file,
            reason: inspect(reason)
          })
          []
      end
    end)
  end

  defp load_zones(_), do: []

  defp lookup_in_zones(name, type, zones) do
    # Find the most specific zone that matches the query name
    matching_zone = find_matching_zone(name, zones)

    case matching_zone do
      nil ->
        {:error, :not_found}

      zone ->
        # Search for records in the zone
        case search_zone_records(zone, name, type) do
          [] ->
            {:nxdomain, []}

          records ->
            {:ok, records}
        end
    end
  end

  defp find_matching_zone(name, zones) do
    zones
    |> Enum.filter(fn zone ->
      zone_name = zone.name.value
      String.ends_with?(name, zone_name) or name == String.trim_trailing(zone_name, ".")
    end)
    |> Enum.sort_by(fn zone -> -String.length(zone.name.value) end)
    |> List.first()
  end

  defp search_zone_records(zone, name, type) do
    # Search through zone records for matching name and type
    zone.records
    |> Enum.filter(fn rr_set ->
      matches_name?(rr_set, name, zone.name.value) and matches_type?(rr_set, type)
    end)
    |> Enum.flat_map(fn rr_set ->
      # Convert RRSet to Message.Record format
      convert_rrset_to_records(rr_set, zone.name.value)
    end)
  end

  defp matches_name?(rr_set, query_name, zone_name) do
    # Handle relative vs absolute names
    rr_name = normalize_record_name(rr_set.name, zone_name)
    normalized_query = String.trim_trailing(query_name, ".")

    rr_name == normalized_query or rr_name == query_name
  end

  defp normalize_record_name(name, zone_name) do
    cond do
      name == "@" -> String.trim_trailing(zone_name, ".")
      String.ends_with?(name, ".") -> String.trim_trailing(name, ".")
      true -> String.trim_trailing("#{name}.#{zone_name}", ".")
    end
  end

  defp matches_type?(rr_set, type) do
    type_atom = if is_atom(type), do: type, else: String.to_atom(to_string(type))
    rr_set.type == type_atom
  end

  defp convert_rrset_to_records(rr_set, zone_name) do
    Enum.map(rr_set.data, fn data ->
      Record.new(
        normalize_record_name(rr_set.name, zone_name),
        rr_set.type,
        :in,
        rr_set.ttl,
        data
      )
    end)
  end

  defp convert_recursive_records_to_message_records(records) do
    # The recursive resolver returns records in a specific format
    # Convert them to Message.Record format
    Enum.map(records, fn record ->
      case record do
        %{name: name, type: type, class: class, ttl: ttl, data: data} ->
          Record.new(name, type, class, ttl, data)

        %Record{} ->
          record

        _ ->
          # Fallback for unexpected format
          Telemetry.warning("Unexpected record format from recursive resolver", %{
            record: inspect(record)
          })
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  ## Private Functions - Upstream Forwarding

  defp forward_to_upstream(query, upstream_servers) do
    data = DNS.Parameter.to_iodata(query)

    # Try each upstream server until one responds
    Enum.reduce_while(upstream_servers, {:error, :no_response}, fn {ip, port}, _acc ->
      case query_upstream(ip, port, data) do
        {:ok, response} -> {:halt, {:ok, response}}
        {:error, _} -> {:cont, {:error, :no_response}}
      end
    end)
  end

  defp query_upstream(ip, port, data) do
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        :gen_udp.send(socket, ip, port, data)

        result = case :gen_udp.recv(socket, 0, 5000) do
          {:ok, {_ip, _port, response_data}} ->
            response = Message.from_iodata(response_data)
            {:ok, response}

          {:error, reason} ->
            {:error, reason}
        end

        :gen_udp.close(socket)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Private Functions - Response Creation

  defp create_response(query, question, records, rcode_atom) do
    rcode = case rcode_atom do
      :no_error -> DNS.Message.RCode.new(0)
      :format_error -> DNS.Message.RCode.new(1)
      :servfail -> DNS.Message.RCode.new(2)
      :nxdomain -> DNS.Message.RCode.new(3)
      _ -> DNS.Message.RCode.new(2)
    end

    %Message{
      header: %{
        query.header |
        id: query.header.id,
        qr: 1,  # Response
        aa: 1,  # Authoritative answer
        rcode: rcode,
        ancount: length(records)
      },
      qdlist: [question],
      anlist: records
    }
  end

  defp create_error_response(query, error_type) do
    rcode = case error_type do
      :format_error -> DNS.Message.RCode.new(1)
      :servfail -> DNS.Message.RCode.new(2)
      :nxdomain -> DNS.Message.RCode.new(3)
      _ -> DNS.Message.RCode.new(2)
    end

    %Message{
      header: %{query.header | id: query.header.id, qr: 1, rcode: rcode},
      qdlist: query.qdlist
    }
  end

  defp send_response(response, client_ip, client_port, socket) do
    data = DNS.Parameter.to_iodata(response)

    case Abyss.Transport.UDP.send(socket, client_ip, client_port, data) do
      :ok ->
        Telemetry.debug("Sent DNS response", %{
          client_ip: format_ip(client_ip),
          client_port: client_port
        })

      {:error, reason} ->
        Telemetry.error("Failed to send DNS response", %{
          reason: inspect(reason)
        })
    end
  end

  ## Private Functions - Caching

  defp cache_response(response, question, state) do
    # Only cache successful responses
    if response.header.rcode.value == <<0>> do
      cache_key = {question.name.value, question.type}
      cached_at = System.monotonic_time(:second)

      update_in(state, [:cache], &Map.put(&1, cache_key, {response, cached_at}))
    else
      state
    end
  end

  ## Private Functions - Helpers

  defp get_config(key, default) do
    # Try to get from YellowDog config, fall back to default
    case YellowDog.Config.get(:dns, key) do
      nil -> default
      value -> value
    end
  rescue
    _ -> default
  end

  defp parse_upstream_servers(servers) when is_list(servers) do
    Enum.map(servers, fn server ->
      case parse_server_address(server) do
        {:ok, ip, port} -> {ip, port}
        {:error, _} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_upstream_servers(_), do: []

  defp parse_server_address(server) when is_binary(server) do
    case String.split(server, ":") do
      [ip_str, port_str] ->
        with {port, ""} <- Integer.parse(port_str),
             {:ok, ip} <- parse_ip(ip_str) do
          {:ok, ip, port}
        else
          _ -> {:error, :invalid_format}
        end

      [ip_str] ->
        case parse_ip(ip_str) do
          {:ok, ip} -> {:ok, ip, 53}
          error -> error
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  defp parse_server_address(_), do: {:error, :invalid_format}

  defp parse_ip(ip_str) do
    charlist = String.to_charlist(ip_str)

    case :inet.parse_ipv4_address(charlist) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} ->
        case :inet.parse_ipv6_address(charlist) do
          {:ok, ip} -> {:ok, ip}
          {:error, _} -> {:error, :invalid_ip}
        end
    end
  end

  defp format_ip({a, b, c, d}) do
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp format_ip({a, b, c, d, e, f, g, h}) do
    parts = [a, b, c, d, e, f, g, h]
    hex_parts = Enum.map(parts, &Integer.to_string(&1, 16))
    Enum.join(hex_parts, ":")
  end

  defp inspect_query(query) do
    case query.qdlist do
      [question | _] ->
        "#{question.name.value} #{question.type} #{question.class}"
      _ ->
        "empty query"
    end
  end
end
