defmodule YellowDog.Console.Diagnostics.DnsClient do
  @moduledoc """
  DNS query client for diagnostic testing.

  Sends DNS queries using UDP or TCP via `YellowDog.Dns.Client` and returns
  parsed results with timing information.
  """

  alias YellowDog.Console.Diagnostics.QueryResult
  alias YellowDog.Dns.Client, as: DnsClient

  alias YellowDog.Console.Diagnostics.ParamHelper
  import ParamHelper, except: [format_error: 1]

  @doc """
  Sends a DNS query and returns the result.

  ## Parameters

    * `params` - Map with query parameters:
      * `:query_name` - Domain name to query
      * `:record_type` - Record type (a, aaaa, mx, txt, etc.)
      * `:server` - DNS server IP address
      * `:port` - DNS server port (default 53)
      * `:protocol` - :udp or :tcp
      * `:recursion_desired` - Boolean
      * `:timeout` - Query timeout in milliseconds

  ## Returns

    * `{:ok, %QueryResult{}}` on success
    * `{:error, reason}` on failure
  """
  @spec query(map()) :: {:ok, QueryResult.t()} | {:error, term()}
  def query(params) do
    start_time = System.monotonic_time(:millisecond)

    with {:ok, parsed_params} <- parse_params(params),
         {:ok, message} <- build_message(parsed_params),
         request_binary <- DNS.to_iodata(message) |> IO.iodata_to_binary(),
         {:ok, response_binary} <- execute_query(parsed_params, request_binary),
         {:ok, response} <- parse_response(response_binary) do
      latency = System.monotonic_time(:millisecond) - start_time

      result =
        QueryResult.success(
          params,
          message,
          request_binary,
          response,
          response_binary,
          latency
        )

      {:ok, result}
    else
      {:error, :timeout} ->
        latency = System.monotonic_time(:millisecond) - start_time
        message = build_message_unsafe(params)

        request_binary =
          if message, do: DNS.to_iodata(message) |> IO.iodata_to_binary(), else: <<>>

        result = QueryResult.timeout(params, message, request_binary, latency)
        {:ok, result}

      {:error, reason} ->
        latency = System.monotonic_time(:millisecond) - start_time
        message = build_message_unsafe(params)

        request_binary =
          if message, do: DNS.to_iodata(message) |> IO.iodata_to_binary(), else: <<>>

        result = QueryResult.error(params, message, request_binary, format_error(reason), latency)
        {:ok, result}
    end
  end

  # Parameter parsing

  defp parse_params(params) do
    try do
      query_name = get_string(params, :query_name)

      # Validate query name - empty or whitespace-only names are invalid
      if query_name == "" or String.trim(query_name) == "" do
        {:error, {:invalid_query_name, "Query name cannot be empty"}}
      else
        {:ok,
         %{
           query_name: query_name,
           record_type: parse_record_type(get_string(params, :record_type)),
           server: parse_ip(get_string(params, :server)),
           port: get_integer(params, :port, 53),
           protocol: parse_protocol(get_string(params, :protocol)),
           recursion_desired: get_boolean(params, :recursion_desired, true),
           timeout: get_integer(params, :timeout, 5000)
         }}
      end
    rescue
      e -> {:error, {:parse_error, Exception.message(e)}}
    end
  end

  @valid_record_types ~w(a aaaa cname mx ns ptr soa srv txt naptr caa dnskey ds rrsig nsec)
  defp parse_record_type(type) when is_binary(type) do
    downcased = String.downcase(type)
    if downcased in @valid_record_types, do: String.to_existing_atom(downcased), else: :a
  end

  defp parse_record_type(type) when is_atom(type), do: type

  @protocols %{"udp" => :udp, "tcp" => :tcp, udp: :udp, tcp: :tcp}

  defp parse_protocol(proto), do: Map.get(@protocols, proto, :udp)

  defp parse_ip(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip} -> ip
      {:error, _} -> {127, 0, 0, 1}
    end
  end

  defp parse_ip(ip) when is_tuple(ip), do: ip
  defp parse_ip(_), do: {127, 0, 0, 1}

  # Message building

  defp build_message(params) do
    try do
      question = DNS.Message.Question.new(params.query_name, params.record_type, :in)
      rd_value = if params.recursion_desired, do: 1, else: 0

      message =
        DNS.Message.new()
        |> DNS.Message.add_question(question)
        |> DNS.Message.update_header_attr(:rd, rd_value)

      {:ok, message}
    rescue
      e -> {:error, {:build_error, Exception.message(e)}}
    end
  end

  defp build_message_unsafe(params) do
    try do
      query_name = get_string(params, :query_name)
      record_type = parse_record_type(get_string(params, :record_type))
      question = DNS.Message.Question.new(query_name, record_type, :in)

      DNS.Message.new()
      |> DNS.Message.add_question(question)
      |> DNS.Message.update_header_attr(:rd, 1)
    rescue
      _ -> nil
    end
  end

  # Query execution - delegates to YellowDog.Dns.Client

  defp execute_query(%{protocol: :udp} = params, _request_binary) do
    # Use YellowDog.Dns.Client.query_raw for UDP queries
    opts = [
      port: params.port,
      timeout: params.timeout,
      recursion_desired: params.recursion_desired
    ]

    case DnsClient.query_raw(params.query_name, params.record_type, params.server, opts) do
      {:ok, response} -> {:ok, response}
      {:error, :timeout} -> {:error, :timeout}
      {:error, reason} -> {:error, {:socket_error, reason}}
    end
  end

  defp execute_query(%{protocol: :tcp} = params, request_binary) do
    # TCP queries still use direct gen_tcp (YellowDog.Dns.Client is UDP-only)
    query_tcp(params, request_binary)
  end

  defp query_tcp(params, request_binary) do
    # DNS over TCP uses 2-byte length prefix
    length_prefix = <<byte_size(request_binary)::16>>
    tcp_message = length_prefix <> request_binary

    opts = [:binary, active: false, packet: 2]

    case :gen_tcp.connect(params.server, params.port, opts, params.timeout) do
      {:ok, socket} ->
        try do
          :gen_tcp.send(socket, tcp_message)

          case :gen_tcp.recv(socket, 0, params.timeout) do
            {:ok, response} -> {:ok, response}
            {:error, :timeout} -> {:error, :timeout}
            {:error, reason} -> {:error, {:socket_error, reason}}
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, reason} ->
        {:error, {:socket_error, reason}}
    end
  end

  # Response parsing

  defp parse_response(response_binary) do
    try do
      message = DNS.Message.from_iodata(response_binary)
      {:ok, message}
    rescue
      e -> {:error, {:parse_error, Exception.message(e)}}
    catch
      :throw, {reason, _details} when is_binary(reason) ->
        {:error, {:parse_error, reason}}

      :throw, reason ->
        {:error, {:parse_error, inspect(reason)}}
    end
  end

  defp format_error({:socket_error, :eacces}), do: "Permission denied"
  defp format_error({:socket_error, :econnrefused}), do: "Connection refused"
  defp format_error(reason), do: ParamHelper.format_error(reason)
end
