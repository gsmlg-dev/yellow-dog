defmodule YellowDog.Mdns.Handler do
  @moduledoc """
  mDNS message handler using Abyss.Handler behaviour.

  Passively receives and caches mDNS broadcast messages for later retrieval.
  This is a listener-only implementation that stores messages without responding.
  """

  use Abyss.Handler
  require Logger

  alias YellowDog.Mdns.MessageCache

  @doc """
  Handles incoming mDNS data packets.

  Parses DNS messages and stores them in the message cache for later retrieval.
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

        Logger.debug("Failed to parse mDNS message from #{format_ip(ip)}:#{port}: #{inspect(e)}")
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

      Logger.error("Error handling mDNS message from #{format_ip(ip)}:#{port}: #{inspect(e)}")
      {:continue, state}
  catch
    e ->
      # Emit telemetry event for handler error
      :telemetry.execute(
        [:yellow_dog, :mdns, :handler_error],
        %{bytes: byte_size(data)},
        %{error: inspect(e), source_ip: ip, source_port: port}
      )

      Logger.error("Error handling mDNS message from #{format_ip(ip)}:#{port}: #{inspect(e)}")
      {:continue, state}
  end

  @doc """
  Handles error events.
  """
  @impl true
  def handle_error(error, state) do
    Logger.error("mDNS handler error: #{inspect(error)}")
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

  # Private functions

  defp handle_dns_message(message, ip, port, state, start_time) do
    # Log message type
    message_type = if message.header.qr == 0, do: "query", else: "response"
    question_count = length(message.qdlist)
    answer_count = length(message.anlist)

    Logger.debug(
      "Received mDNS #{message_type} from #{format_ip(ip)}:#{port} (#{question_count} questions, #{answer_count} answers)"
    )

    # Check if this is a .local domain message
    if has_local_domain?(message) do
      # Cache the message
      MessageCache.cache_message(message, ip, port)

      # Emit telemetry event for successful caching
      end_time = System.monotonic_time(:microsecond)
      duration = end_time - start_time

      :telemetry.execute(
        [:yellow_dog, :mdns, :message_cached],
        %{
          duration: duration,
          question_count: question_count,
          answer_count: answer_count,
          authority_count: length(message.nslist),
          additional_count: length(message.arlist)
        },
        %{source_ip: ip, source_port: port, message_type: message_type}
      )
    else
      Logger.debug("Ignoring non-.local mDNS message")
    end

    {:continue, state}
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

  defp format_ip({a, b, c, d}) do
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp format_ip({a, b, c, d, e, f, g, h}) do
    parts = [a, b, c, d, e, f, g, h]
    hex_parts = Enum.map(parts, &Integer.to_string(&1, 16))
    Enum.join(hex_parts, ":")
  end
end
