defmodule YellowDogIdentity.Webhook do
  @moduledoc """
  Outbound webhook notifications for host identity state changes.

  Sends POST requests to configured webhook URLs when hosts are
  approved, revoked, or registered. Retries with exponential backoff
  on transient failures.
  """

  require Logger

  alias YellowDogIdentity.Host

  @max_retries 3
  @base_delay_ms 1000

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
        deliver_with_retry(url, body, 0)
      rescue
        e ->
          Logger.warning("Webhook error: #{Exception.message(e)}")
      end
    end)

    :ok
  end

  defp deliver_with_retry(url, body, attempt) do
    case http_post(url, body) do
      {:ok, _} ->
        :ok

      {:error, _reason} when attempt < @max_retries ->
        delay = @base_delay_ms * Integer.pow(2, attempt)
        Logger.debug("Webhook retry #{attempt + 1}/#{@max_retries} to #{url} in #{delay}ms")
        Process.sleep(delay)
        deliver_with_retry(url, body, attempt + 1)

      {:error, reason} ->
        Logger.warning(
          "Webhook delivery failed after #{@max_retries} retries to #{url}: #{inspect(reason)}"
        )
    end
  end

  defp http_post(url, body) do
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
