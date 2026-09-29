defmodule YellowDog.Worker.Dns.UdpHandler do
  @moduledoc false
  use Abyss.Handler

  alias YellowDog.Worker.Dns.Resolver

  @impl Abyss.Handler
  def handle_data({ip, port, packet}, state) do
    adapter = state.server_config.handler_options[:adapter]

    if is_pid(adapter) do
      case safe_snapshot(adapter) do
        {:ok, zones} ->
          if wire = Resolver.reply(packet, zones, :udp) do
            Abyss.Transport.UDP.send(state.socket, ip, port, wire)
          end

        _ ->
          :ok
      end
    end

    {:close, state}
  end

  defp safe_snapshot(adapter) do
    GenServer.call(adapter, :snapshot, 2_000)
  catch
    :exit, _ -> {:error, :adapter_unavailable}
  end
end
