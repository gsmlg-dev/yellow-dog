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
  alias YellowDog.Dns.Query.Resolver
  alias YellowDog.Dns.Query.Cache.Manager, as: CacheManager
  alias YellowDog.Dns.Zone.Manager, as: ZoneManager
  alias YellowDog.Dns.View
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
      zone_files = get_config(:zone_files, [])

      # Load zones into the zone manager
      loaded_zones = load_zones(zone_files)

      Telemetry.info("Loaded #{length(loaded_zones)} DNS zones", %{
        zone_count: length(loaded_zones)
      })

      # Initialize views for split-horizon DNS
      views = initialize_views(loaded_zones)

      Telemetry.info("Initialized #{length(views)} DNS view(s)", %{
        view_count: length(views),
        view_names: Enum.map(views, & &1.name)
      })

      # Add DNS-specific state (cache is now managed by CacheManager)
      dns_state = %{
        mode: mode,
        upstream_servers: parse_upstream_servers(upstream_servers),
        loaded_zones: loaded_zones,
        views: views,
        stats: %{
          queries: 0,
          cache_hits: 0,
          authoritative: 0,
          recursive: 0,
          forwarded: 0,
          errors: 0,
          view_matches: 0
        }
      }

      {:ok, Map.merge(state, dns_state)}
    end)
  end

  @impl true
  def handle_data({client_ip, client_port, data}, state) do
    Telemetry.span(
      "dns.query.handle",
      %{client_ip: format_ip(client_ip), client_port: client_port},
      fn ->
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
      end
    )
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

  defp process_single_question(query, question, client_ip, state, start_time) do
    query_name = question.name.value
    query_type = question.type
    query_class = question.class

    # Match client to view for split-horizon DNS
    view = match_client_to_view(client_ip, state.views)

    Telemetry.debug("Matched client to view", %{
      client_ip: format_ip(client_ip),
      view_name: view.name,
      recursion_enabled: view.recursion_enabled
    })

    # 1. Check cache first using CacheManager
    case CacheManager.get(query_name, query_type, query_class) do
      {:ok, cached_records, cached_authority} ->
        # Cache hit - create response from cached data
        Telemetry.debug("Cache hit", %{
          name: query_name,
          type: to_string(query_type)
        })

        state = update_in(state, [:stats, :cache_hits], &(&1 + 1))

        # Convert cached records to DNS message format
        dns_records = convert_resolver_records_to_message_records(cached_records)
        dns_authority = convert_resolver_records_to_message_records(cached_authority)

        # Create response with cached data
        response =
          if cached_authority == [] do
            create_response(query, question, dns_records, :no_error)
          else
            create_response_with_authority(
              query,
              question,
              dns_records,
              dns_authority,
              :no_error
            )
          end

        :telemetry.execute(
          [:yellow_dog, :dns, :cache_hit],
          %{duration: System.monotonic_time(:microsecond) - start_time},
          %{name: query_name, type: to_string(query_type)}
        )

        {response, state}

      {:error, :not_found} ->
        # Not in cache, resolve normally
        resolve_question(query, question, view, state, start_time)

      {:error, :disabled} ->
        # Caching disabled, resolve without cache
        resolve_question(query, question, view, state, start_time)
    end
  end

  defp resolve_question(query, question, view, state, start_time) do
    # 2. Check authoritative zones using Query.Resolver
    query_name = question.name.value
    query_type = question.type

    # Find matching zone for this query within the view's accessible zones
    case find_matching_zone_name_in_view(query_name, view) do
      {:ok, zone_name} ->
        # Resolve using Query.Resolver with CNAME following
        case Resolver.resolve_with_cname(zone_name, query_name, query_type) do
          {:ok, answers, _authority} ->
            # Convert resolver records to DNS.Message.Record format
            dns_records = convert_resolver_records_to_message_records(answers)

            Telemetry.debug("Authoritative answer", %{
              name: query_name,
              type: to_string(query_type),
              record_count: length(dns_records)
            })

            state = update_in(state, [:stats, :authoritative], &(&1 + 1))

            response = create_response(query, question, dns_records, :no_error)
            state = cache_response(response, question, state)

            :telemetry.execute(
              [:yellow_dog, :dns, :authoritative_response],
              %{duration: System.monotonic_time(:microsecond) - start_time},
              %{
                name: query_name,
                type: to_string(query_type),
                record_count: length(dns_records)
              }
            )

            {response, state}

          {:nxdomain, _answers, authority} ->
            # Name doesn't exist - return NXDOMAIN with SOA authority
            dns_authority = convert_soa_to_message_records(authority)

            Telemetry.debug("NXDOMAIN with authority", %{
              name: query_name,
              type: to_string(query_type)
            })

            response =
              create_response_with_authority(query, question, [], dns_authority, :nxdomain)

            # Cache negative response
            query_class = question.class
            authority_records = convert_message_records_to_resolver_records(dns_authority)

            CacheManager.put(
              query_name,
              query_type,
              [],
              authority_records,
              300,
              query_class: query_class,
              response_type: :nxdomain
            )

            {response, state}

          {:nodata, _answers, authority} ->
            # Name exists but no records of this type - return NODATA with SOA authority
            dns_authority = convert_soa_to_message_records(authority)

            Telemetry.debug("NODATA with authority", %{
              name: query_name,
              type: to_string(query_type)
            })

            response =
              create_response_with_authority(query, question, [], dns_authority, :no_error)

            # Cache negative response
            query_class = question.class
            authority_records = convert_message_records_to_resolver_records(dns_authority)

            CacheManager.put(
              query_name,
              query_type,
              [],
              authority_records,
              300,
              query_class: query_class,
              response_type: :nodata
            )

            {response, state}

          {:delegation, ns_records, glue_records} ->
            # Delegation to sub-zone - return referral response
            dns_ns_records = convert_resolver_records_to_message_records(ns_records)
            dns_glue_records = convert_resolver_records_to_message_records(glue_records)

            Telemetry.debug("Delegation response", %{
              name: query_name,
              type: to_string(query_type),
              ns_count: length(dns_ns_records),
              glue_count: length(dns_glue_records)
            })

            # Delegation response: empty answers, NS in authority, glue in additional
            response =
              create_delegation_response(
                query,
                question,
                dns_ns_records,
                dns_glue_records
              )

            :telemetry.execute(
              [:yellow_dog, :dns, :delegation_response],
              %{duration: System.monotonic_time(:microsecond) - start_time},
              %{
                name: query_name,
                type: to_string(query_type),
                ns_count: length(dns_ns_records),
                glue_count: length(dns_glue_records)
              }
            )

            {response, state}

          {:rpz_block, :nxdomain, _} ->
            # RPZ blocked with NXDOMAIN
            Telemetry.debug("RPZ block: NXDOMAIN", %{
              name: query_name,
              type: to_string(query_type)
            })

            response = create_response(query, question, [], :nxdomain)

            :telemetry.execute(
              [:yellow_dog, :dns, :rpz_block],
              %{duration: System.monotonic_time(:microsecond) - start_time},
              %{name: query_name, type: to_string(query_type), action: :nxdomain}
            )

            {response, state}

          {:rpz_block, :nodata, _} ->
            # RPZ blocked with NODATA
            Telemetry.debug("RPZ block: NODATA", %{
              name: query_name,
              type: to_string(query_type)
            })

            response = create_response(query, question, [], :no_error)

            :telemetry.execute(
              [:yellow_dog, :dns, :rpz_block],
              %{duration: System.monotonic_time(:microsecond) - start_time},
              %{name: query_name, type: to_string(query_type), action: :nodata}
            )

            {response, state}

          {:rpz_block, :drop, _} ->
            # RPZ drop - don't send response
            Telemetry.debug("RPZ block: DROP", %{
              name: query_name,
              type: to_string(query_type)
            })

            :telemetry.execute(
              [:yellow_dog, :dns, :rpz_block],
              %{duration: System.monotonic_time(:microsecond) - start_time},
              %{name: query_name, type: to_string(query_type), action: :drop}
            )

            # Return empty response (will be ignored)
            response = create_response(query, question, [], :servfail)
            {response, state}

          {:rpz_rewrite, records, _} ->
            # RPZ rewrite with local data
            dns_records = convert_resolver_records_to_message_records(records)

            Telemetry.debug("RPZ rewrite", %{
              name: query_name,
              type: to_string(query_type),
              record_count: length(dns_records)
            })

            response = create_response(query, question, dns_records, :no_error)

            :telemetry.execute(
              [:yellow_dog, :dns, :rpz_rewrite],
              %{duration: System.monotonic_time(:microsecond) - start_time},
              %{name: query_name, type: to_string(query_type), record_count: length(dns_records)}
            )

            {response, state}

          {:servfail, _, _} ->
            # Server failure
            Telemetry.warning("SERVFAIL", %{
              name: query_name,
              type: to_string(query_type)
            })

            response = create_response(query, question, [], :servfail)
            {response, state}
        end

      {:error, :not_found} ->
        # Not in our zones, try recursive/forward (if view allows)
        handle_not_found(query, question, view, state, start_time)
    end
  end

  defp handle_not_found(query, question, view, state, start_time) do
    # Check if view allows recursion
    if view.recursion_enabled do
      # View allows recursion - check mode
      case state.mode do
        :recursive ->
          # Perform recursive DNS resolution
          perform_recursive_resolution(query, question, state, start_time)

        :forward ->
          # Forward to upstream DNS servers
          perform_forward(query, question, state, start_time)

        :authoritative ->
          # We're authoritative-only, return NXDOMAIN
          Telemetry.debug("NXDOMAIN (authoritative mode)", %{
            name: question.name.value,
            type: to_string(question.type)
          })

          response = create_response(query, question, [], :nxdomain)
          {response, state}
      end
    else
      # View disables recursion - return NXDOMAIN
      Telemetry.debug("NXDOMAIN (recursion disabled by view)", %{
        name: question.name.value,
        type: to_string(question.type),
        view_name: view.name
      })

      response = create_response(query, question, [], :nxdomain)
      {response, state}
    end
  end

  defp perform_recursive_resolution(query, question, state, start_time) do
    Telemetry.span(
      "dns.recursive.resolve",
      %{name: question.name.value, type: to_string(question.type)},
      fn ->
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
              %{
                name: question.name.value,
                type: to_string(question.type),
                record_count: length(dns_records)
              }
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
            Telemetry.warning("Unexpected recursive resolution result", %{
              name: question.name.value
            })

            response = create_response(query, question, [], :servfail)
            {response, state}
        end
      end
    )
  end

  defp perform_forward(query, question, state, start_time) do
    Telemetry.span(
      "dns.forward.query",
      %{name: question.name.value, type: to_string(question.type)},
      fn ->
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
      end
    )
  end

  ## Private Functions - Zone Management

  defp load_zones(_zone_files) do
    # Zones are now managed by Zone.Manager and stored in ETS
    # No need to load them here, just return empty list for compatibility
    []
  end

  defp find_matching_zone_name(query_name) do
    # Get list of loaded zones from Zone.Manager
    case ZoneManager.list_zones() do
      {:ok, zones} ->
        # Find the most specific zone that matches the query name
        normalized_query = String.downcase(query_name) |> String.trim_trailing(".")

        matching_zone =
          zones
          |> Enum.filter(fn zone_name ->
            normalized_zone = String.downcase(zone_name) |> String.trim_trailing(".")

            normalized_query == normalized_zone or
              String.ends_with?(normalized_query, "." <> normalized_zone)
          end)
          |> Enum.sort_by(&(-String.length(&1)))
          |> List.first()

        case matching_zone do
          nil -> {:error, :not_found}
          zone_name -> {:ok, zone_name}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp convert_resolver_records_to_message_records(records) do
    # Convert YellowDog.Dns.Zone.Record to DNS.Message.Record format
    Enum.map(records, fn record ->
      # Convert record type and rdata to ex_dns format
      {dns_type, dns_data} = convert_record_type_and_data(record.type, record.rdata)

      Record.new(
        record.owner,
        dns_type,
        :in,
        record.ttl,
        dns_data
      )
    end)
  end

  defp convert_soa_to_message_records(authority) do
    # Convert Zone.SOA structs to DNS.Message.Record format
    Enum.map(authority, fn soa ->
      # SOA record format for ex_dns
      dns_data = %{
        mname: soa.mname,
        rname: soa.rname,
        serial: soa.serial,
        refresh: soa.refresh,
        retry: soa.retry,
        expire: soa.expire,
        minimum: soa.minimum
      }

      Record.new(
        "@",
        :soa,
        :in,
        3600,
        dns_data
      )
    end)
  end

  defp convert_record_type_and_data(:A, rdata), do: {:a, rdata}
  defp convert_record_type_and_data(:AAAA, rdata), do: {:aaaa, rdata}
  defp convert_record_type_and_data(:NS, rdata), do: {:ns, rdata}
  defp convert_record_type_and_data(:CNAME, rdata), do: {:cname, rdata}

  defp convert_record_type_and_data(:MX, {priority, exchange}),
    do: {:mx, %{preference: priority, exchange: exchange}}

  defp convert_record_type_and_data(:TXT, rdata), do: {:txt, [rdata]}
  defp convert_record_type_and_data(:PTR, rdata), do: {:ptr, rdata}

  defp convert_record_type_and_data(:SRV, {priority, weight, port, target}),
    do: {:srv, %{priority: priority, weight: weight, port: port, target: target}}

  defp convert_record_type_and_data(:SOA, soa),
    do:
      {:soa,
       %{
         mname: soa.mname,
         rname: soa.rname,
         serial: soa.serial,
         refresh: soa.refresh,
         retry: soa.retry,
         expire: soa.expire,
         minimum: soa.minimum
       }}

  defp convert_record_type_and_data(type, rdata), do: {type, rdata}

  defp convert_message_records_to_resolver_records(records) when is_list(records) do
    # Convert DNS.Message.Record to YellowDog.Dns.Zone.Record format
    Enum.map(records, fn record ->
      %YellowDog.Dns.Zone.Record{
        owner: record.domain,
        type: normalize_record_type(record.type),
        class: record.class,
        ttl: record.ttl,
        rdata: normalize_rdata(record.type, record.data)
      }
    end)
  end

  defp convert_message_records_to_resolver_records(_), do: []

  defp normalize_record_type(type) when is_atom(type), do: type |> to_string() |> String.upcase() |> String.to_atom()
  defp normalize_record_type(type), do: type

  defp normalize_rdata(:a, ip_tuple), do: ip_tuple
  defp normalize_rdata(:aaaa, ip_tuple), do: ip_tuple
  defp normalize_rdata(:ns, domain), do: domain
  defp normalize_rdata(:cname, domain), do: domain
  defp normalize_rdata(:ptr, domain), do: domain
  defp normalize_rdata(:mx, %{preference: pref, exchange: exch}), do: {pref, exch}
  defp normalize_rdata(:txt, txt_list) when is_list(txt_list), do: Enum.join(txt_list, "")
  defp normalize_rdata(:txt, txt_string), do: txt_string

  defp normalize_rdata(:srv, %{priority: pri, weight: wgt, port: prt, target: tgt}),
    do: {pri, wgt, prt, tgt}

  defp normalize_rdata(:soa, %{
         mname: mname,
         rname: rname,
         serial: serial,
         refresh: refresh,
         retry: retry,
         expire: expire,
         minimum: minimum
       }) do
    %YellowDog.Dns.Zone.SOA{
      mname: mname,
      rname: rname,
      serial: serial,
      refresh: refresh,
      retry: retry,
      expire: expire,
      minimum: minimum
    }
  end

  defp normalize_rdata(_type, rdata), do: rdata

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

        result =
          case :gen_udp.recv(socket, 0, 5000) do
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
    rcode =
      case rcode_atom do
        :no_error -> DNS.Message.RCode.new(0)
        :format_error -> DNS.Message.RCode.new(1)
        :servfail -> DNS.Message.RCode.new(2)
        :nxdomain -> DNS.Message.RCode.new(3)
        _ -> DNS.Message.RCode.new(2)
      end

    %Message{
      header: %{
        query.header
        | id: query.header.id,
          # Response
          qr: 1,
          # Authoritative answer
          aa: 1,
          rcode: rcode,
          ancount: length(records)
      },
      qdlist: [question],
      anlist: records
    }
  end

  defp create_response_with_authority(query, question, records, authority, rcode_atom) do
    rcode =
      case rcode_atom do
        :no_error -> DNS.Message.RCode.new(0)
        :format_error -> DNS.Message.RCode.new(1)
        :servfail -> DNS.Message.RCode.new(2)
        :nxdomain -> DNS.Message.RCode.new(3)
        _ -> DNS.Message.RCode.new(2)
      end

    %Message{
      header: %{
        query.header
        | id: query.header.id,
          # Response
          qr: 1,
          # Authoritative answer
          aa: 1,
          rcode: rcode,
          ancount: length(records),
          nscount: length(authority)
      },
      qdlist: [question],
      anlist: records,
      nslist: authority
    }
  end

  defp create_delegation_response(query, question, ns_records, glue_records) do
    %Message{
      header: %{
        query.header
        | id: query.header.id,
          # Response
          qr: 1,
          # NOT authoritative for delegated sub-zone
          aa: 0,
          # NOERROR
          rcode: DNS.Message.RCode.new(0),
          # No answers
          ancount: 0,
          # NS records in authority
          nscount: length(ns_records),
          # Glue records in additional
          arcount: length(glue_records)
      },
      qdlist: [question],
      # Empty answers for delegation
      anlist: [],
      # NS records
      nslist: ns_records,
      # Glue records
      arlist: glue_records
    }
  end

  defp create_error_response(query, error_type) do
    rcode =
      case error_type do
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
      query_name = question.name.value
      query_type = question.type
      query_class = question.class

      # Extract records and authority from response
      records = convert_message_records_to_resolver_records(response.anlist)
      authority = convert_message_records_to_resolver_records(response.nslist)

      # Calculate TTL from answer records (use minimum TTL)
      ttl =
        case records do
          [] -> 300
          _ -> Enum.map(records, & &1.ttl) |> Enum.min()
        end

      # Store in cache using CacheManager
      CacheManager.put(query_name, query_type, records, authority, ttl, query_class: query_class)
    end

    state
  end

  ## Private Functions - Helpers

  defp get_config(key, default) do
    # Try to get from YellowDog config, fall back to default
    case apply(YellowDog.Config, :get, [:dns, key]) do
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
      {:ok, ip} ->
        {:ok, ip}

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

  ## View-related private functions

  defp initialize_views(loaded_zones) do
    # For now, create a default view that matches all clients
    # In the future, this will load views from configuration
    default_view = View.new("default", :all, loaded_zones, true)
    [default_view]
  end

  defp match_client_to_view(client_ip, views) do
    case View.match_client(client_ip, views) do
      {:ok, view} ->
        view

      {:error, :no_match} ->
        # Fallback to default view if no match
        # This should not happen if views include an "any" catch-all
        Telemetry.warning("No view matched client IP, using default", %{
          client_ip: format_ip(client_ip)
        })

        View.default()
    end
  end

  defp find_matching_zone_name_in_view(query_name, view) do
    # If view has no zone restrictions (empty list), allow all zones
    # Otherwise, only search within view's accessible zones
    accessible_zones =
      case view.zones do
        [] ->
          # Empty zone list means all zones are accessible
          case ZoneManager.list_zones() do
            {:ok, zones} -> zones
            {:error, _} -> []
          end

        zones ->
          # Only these specific zones are accessible
          zones
      end

    # Find the most specific zone that matches the query name
    normalized_query = String.downcase(query_name) |> String.trim_trailing(".")

    matching_zone =
      accessible_zones
      |> Enum.filter(fn zone_name ->
        normalized_zone = String.downcase(zone_name) |> String.trim_trailing(".")

        normalized_query == normalized_zone or
          String.ends_with?(normalized_query, "." <> normalized_zone)
      end)
      |> Enum.sort_by(&(-String.length(&1)))
      |> List.first()

    case matching_zone do
      nil -> {:error, :not_found}
      zone_name -> {:ok, zone_name}
    end
  end
end
