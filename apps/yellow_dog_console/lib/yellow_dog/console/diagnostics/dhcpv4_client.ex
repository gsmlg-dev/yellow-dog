defmodule YellowDog.Console.Diagnostics.Dhcpv4Client do
  @moduledoc """
  DHCPv4 broadcast query client for diagnostic testing.

  Uses `DHCPv4.Client` for message building.
  Sends DHCPv4 messages to the broadcast address 255.255.255.255:67
  and waits for responses on port 68.

  Note: Port 68 requires root/admin privileges.
  """

  alias YellowDog.Console.Diagnostics.QueryResult

  alias YellowDog.Console.Diagnostics.ParamHelper
  import ParamHelper, except: [format_error: 1]

  @dhcp_server_port 67
  @dhcp_client_port 68
  @broadcast_addr {255, 255, 255, 255}

  @doc """
  Returns true - DHCPv4 client port 68 requires root/admin privileges.
  """
  @spec requires_privileged_port?() :: boolean()
  def requires_privileged_port?, do: true

  @doc """
  Sends a DHCPv4 message and returns the result.

  ## Parameters

    * `params` - Map with query parameters:
      * `:message_type` - Message type (discover, request, decline, release, inform)
      * `:client_mac` - Client MAC address (xx:xx:xx:xx:xx:xx) or empty for auto-gen
      * `:transaction_id` - Transaction ID (hex string) or empty for auto-gen
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
         {:ok, response_binary} <- execute_broadcast_query(parsed_params, request_binary),
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
         client_mac: parse_mac(get_string(params, :client_mac)),
         transaction_id: parse_xid(get_string(params, :transaction_id)),
         requested_options: parse_options(get_string(params, :requested_options)),
         timeout: get_integer(params, :timeout, 10000)
       }}
    rescue
      e -> {:error, {:parse_error, Exception.message(e)}}
    end
  end

  @dhcpv4_message_types %{
    "discover" => :discover, "request" => :request, "decline" => :decline,
    "release" => :release, "inform" => :inform
  }

  defp parse_message_type(type) when is_atom(type), do: type
  defp parse_message_type(type), do: Map.get(@dhcpv4_message_types, type, :discover)

  defp parse_mac(""), do: generate_mac()

  defp parse_mac(mac_string) when is_binary(mac_string) do
    parts = String.split(mac_string, ":")

    case parts do
      [_, _, _, _, _, _] ->
        hex = parts |> Enum.map_join(&String.pad_leading(&1, 2, "0")) |> String.upcase()

        case Base.decode16(hex) do
          {:ok, bytes} -> bytes
          :error -> generate_mac()
        end

      _ ->
        generate_mac()
    end
  end

  defp parse_mac(mac) when is_binary(mac) and byte_size(mac) == 6, do: mac
  defp parse_mac(_), do: generate_mac()

  defp generate_mac do
    DHCP.SecureRandom.generate_bytes(6)
  end

  defp parse_xid(""), do: generate_xid()

  defp parse_xid(xid_string) when is_binary(xid_string) do
    case Base.decode16(xid_string, case: :mixed) do
      {:ok, <<xid::32>>} -> xid
      {:ok, binary} when byte_size(binary) >= 4 -> :binary.decode_unsigned(binary)
      _ -> generate_xid()
    end
  end

  defp parse_xid(xid) when is_integer(xid), do: xid
  defp parse_xid(_), do: generate_xid()

  defp generate_xid do
    :rand.uniform(0xFFFFFFFF)
  end

  defp parse_options(""), do: [1, 3, 6, 15]

  defp parse_options(options_string) when is_binary(options_string) do
    options_string
    |> String.split(",")
    |> Enum.map(fn s -> s |> String.trim() |> String.to_integer() end)
  rescue
    _ -> [1, 3, 6, 15]
  end

  defp parse_options(options) when is_list(options), do: options
  defp parse_options(_), do: [1, 3, 6, 15]

  defp build_message(params) do
    try do
      # Use YellowDog.Dhcpv4.Client's underlying DHCPv4.Client for message building
      message =
        case params.message_type do
          :discover ->
            DHCPv4.Client.discover(mac: params.client_mac, xid: params.transaction_id)

          :request ->
            DHCPv4.Client.request(
              mac: params.client_mac,
              xid: params.transaction_id,
              server_ip: @broadcast_addr,
              requested_ip: {0, 0, 0, 0}
            )

          :release ->
            DHCPv4.Client.release(
              mac: params.client_mac,
              xid: params.transaction_id,
              server_ip: @broadcast_addr,
              leased_ip: {0, 0, 0, 0}
            )

          :decline ->
            DHCPv4.Client.decline(
              mac: params.client_mac,
              xid: params.transaction_id,
              server_ip: @broadcast_addr,
              declined_ip: {0, 0, 0, 0}
            )

          _ ->
            DHCPv4.Client.discover(mac: params.client_mac, xid: params.transaction_id)
        end

      {:ok, message}
    rescue
      e -> {:error, {:build_error, Exception.message(e)}}
    end
  end

  defp build_message_unsafe(params) do
    try do
      client_mac = parse_mac(get_string(params, :client_mac))
      xid = parse_xid(get_string(params, :transaction_id))

      DHCPv4.Client.discover(mac: client_mac, xid: xid)
    rescue
      _ -> nil
    end
  end

  defp execute_broadcast_query(params, request_binary) do
    # Use YellowDog.Dhcpv4.Client's transport logic via direct socket
    # (we need raw response binary for hex display)
    socket_opts = [
      :binary,
      active: false,
      broadcast: true,
      reuseaddr: true
    ]

    case :gen_udp.open(@dhcp_client_port, socket_opts) do
      {:ok, socket} ->
        try do
          :gen_udp.send(socket, @broadcast_addr, @dhcp_server_port, request_binary)

          case :gen_udp.recv(socket, 0, params.timeout) do
            {:ok, {_ip, _port, response}} -> {:ok, response}
            {:error, :timeout} -> {:error, :timeout}
            {:error, reason} -> {:error, {:socket_error, reason}}
          end
        after
          :gen_udp.close(socket)
        end

      {:error, :eaddrinuse} ->
        # Port 68 in use, try ephemeral port via Dhcpv4Client
        execute_via_client(params, request_binary)

      {:error, :eacces} ->
        {:error, {:socket_error, :eacces}}

      {:error, reason} ->
        {:error, {:socket_error, reason}}
    end
  end

  # Fallback to ephemeral port when port 68 is unavailable
  defp execute_via_client(params, request_binary) do
    socket_opts = [:binary, active: false, broadcast: true]

    case :gen_udp.open(0, socket_opts) do
      {:ok, socket} ->
        try do
          :gen_udp.send(socket, @broadcast_addr, @dhcp_server_port, request_binary)

          case :gen_udp.recv(socket, 0, params.timeout) do
            {:ok, {_ip, _port, response}} -> {:ok, response}
            {:error, :timeout} -> {:error, :timeout}
            {:error, reason} -> {:error, {:socket_error, reason}}
          end
        after
          :gen_udp.close(socket)
        end

      {:error, reason} ->
        {:error, {:socket_error, reason}}
    end
  end

  defp parse_response(response_binary) do
    try do
      message = DHCPv4.Message.from_iodata(response_binary)
      {:ok, message}
    rescue
      e -> {:error, {:parse_error, Exception.message(e)}}
    end
  end

  defp format_error({:socket_error, :eacces}), do: "Permission denied (port 68 requires root)"
  defp format_error(reason), do: ParamHelper.format_error(reason)
end
