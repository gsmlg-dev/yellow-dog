defmodule YellowDog.Resolved.Listener do
  @moduledoc """
  Abyss UDP listener for incoming DNS queries.
  Dispatches queries through the Router.
  """
  use GenServer

  require Logger

  alias YellowDog.Resolved.Router

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(config) do
    listen_ip = Map.get(config, :listen, {127, 0, 0, 1})
    port = Map.get(config, :port, 53)

    Logger.info("[Resolved] Starting listener on #{:inet.ntoa(listen_ip)}:#{port}")

    abyss_config = [
      handler_module: YellowDog.Resolved.Handler,
      port: port,
      transport_module: Abyss.Transport.UDP,
      transport_options: [ip: listen_ip],
      read_timeout: 60_000,
      num_listeners: 4,
      num_connections: 1000,
      max_packet_size: 4096
    ]

    case Abyss.start_link(abyss_config) do
      {:ok, abyss_pid} ->
        {:ok, %{abyss_pid: abyss_pid, config: config}}

      {:error, reason} ->
        Logger.error("[Resolved] Failed to start listener: #{inspect(reason)}")
        {:stop, reason}
    end
  end
end

defmodule YellowDog.Resolved.Handler do
  @moduledoc """
  Abyss handler for DNS query packets.
  """
  use Abyss.Handler

  require Logger

  alias YellowDog.Resolved.{Counters, RateLimiter, ResponseBuilder, Router}

  # RFC 1035 §4.2.1: UDP messages are limited to 512 bytes unless EDNS0 is used.
  @udp_max_default 512
  # DNS OPT RR type code (EDNS0, RFC 6891)
  @opt_rr_type 41

  @impl Abyss.Handler
  def handle_data({client_ip, client_port, data}, state) do
    case RateLimiter.allow?(client_ip) do
      :ok ->
        handle_query(client_ip, client_port, data, state)

      :rate_limited ->
        Counters.increment(:rate_limited)

        :telemetry.execute(
          [:yellow_dog, :resolved, :query, :rate_limited],
          %{},
          %{client: client_ip}
        )

        send_refused(client_ip, client_port, data, state)
    end

    {:close, state}
  end

  defp handle_query(client_ip, client_port, data, state) do
    try do
      case DNS.Message.from_iodata(data) do
        %DNS.Message{header: %{qr: 0, opcode: %DNS.Message.OpCode{value: <<0::4>>}}} = query ->
          response = Router.resolve(query)
          response_data = maybe_truncate_response(response, query)
          Abyss.Transport.UDP.send(state.socket, client_ip, client_port, response_data)

        %DNS.Message{header: %{qr: 0}} = query ->
          # RFC 1035 §4.1.1: non-QUERY opcodes are not supported — return NOTIMP
          Logger.debug("[Resolved] Received non-QUERY opcode from #{:inet.ntoa(client_ip)} — returning NOTIMP")
          response = ResponseBuilder.build_response(query, [], DNS.Message.RCode.not_imp())
          response_data = DNS.to_iodata(response) |> IO.iodata_to_binary()
          Abyss.Transport.UDP.send(state.socket, client_ip, client_port, response_data)

        %DNS.Message{header: %{qr: 1}} ->
          # Silently discard DNS response packets — the resolver only accepts
          # queries (QR=0).  Sending a reply to a response would be incorrect
          # and could participate in reflection amplification.
          Logger.debug("[Resolved] Received DNS response on query port from #{:inet.ntoa(client_ip)} — discarding")

        _ ->
          emit_malformed_packet(client_ip)
      end
    rescue
      _ -> emit_malformed_packet(client_ip)
    catch
      :throw, _ -> emit_malformed_packet(client_ip)
    end
  end

  defp send_refused(client_ip, client_port, data, state) do
    try do
      case DNS.Message.from_iodata(data) do
        %DNS.Message{header: %{qr: 0}} = query ->
          response = ResponseBuilder.build_response(query, [], DNS.Message.RCode.refused())
          response_data = DNS.to_iodata(response) |> IO.iodata_to_binary()
          Abyss.Transport.UDP.send(state.socket, client_ip, client_port, response_data)

        _ ->
          :ok
      end
    rescue
      _ -> :ok
    catch
      :throw, _ -> :ok
    end
  end

  # RFC 1035 §4.2.1: if the encoded response exceeds the negotiated UDP limit,
  # truncate the answer section and set TC=1 so the client can retry over TCP.
  defp maybe_truncate_response(response, query) do
    max_size = edns0_max_size(query)
    data = DNS.to_iodata(response) |> IO.iodata_to_binary()

    if byte_size(data) <= max_size do
      data
    else
      :telemetry.execute(
        [:yellow_dog, :resolved, :response, :truncated],
        %{original_size: byte_size(data), max_size: max_size},
        %{ancount: length(response.anlist)}
      )

      truncate_response(response, max_size)
    end
  end

  defp edns0_max_size(query) do
    opt_type = DNS.ResourceRecordType.new(@opt_rr_type)

    case Enum.find(query.arlist, fn rec -> rec.type == opt_type end) do
      nil ->
        @udp_max_default

      opt_rec ->
        <<udp_payload::16>> = opt_rec.class.value
        max(udp_payload, @udp_max_default)
    end
  end

  defp truncate_response(response, max_size) do
    do_truncate(response.anlist, response, max_size)
  end

  defp do_truncate([], response, _max_size) do
    truncated = %{response | anlist: [], header: %{response.header | tc: 1, ancount: 0}}
    DNS.to_iodata(truncated) |> IO.iodata_to_binary()
  end

  defp do_truncate(answers, response, max_size) do
    truncated = %{response | anlist: answers, header: %{response.header | tc: 1, ancount: length(answers)}}
    data = DNS.to_iodata(truncated) |> IO.iodata_to_binary()

    if byte_size(data) <= max_size do
      data
    else
      do_truncate(Enum.drop(answers, -1), response, max_size)
    end
  end

  defp emit_malformed_packet(client_ip) do
    Logger.debug("[Resolved] Received malformed DNS packet")
    Counters.increment(:error)

    :telemetry.execute(
      [:yellow_dog, :resolved, :query, :malformed],
      %{count: 1},
      %{client: client_ip}
    )
  end
end
