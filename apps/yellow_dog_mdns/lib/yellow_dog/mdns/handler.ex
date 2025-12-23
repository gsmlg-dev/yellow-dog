defmodule YellowDog.Mdns.Handler do
  @moduledoc """
  mDNS message handler using Abyss.Handler behaviour.

  Supports three modes:
  - :listener - Passive listening only (caches messages)
  - :responder - Active response only (answers queries)
  - :hybrid - Both listening and responding (recommended)
  """

  use Abyss.Handler

  alias YellowDog.Mdns.{MessageCache, NetworkMonitor, Responder, ServiceRegistry}

  @doc """
  Handles incoming mDNS data packets.

  Routes messages based on mode:
  - Queries → Responder (if responder mode)
  - Responses → NetworkMonitor (if listener/hybrid mode)
  """
  @impl true
  def handle_data({ip, port, data}, state) do
    start_time = System.monotonic_time(:microsecond)

    # Emit telemetry event for message reception
    :telemetry.execute(
      [:yellow_dog, :mdns, :message_received],
      %{bytes: byte_size(data)},
      %{source_ip: ip, source_port: port}
    )

    try do
      message = DNS.Message.from_iodata(data)
      mode = Map.get(state, :mode, :hybrid)
      handle_dns_message(message, ip, port, state, start_time, mode)
    rescue
      e ->
        :telemetry.execute(
          [:yellow_dog, :mdns, :message, :parse_error],
          %{count: 1, bytes: byte_size(data)},
          %{reason: inspect(e), source_ip: ip, source_port: port}
        )

        {:continue, state}
    end
  rescue
    e ->
      :telemetry.execute(
        [:yellow_dog, :mdns, :handler, :error],
        %{count: 1, bytes: byte_size(data)},
        %{error: inspect(e), source_ip: ip, source_port: port}
      )

      {:continue, state}
  catch
    e ->
      :telemetry.execute(
        [:yellow_dog, :mdns, :handler, :error],
        %{count: 1, bytes: byte_size(data)},
        %{error: inspect(e), source_ip: ip, source_port: port}
      )

      {:continue, state}
  end

  @doc """
  Handles error events.
  """
  @impl true
  def handle_error(error, state) do
    :telemetry.execute(
      [:yellow_dog, :mdns, :handler, :error],
      %{count: 1},
      %{reason: inspect(error)}
    )

    {:continue, state}
  end

  @doc """
  Handles timeout events for mDNS connections.
  """
  @impl true
  def handle_timeout(state) do
    :telemetry.execute(
      [:yellow_dog, :mdns, :handler, :timeout],
      %{count: 1},
      %{}
    )

    {:continue, state}
  end

  # Private functions

  defp handle_dns_message(message, ip, port, state, start_time, mode) do
    is_query = message.header.qr == 0
    message_type = if is_query, do: :query, else: :response
    question_count = length(message.qdlist)
    answer_count = length(message.anlist)

    # Check if this is a .local domain message
    if has_local_domain?(message) do
      # Route based on message type and mode
      case {is_query, mode} do
        # Query in responder or hybrid mode → try to respond
        {true, mode} when mode in [:responder, :hybrid] ->
          handle_query(message, ip, port, state, start_time)

        # Query in listener mode → just log it
        {true, :listener} ->
          NetworkMonitor.log_query(message, ip, port)

        # Response in listener or hybrid mode → cache it
        {false, mode} when mode in [:listener, :hybrid] ->
          NetworkMonitor.cache_response(message, ip, port)
          # Also update legacy MessageCache for backward compatibility
          MessageCache.cache_message(message, ip, port)

        # Response in responder mode → ignore
        {false, :responder} ->
          :ok
      end

      # Emit telemetry event
      end_time = System.monotonic_time(:microsecond)
      duration = end_time - start_time

      :telemetry.execute(
        [:yellow_dog, :mdns, :message_processed],
        %{
          duration: duration,
          question_count: question_count,
          answer_count: answer_count,
          authority_count: length(message.nslist),
          additional_count: length(message.arlist)
        },
        %{source_ip: ip, source_port: port, message_type: message_type, mode: mode}
      )
    else
      :telemetry.execute(
        [:yellow_dog, :mdns, :message, :ignored],
        %{count: 1},
        %{reason: :non_local_domain, source_ip: ip, source_port: port}
      )
    end

    {:continue, state}
  end

  defp handle_query(query, ip, _port, state, _start_time) do
    # Get matching services from registry
    services = ServiceRegistry.get_records_for_query(query.qdlist)

    if Enum.empty?(services) do
      :telemetry.execute(
        [:yellow_dog, :mdns, :query, :no_match],
        %{count: 1},
        %{source_ip: ip}
      )

      :ok
    else
      :telemetry.execute(
        [:yellow_dog, :mdns, :query, :matched],
        %{count: 1, service_count: length(services)},
        %{source_ip: ip}
      )

      # Check if we should respond (known-answer suppression)
      if Responder.should_respond?(query, services) do
        # Build response
        response = Responder.build_response(query, services)

        # Validate size
        case Responder.validate_response_size(response) do
          {:ok, validated_response} ->
            # Send response via multicast
            send_multicast_response(validated_response, state)

            :telemetry.execute(
              [:yellow_dog, :mdns, :response, :sent],
              %{count: 1, service_count: length(services)},
              %{}
            )

          {:error, :too_large, size} ->
            :telemetry.execute(
              [:yellow_dog, :mdns, :response, :too_large],
              %{count: 1, size: size},
              %{}
            )
        end
      end
    end

    :ok
  end

  defp send_multicast_response(message, _state) do
    # Convert DNS message to binary
    response_data = DNS.to_iodata(message) |> IO.iodata_to_binary()

    # Send via Server module
    YellowDog.Mdns.Server.send_multicast(response_data)
  rescue
    e ->
      :telemetry.execute(
        [:yellow_dog, :mdns, :response, :send_failed],
        %{count: 1},
        %{reason: inspect(e)}
      )

      :ok
  end

  defp has_local_domain?(message) do
    # Check questions
    local_in_questions =
      Enum.any?(message.qdlist, fn question ->
        is_local_domain?(to_string(question.name))
      end)

    # Check answers
    local_in_answers =
      Enum.any?(message.anlist, fn record ->
        is_local_domain?(to_string(record.name))
      end)

    # Check authority records
    local_in_authority =
      Enum.any?(message.nslist, fn record ->
        is_local_domain?(to_string(record.name))
      end)

    # Check additional records
    local_in_additional =
      Enum.any?(message.arlist, fn record ->
        is_local_domain?(to_string(record.name))
      end)

    local_in_questions || local_in_answers || local_in_authority || local_in_additional
  end

  defp is_local_domain?(domain) when is_binary(domain) do
    String.ends_with?(domain, ".local") || String.ends_with?(domain, ".local.")
  end

  defp is_local_domain?(_), do: false
end
