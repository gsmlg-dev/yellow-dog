defmodule DumpDHCP do
  use Abyss.Handler

  def handle_data(recv_data, state) do
    {ip, port, data} = recv_data
    IO.puts("📩 Received UDP message from #{:inet.ntoa(ip)}:#{port} ->")

    message = DHCPv4.Message.from_iodata(data)
    IO.puts(to_string(message))

    {:close, state}
  rescue
    e ->
      IO.inspect(e, limit: :infinity)
      {:close, state}
  end
end
