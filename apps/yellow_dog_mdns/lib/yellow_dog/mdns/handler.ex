defmodule YellowDog.Mdns.Handler do
  @moduledoc """
  mDNS message handler using Abyss.Handler behaviour.

  Processes incoming mDNS packets, parses DNS messages, and generates
  appropriate responses for multicast DNS operations.
  """

  use Abyss.Handler
  require Logger

  @doc """
  Handles incoming mDNS data packets.

  Parses the DNS message and processes mDNS queries for .local domains.
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
      handle_dns_message(message, ip, port, state, start_time)
    rescue
      e ->
        # Emit telemetry event for parsing error
        :telemetry.execute(
          [:yellow_dog, :mdns, :parse_error],
          %{bytes: byte_size(data)},
          %{reason: inspect(e), source_ip: ip, source_port: port}
        )

        Logger.debug("Failed to parse DNS message from #{:inet.ntoa(ip)}:#{port}: #{inspect(e)}")
        {:continue, state}
    end
  rescue
    e ->
      # Emit telemetry event for handler error
      :telemetry.execute(
        [:yellow_dog, :mdns, :handler_error],
        %{bytes: byte_size(data)},
        %{error: inspect(e), source_ip: ip, source_port: port}
      )

      Logger.error("Error handling mDNS message from #{:inet.ntoa(ip)}:#{port}: #{inspect(e)}")
      {:continue, state}
  catch
    e ->
      # Emit telemetry event for handler error
      :telemetry.execute(
        [:yellow_dog, :mdns, :handler_error],
        %{bytes: byte_size(data)},
        %{error: inspect(e), source_ip: ip, source_port: port}
      )

      Logger.error("Error handling mDNS message from #{:inet.ntoa(ip)}:#{port}: #{inspect(e)}")
      {:continue, state}
  end

  @doc """
  Handles timeout events for mDNS connections.
  """
  @impl true
  def handle_timeout(state) do
    Logger.debug("mDNS handler timeout")
    {:continue, state}
  end

  @doc """
  Handles connection close events.
  """
  @impl true
  def handle_close(state) do
    Logger.debug("mDNS handler connection closed")
    {:close, state}
  end

  @doc """
  Called when the handler process terminates.
  """
  @impl true
  def terminate(_reason, _state) do
    Logger.debug("mDNS handler terminating")
    :ok
  end

  # Private functions

  defp handle_dns_message(message, ip, port, state, start_time) do
    Logger.debug("Received mDNS message from #{:inet.ntoa(ip)}:#{port}: #{message}")

    # Process the DNS message
    try do
      response = process_message(message)
      if response do
        send_response(response, ip, port, state)
      end

      # Emit telemetry event for successful processing
      end_time = System.monotonic_time(:microsecond)
      duration = end_time - start_time

      :telemetry.execute(
        [:yellow_dog, :mdns, :message_processed],
        %{duration: duration, bytes: byte_size(DNS.to_iodata(message))},
        %{source_ip: ip, source_port: port, had_response: response != nil}
      )

      {:continue, state}
    rescue
      e ->
        Logger.debug("Failed to process mDNS message: #{inspect(e)}")

        # Emit telemetry event for processing error
        :telemetry.execute(
          [:yellow_dog, :mdns, :process_error],
          %{bytes: byte_size(DNS.to_iodata(message))},
          %{reason: inspect(e), source_ip: ip, source_port: port}
        )

        {:continue, state}
    end
  end

  defp process_message(%DNS.Message{header: header} = message) do
    if header.qr == 0 do
      # This is a query message
      Logger.debug("Processing mDNS query with #{length(message.qdlist)} questions")
      process_query(message)
    else
      # This is a response message - in mDNS, we typically don't need to process responses
      Logger.debug("Ignoring mDNS response message")
      nil
    end
  end

  defp process_query(%DNS.Message{qdlist: []}) do
    # No questions in the query
    nil
  end

  defp process_query(%DNS.Message{qdlist: questions} = message) do
    # Check if any questions are for .local domains
    local_questions = Enum.filter(questions, &is_local_question?/1)

    if local_questions == [] do
      Logger.debug("No .local questions found, ignoring query")
      nil
    else
      # For now, just acknowledge that we received a local query
      # In a full implementation, we would look up records and generate responses
      Logger.debug("Processing #{length(local_questions)} .local questions")
      generate_query_response(local_questions, message)
    end
  end

  defp is_local_question?(%DNS.Message.Question{name: domain}) do
    to_string(domain)
    |> String.ends_with?(".local")
  end

  defp is_local_question?(_) do
    false
  end

  defp generate_query_response(_questions, original_message) do
    # For now, return a basic response
    # In a full implementation, this would look up records and generate proper responses
    response_header = DNS.Message.Header.new()
    |> Map.put(:qr, 1)  # This is a response
    |> Map.put(:aa, 1)  # Authoritative answer for mDNS
    |> Map.put(:qdcount, length(original_message.qdlist))

    response = %DNS.Message{
      header: response_header,
      qdlist: original_message.qdlist,  # Echo back questions
      anlist: [],  # Would contain actual answers in full implementation
      nslist: [],
      arlist: []
    }

    response
  end

  defp send_response(response, ip, port, state) do
    try do
      iodata = DNS.to_iodata(response)
      Abyss.Transport.UDP.send(state.socket, ip, port, iodata)
      Logger.debug("Sent mDNS response to #{:inet.ntoa(ip)}:#{port}")

      # Emit telemetry event for response sent
      :telemetry.execute(
        [:yellow_dog, :mdns, :response_sent],
        %{bytes: IO.iodata_length(iodata)},
        %{target_ip: ip, target_port: port}
      )
    rescue
      e ->
        Logger.error("Failed to encode mDNS response: #{inspect(e)}")

        # Emit telemetry event for encoding error
        :telemetry.execute(
          [:yellow_dog, :mdns, :encode_error],
          %{answers: length(response.anlist)},
          %{reason: inspect(e), target_ip: ip, target_port: port}
        )
    end
  end
end