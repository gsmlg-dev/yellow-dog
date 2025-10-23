defmodule DumpMDNS do
  use Abyss.Handler

  def handle_data(recv_data, state) do
    {ip, port, data} = recv_data
    IO.puts("📩 Received UDP message from #{:inet.ntoa(ip)}:#{port} ->")

    message = DNS.Message.from_iodata(data)

    # IO.inspect({:inet_dns.decode(data), "#{message}"})
    IO.puts(message)

    {:close, state}
  rescue
    e ->
      {ip, port, data} = recv_data
      IO.inspect(e, limit: :infinity)
      IO.inspect({ip, port, data}, limit: :infinity)
      {:close, state}
  catch
    e ->
      {ip, port, data} = recv_data
      IO.inspect(e, limit: :infinity)
      IO.inspect({ip, port, data}, limit: :infinity)
      {:close, state}
  end
end
