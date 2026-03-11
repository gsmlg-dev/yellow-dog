defmodule YellowDog.Mdns.Client do
  @moduledoc """
  mDNS client for sending multicast DNS queries and discovering services.

  Uses multicast DNS on 224.0.0.251:5353 (IPv4) or ff02::fb:5353 (IPv6)
  to query services on the local network.

  ## Usage

      # Query for a specific host
      {:ok, responses} = YellowDog.Mdns.Client.query("mydevice.local", :a)

      # Discover HTTP services
      {:ok, services} = YellowDog.Mdns.Client.discover("_http._tcp.local")

      # Browse all services
      {:ok, types} = YellowDog.Mdns.Client.browse()
  """

  alias DNS.Message
  alias DNS.Message.{Header, Question}

  @mdns_ipv4_addr {224, 0, 0, 251}
  @mdns_ipv6_addr {0xFF02, 0, 0, 0, 0, 0, 0, 0x00FB}
  @mdns_port 5353
  # RFC 6762 §11: mDNS multicast TTL must be 255
  @mdns_multicast_ttl 255
  @default_timeout 2000

  @typedoc "Query options"
  @type query_opts :: [
          timeout: non_neg_integer(),
          interface: String.t() | :inet.ip_address(),
          ipv6: boolean()
        ]

  @doc """
  Send an mDNS query and collect responses.

  mDNS is multicast, so multiple responses may be received from different hosts.

  ## Parameters

  - `name` - Domain name to query (e.g., "mydevice.local", "_http._tcp.local")
  - `type` - Record type (:a, :aaaa, :ptr, :srv, :txt, :any)
  - `opts` - Optional keyword list:
    - `:timeout` - Time to wait for responses (default: 2000ms)
    - `:interface` - Network interface to use (optional)
    - `:ipv6` - Use IPv6 multicast (default: false)

  ## Returns

  - `{:ok, [%DNS.Message{}]}` - List of response messages received
  - `{:error, reason}` - Error

  ## Examples

      # Query for A record
      {:ok, responses} = YellowDog.Mdns.Client.query("printer.local", :a)

      # Query for service instances
      {:ok, responses} = YellowDog.Mdns.Client.query("_http._tcp.local", :ptr)
  """
  @spec query(String.t(), atom(), query_opts()) :: {:ok, [Message.t()]} | {:error, term()}
  def query(name, type, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    use_ipv6 = Keyword.get(opts, :ipv6, false)

    message = build_query(name, type)
    binary = DNS.to_iodata(message) |> IO.iodata_to_binary()

    multicast_addr = if use_ipv6, do: @mdns_ipv6_addr, else: @mdns_ipv4_addr

    socket_opts = build_socket_opts(opts, use_ipv6)

    case open_multicast_socket(socket_opts, use_ipv6) do
      {:ok, socket} ->
        try do
          case Abyss.Transport.UDP.send(socket, multicast_addr, @mdns_port, binary) do
            :ok ->
              responses = collect_responses(socket, timeout, [])
              {:ok, responses}

            {:error, reason} ->
              {:error, reason}
          end
        after
          Abyss.Transport.UDP.close(socket)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Send an mDNS query and return raw binary responses.

  ## Parameters

  Same as `query/3`.

  ## Returns

  - `{:ok, [binary()]}` - List of raw response binaries
  - `{:error, reason}` - Error
  """
  @spec query_raw(String.t(), atom(), query_opts()) :: {:ok, [binary()]} | {:error, term()}
  def query_raw(name, type, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    use_ipv6 = Keyword.get(opts, :ipv6, false)

    message = build_query(name, type)
    binary = DNS.to_iodata(message) |> IO.iodata_to_binary()

    multicast_addr = if use_ipv6, do: @mdns_ipv6_addr, else: @mdns_ipv4_addr

    socket_opts = build_socket_opts(opts, use_ipv6)

    case open_multicast_socket(socket_opts, use_ipv6) do
      {:ok, socket} ->
        try do
          case Abyss.Transport.UDP.send(socket, multicast_addr, @mdns_port, binary) do
            :ok ->
              responses = collect_raw_responses(socket, timeout, [])
              {:ok, responses}

            {:error, reason} ->
              {:error, reason}
          end
        after
          Abyss.Transport.UDP.close(socket)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Discover services of a specific type on the local network.

  Sends a PTR query for the service type and collects responses.

  ## Parameters

  - `service_type` - Service type (e.g., "_http._tcp.local", "_ssh._tcp.local")
  - `opts` - Optional keyword list (same as `query/3`)

  ## Returns

  - `{:ok, [map()]}` - List of discovered services with name, host, port, txt
  - `{:error, reason}` - Error

  ## Examples

      # Discover HTTP services
      {:ok, services} = YellowDog.Mdns.Client.discover("_http._tcp.local")
      # => [{name: "My Web Server", host: "server.local", port: 80, ...}]

      # Discover SSH services
      {:ok, services} = YellowDog.Mdns.Client.discover("_ssh._tcp.local")
  """
  @spec discover(String.t(), query_opts()) :: {:ok, [map()]} | {:error, term()}
  def discover(service_type, opts \\ []) do
    # First, query for PTR records to find service instances
    case query(service_type, :ptr, opts) do
      {:ok, responses} ->
        # Extract service instance names from PTR records
        instances = extract_ptr_targets(responses)

        # Query for SRV and TXT records for each instance
        services =
          for name <- instances,
              svc = fetch_service_details(name, opts),
              svc != nil,
              do: svc

        {:ok, services}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Browse for all available service types on the network.

  Queries for `_services._dns-sd._udp.local` to discover service types.

  ## Parameters

  - `opts` - Optional keyword list (same as `query/3`)

  ## Returns

  - `{:ok, [String.t()]}` - List of service types (e.g., ["_http._tcp.local", "_ssh._tcp.local"])
  - `{:error, reason}` - Error

  ## Examples

      {:ok, types} = YellowDog.Mdns.Client.browse()
      # => ["_http._tcp.local", "_ssh._tcp.local", "_airplay._tcp.local"]
  """
  @spec browse(query_opts()) :: {:ok, [String.t()]} | {:error, term()}
  def browse(opts \\ []) do
    case query("_services._dns-sd._udp.local", :ptr, opts) do
      {:ok, responses} ->
        types = extract_ptr_targets(responses)
        {:ok, types}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resolve a hostname to IP addresses.

  Queries for both A and AAAA records.

  ## Parameters

  - `hostname` - Hostname to resolve (e.g., "mydevice.local")
  - `opts` - Optional keyword list (same as `query/3`)

  ## Returns

  - `{:ok, %{ipv4: [...], ipv6: [...]}}` - Map with resolved addresses
  - `{:error, reason}` - Error

  ## Examples

      {:ok, addrs} = YellowDog.Mdns.Client.resolve("printer.local")
      # => %{ipv4: [{192, 168, 1, 100}], ipv6: []}
  """
  @spec resolve(String.t(), query_opts()) :: {:ok, map()} | {:error, term()}
  def resolve(hostname, opts \\ []) do
    # Query for A records
    ipv4_addrs =
      case query(hostname, :a, opts) do
        {:ok, responses} -> extract_a_records(responses)
        {:error, _} -> []
      end

    # Query for AAAA records
    ipv6_addrs =
      case query(hostname, :aaaa, opts) do
        {:ok, responses} -> extract_aaaa_records(responses)
        {:error, _} -> []
      end

    {:ok, %{ipv4: ipv4_addrs, ipv6: ipv6_addrs}}
  end

  @doc """
  Send a pre-built DNS message as an mDNS query.

  ## Parameters

  - `message` - `%DNS.Message{}` struct
  - `opts` - Optional keyword list (same as `query/3`)

  ## Returns

  - `{:ok, [%DNS.Message{}]}` - List of response messages
  - `{:error, reason}` - Error
  """
  @spec send_message(Message.t(), query_opts()) :: {:ok, [Message.t()]} | {:error, term()}
  def send_message(message, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    use_ipv6 = Keyword.get(opts, :ipv6, false)

    binary = DNS.to_iodata(message) |> IO.iodata_to_binary()

    multicast_addr = if use_ipv6, do: @mdns_ipv6_addr, else: @mdns_ipv4_addr

    socket_opts = build_socket_opts(opts, use_ipv6)

    case open_multicast_socket(socket_opts, use_ipv6) do
      {:ok, socket} ->
        try do
          case Abyss.Transport.UDP.send(socket, multicast_addr, @mdns_port, binary) do
            :ok ->
              responses = collect_responses(socket, timeout, [])
              {:ok, responses}

            {:error, reason} ->
              {:error, reason}
          end
        after
          Abyss.Transport.UDP.close(socket)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Send an mDNS announcement (no response expected).

  Used to announce services or goodbye packets.

  ## Parameters

  - `message` - `%DNS.Message{}` struct to send
  - `opts` - Optional keyword list:
    - `:interface` - Network interface to use
    - `:ipv6` - Use IPv6 multicast (default: false)

  ## Returns

  - `:ok` - Message sent
  - `{:error, reason}` - Error
  """
  @spec announce(Message.t(), query_opts()) :: :ok | {:error, term()}
  def announce(message, opts \\ []) do
    use_ipv6 = Keyword.get(opts, :ipv6, false)

    binary = DNS.to_iodata(message) |> IO.iodata_to_binary()

    multicast_addr = if use_ipv6, do: @mdns_ipv6_addr, else: @mdns_ipv4_addr

    # Use Abyss.Client.broadcast for announcements
    Abyss.Client.broadcast(multicast_addr, @mdns_port, binary, ttl: @mdns_multicast_ttl)
  end

  # Private functions

  defp build_query(name, type) do
    question = %Question{
      name: name,
      type: type,
      class: :in
    }

    %Message{
      header: %Header{
        id: 0,
        qr: 0,
        opcode: 0,
        aa: 0,
        tc: 0,
        rd: 0,
        ra: 0,
        rcode: 0
      },
      qdlist: [question],
      anlist: [],
      nslist: [],
      arlist: []
    }
  end

  defp build_socket_opts(opts, use_ipv6) do
    base_opts = [:binary, {:active, false}, {:reuseaddr, true}]

    base_opts =
      if use_ipv6 do
        [:inet6 | base_opts]
      else
        base_opts
      end

    case Keyword.get(opts, :interface) do
      nil ->
        base_opts

      iface when is_binary(iface) ->
        # Try to resolve interface name to IP
        case Abyss.Client.resolve_interface_ip(iface) do
          {:ok, ip} -> [{:ip, ip} | base_opts]
          {:error, _} -> base_opts
        end

      ip when is_tuple(ip) ->
        [{:ip, ip} | base_opts]
    end
  end

  defp open_multicast_socket(opts, use_ipv6) do
    multicast_addr = if use_ipv6, do: @mdns_ipv6_addr, else: @mdns_ipv4_addr

    # Add multicast options
    multicast_opts =
      if use_ipv6 do
        [
          {:add_membership, {multicast_addr, {0, 0, 0, 0, 0, 0, 0, 0}}},
          {:multicast_loop, true},
          {:multicast_ttl, @mdns_multicast_ttl}
        ]
      else
        [
          {:add_membership, {multicast_addr, {0, 0, 0, 0}}},
          {:multicast_loop, true},
          {:multicast_ttl, @mdns_multicast_ttl}
        ]
      end

    all_opts = opts ++ multicast_opts

    Abyss.Transport.UDP.open(@mdns_port, all_opts)
  end

  defp collect_responses(socket, timeout, acc) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect_responses(socket, deadline, acc)
  end

  defp do_collect_responses(socket, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      case Abyss.Transport.UDP.recv(socket, 0, remaining) do
        {:ok, {_ip, _port, data}} ->
          case parse_response(data) do
            {:ok, message} ->
              do_collect_responses(socket, deadline, [message | acc])

            {:error, _} ->
              do_collect_responses(socket, deadline, acc)
          end

        {:error, :timeout} ->
          Enum.reverse(acc)

        {:error, _reason} ->
          Enum.reverse(acc)
      end
    end
  end

  defp collect_raw_responses(socket, timeout, acc) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect_raw_responses(socket, deadline, acc)
  end

  defp do_collect_raw_responses(socket, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      case Abyss.Transport.UDP.recv(socket, 0, remaining) do
        {:ok, {_ip, _port, data}} ->
          do_collect_raw_responses(socket, deadline, [data | acc])

        {:error, :timeout} ->
          Enum.reverse(acc)

        {:error, _reason} ->
          Enum.reverse(acc)
      end
    end
  end

  defp parse_response(binary) do
    try do
      message = DNS.Message.from_iodata(binary)
      {:ok, message}
    rescue
      e -> {:error, {:parse_error, Exception.message(e)}}
    catch
      :throw, reason ->
        {:error, {:parse_error, inspect(reason)}}
    end
  end

  defp extract_ptr_targets(responses) do
    for msg <- responses,
        record <- msg.anlist,
        to_string(record.type) == "PTR",
        uniq: true,
        do: to_string(record.data)
  end

  defp extract_a_records(responses) do
    for msg <- responses,
        record <- msg.anlist ++ msg.arlist,
        to_string(record.type) == "A",
        uniq: true,
        do: record.data
  end

  defp extract_aaaa_records(responses) do
    for msg <- responses,
        record <- msg.anlist ++ msg.arlist,
        to_string(record.type) == "AAAA",
        uniq: true,
        do: record.data
  end

  defp fetch_service_details(instance_name, opts) do
    # Query for SRV record to get host and port
    srv_info =
      case query(instance_name, :srv, opts) do
        {:ok, responses} ->
          extract_srv_record(responses)

        {:error, _} ->
          nil
      end

    # Query for TXT record to get metadata
    txt_info =
      case query(instance_name, :txt, opts) do
        {:ok, responses} ->
          extract_txt_record(responses)

        {:error, _} ->
          %{}
      end

    case srv_info do
      nil ->
        nil

      %{host: host, port: port, priority: priority, weight: weight} ->
        %{
          name: instance_name,
          host: host,
          port: port,
          priority: priority,
          weight: weight,
          txt: txt_info
        }
    end
  end

  defp extract_srv_record(responses) do
    Enum.find_value(responses, fn msg ->
      Enum.find_value(msg.anlist ++ msg.arlist, fn record ->
        if to_string(record.type) == "SRV" do
          case record.data do
            %{target: target, port: port, priority: priority, weight: weight} ->
              %{host: to_string(target), port: port, priority: priority, weight: weight}

            _ ->
              nil
          end
        end
      end)
    end)
  end

  defp extract_txt_record(responses) do
    responses
    |> Enum.flat_map(fn msg -> msg.anlist ++ msg.arlist end)
    |> Enum.filter(fn record -> to_string(record.type) == "TXT" end)
    |> Enum.flat_map(fn record ->
      case record.data do
        list when is_list(list) ->
          Enum.map(list, fn entry ->
            case String.split(to_string(entry), "=", parts: 2) do
              [key, value] -> {key, value}
              [key] -> {key, ""}
            end
          end)

        _ ->
          []
      end
    end)
    |> Map.new()
  end
end
