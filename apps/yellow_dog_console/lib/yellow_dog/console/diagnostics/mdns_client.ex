defmodule YellowDog.Console.Diagnostics.MdnsClient do
  @moduledoc """
  mDNS multicast query client for diagnostic testing.

  Sends mDNS queries to the multicast address 224.0.0.251:5353
  and collects responses from multiple sources until timeout.
  """

  alias YellowDog.Console.Diagnostics.QueryResult

  import YellowDog.Console.Diagnostics.ParamHelper

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

  @valid_record_types ~w(a aaaa ptr srv txt)
  defp parse_record_type(type) when is_binary(type) do
    downcased = String.downcase(type)
    if downcased in @valid_record_types, do: String.to_existing_atom(downcased), else: :ptr
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
    case Abyss.Client.multicast_query(
           @mdns_multicast_addr,
           @mdns_port,
           request_binary,
           params.timeout
         ) do
      {:ok, raw_sources} ->
        sources =
          Enum.map(raw_sources, fn {address, port, response_binary} ->
            %{
              address: address,
              port: port,
              response_binary: response_binary,
              response_struct: parse_response(response_binary)
            }
          end)

        {:ok, sources}

      {:error, reason} ->
        {:error, {:socket_error, reason}}
    end
  end

  defp parse_response(response_binary) do
    try do
      DNS.Message.from_iodata(response_binary)
    rescue
      _ -> nil
    end
  end
end
