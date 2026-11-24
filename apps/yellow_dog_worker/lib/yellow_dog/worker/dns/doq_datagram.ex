defmodule YellowDog.Worker.Dns.DoqDatagram do
  @moduledoc false
  @behaviour Abyss.DatagramHandler

  @impl true
  def init(options, _context), do: {:ok, Keyword.fetch!(options, :endpoint_table)}

  @impl true
  def handle_datagram(%Abyss.Datagram{peer: peer, payload: bytes}, table) do
    case :ets.lookup(table, :quic) do
      [{:quic, endpoint}] ->
        Quic.Endpoint.receive_datagram(
          endpoint,
          {peer.addr, peer.port},
          bytes,
          System.monotonic_time(:microsecond)
        )

      [] ->
        :ok
    end

    {:ok, table, []}
  end
end
