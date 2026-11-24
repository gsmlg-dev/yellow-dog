defmodule YellowDog.Worker.Dns.Doh do
  @moduledoc false

  alias YellowDog.Worker.Dns.Resolver

  @media_type "application/dns-message"
  @timeout 2_000
  @max_header_count 64

  def serve(client, peer, adapter) do
    deadline = System.monotonic_time(:millisecond) + @timeout

    result =
      with :ok <- :ssl.setopts(client, packet: :http_bin, packet_size: 8192),
           {:ok, {:http_request, method, {:abs_path, target}, {1, _}}} <-
             recv(client, 0, deadline),
           :ok <- :ssl.setopts(client, packet: :httph_bin),
           {:ok, headers} <- headers(client, %{}, @max_header_count, deadline),
           :ok <- :ssl.setopts(client, packet: :raw, packet_size: 0),
           {:ok, packet} <- dns_packet(client, method, target, headers, deadline),
           {:ok, context} <- GenServer.call(adapter, :snapshot, @timeout),
           reply when is_binary(reply) <- Resolver.reply(packet, context, :tcp, peer) do
        {:ok, reply}
      end

    response(client, result)
  catch
    :exit, _ -> :ok
  end

  defp headers(client, entries, remaining, deadline) do
    case recv(client, 0, deadline) do
      {:ok, :http_eoh} ->
        {:ok, entries}

      {:ok, {:http_header, _, key, _, value}} when remaining > 0 ->
        name = key |> to_string() |> String.downcase()

        if name in ["content-length", "content-type", "transfer-encoding"] do
          if Map.has_key?(entries, name) do
            {:error, :bad_request}
          else
            headers(client, Map.put(entries, name, value), remaining - 1, deadline)
          end
        else
          headers(client, entries, remaining - 1, deadline)
        end

      _ ->
        {:error, :bad_request}
    end
  end

  defp dns_packet(_client, _method, _target, %{"transfer-encoding" => _}, _deadline),
    do: {:error, :bad_request}

  defp dns_packet(client, method, target, headers, deadline) do
    case String.split(target, "?", parts: 2) do
      ["/dns-query" | query] -> request_payload(client, method, query, headers, deadline)
      _ -> {:error, :not_found}
    end
  end

  defp request_payload(_client, :GET, [query], headers, _deadline) do
    with true <- headers["content-length"] in [nil, "0"],
         [{_, encoded}] <- Enum.filter(URI.query_decoder(query), &(elem(&1, 0) == "dns")),
         {:ok, packet} when byte_size(packet) in 12..65_535 <-
           Base.url_decode64(encoded, padding: false) do
      {:ok, packet}
    else
      _ -> {:error, :bad_request}
    end
  rescue
    ArgumentError -> {:error, :bad_request}
  end

  defp request_payload(_client, :GET, _query, _headers, _deadline), do: {:error, :bad_request}

  defp request_payload(client, :POST, _query, headers, deadline) do
    if String.downcase(headers["content-type"] || "") == @media_type do
      case Integer.parse(headers["content-length"] || "") do
        {length, ""} when length in 12..65_535 -> recv(client, length, deadline)
        _ -> {:error, :bad_request}
      end
    else
      {:error, :unsupported_media_type}
    end
  end

  defp request_payload(_client, _method, _query, _headers, _deadline),
    do: {:error, :method_not_allowed}

  defp recv(client, length, deadline) do
    :ssl.recv(client, length, max(0, deadline - System.monotonic_time(:millisecond)))
  end

  defp response(client, {:ok, packet}) do
    :ssl.send(client, [
      "HTTP/1.1 200 OK\r\nContent-Type: ",
      @media_type,
      "\r\nCache-Control: no-store\r\nContent-Length: ",
      Integer.to_string(byte_size(packet)),
      "\r\nConnection: close\r\n\r\n",
      packet
    ])
  end

  defp response(client, result) do
    {status, headers} =
      case result do
        {:error, :not_found} -> {"404 Not Found", ""}
        {:error, :method_not_allowed} -> {"405 Method Not Allowed", "Allow: GET, POST\r\n"}
        {:error, :unsupported_media_type} -> {"415 Unsupported Media Type", ""}
        _ -> {"400 Bad Request", ""}
      end

    :ssl.send(client, [
      "HTTP/1.1 ",
      status,
      "\r\n",
      headers,
      "Content-Length: 0\r\nConnection: close\r\n\r\n"
    ])
  end
end
