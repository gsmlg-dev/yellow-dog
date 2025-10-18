defmodule YellowDogDns.Handler.UDP do
  use Abyss.Handler

  @impl true
  def handle_data(recv_data, %{socket: listener_socket} = state) do
    {ip, port, data} = recv_data

    message = DNS.Message.from_iodata(data)

    # Store client info in the message for later use using Map.put
    message = Map.put(message, :client_ip, ip) |> Map.put(:client_port, port)

    resp = YellowDogDns.NameResolver.resolve(message)

    Abyss.Transport.UDP.send(listener_socket, ip, port, DNS.to_iodata(resp))

    {:close, state}
  end
end
