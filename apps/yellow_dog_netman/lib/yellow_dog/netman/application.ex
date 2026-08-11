defmodule YellowDog.Netman.Application do
  @moduledoc false
  use Application

  alias YellowDog.Config.Schema
  alias YellowDog.ConfigHelpers
  alias YellowDog.Netman.ProfileResolver
  alias YellowDog.NetmanAgent.Bootstrap
  alias YellowDog.Sync.Identity.Netman, as: NetmanIdentity

  require Logger

  @impl true
  def start(_type, _args) do
    if netman_autostart?() and netman_supported?() do
      profile = load_config() |> ProfileResolver.resolve()
      children = netman_children(profile)

      opts = [strategy: :one_for_one, name: YellowDog.Netman.AppSupervisor]
      Supervisor.start_link(children, opts)
    else
      if not netman_autostart?() do
        Logger.info(
          "[Netman] Skipping start — autostart is disabled. Use `mix netman.server` to start Netman."
        )
      else
        Logger.info(
          "[Netman] Skipping start — not supported on this platform (#{inspect(:os.type())})"
        )
      end

      Supervisor.start_link([], strategy: :one_for_one, name: YellowDog.Netman.AppSupervisor)
    end
  end

  @doc false
  def child_specs_for_profile(profile), do: netman_children(profile)

  @doc false
  def start_netman_agent(module, profile) when is_atom(module) and is_map(profile) do
    with {:ok, bootstrap} <- Bootstrap.validate(netman_agent_runtime()),
         {:ok, capabilities} <- netman_capabilities(),
         {:ok, config_revision} <- initial_config_revision(bootstrap),
         {:ok, version} <- netman_version(),
         {:ok, profile_name} <- identity_profile(profile),
         true <- Code.ensure_loaded?(module) and function_exported?(module, :start_link, 1) do
      identity = %NetmanIdentity{
        id: bootstrap.netman_id,
        name: normalize_text(Map.get(profile, :name)) || bootstrap.netman_id,
        version: version,
        profile: profile_name,
        capabilities: capabilities,
        config_revision: config_revision
      }

      module
      |> apply(:start_link, [netman_agent_options(bootstrap, identity, capabilities)])
      |> sanitize_agent_start()
    else
      _invalid -> {:error, :netman_agent_start_failed}
    end
  rescue
    _exception -> {:error, :netman_agent_start_failed}
  catch
    _kind, _reason -> {:error, :netman_agent_start_failed}
  end

  def start_netman_agent(_module, _profile), do: {:error, :netman_agent_start_failed}

  # Returns false when :netman_autostart is explicitly set to false.
  # Used to prevent Netman from starting automatically when running `mix phx.server`.
  # The `mix netman.server` task sets this to true at runtime before starting.
  defp netman_autostart? do
    Application.get_env(:yellow_dog_netman, :netman_autostart, true) != false
  end

  defp netman_children(profile) do
    features = Map.get(profile, :features, %{})
    agent_child = netman_agent_child(profile)
    runtime_required? = start_netman_supervisor?(features) or not is_nil(agent_child)

    [{YellowDog.Netman.RuntimeState, netman_opts(profile)}]
    |> maybe_add_child(Map.get(features, :dns_client, false), {YellowDog.Resolved.Supervisor, []})
    |> maybe_add_child(
      runtime_required?,
      {YellowDog.Netman.Supervisor, netman_opts(profile)}
    )
    |> maybe_add_child(not is_nil(agent_child), agent_child)
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_add_child(children, true, child), do: children ++ [child]
  defp maybe_add_child(children, _enabled, _child), do: children

  defp start_netman_supervisor?(features) do
    Enum.any?(
      [:interfaces, :dhcp_client, :dns_client, :routes, :link_state],
      &Map.get(features, &1, false)
    )
  end

  defp netman_opts(profile) do
    [
      features: Map.get(profile, :features, %{}),
      apply_mode: Map.get(profile, :apply_mode, :managed)
    ]
  end

  defp management_agent_enabled?(profile) do
    management = Map.get(profile, :management, %{})

    if not is_map(management) do
      true
    else
      agent_enabled =
        management
        |> ConfigHelpers.get_value(
          :agent_enabled,
          ConfigHelpers.get_value(management, :enabled, true)
        )

      agent_enabled != false
    end
  end

  defp netman_agent_child(profile) do
    module = netman_agent_module()

    with true <- management_agent_enabled?(profile),
         true <- Code.ensure_loaded?(module) and function_exported?(module, :start_link, 1),
         {:ok, _bootstrap} <- Bootstrap.validate(netman_agent_runtime()) do
      %{
        id: YellowDog.NetmanAgent,
        start: {__MODULE__, :start_netman_agent, [module, profile]},
        type: :supervisor
      }
    else
      _disabled_or_invalid -> nil
    end
  end

  defp netman_agent_options(bootstrap, identity, capabilities) do
    [
      enabled: true,
      data_dir: bootstrap.data_dir,
      netman_id: bootstrap.netman_id,
      capabilities: capabilities,
      config_runtime_adapter: YellowDog.Netman.Control.ConfigRuntimeAdapter,
      client_opts: [
        enabled: true,
        management_url: bootstrap.management_url,
        token: bootstrap.management_token,
        identity: identity,
        dispatcher: YellowDog.NetmanAgent.Dispatcher,
        dispatcher_runtime_adapter: YellowDog.Netman.Control,
        query_dispatcher: YellowDog.NetmanAgent.QueryDispatcher,
        query_runtime_adapter: YellowDog.Netman.Control,
        socket: YellowDog.NetmanAgent.Client.Socket,
        timer: YellowDog.NetmanAgent.Client.Timer,
        monotonic_clock: YellowDog.NetmanAgent.Client.MonotonicClock,
        wall_clock: YellowDog.NetmanAgent.Client.WallClock,
        connection_poll_interval: 100,
        connect_timeout: 10_000,
        join_timeout: 5_000,
        push_timeout: 5_000,
        heartbeat_interval: 30_000,
        status_interval: 30_000,
        initial_backoff: bootstrap.reconnect_initial_ms,
        max_backoff: bootstrap.reconnect_max_ms
      ]
    ]
  end

  defp initial_config_revision(bootstrap) do
    case YellowDog.NetmanAgent.ConfigApplyStore.read_boot_state(
           bootstrap.data_dir,
           bootstrap.netman_id
         ) do
      {:ok, %{known_good: %{revision: revision}}} ->
        {:ok, revision}

      {:ok, %{known_good: nil}} ->
        YellowDog.Netman.profiles_revision()

      {:error, :missing} ->
        YellowDog.Netman.profiles_revision()

      _corrupt_or_invalid ->
        :error
    end
  end

  defp netman_capabilities do
    case YellowDog.Netman.Control.Runtime.dispatch(
           "netman.runtime.capabilities.get",
           %{}
         ) do
      {:ok, %{"capabilities" => capabilities}} when is_list(capabilities) ->
        {:ok, Enum.sort(Enum.uniq(capabilities))}

      _unavailable ->
        :error
    end
  end

  defp netman_version do
    case Application.spec(:yellow_dog_netman, :vsn) do
      nil ->
        :error

      version ->
        version |> to_string() |> normalize_text() |> then(&if(&1, do: {:ok, &1}, else: :error))
    end
  end

  defp identity_profile(profile) do
    profile
    |> Map.get(:profile)
    |> case do
      value when is_atom(value) -> value |> Atom.to_string() |> normalize_text()
      value -> normalize_text(value)
    end
    |> case do
      nil -> :error
      value -> {:ok, value}
    end
  end

  defp sanitize_agent_start({:ok, pid} = result) when is_pid(pid), do: result
  defp sanitize_agent_start(_invalid), do: {:error, :netman_agent_start_failed}

  defp netman_agent_runtime do
    case Application.get_env(:yellow_dog_netman_agent, :runtime, []) do
      runtime when is_list(runtime) -> if Keyword.keyword?(runtime), do: runtime, else: []
      _invalid -> []
    end
  end

  defp netman_agent_module do
    case Application.get_env(:yellow_dog_netman, :netman_agent_module, YellowDog.NetmanAgent) do
      module when is_atom(module) and not is_nil(module) -> module
      _invalid -> YellowDog.NetmanAgent
    end
  end

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_text(_value), do: nil

  defp load_config do
    cond do
      Process.whereis(YellowDog.Config) ->
        YellowDog.Config.get_all()

      config_file_path = Application.get_env(:yellow_dog, :config_file_path) ->
        load_config_file(config_file_path)

      true ->
        Schema.defaults()
    end
  end

  defp load_config_file(config_file_path) do
    with {:ok, content} <- File.read(config_file_path),
         {:ok, parsed} <- Toml.decode(content) do
      Schema.merge_defaults(parsed)
    else
      _error -> Schema.defaults()
    end
  end

  # Netman requires Linux netlink interfaces. It is not supported on macOS/Darwin
  # or when explicitly disabled via the :netman_enabled application env.
  defp netman_supported? do
    Application.get_env(:yellow_dog, :netman_enabled, true) != false and
      :os.type() != {:unix, :darwin}
  end
end
