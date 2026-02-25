defmodule YellowDogIdentity.Webhook do
  @moduledoc """
  Outbound webhook notifications for host identity state changes.

  Sends POST requests to configured webhook URLs when hosts are
  approved, revoked, or registered.
  """

  require Logger

  alias YellowDogIdentity.Host

  @doc """
  Sends a webhook notification for a host state change.
  """
  @spec notify(String.t(), Host.t()) :: :ok
  def notify(event, %Host{} = host) do
    case get_webhook_url() do
      nil ->
        :ok

      url ->
        payload = build_payload(event, host)
        send_async(url, payload)
    end
  end

  defp build_payload(event, host) do
    %{
      "event" => event,
      "host_id" => host.id,
      "hostname" => host.hostname,
      "age_recipient" => host.age_recipient,
      "status" => to_string(host.status),
      "trust_level" => to_string(host.trust_level),
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp send_async(url, payload) do
    Task.start(fn ->
      try do
        body = Jason.encode!(payload)

        case http_post(url, body) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("Webhook delivery failed to #{url}: #{inspect(reason)}")
        end
      rescue
        e ->
          Logger.warning("Webhook error: #{Exception.message(e)}")
      end
    end)

    :ok
  end

  defp http_post(url, body) do
    # Use :httpc from Erlang stdlib — no external HTTP client dependency needed
    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"user-agent", ~c"yellowdog-identity/1.0"}
    ]

    request = {String.to_charlist(url), headers, ~c"application/json", body}

    case :httpc.request(:post, request, [{:timeout, 10_000}], []) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 ->
        {:ok, status}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_webhook_url do
    case Code.ensure_loaded(YellowDog.Config) do
      {:module, _} ->
        try do
          config = YellowDog.Config.get_all()
          get_in(config, ["identity", "webhook", "url"])
        rescue
          _ -> nil
        catch
          :exit, _ -> nil
        end

      _ ->
        nil
    end
  end
end
