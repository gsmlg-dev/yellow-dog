defmodule YellowDogIdentity.Supervisor do
  @moduledoc """
  Supervisor for the identity service.

  Manages the Registry GenServer and DHCP LeaseCache.
  """

  use Supervisor

  require Logger

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    data_dir = Keyword.get(opts, :data_dir, "data/identity")

    validate_config()
    ensure_ets_caches()

    children = [
      {YellowDogIdentity.Registry, [data_dir: data_dir]},
      {YellowDogIdentity.Trust.DHCP.LeaseCache, []},
      # Post-init: start Store event consumers if available
      {Task, fn -> start_store_consumers() end}
      |> Supervisor.child_spec(id: :post_init, restart: :temporary)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp ensure_ets_caches do
    # Create GCP JWKS cache table owned by the supervisor process,
    # preventing garbage collection when short-lived Tasks create it
    try do
      :ets.new(:gcp_jwks_cache, [:set, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end
  end

  defp validate_config do
    case Code.ensure_loaded(YellowDog.Config) do
      {:module, _} ->
        try do
          config = YellowDog.Config.get_all()
          identity_config = Map.get(config, "identity", %{})
          validate_approval_config(get_in(identity_config, ["approval"]))
          validate_cloud_config(get_in(identity_config, ["cloud"]))
          validate_webhook_config(get_in(identity_config, ["webhook"]))
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp validate_approval_config(nil), do: :ok

  defp validate_approval_config(config) when is_map(config) do
    case Map.get(config, "default_action") do
      action when action in [nil, "pending", "approve", "reject"] ->
        :ok

      invalid ->
        Logger.warning("Identity: invalid approval default_action '#{invalid}', using 'pending'")
    end

    case Map.get(config, "policies") do
      nil ->
        :ok

      policies when is_list(policies) ->
        Enum.each(policies, fn policy ->
          unless Map.has_key?(policy, "name") do
            Logger.warning("Identity: approval policy missing 'name' field")
          end

          unless Map.get(policy, "action") in ["approve", "reject"] do
            Logger.warning(
              "Identity: approval policy '#{Map.get(policy, "name", "?")}' has invalid action"
            )
          end
        end)

      _ ->
        Logger.warning("Identity: approval.policies should be a list")
    end
  end

  defp validate_approval_config(_), do: :ok

  defp validate_cloud_config(nil), do: :ok

  defp validate_cloud_config(config) when is_map(config) do
    Enum.each(["aws", "gcp", "azure"], fn provider ->
      case Map.get(config, provider) do
        %{"allowed_projects" => projects} when not is_list(projects) ->
          Logger.warning("Identity: cloud.#{provider}.allowed_projects should be a list")

        _ ->
          :ok
      end
    end)
  end

  defp validate_cloud_config(_), do: :ok

  defp validate_webhook_config(nil), do: :ok

  defp validate_webhook_config(config) when is_map(config) do
    case Map.get(config, "url") do
      nil ->
        :ok

      url when is_binary(url) ->
        unless String.starts_with?(url, "http://") or String.starts_with?(url, "https://") do
          Logger.warning("Identity: webhook.url should start with http:// or https://")
        end

      _ ->
        Logger.warning("Identity: webhook.url should be a string")
    end
  end

  defp validate_webhook_config(_), do: :ok

  defp start_store_consumers do
    if Process.whereis(YellowDog.Store.EventBridge) do
      child_spec =
        {YellowDog.Store.ConfigWatcher,
         service: :identity,
         handler: &handle_store_config_change/2,
         name: :identity_store_config_watcher}

      case Supervisor.start_child(__MODULE__, child_spec) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, _reason} -> :ok
      end
    end
  rescue
    _ -> :ok
  end

  defp handle_store_config_change(key, value) do
    :telemetry.execute(
      [:yellow_dog, :identity, :config, :store_change],
      %{},
      %{key: key, value: value}
    )
  end
end
