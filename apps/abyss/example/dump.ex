defmodule Dump do
  use Abyss.Handler

  def handle_data(recv_data, state) do
    {ip, port, data} = recv_data
    IO.puts("📩 Received UDP message from #{:inet.ntoa(ip)}:#{port} ->")
    IO.inspect(data, limit: :infinity)
    {:close, state}
  end
end
