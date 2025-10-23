defmodule HandleDNS do
  use Abyss.Handler
  alias DNS.Message.EDNS0

  def handle_data(recv_data, state) do
    {ip, port, data} = recv_data
    IO.puts("📩 Received UDP message from #{:inet.ntoa(ip)}:#{port} ->")
    dns_message = DNS.Message.from_iodata(data)
    # IO.inspect(data, limit: :infinity)
    # IO.puts(to_string(dns_message))

    resp = forward(dns_message)

    header = %{dns_message.header | qr: 1, ancount: 0, nscount: 0, arcount: 0}
    qdlist = dns_message.qdlist

    new_msg =
      case resp do
        %DNS.Message{
          header: header,
          qdlist: qdlist,
          anlist: anlist,
          nslist: nslist,
          arlist: arlist
        } ->
          %{
            DNS.Message.new()
            | header: %{
                header
                | id: dns_message.header.id
              },
              qdlist: qdlist,
              anlist: anlist,
              nslist: nslist,
              arlist: arlist
          }

        _ ->
          %{DNS.Message.new() | header: header, qdlist: qdlist}
      end

    iodata = DNS.to_iodata(new_msg)
    :gen_udp.send(state.socket, ip, port, iodata)
    {:close, state}
  end

  def forward(dns_message) do
    IO.puts("forwarding...")

    msg = %{DNS.Message.new() | qdlist: dns_message.qdlist}
    msg = %{msg | header: %{msg.header | qdcount: dns_message.header.qdcount, rd: 1}}

    msg = msg |> set_edns0()

    {:ok, socket} =
      :gen_udp.open(0, mode: :binary, active: false, reuseaddr: true, reuseport: true)

    :ok = :gen_udp.send(socket, {8, 8, 8, 8}, 53, DNS.to_iodata(msg))

    case :gen_udp.recv(socket, 0, to_timeout(second: 3)) do
      {:ok, {_ip, _port, data}} ->
        resp = DNS.Message.from_iodata(data)
        # IO.inspect(data, limit: :infinity)
        # IO.puts("from forwarder:")
        # IO.inspect(resp, limit: :infinity)
        IO.puts("from forwarder:\n#{resp}")
        :gen_udp.close(socket)
        resp

      _ ->
        IO.puts("forward failed")
        :gen_udp.close(socket)
        nil
    end
  rescue
    err ->
      IO.inspect(err)
      IO.inspect(__STACKTRACE__)
      nil
  end

  def set_edns0(msg) do
    # {udp_payload, extended_rcode, version, do_bit, flags, options}
    edns0 = DNS.Message.EDNS0.new({1232, 0, 0, 1, 0, []})

    ecs = EDNS0.Option.ECS.new({{167, 179, 96, 0}, 19, 19})

    client = "asdfqwer"
    cookie = EDNS0.Option.Cookie.new({<<client::binary-size(8)>>, client})

    edns0 = edns0 |> EDNS0.add_option(ecs) |> EDNS0.add_option(cookie)

    rr = DNS.Message.Record.from_iodata(DNS.to_iodata(edns0))

    %{
      msg
      | header: %{msg.header | arcount: msg.header.arcount + 1},
        arlist:
          Enum.filter(msg.arlist, fn r -> r.type.value != <<41::16>> end) ++
            [
              rr
            ]
    }
  end
end
