defmodule Echo do
  use Abyss.Handler

  @impl true
  def handle_data({ip, port, data}, state) do
    IO.puts("📩 Received UDP message from #{:inet.ntoa(ip)}:#{port} -> #{inspect(data)}")

    msg = "✅ Processed: #{data}"

    Abyss.Transport.UDP.send(state.socket, ip, port, msg)
    {:close, state}
  end
end
