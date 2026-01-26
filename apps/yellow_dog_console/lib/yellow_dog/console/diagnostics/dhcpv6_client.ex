defmodule YellowDog.Console.Diagnostics.Dhcpv6Client do
  @moduledoc """
  DHCPv6 multicast query client for diagnostic testing.

  Uses `DHCPv6.Client` for message building.
  Sends DHCPv6 messages to the multicast address ff02::1:2 port 547
  and waits for responses on port 546.

  Note: Port 546 requires root/admin privileges.
  """

  alias YellowDog.Console.Diagnostics.QueryResult

  @dhcpv6_server_port 547
  @dhcpv6_client_port 546
  # ff02::1:2 - All DHCP Relay Agents and Servers
  @multicast_addr {0xFF02, 0, 0, 0, 0, 0, 1, 2}

  @doc """
  Returns true - DHCPv6 client port 546 requires root/admin privileges.
  """
  @spec requires_privileged_port?() :: boolean()
  def requires_privileged_port?, do: true

  @doc """
  Sends a DHCPv6 message and returns the result.

  ## Parameters

    * `params` - Map with query parameters:
      * `:message_type` - Message type (solicit, request, renew, rebind, release, decline, information_request)
      * `:duid` - Client DUID (hex string) or empty for auto-gen
      * `:transaction_id` - Transaction ID (hex string) or empty for auto-gen
      * `:iaid` - Identity Association ID (hex string) or empty for auto-gen
      * `:requested_options` - Comma-separated list of option codes
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
         request_binary <- DHCP.to_iodata(message) |> IO.iodata_to_binary(),
         {:ok, response_binary} <- execute_multicast_query(parsed_params, request_binary),
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
          if message, do: DHCP.to_iodata(message) |> IO.iodata_to_binary(), else: <<>>

        result = QueryResult.timeout(params, message, request_binary, latency)
        {:ok, result}

      {:error, reason} ->
        latency = System.monotonic_time(:millisecond) - start_time
        message = build_message_unsafe(params)

        request_binary =
          if message, do: DHCP.to_iodata(message) |> IO.iodata_to_binary(), else: <<>>

        result = QueryResult.error(params, message, request_binary, format_error(reason), latency)
        {:ok, result}
    end
  end

  defp parse_params(params) do
    try do
      {:ok,
       %{
         message_type: parse_message_type(get_string(params, :message_type)),
         duid: parse_duid(get_string(params, :duid)),
         transaction_id: parse_xid(get_string(params, :transaction_id)),
         iaid: parse_iaid(get_string(params, :iaid)),
         requested_options: parse_options(get_string(params, :requested_options)),
         timeout: get_integer(params, :timeout, 10000)
       }}
    rescue
      e -> {:error, {:parse_error, Exception.message(e)}}
    end
  end

  defp get_string(params, key) do
    Map.get(params, key) || Map.get(params, to_string(key)) || ""
  end

  defp get_integer(params, key, default) do
    value = Map.get(params, key) || Map.get(params, to_string(key)) || default

    case value do
      v when is_integer(v) -> v
      v when is_binary(v) -> String.to_integer(v)
      _ -> default
    end
  end

  defp parse_message_type("solicit"), do: :solicit
  defp parse_message_type("request"), do: :request
  defp parse_message_type("renew"), do: :renew
  defp parse_message_type("rebind"), do: :rebind
  defp parse_message_type("release"), do: :release
  defp parse_message_type("decline"), do: :decline
  defp parse_message_type("information_request"), do: :information_request
  defp parse_message_type(type) when is_atom(type), do: type
  defp parse_message_type(_), do: :solicit

  defp parse_duid(""), do: generate_duid()

  defp parse_duid(duid_string) when is_binary(duid_string) do
    case Base.decode16(duid_string, case: :mixed) do
      {:ok, binary} -> binary
      :error -> generate_duid()
    end
  end

  defp parse_duid(_), do: generate_duid()

  defp generate_duid do
    # DUID-LLT format: type(2) + hw_type(2) + time(4) + link_layer(6)
    DHCP.SecureRandom.generate_bytes(14)
  end

  defp parse_xid(""), do: generate_xid()

  defp parse_xid(xid_string) when is_binary(xid_string) do
    case Base.decode16(xid_string, case: :mixed) do
      {:ok, <<xid::24>>} ->
        xid

      {:ok, binary} when byte_size(binary) >= 3 ->
        <<xid::24, _rest::binary>> = binary
        xid

      _ ->
        generate_xid()
    end
  end

  defp parse_xid(xid) when is_integer(xid), do: xid
  defp parse_xid(_), do: generate_xid()

  defp generate_xid do
    :rand.uniform(0xFFFFFF)
  end

  defp parse_iaid(""), do: generate_iaid()

  defp parse_iaid(iaid_string) when is_binary(iaid_string) do
    case Base.decode16(iaid_string, case: :mixed) do
      {:ok, <<iaid::32>>} -> iaid
      {:ok, binary} when byte_size(binary) >= 4 -> :binary.decode_unsigned(binary)
      _ -> generate_iaid()
    end
  end

  defp parse_iaid(iaid) when is_integer(iaid), do: iaid
  defp parse_iaid(_), do: generate_iaid()

  defp generate_iaid do
    :rand.uniform(0xFFFFFFFF)
  end

  defp parse_options(""), do: [23]

  defp parse_options(options_string) when is_binary(options_string) do
    options_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_integer/1)
  rescue
    _ -> [23]
  end

  defp parse_options(options) when is_list(options), do: options
  defp parse_options(_), do: [23]

  defp build_message(params) do
    try do
      # Use YellowDog.Dhcpv6.Client's underlying DHCPv6.Client for message building
      message =
        case params.message_type do
          :solicit ->
            DHCPv6.Client.solicit(
              duid: params.duid,
              iaid: params.iaid,
              transaction_id: params.transaction_id
            )

          :information_request ->
            DHCPv6.Client.information_request(
              duid: params.duid,
              transaction_id: params.transaction_id
            )

          _ ->
            DHCPv6.Client.solicit(
              duid: params.duid,
              iaid: params.iaid,
              transaction_id: params.transaction_id
            )
        end

      {:ok, message}
    rescue
      e -> {:error, {:build_error, Exception.message(e)}}
    end
  end

  defp build_message_unsafe(params) do
    try do
      duid = parse_duid(get_string(params, :duid))
      xid = parse_xid(get_string(params, :transaction_id))
      iaid = parse_iaid(get_string(params, :iaid))

      DHCPv6.Client.solicit(duid: duid, iaid: iaid, transaction_id: xid)
    rescue
      _ -> nil
    end
  end

  defp execute_multicast_query(params, request_binary) do
    # Use :socket for IPv6 multicast (we need raw response binary for hex display)
    case :socket.open(:inet6, :dgram, :udp) do
      {:ok, socket} ->
        try do
          :socket.setopt(socket, {:ipv6, :multicast_hops}, 1)
          :socket.setopt(socket, {:socket, :reuseaddr}, true)

          case :socket.bind(socket, %{family: :inet6, port: @dhcpv6_client_port, addr: :any}) do
            :ok ->
              dest = %{family: :inet6, port: @dhcpv6_server_port, addr: @multicast_addr}
              :socket.sendto(socket, request_binary, dest)

              case :socket.recvfrom(socket, 0, [], params.timeout) do
                {:ok, {_source, response}} -> {:ok, response}
                {:error, :timeout} -> {:error, :timeout}
                {:error, reason} -> {:error, {:socket_error, reason}}
              end

            {:error, :eaddrinuse} ->
              # Port 546 in use, try ephemeral port
              execute_via_ephemeral(socket, request_binary, params.timeout)

            {:error, :eacces} ->
              {:error, {:socket_error, :eacces}}

            {:error, reason} ->
              {:error, {:socket_error, reason}}
          end
        after
          :socket.close(socket)
        end

      {:error, reason} ->
        {:error, {:socket_error, reason}}
    end
  end

  # Fallback to ephemeral port when port 546 is unavailable
  defp execute_via_ephemeral(socket, request_binary, timeout) do
    case :socket.bind(socket, %{family: :inet6, port: 0, addr: :any}) do
      :ok ->
        dest = %{family: :inet6, port: @dhcpv6_server_port, addr: @multicast_addr}
        :socket.sendto(socket, request_binary, dest)

        case :socket.recvfrom(socket, 0, [], timeout) do
          {:ok, {_source, response}} -> {:ok, response}
          {:error, :timeout} -> {:error, :timeout}
          {:error, reason} -> {:error, {:socket_error, reason}}
        end

      {:error, reason} ->
        {:error, {:socket_error, reason}}
    end
  end

  defp parse_response(response_binary) do
    try do
      message = DHCPv6.Message.from_iodata(response_binary)
      {:ok, message}
    rescue
      e -> {:error, {:parse_error, Exception.message(e)}}
    end
  end

  defp format_error(:timeout), do: "Query timed out"
  defp format_error({:socket_error, :eacces}), do: "Permission denied (port 546 requires root)"
  defp format_error({:socket_error, reason}), do: "Socket error: #{inspect(reason)}"
  defp format_error({:parse_error, msg}), do: "Parse error: #{msg}"
  defp format_error({:build_error, msg}), do: "Build error: #{msg}"
  defp format_error(reason), do: inspect(reason)
end
