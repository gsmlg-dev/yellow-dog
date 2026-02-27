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
    payload = %{
      "event" => event,
      "host_id" => host.id,
      "hostname" => host.hostname,
      "age_recipient" => host.age_recipient,
      "status" => to_string(host.status),
      "trust_level" => to_string(host.trust_level),
      "trust_provider" => to_string(host.trust_provider),
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
    }

    # Include recipients_url for GitOps integration on approval/revocation events
    case get_registration_url() do
      nil -> payload
      base_url -> Map.put(payload, "recipients_url", String.replace(base_url, "/register", "/recipients"))
    end
  end

  defp send_async(url, payload) do
    Task.start(fn ->
      case Jason.encode(payload) do
        {:ok, body} ->
          deliver_with_retry(url, body, 0)

        {:error, reason} ->
          Logger.warning("Webhook encoding failed: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp deliver_with_retry(url, body, attempt) do
    case http_post(url, body) do
      {:ok, _} ->
        :ok

      {:error, reason} when attempt < @max_retries ->
        delay = @base_delay_ms * Integer.pow(2, attempt)

        Logger.debug(
          "Webhook retry #{attempt + 1}/#{@max_retries} to #{url} in #{delay}ms: #{inspect(reason)}"
        )

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

    ssl_opts =
      if String.starts_with?(url, "https") do
        [{:ssl, [{:verify, :verify_peer}, {:cacerts, :public_key.cacerts_get()}, {:depth, 3}]}]
      else
        []
      end

    http_opts = [{:timeout, 10_000}, {:connect_timeout, 5_000}] ++ ssl_opts

    case :httpc.request(:post, request, http_opts, []) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 ->
        {:ok, status}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_webhook_url do
    get_config_value(["identity", "webhook", "url"])
  end

  defp get_registration_url do
    get_config_value(["identity", "registration_url"])
  end

  defp get_config_value(path) do
    case Code.ensure_loaded(YellowDog.Config) do
      {:module, _} ->
        try do
          config = YellowDog.Config.get_all()
          get_in(config, path)
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
