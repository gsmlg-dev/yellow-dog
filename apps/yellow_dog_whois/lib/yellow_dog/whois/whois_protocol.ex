defmodule YellowDog.Whois.WhoisProtocol do
  @moduledoc """
  TCP WHOIS lookup protocol (RFC 3912).

  Returns root-first `{server_host, raw_text}` records. DNS, connection,
  send, response reads and referrals share one finite deadline. A linked
  worker bounds native DNS resolution and owns all sockets so cancellation
  also closes them.
  """

  require Logger

  alias YellowDog.Whois.Server

  @type result :: {:ok, [{binary(), binary()}]} | {:error, term()}

  @doc """
  Performs a raw WHOIS lookup starting from the given server.

  `:timeout` is the total budget in milliseconds (default: the application's
  `:yellow_dog_whois, :timeout` configuration, or 30,000). Expiry returns
  `{:error, :timeout}`, including when a referral times out.
  """
  @spec lookup(binary(), Server.t(), keyword()) :: result()
  def lookup(query, server, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Application.get_env(:yellow_dog_whois, :timeout, 30_000))

    unless is_integer(timeout) and timeout >= 0 do
      raise ArgumentError, "WHOIS timeout must be a non-negative integer in milliseconds"
    end

    deadline = System.monotonic_time(:millisecond) + timeout

    if timeout == 0 do
      {:error, :timeout}
    else
      task = Task.async(fn -> lookup_until(query, server, deadline) end)

      try do
        case Task.yield(task, remaining(deadline)) do
          {:ok, result} -> if remaining(deadline) > 0, do: result, else: {:error, :timeout}
          nil -> {:error, :timeout}
        end
      after
        Task.shutdown(task, :brutal_kill)
      end
    end
  end

  defp lookup_until(query, server, deadline) do
    host = server.host
    Logger.debug("WHOIS lookup #{query} on #{host}")

    with {:ok, timeout} <- budget(deadline),
         {:ok, socket} <-
           :gen_tcp.connect(
             String.to_charlist(host),
             server.port,
             [
               active: false,
               mode: :binary,
               packet: :raw,
               send_timeout: timeout,
               send_timeout_close: true
             ],
             timeout
           ) do
      raw_result =
        try do
          with {:ok, timeout} <- budget(deadline),
               :ok <- :inet.setopts(socket, send_timeout: timeout),
               :ok <- :gen_tcp.send(socket, [query, "\r\n"]) do
            recv_all(socket, deadline, [])
          end
        after
          :gen_tcp.close(socket)
        end

      with {:ok, raw} <- raw_result do
        case next_server(raw) do
          nil ->
            {:ok, [{host, raw}]}

          ^server ->
            {:ok, [{host, raw}]}

          next ->
            case lookup_until(query, next, deadline) do
              {:ok, rest} -> {:ok, [{host, raw} | rest]}
              {:error, :timeout} = error -> error
              {:error, _} -> {:ok, [{host, raw}]}
            end
        end
      end
    end
  end

  defp recv_all(socket, deadline, acc) do
    with {:ok, timeout} <- budget(deadline) do
      case :gen_tcp.recv(socket, 0, timeout) do
        {:ok, data} -> recv_all(socket, deadline, [data | acc])
        {:error, :closed} -> {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  defp budget(deadline) do
    case remaining(deadline) do
      0 -> {:error, :timeout}
      timeout -> {:ok, timeout}
    end
  end

  defp next_server(raw) do
    raw
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case line |> String.trim() |> String.downcase() do
        "whois:" <> host -> referral(host)
        "whois server:" <> host -> referral(host)
        "registrar whois server:" <> host -> referral(host)
        _ -> nil
      end
    end)
  end

  defp referral(host) do
    host = String.trim(host)
    uri = URI.parse(if String.contains?(host, "://"), do: host, else: "whois://" <> host)

    case uri do
      %URI{scheme: "whois", host: host, port: port}
      when is_binary(host) and host != "" and (is_nil(port) or port in 1..65_535) ->
        %Server{host: host, port: port || 43}

      _ ->
        nil
    end
  end
end
