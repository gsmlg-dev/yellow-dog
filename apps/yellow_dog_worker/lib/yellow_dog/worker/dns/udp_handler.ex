defmodule YellowDog.Worker.Dns.UdpHandler do
  @moduledoc false
  @behaviour Abyss.DatagramHandler

  alias YellowDog.Worker.Dns.Resolver

  @impl Abyss.DatagramHandler
  def init(options, _context), do: {:ok, Keyword.fetch!(options, :adapter)}

  @impl Abyss.DatagramHandler
  def handle_datagram(%Abyss.Datagram{payload: packet, peer: %{addr: ip}}, adapter) do
    actions =
      with {:ok, context} <- safe_snapshot(adapter),
           wire when is_binary(wire) <- Resolver.reply(packet, context, :udp, ip) do
        [{:reply, wire}]
      else
        _ -> []
      end

    {:ok, adapter, actions}
  end

  defp safe_snapshot(adapter) do
    GenServer.call(adapter, :snapshot, 2_000)
  catch
    :exit, _ -> {:error, :adapter_unavailable}
  end
end
