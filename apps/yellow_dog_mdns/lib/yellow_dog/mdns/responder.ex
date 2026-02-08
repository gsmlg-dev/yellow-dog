defmodule YellowDog.Mdns.Responder do
  @moduledoc """
  mDNS responder for generating DNS responses to queries.

  Implements RFC 6762 §6 (Responding) including:
  - Query matching against registered services
  - Known-answer suppression
  - Response message building with proper sections
  - Response delay for shared records
  """

  alias YellowDog.Mdns.{ServiceRegistry, RecordBuilder}
  alias DNS.Message
  alias DNS.Message.{Header, Question, Record}

  # RFC 6762 §17: mDNS messages should fit in a single packet
  @mdns_max_packet_size 1232
  # RFC 6762 §6.3: Response delay range for shared records
  @response_delay_min_ms 20
  @response_delay_range_ms 100

  @doc """
  Checks if we should respond to a query.

  Returns true if we have matching services and the query is not
  already answered (known-answer suppression).
  """
  @spec should_respond?(Message.t(), [ServiceRegistry.service()]) :: boolean()
  def should_respond?(_query, []), do: false

  def should_respond?(query, matching_services) do
    not has_known_answers?(query, matching_services)
  end

  @doc """
  Builds a complete mDNS response message.

  Returns a DNS message with:
  - QR=1 (response)
  - AA=1 (authoritative)
  - Answers section with matching records
  - Additional section with related records
  """
  @spec build_response(Message.t(), [ServiceRegistry.service()]) :: Message.t()
  def build_response(query, matching_services) do
    # Build records for each service
    all_records =
      Enum.flat_map(matching_services, fn service ->
        build_records_for_service(service, query.qdlist)
      end)

    # Separate into answers and additional
    answers = Enum.flat_map(all_records, & &1.answers)
    additional = Enum.flat_map(all_records, & &1.additional)

    # Remove duplicates
    unique_answers = deduplicate_records(answers)
    unique_additional = deduplicate_records(additional)

    # Build response message
    %Message{
      header: %Header{
        # Copy query ID
        id: query.header.id,
        # Response
        qr: 1,
        # Standard query
        opcode: 0,
        # Authoritative
        aa: 1,
        # Not truncated
        tc: 0,
        # Recursion not desired for mDNS
        rd: 0,
        # Recursion not available
        ra: 0,
        # No error
        rcode: 0
      },
      # Echo questions
      qdlist: query.qdlist,
      # Answer records
      anlist: unique_answers,
      # No authority records in mDNS
      nslist: [],
      # Additional records
      arlist: unique_additional
    }
  end

  @doc """
  Calculates appropriate response delay for shared records.

  RFC 6762 §6.3: Responses for shared records should be delayed
  20-120ms to allow for response aggregation.
  """
  @spec calculate_response_delay([ServiceRegistry.service()]) :: non_neg_integer()
  def calculate_response_delay(_services) do
    :rand.uniform(@response_delay_range_ms) + @response_delay_min_ms
  end

  @doc """
  Checks if a query contains known answers that match our records.

  RFC 6762 §7.1: Known-Answer Suppression
  """
  @spec has_known_answers?(Message.t(), [ServiceRegistry.service()]) :: boolean()
  def has_known_answers?(query, services) do
    # Get all records we would send
    our_records =
      Enum.flat_map(services, fn service ->
        all_service_records = RecordBuilder.build_all_records(service)

        [
          all_service_records.ptr,
          all_service_records.srv,
          all_service_records.txt
        ] ++
          all_service_records.a ++ all_service_records.aaaa
      end)

    # Check if any of our records are in the query's answer section
    Enum.any?(our_records, fn our_record ->
      Enum.any?(query.anlist, fn known_answer ->
        records_match?(our_record, known_answer) and
          known_answer.ttl > our_record.ttl / 2
      end)
    end)
  end

  # Private functions

  defp build_records_for_service(service, questions) do
    Enum.map(questions, fn question ->
      RecordBuilder.build_records_for_question(service, question)
    end)
  end

  defp records_match?(record1, record2) do
    normalize_name(record1.name) == normalize_name(record2.name) and
      record1.type == record2.type and
      record1.class == record2.class and
      normalize_data(record1.data, record1.type) == normalize_data(record2.data, record2.type)
  end

  defp normalize_name(name), do: YellowDog.Mdns.normalize_name(name)

  defp normalize_data(data, :PTR), do: normalize_name(data)
  defp normalize_data(data, :TXT) when is_list(data), do: Enum.sort(data)

  defp normalize_data(%{target: target} = data, :SRV) do
    %{data | target: normalize_name(target)}
  end

  defp normalize_data(data, _type), do: data

  defp deduplicate_records(records) do
    records
    |> Enum.uniq_by(fn record ->
      {normalize_name(record.name), record.type, record.class,
       normalize_data(record.data, record.type)}
    end)
  end

  @doc """
  Validates that a response fits within mDNS MTU limits.

  RFC 6762 §17: mDNS messages should fit in a single packet (1232 bytes).
  Returns {:ok, message} or {:error, :too_large, size}
  """
  @spec validate_response_size(Message.t()) ::
          {:ok, Message.t()} | {:error, :too_large, integer()}
  def validate_response_size(message) do
    # Rough estimate of message size
    estimated_size = estimate_message_size(message)

    if estimated_size > @mdns_max_packet_size do
      :telemetry.execute(
        [:yellow_dog, :mdns, :responder, :response_too_large],
        %{size: estimated_size},
        %{}
      )

      {:error, :too_large, estimated_size}
    else
      {:ok, message}
    end
  end

  defp estimate_message_size(message) do
    # Header: 12 bytes
    header_size = 12

    # Questions
    questions_size =
      Enum.reduce(message.qdlist, 0, fn q, acc ->
        acc + byte_size(to_string(q.name)) + 4
      end)

    # Records
    records_size =
      Enum.reduce(message.anlist ++ message.nslist ++ message.arlist, 0, fn rec, acc ->
        acc + estimate_record_size(rec)
      end)

    header_size + questions_size + records_size
  end

  defp estimate_record_size(%Record{name: name, type: type, data: data}) do
    name_size = byte_size(to_string(name))
    # type (2) + class (2) + ttl (4) + rdlength (2)
    fixed_size = 10

    data_size =
      case {type, data} do
        {:A, {_, _, _, _}} -> 4
        {:AAAA, {_, _, _, _, _, _, _, _}} -> 16
        {:PTR, target} -> byte_size(to_string(target))
        {:TXT, list} when is_list(list) -> Enum.sum_by(list, &byte_size/1)
        {:SRV, %{target: target}} -> byte_size(to_string(target)) + 6
        _ -> 20
      end

    name_size + fixed_size + data_size
  end

  @doc """
  Filters questions to only those we can answer.
  """
  @spec filter_answerable_questions([Question.t()], [ServiceRegistry.service()]) :: [
          {Question.t(), [ServiceRegistry.service()]}
        ]
  def filter_answerable_questions(questions, all_services) do
    Enum.map(questions, fn question ->
      matching_services = find_matching_services(question, all_services)
      {question, matching_services}
    end)
    |> Enum.reject(fn {_question, services} -> Enum.empty?(services) end)
  end

  defp find_matching_services(question, services) do
    qname = normalize_name(question.name)
    qtype = question.type

    Enum.filter(services, fn service ->
      service_fqdn = normalize_name(service.fqdn)
      service_type = normalize_name("#{service.type}.#{service.domain}")
      service_host = normalize_name(service.host)

      cond do
        # PTR query for service type
        qtype == :PTR and qname == service_type ->
          true

        # SRV/TXT/ANY query for service instance
        qtype in [:SRV, :TXT, :ANY] and qname == service_fqdn ->
          true

        # A/AAAA query for host
        qtype in [:A, :AAAA, :ANY] and qname == service_host ->
          true

        true ->
          false
      end
    end)
  end

  @doc """
  Builds a legacy response for backward compatibility.

  This is a simplified response builder for testing.
  """
  @spec build_legacy_response(String.t(), atom()) :: binary() | nil
  def build_legacy_response(query_name, query_type) do
    services = ServiceRegistry.list_services(filter: :registered)

    matching_services =
      Enum.filter(services, fn service ->
        qname = normalize_name(query_name)
        service_type = normalize_name("#{service.type}.#{service.domain}")
        service_fqdn = normalize_name(service.fqdn)

        cond do
          query_type == :PTR and qname == service_type -> true
          query_type in [:SRV, :ANY] and qname == service_fqdn -> true
          true -> false
        end
      end)

    if Enum.empty?(matching_services) do
      nil
    else
      # Build a simple response
      service = hd(matching_services)
      records = RecordBuilder.build_all_records(service)

      message = %Message{
        header: %Header{
          id: :rand.uniform(65535),
          qr: 1,
          aa: 1,
          rcode: 0
        },
        qdlist: [],
        anlist: [records.ptr],
        nslist: [],
        arlist: [records.srv, records.txt] ++ records.a ++ records.aaaa
      }

      DNS.to_iodata(message) |> IO.iodata_to_binary()
    end
  end
end
