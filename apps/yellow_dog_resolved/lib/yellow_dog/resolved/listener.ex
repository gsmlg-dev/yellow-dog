defmodule YellowDog.Resolved.Listener do
  @moduledoc """
  Abyss UDP listener for incoming DNS queries.
  Dispatches queries through the Router.
  """
  use GenServer

  require Logger

  alias YellowDog.Resolved.Router

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

  alias YellowDog.Resolved.Router

  @impl Abyss.Handler
  def handle_data({client_ip, client_port, data}, state) do
    try do
      case DNS.Message.from_iodata(data) do
        %DNS.Message{} = query ->
          response = Router.resolve(query)
          response_data = DNS.to_iodata(response) |> IO.iodata_to_binary()
          Abyss.Transport.UDP.send(state.socket, client_ip, client_port, response_data)

        _ ->
          emit_malformed_packet(client_ip)
      end
    rescue
      _ -> emit_malformed_packet(client_ip)
    catch
      :throw, _ -> emit_malformed_packet(client_ip)
    end

    {:close, state}
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
