defmodule YellowDog.Worker.Dns.Upstream do
  @moduledoc false
  # The only path by which the Worker talks to upstream DNS servers.

  alias DNS.Message
  alias DNS.Message.{EDNS0, Header, Question}

  @udp_size 1232
  @default_timeout 2_000

  @spec query({:inet.ip_address(), :inet.port_number()}, String.t(), non_neg_integer(), keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def query({ip, port}, name, type, opts \\ []) do
    rd = Keyword.get(opts, :rd, true)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    id = :crypto.strong_rand_bytes(2)
    packet = build(id, name, type, rd)

    with {:ok, wire} <- udp(ip, port, packet, timeout),
         {:ok, msg} <- parse(wire, id, name, type) do
      if msg.header.tc == 1, do: tcp(ip, port, packet, timeout, id, name, type), else: {:ok, msg}
    end
  end

  defp build(<<id::16>>, name, type, rd) do
    header = %Header{
      Header.new()
      | id: id,
        rd: if(rd, do: 1, else: 0),
        qdcount: 1,
        arcount: 1
    }

    message = %Message{header: header, qdlist: [Question.new(name, <<type::16>>, <<1::16>>)]}
    DNS.to_iodata(message) <> DNS.to_iodata(EDNS0.new({@udp_size, 0, 0, 0, 0, []}))
  end

  defp udp(ip, port, packet, timeout), do: Abyss.Client.send_recv(ip, port, packet, timeout)

  defp tcp(ip, port, packet, timeout, id, name, type) do
    opts = [:binary, active: false, packet: 2]

    with {:ok, sock} <- :gen_tcp.connect(ip, port, opts, timeout) do
      try do
        with :ok <- :gen_tcp.send(sock, packet),
             {:ok, wire} <- :gen_tcp.recv(sock, 0, timeout) do
          parse(wire, id, name, type)
        end
      after
        :gen_tcp.close(sock)
      end
    end
  end

  defp parse(wire, <<id::16>>, name, type) do
    msg = Message.from_iodata(wire)

    case msg do
      %Message{header: %{id: ^id, qr: 1}, qdlist: [q]} ->
        if same_question?(q, name, type), do: {:ok, msg}, else: {:error, :mismatch}

      %Message{} ->
        {:error, :mismatch}
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  defp same_question?(q, name, type) do
    norm = fn n -> n |> to_string() |> String.trim_trailing(".") |> String.downcase() end

    norm.(q.name) == norm.(name) and q.type.value == <<type::16>> and q.class.value == <<1::16>>
  end
end
