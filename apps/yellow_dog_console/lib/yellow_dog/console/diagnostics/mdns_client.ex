defmodule YellowDog.Console.Diagnostics.MdnsClient do
  @moduledoc """
  mDNS multicast query client for diagnostic testing.

  Sends mDNS queries to the multicast address 224.0.0.251:5353
  and collects responses from multiple sources until timeout.
  """

  alias YellowDog.Console.Diagnostics.QueryResult

  @mdns_multicast_addr {224, 0, 0, 251}
  @mdns_port 5353

  @doc """
  Sends an mDNS query and returns collected responses.

  ## Parameters

    * `params` - Map with query parameters:
      * `:service_type` - Service type to query (e.g., "_http._tcp.local")
      * `:query_type` - Record type (ptr, srv, txt, a, aaaa)
      * `:timeout` - Query timeout in milliseconds

  ## Returns

    * `{:ok, %QueryResult{}}` with sources list containing multiple responses
  """
  @spec query(map()) :: {:ok, QueryResult.t()} | {:error, term()}
  def query(params) do
    start_time = System.monotonic_time(:millisecond)

    with {:ok, parsed_params} <- parse_params(params),
         {:ok, message} <- build_message(parsed_params),
         request_binary <- DNS.to_iodata(message) |> IO.iodata_to_binary(),
         {:ok, sources} <- execute_multicast_query(parsed_params, request_binary) do
      latency = System.monotonic_time(:millisecond) - start_time

      result =
        QueryResult.multicast_success(
          params,
          message,
          request_binary,
          sources,
          latency
        )

      {:ok, result}
    else
      {:error, reason} ->
        latency = System.monotonic_time(:millisecond) - start_time
        message = build_message_unsafe(params)

        request_binary =
          if message, do: DNS.to_iodata(message) |> IO.iodata_to_binary(), else: <<>>

        result = QueryResult.error(params, message, request_binary, format_error(reason), latency)
        {:ok, result}
    end
  end

  defp parse_params(params) do
    try do
      {:ok,
       %{
         service_type: get_string(params, :service_type),
         query_type: parse_record_type(get_string(params, :query_type)),
         timeout: get_integer(params, :timeout, 3000)
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

      v when is_binary(v) ->
        case Integer.parse(v) do
          {int, ""} -> int
          _ -> default
        end

      _ ->
        default
    end
  end

  defp parse_record_type(type) when is_binary(type) do
    type
    |> String.downcase()
    |> String.to_existing_atom()
  rescue
    _ -> :ptr
  end

  defp parse_record_type(type) when is_atom(type), do: type

  defp build_message(params) do
    try do
      question = DNS.Message.Question.new(params.service_type, params.query_type, :in)

      message =
        DNS.Message.new()
        |> DNS.Message.add_question(question)
        |> DNS.Message.update_header_attr(:id, 0)
        |> DNS.Message.update_header_attr(:rd, 0)

      {:ok, message}
    rescue
      e -> {:error, {:build_error, Exception.message(e)}}
    end
  end

  defp build_message_unsafe(params) do
    try do
      service_type = get_string(params, :service_type)
      query_type = parse_record_type(get_string(params, :query_type))
      question = DNS.Message.Question.new(service_type, query_type, :in)

      DNS.Message.new()
      |> DNS.Message.add_question(question)
      |> DNS.Message.update_header_attr(:id, 0)
      |> DNS.Message.update_header_attr(:rd, 0)
    rescue
      _ -> nil
    end
  end

  defp execute_multicast_query(params, request_binary) do
    # We need source address info (IP, port) for diagnostics display,
    # so we keep the direct socket approach here rather than using
    # MdnsClient.query_raw which doesn't preserve source info
    socket_opts = [
      :binary,
      active: false,
      multicast_ttl: 255,
      multicast_loop: true,
      reuseaddr: true
    ]

    case :gen_udp.open(0, socket_opts) do
      {:ok, socket} ->
        try do
          :gen_udp.send(socket, @mdns_multicast_addr, @mdns_port, request_binary)
          sources = collect_responses(socket, params.timeout, [])
          {:ok, sources}
        after
          :gen_udp.close(socket)
        end

      {:error, reason} ->
        {:error, {:socket_error, reason}}
    end
  end

  defp collect_responses(socket, timeout, acc) when timeout > 0 do
    start = System.monotonic_time(:millisecond)

    case :gen_udp.recv(socket, 0, timeout) do
      {:ok, {address, port, response_binary}} ->
        elapsed = System.monotonic_time(:millisecond) - start
        remaining = max(0, timeout - elapsed)

        source = %{
          address: address,
          port: port,
          response_binary: response_binary,
          response_struct: parse_response(response_binary)
        }

        collect_responses(socket, remaining, [source | acc])

      {:error, :timeout} ->
        Enum.reverse(acc)

      {:error, _reason} ->
        Enum.reverse(acc)
    end
  end

  defp collect_responses(_socket, _timeout, acc), do: Enum.reverse(acc)

  defp parse_response(response_binary) do
    try do
      DNS.Message.from_iodata(response_binary)
    rescue
      _ -> nil
    end
  end

  defp format_error({:socket_error, reason}), do: "Socket error: #{inspect(reason)}"
  defp format_error({:parse_error, msg}), do: "Parse error: #{msg}"
  defp format_error({:build_error, msg}), do: "Build error: #{msg}"
  defp format_error(reason), do: inspect(reason)
end
