defmodule YellowDog.Worker.ConnectionHTTP do
  @moduledoc false
  @max_bytes 1_048_576
  @timeout 5_000

  def connect(options, report) do
    uri = URI.parse(options[:management_url])
    scheme = if uri.scheme == "https", do: :https, else: :http
    transport = [timeout: 3_000, send_timeout: @timeout, send_timeout_close: true]
    transport = if scheme == :https, do: transport ++ tls(options), else: transport

    with true <- YellowDog.Worker.Bootstrap.valid_url?(options[:management_url]),
         {:ok, conn} <-
           Mint.HTTP.connect(scheme, uri.host, uri.port,
             mode: :passive,
             protocols: [:http1],
             transport_opts: transport
           ) do
      try do
        headers = [
          {"authorization", "Bearer " <> options[:token]},
          {"content-type", "application/json"},
          {"connection", "close"}
        ]

        case Mint.HTTP.request(
               conn,
               "POST",
               "/api/worker/connect",
               headers,
               Jason.encode!(report)
             ) do
          {:ok, conn, ref} ->
            receive_response(
              conn,
              ref,
              %{code: nil, chunks: [], size: 0, done: false},
              System.monotonic_time(:millisecond) + @timeout
            )

          _ ->
            {:error, :request_failed}
        end
      after
        Mint.HTTP.close(conn)
      end
    else
      _ -> {:error, :request_failed}
    end
  rescue
    _ -> {:error, :request_failed}
  catch
    _, _ -> {:error, :request_failed}
  end

  defp receive_response(conn, ref, response, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    case Mint.HTTP.recv(conn, 0, remaining) do
      {:ok, conn, events} ->
        case collect(events, ref, response) do
          {:ok, %{done: true} = response} -> finish(response)
          {:ok, response} -> receive_response(conn, ref, response, deadline)
          error -> error
        end

      _ ->
        {:error, :request_failed}
    end
  end

  defp collect(events, ref, response) do
    Enum.reduce_while(events, {:ok, response}, fn
      {:status, ^ref, code}, {:ok, current} ->
        {:cont, {:ok, %{current | code: code}}}

      {:headers, ^ref, headers}, {:ok, current} ->
        oversized? =
          Enum.any?(headers, fn
            {"content-length", length} ->
              case Integer.parse(length) do
                {size, ""} -> size > @max_bytes
                _ -> false
              end

            _ ->
              false
          end)

        if oversized?, do: {:halt, {:error, :response_too_large}}, else: {:cont, {:ok, current}}

      {:data, ^ref, bytes}, {:ok, current} ->
        if current.size + byte_size(bytes) > @max_bytes do
          {:halt, {:error, :response_too_large}}
        else
          chunks = if current.code == 200, do: [bytes | current.chunks], else: current.chunks
          {:cont, {:ok, %{current | size: current.size + byte_size(bytes), chunks: chunks}}}
        end

      {:done, ^ref}, {:ok, current} ->
        {:cont, {:ok, %{current | done: true}}}

      _, _ ->
        {:halt, {:error, :request_failed}}
    end)
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

    [
      verify: :verify_peer,
      depth: 10,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ] ++ ca ++ client
  end
end
