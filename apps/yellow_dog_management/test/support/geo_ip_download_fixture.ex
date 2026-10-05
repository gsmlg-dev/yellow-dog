defmodule YellowDog.Management.GeoIPDownloadFixture do
  def start(status, body, opts \\ []) do
    owner = self()

    server =
      spawn(fn ->
        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
        {:ok, {_address, port}} = :inet.sockname(listener)
        send(owner, {:geo_ip_fixture_ready, self(), port})
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
        send(owner, {:geo_ip_fixture_request, self()})
        Process.sleep(Keyword.get(opts, :header_delay, 0))
        length = Keyword.get(opts, :content_length, byte_size(body))
        headers = Keyword.get(opts, :headers, [])
        chunked = Keyword.get(opts, :chunked, false)

        framing =
          if chunked, do: "Transfer-Encoding: chunked\r\n", else: "Content-Length: #{length}\r\n"

        :gen_tcp.send(socket, [
          "HTTP/1.1 #{status} Fixture\r\n",
          framing,
          "Connection: close\r\n",
          Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end),
          "\r\n"
        ])

        Process.sleep(Keyword.get(opts, :body_delay, 0))

        for chunk <- chunks(body, Keyword.get(opts, :chunk_size, 512)) do
          data =
            if chunked,
              do: [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"],
              else: chunk

          :gen_tcp.send(socket, data)
          Process.sleep(Keyword.get(opts, :chunk_delay, 0))
        end

        if chunked, do: :gen_tcp.send(socket, "0\r\n\r\n")

        if Keyword.get(opts, :hold, false) do
          result = :gen_tcp.recv(socket, 0, 5_000)
          send(owner, {:geo_ip_fixture_closed, self(), result})
        end

        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    receive do
      {:geo_ip_fixture_ready, ^server, port} ->
        ExUnit.Callbacks.on_exit(fn ->
          monitor = Process.monitor(server)
          Process.exit(server, :kill)

          receive do
            {:DOWN, ^monitor, :process, ^server, _reason} -> :ok
          end
        end)

        {"http://127.0.0.1:#{port}/database.mmdb.gz", server}
    after
      5_000 -> raise "HTTP fixture did not start"
    end
  end

  defp chunks(<<>>, _size), do: []

  defp chunks(body, size) when byte_size(body) <= size, do: [body]

  defp chunks(body, size) do
    <<chunk::binary-size(size), rest::binary>> = body
    [chunk | chunks(rest, size)]
  end
end
