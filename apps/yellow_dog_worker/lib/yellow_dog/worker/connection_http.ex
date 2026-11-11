defmodule YellowDog.Worker.ConnectionHTTP do
  @moduledoc false
  @max_bytes 1_048_576
  @timeout 5_000

  def connect(options, report) do
    uri = URI.parse(options[:management_url])

    with true <- YellowDog.Worker.Bootstrap.valid_url?(options[:management_url]) do
      fetch_options = [
        method: "POST",
        headers: [
          {"authorization", "Bearer " <> options[:token]},
          {"content-type", "application/json"},
          {"connection", "close"}
        ],
        body: Jason.encode!(report),
        redirect: :error,
        http_version: :http1,
        stream_response: true,
        timeout: @timeout,
        connect_timeout: 3_000
      ]

      fetch_options =
        if uri.scheme == "https", do: [{:ssl, tls(options)} | fetch_options], else: fetch_options

      url = URI.to_string(%{uri | path: "/api/worker/connect", query: nil, fragment: nil})

      case url |> HTTP.fetch(fetch_options) |> HTTP.Promise.await() do
        %HTTP.Response{status: status} = response ->
          read_body(response, status, System.monotonic_time(:millisecond) + @timeout)

        _ ->
          {:error, :request_failed}
      end
    else
      _ -> {:error, :request_failed}
    end
  rescue
    _ -> {:error, :request_failed}
  catch
    _, _ -> {:error, :request_failed}
  end

  defp read_body(response, status, deadline) do
    oversized? =
      case HTTP.Response.get_header(response, "content-length") do
        nil ->
          false

        length ->
          case Integer.parse(length) do
            {size, ""} -> size > @max_bytes
            _ -> false
          end
      end

    case HTTP.Response.stream_pid(response) do
      _ when oversized? ->
        {:error, :response_too_large}

      nil ->
        body = HTTP.Response.read_all(response)

        if byte_size(body) > @max_bytes,
          do: {:error, :response_too_large},
          else: finish(%{code: status, chunks: [body]})

      stream ->
        monitor = Process.monitor(stream)
        send(stream, {:read_chunk, self(), :ack})

        try do
          collect(stream, monitor, deadline, status, %{size: 0, chunks: []})
        after
          Process.demonitor(monitor, [:flush])
        end
    end
  end

  defp collect(stream, monitor, deadline, status, acc) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:stream_chunk, ^stream, chunk, ack_ref} ->
        send(stream, {:stream_chunk_ack, ack_ref})
        append(stream, monitor, deadline, status, acc, chunk)

      {:stream_chunk, ^stream, chunk} ->
        append(stream, monitor, deadline, status, acc, chunk)

      {:stream_end, ^stream} ->
        finish(%{code: status, chunks: acc.chunks})

      {:stream_error, ^stream, _reason} ->
        {:error, :request_failed}

      {:DOWN, ^monitor, :process, ^stream, _reason} ->
        {:error, :request_failed}
    after
      remaining ->
        HTTP.Stream.stop(stream, :timeout)
        {:error, :request_failed}
    end
  end

  defp append(stream, monitor, deadline, status, acc, chunk) do
    size = acc.size + byte_size(chunk)

    if size > @max_bytes do
      HTTP.Stream.stop(stream, :response_too_large)
      {:error, :response_too_large}
    else
      chunks = if status == 200, do: [chunk | acc.chunks], else: acc.chunks
      collect(stream, monitor, deadline, status, %{size: size, chunks: chunks})
    end
  end

  defp finish(%{code: 200, chunks: chunks}) do
    case Jason.decode(chunks |> Enum.reverse() |> IO.iodata_to_binary()) do
      {:ok, response} when is_map(response) -> {:ok, response}
      _ -> {:error, :invalid_response}
    end
  end

  defp finish(%{code: 401}), do: {:error, :unauthorized}
  defp finish(_), do: {:error, :request_failed}

  defp tls(options) do
    ca =
      case options[:tls_ca_file] do
        nil -> [cacerts: :public_key.cacerts_get()]
        path -> [cacertfile: String.to_charlist(path)]
      end

    client =
      if options[:tls_cert_file] && options[:tls_key_file] do
        [
          certfile: String.to_charlist(options[:tls_cert_file]),
          keyfile: String.to_charlist(options[:tls_key_file])
        ]
      else
        []
      end

    [verify: :verify_peer] ++ ca ++ client
  end
end
