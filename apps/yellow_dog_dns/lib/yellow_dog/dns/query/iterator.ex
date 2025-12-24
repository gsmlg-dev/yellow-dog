defmodule YellowDog.Dns.Query.Iterator do
  @moduledoc """
  Handles single iteration of recursive DNS query.

  This module is responsible for querying a single nameserver and
  classifying the response. It determines whether the response is:
  - A final answer (authoritative)
  - A referral to other nameservers
  - An error (NXDOMAIN, SERVFAIL, etc.)

  The iterator does NOT follow referrals - that's the job of the
  recursive resolver. This module only handles one query/response cycle.
  """

  alias DNS.Message
  alias DNS.Message.Record

  @default_timeout 5000
  @dns_port 53

  @type query_result ::
          {:answer, [Record.t()], [Record.t()]}
          | {:referral, [Record.t()], map()}
          | {:nxdomain, [Record.t()]}
          | {:error, atom()}

  @doc """
  Queries a single nameserver and classifies the response.

  ## Parameters
  - `ns_ip` - IP address tuple of the nameserver
  - `query_name` - Domain name to query (with trailing dot)
  - `query_type` - DNS record type atom (e.g., :A, :AAAA, :MX)
  - `opts` - Optional configuration

  ## Options
  - `:timeout_ms` - Query timeout in milliseconds (default: 5000)
  - `:query_id` - Custom query ID (default: random)
  - `:port` - DNS port (default: 53)

  ## Returns
  - `{:answer, answer_records, authority_records}` - Got final answer
  - `{:referral, ns_records, glue_map}` - Got referral to other nameservers
  - `{:nxdomain, soa_records}` - Name doesn't exist
  - `{:error, reason}` - Query failed

  ## Examples

      iex> Iterator.query_nameserver({8, 8, 8, 8}, "example.com.", :A)
      {:answer, [%Record{type: :a, ...}], []}

      iex> Iterator.query_nameserver({198, 41, 0, 4}, "example.com.", :A)
      {:referral, [%Record{type: :ns, ...}], %{"ns1.example.com." => [{192, 0, 2, 1}]}}
  """
  @spec query_nameserver(:inet.ip_address(), String.t(), atom(), keyword()) :: query_result()
  def query_nameserver(ns_ip, query_name, query_type, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout)
    port = Keyword.get(opts, :port, @dns_port)
    query_id = Keyword.get(opts, :query_id, :rand.uniform(65535))

    # Emit telemetry
    :telemetry.execute(
      [:yellow_dog, :dns, :recursive, :query_start],
      %{},
      %{ns_ip: format_ip(ns_ip), query_name: query_name, query_type: query_type}
    )

    start_time = System.monotonic_time(:microsecond)

    result =
      with {:ok, query_message} <- create_query_message(query_name, query_type, query_id),
           {:ok, query_data} <- encode_query(query_message),
           {:ok, response_data} <- send_query(ns_ip, port, query_data, timeout_ms),
           {:ok, response_message} <- decode_response(response_data, query_id) do
        classify_response(response_message, query_name, query_type)
      end

    duration = System.monotonic_time(:microsecond) - start_time

    :telemetry.execute(
      [:yellow_dog, :dns, :recursive, :query_complete],
      %{duration: duration},
      %{ns_ip: format_ip(ns_ip), result: elem(result, 0)}
    )

    result
  end

  # Private functions

  defp create_query_message(query_name, query_type, query_id) do
    try do
      # Normalize query name
      normalized_name = normalize_query_name(query_name)
      dns_type = normalize_type(query_type)

      # Create DNS message
      message = Message.new()

      # Set query ID and flags
      message = Message.update_header_attr(message, :id, query_id)
      # 0 = query
      message = Message.update_header_attr(message, :qr, 0)
      # 0 = no recursion desired (we're doing recursion ourselves)
      message = Message.update_header_attr(message, :rd, 0)

      # Create question
      question = DNS.Message.Question.new(normalized_name, dns_type, :in)

      # Add question to message
      message = Message.add_question(message, question)

      {:ok, message}
    rescue
      error ->
        :telemetry.execute(
          [:yellow_dog, :dns, :query, :error],
          %{count: 1},
          %{source: __MODULE__, reason: :message_creation_failed, error: inspect(error), severity: :error}
        )
        {:error, :message_creation_failed}
    end
  end

  defp encode_query(query_message) do
    try do
      data = DNS.Parameter.to_iodata(query_message)
      {:ok, IO.iodata_to_binary(data)}
    rescue
      error ->
        :telemetry.execute(
          [:yellow_dog, :dns, :query, :error],
          %{count: 1},
          %{source: __MODULE__, reason: :encode_failed, error: inspect(error), severity: :error}
        )
        {:error, :encode_failed}
    end
  end

  defp send_query(ns_ip, port, query_data, timeout_ms) do
    # Open UDP socket
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        try do
          # Send query
          :ok = :gen_udp.send(socket, ns_ip, port, query_data)

          # Receive response with timeout
          case :gen_udp.recv(socket, 0, timeout_ms) do
            {:ok, {^ns_ip, ^port, response_data}} ->
              {:ok, response_data}

            {:ok, {other_ip, other_port, _data}} ->
              :telemetry.execute(
                [:yellow_dog, :dns, :query, :error],
                %{count: 1},
                %{source: __MODULE__, reason: :unexpected_source, from_ip: format_ip(other_ip), from_port: other_port, severity: :warning}
              )

              {:error, :unexpected_source}

            {:error, :timeout} ->
              {:error, :timeout}

            {:error, reason} ->
              {:error, reason}
          end
        after
          :gen_udp.close(socket)
        end

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dns, :query, :error],
          %{count: 1},
          %{source: __MODULE__, reason: :socket_open_failed, error: inspect(reason), severity: :error}
        )
        {:error, :socket_open_failed}
    end
  end

  defp decode_response(response_data, expected_id) do
    try do
      response = Message.from_iodata(response_data)

      # Verify query ID matches
      if response.header.id == expected_id do
        {:ok, response}
      else
        :telemetry.execute(
          [:yellow_dog, :dns, :query, :error],
          %{count: 1},
          %{source: __MODULE__, reason: :id_mismatch, expected_id: expected_id, got_id: response.header.id, severity: :warning}
        )
        {:error, :id_mismatch}
      end
    rescue
      error ->
        :telemetry.execute(
          [:yellow_dog, :dns, :query, :error],
          %{count: 1},
          %{source: __MODULE__, reason: :decode_failed, error: inspect(error), severity: :error}
        )
        {:error, :decode_failed}
    end
  end

  defp classify_response(response, _query_name, _query_type) do
    rcode_value = response.header.rcode.value

    case rcode_value do
      # NOERROR
      <<0>> ->
        if response.header.ancount > 0 do
          # We have answers - this is a final answer
          answers = response.anlist || []
          authority = response.nslist || []
          {:answer, answers, authority}
        else
          # No answers but NOERROR - this is a referral
          ns_records = response.nslist || []
          additional = response.arlist || []

          if length(ns_records) > 0 do
            # Extract glue records from additional section
            glue_map = extract_glue_records(additional)
            {:referral, ns_records, glue_map}
          else
            # No answers and no NS records - unusual but treat as error
            {:error, :no_data}
          end
        end

      # NXDOMAIN
      <<3>> ->
        authority = response.nslist || []
        {:nxdomain, authority}

      # SERVFAIL
      <<2>> ->
        {:error, :servfail}

      # REFUSED
      <<5>> ->
        {:error, :refused}

      _ ->
        :telemetry.execute(
          [:yellow_dog, :dns, :query, :error],
          %{count: 1},
          %{source: __MODULE__, reason: :dns_error, rcode: inspect(rcode_value), severity: :debug}
        )
        {:error, :dns_error}
    end
  end

  defp extract_glue_records(additional_records) do
    additional_records
    |> Enum.filter(&glue_record?/1)
    |> Enum.reduce(%{}, fn record, acc ->
      name = record.name.value |> normalize_query_name()
      ip = extract_ip_from_record(record)

      Map.update(acc, name, [ip], fn existing -> [ip | existing] end)
    end)
  end

  defp glue_record?(record) do
    type_value = record.type.value

    # A record (type 1) or AAAA record (type 28)
    type_value == <<0, 1>> or type_value == <<0, 28>>
  end

  defp extract_ip_from_record(record) do
    case record.type.value do
      # A record
      <<0, 1>> ->
        record.data.data

      # AAAA record
      <<0, 28>> ->
        record.data.data

      _ ->
        nil
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
