defmodule YellowDog.Handler.UDP do
  use Abyss.Handler

  @impl true
  def handle_data(recv_data, %{socket: listener_socket} = state) do
    {ip, port, data} = recv_data

    message =
      DNS.Message.from_iodata(data)
      |> DNS.Message.put_option(:client_ip, ip)
      |> DNS.Message.put_option(:client_port, port)

    resp = YellowDog.NameResolver.resolve(message)

    Abyss.Transport.UDP.send(listener_socket, ip, port, DNS.to_iodata(resp))

    {:close, state}
  end
end
