defmodule YellowDog.DnsProvider.HTTPServer do
  @moduledoc false
  use GenServer

  def start_link(handler), do: GenServer.start_link(__MODULE__, handler)
  def base_url(server, path \\ ""), do: GenServer.call(server, :base_url) <> path
  def response(options), do: Map.new(options)

  @impl true
  def init(handler) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    acceptor = spawn_link(fn -> accept(listener, handler) end)
    {:ok, %{listener: listener, acceptor: acceptor, port: port}}
  end

  @impl true
  def handle_call(:base_url, _from, state), do: {:reply, "http://127.0.0.1:#{state.port}", state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    Process.exit(state.acceptor, :shutdown)
  end

  defp accept(listener, handler) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        try do
          socket |> read_request() |> handler.() |> write_response(socket)
        after
          :gen_tcp.close(socket)
        end

        accept(listener, handler)

      {:error, :closed} ->
        :ok
    end
  end

  defp read_request(socket) do
    :ok = :inet.setopts(socket, packet: :http_bin)
    {:ok, {:http_request, method, {:abs_path, target}, _}} = :gen_tcp.recv(socket, 0, 5_000)
    headers = read_headers(socket, %{})
    :ok = :inet.setopts(socket, packet: :raw)
    length = headers |> Map.get("content-length", "0") |> String.to_integer()
    body = if length == 0, do: "", else: elem(:gen_tcp.recv(socket, length, 5_000), 1)

    %{
      method: method |> to_string() |> String.downcase() |> String.to_existing_atom(),
      url: URI.parse(target),
      headers: headers,
      body: body
    }
  end

  defp read_headers(socket, headers) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, :http_eoh} ->
        headers

      {:ok, {:http_header, _, name, _, value}} ->
        read_headers(socket, Map.put(headers, name |> to_string() |> String.downcase(), value))
    end
  end

  defp write_response(%{raw: handler}, socket), do: handler.(socket)

  defp write_response(response, socket) do
    body = Map.get(response, :body, "")
    json? = is_map(body) or is_list(body)
    body = if json?, do: Jason.encode!(body), else: body
    content_type = if json?, do: "application/json", else: "text/plain"
    headers = Map.get(response, :headers, [{"content-type", content_type}])

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{Map.get(response, :status, 200)} OK\r\n",
      Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end),
      "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
      body
    ])
  end
end
