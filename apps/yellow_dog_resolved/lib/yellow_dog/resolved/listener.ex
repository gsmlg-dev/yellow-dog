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
          response_data = DNS.to_iodata(response) |> IO.iodata_to_binary()
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

  defp emit_malformed_packet(client_ip) do
    Logger.debug("[Resolved] Received malformed DNS packet")

    :telemetry.execute(
      [:yellow_dog, :resolved, :query, :malformed],
      %{},
      %{client: client_ip}
    )
  end
end
