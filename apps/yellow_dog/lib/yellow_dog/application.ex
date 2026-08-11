defmodule YellowDog.Application do
  @moduledoc """
  Main application supervisor for YellowDog with conditional service starting.

  Starts the configuration manager first, then conditionally starts protocol
  services based on the configuration settings.
  """

  use Application

  alias YellowDog.Server.{BootConfig, ConfigReconciler, ProfileResolver}
  alias YellowDog.Server.ServiceRegistry
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.ServerOperation

  # Capture Mix.env() at compile time (Mix is not available in releases)
  @compile_env Mix.env()
  @default_server_agent_module :"Elixir.YellowDog.ServerAgent"
  @default_reconnect_initial_ms 1_000
  @default_reconnect_max_ms 30_000
  @max_reconnect_ms 86_400_000
  @server_agent_reconcile_attempts 3
  @server_agent_terminal_reconcile_attempts 3
  @managed_reconcile_key {__MODULE__, :managed_reconcile}

  @impl true
  def start(_type, _args) do
    # Attach telemetry logger handlers before starting services
    # This enables log output for all protocol-specific telemetry events
    YellowDog.Telemetry.attach_logger_handlers()

    # Attach Abyss logger if configured
    # This enables debug logging for UDP transport operations
    if log_level = Application.get_env(:abyss, :log_level) do
      Abyss.Logger.attach_logger(log_level)
    end

    # Load the local/bootstrap TOML first, then select only the exact managed
    # revision acknowledged as known-good by the durable Server-agent journal.
    case load_boot_config() do
      {:ok, boot} -> start_with_boot(boot)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_with_boot(boot) do
    bootstrap = boot.bootstrap
    config = boot.effective

    # Log which config file was loaded and enabled services
    log_config_info(config)

    # Debug: emit telemetry for loaded config
    :telemetry.execute(
      [:yellow_dog, :config, :loaded],
      %{count: 1},
      %{source: __MODULE__, severity: :debug}
    )

    # Only start essential children in the supervisor init.
    # Protocol services are started asynchronously in a post-init task
    # so that one service failure (e.g., DNS can't bind port 53) doesn't
    # prevent other services from starting.
    children = [
      # Configuration manager - must start first
      {YellowDog.Config, [bootstrap: bootstrap, effective: config]},
      # Data layer supervisor (Registry for collection tracking)
      YellowDog.Data.Supervisor,
      # Store mode detector: creates ETS table, detects single-node vs. cluster
      YellowDog.Store.ModeDetector,
      # Task supervisor for EventBridge handler dispatch and event persistence
      {Task.Supervisor, name: YellowDog.Store.TaskSupervisor},
      # Store event bridge (must start before DynDnsUpdater)
      YellowDog.Store.EventBridge,
      # DynDnsUpdater: subscribes to lease events, creates DNS records
      {YellowDog.Store.DynDnsUpdater, domain: get_dyn_dns_domain(config)},
      # Service heartbeat for periodic status logging
      YellowDog.ServiceHeartbeat
    ]

    # Note: YellowDog.Console and YellowDog.Netman have their own Application
    # modules and start separately as OTP applications

    opts = [strategy: :one_for_one, name: YellowDog.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Start protocol services asynchronously after supervisor is up.
        # Each service is started independently so failures are isolated.
        start_services_async(config)
        {:ok, pid}

      error ->
        error
    end
  end

  @doc "Returns the local directory shared by managed config history and apply evidence."
  @spec managed_config_data_dir(map()) :: String.t()
  def managed_config_data_dir(bootstrap) when is_map(bootstrap) do
    case runtime_value(server_agent_runtime(), :data_dir) do
      value when is_binary(value) and value != "" -> resolve_data_dir(value)
      _unset -> get_data_dir(bootstrap)
    end
  end

  @doc "Hot-reconciles only service supervisors affected by an effective config change."
  @spec reconcile_config(map(), map()) :: :ok | {:error, term()}
  def reconcile_config(previous, next) when is_map(previous) and is_map(next) do
    previous_flag = Process.get(@managed_reconcile_key)
    Process.put(@managed_reconcile_key, true)

    try do
      case ConfigReconciler.reconcile(previous, next) do
        :ok ->
          refresh_managed_server_agent_identity(next)
          :ok

        {:error, _reason} = error ->
          error
      end
    after
      restore_process_flag(previous_flag)
    end
  end

  def reconcile_config(_previous, _next), do: {:error, :invalid_reconciliation_input}

  @doc """
  Starts a service supervisor dynamically.

  ## Parameters
  - `service` - Service name (:dns, :mdns, :dhcpv4, :dhcpv6)
  - `supervisor_module` - The supervisor module to start

  ## Returns
  - `{:ok, pid}` if started successfully
  - `{:ok, :restarting}` if the supervisor already owns a pending restart
  - `{:error, reason}` if start failed
  """
  @spec start_service_supervisor(atom(), module()) ::
          {:ok, pid() | :restarting} | {:error, term()}
  def start_service_supervisor(:server_agent, _supervisor_module) do
    case ProfileResolver.resolve(current_config()) do
      %{source: :yellow_dog_server} ->
        module = server_agent_module()

        if Code.ensure_loaded?(module) and function_exported?(module, :start_link, 1) do
          start_service_child(:server_agent, server_agent_child_spec(module))
        else
          {:error, :module_not_available}
        end

      _unsupported_profile ->
        {:error, :unsupported_profile}
    end
  end

  def start_service_supervisor(service, _supervisor_module) do
    case ServiceRegistry.fetch(service) do
      {:ok, %{controllable?: true, module: app_module}} ->
        app_module = service_module(service, app_module)

        # Guard: module may not be available in all releases
        if not Code.ensure_loaded?(app_module) do
          {:error, :module_not_available}
        else
          start_service_supervisor_impl(service, app_module)
        end

      {:ok, _metadata} ->
        {:error, :not_controllable}

      :error ->
        {:error, :unknown_service}
    end
  end

  defp start_service_supervisor_impl(service, app_module) do
    # Get server options from current config
    config = YellowDog.Config.get_all()
    server_options = build_server_options(config, service)

    # Build child spec
    child_spec = {app_module, server_options: server_options}

    start_service_child(service, child_spec)
  end

  defp start_service_child(service, child_spec) do
    result =
      case service do
        :server_agent ->
          case start_or_recover_server_agent_child(child_spec) do
            :ignore -> {:error, :service_disabled}
            result -> result
          end

        _other ->
          Supervisor.start_child(YellowDog.Supervisor, child_spec)
      end

    case result do
      {:ok, :restarting} when service == :server_agent ->
        emit_server_agent_reconcile_pending()
        {:ok, :restarting}

      {:ok, pid} ->
        :telemetry.execute(
          [:yellow_dog, :service, :started],
          %{count: 1},
          %{source: __MODULE__, service: service, pid: inspect(pid), severity: :info}
        )

        refresh_server_agent_identity(service)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        :telemetry.execute(
          [:yellow_dog, :service, :started],
          %{count: 1},
          %{
            source: __MODULE__,
            service: service,
            pid: inspect(pid),
            already_started: true,
            severity: :info
          }
        )

        refresh_server_agent_identity(service)
        {:error, {:already_started, pid}}

      {:error, reason} = error ->
        :telemetry.execute(
          [:yellow_dog, :application, :error],
          %{count: 1},
          %{
            source: __MODULE__,
            service: service,
            reason: service_start_error(service, reason),
            severity: :error
          }
        )

        error
    end
  end

  @doc """
  Stops a service supervisor dynamically.

  ## Parameters
  - `service` - Service name (:dns, :mdns, :dhcpv4, :dhcpv6)
  - `supervisor_module` - The supervisor module to stop

  ## Returns
  - `:ok` if stopped successfully
  - `{:error, reason}` if stop failed
  """
  @spec stop_service_supervisor(atom(), module()) :: :ok | {:error, term()}
  def stop_service_supervisor(service, _supervisor_module) do
    case ServiceRegistry.fetch(service) do
      {:ok, %{controllable?: true, module: app_module}} ->
        child_id =
          if service == :server_agent,
            do: @default_server_agent_module,
            else: service_module(service, app_module)

        case Supervisor.terminate_child(YellowDog.Supervisor, child_id) do
          :ok ->
            # Also delete the child spec so it can be restarted later
            Supervisor.delete_child(YellowDog.Supervisor, child_id)

            :telemetry.execute(
              [:yellow_dog, :service, :stopped],
              %{count: 1},
              %{source: __MODULE__, service: service, severity: :info}
            )

            refresh_server_agent_identity(service)
            :ok

          {:error, :not_found} ->
            :telemetry.execute(
              [:yellow_dog, :service, :stopped],
              %{count: 1},
              %{source: __MODULE__, service: service, not_found: true, severity: :debug}
            )

            refresh_server_agent_identity(service)
            {:error, :not_found}

          {:error, reason} = error ->
            :telemetry.execute(
              [:yellow_dog, :application, :error],
              %{count: 1},
              %{source: __MODULE__, service: service, reason: inspect(reason), severity: :error}
            )

            error
        end

      {:ok, _metadata} ->
        {:error, :not_controllable}

      :error ->
        {:error, :unknown_service}
    end
  end

  # Starts enabled services asynchronously after the supervisor is running.
  # Each service is started independently so one failure doesn't block others.
  defp start_services_async(_boot_config) do
    Task.start(fn ->
      # Start DNS Provider subsystem unconditionally (ConfigWatcher handles empty state)
      # Must start after Store children (ModeDetector, EventBridge) are ready
      maybe_start_dns_provider()

      startup_barrier = await_startup_selection()

      try do
        config = current_config()
        enabled_services = get_enabled_services(config)

        Enum.each(enabled_services, fn {service, child_spec} ->
          start_async_service_child(service, child_spec)
        end)
      after
        notify_startup_selection_complete(startup_barrier)
      end
    end)
  end

  defp start_async_service_child(:server_agent, child_spec) do
    case start_or_recover_server_agent_child(child_spec) do
      :ignore ->
        :ok

      {:ok, :restarting} ->
        emit_server_agent_reconcile_pending()

      {:ok, pid} ->
        emit_async_service_started(:server_agent, pid, false)

      {:error, {:already_started, pid}} ->
        emit_async_service_started(:server_agent, pid, true)

      {:error, reason} ->
        emit_async_service_error(:server_agent, reason)
    end
  end

  defp start_async_service_child(service, child_spec) do
    case Supervisor.start_child(YellowDog.Supervisor, child_spec) do
      {:ok, pid} -> emit_async_service_started(service, pid, false)
      {:error, reason} -> emit_async_service_error(service, reason)
    end
  end

  defp emit_async_service_started(service, pid, already_started?) do
    metadata = %{source: __MODULE__, service: service, pid: inspect(pid), severity: :info}
    metadata = if already_started?, do: Map.put(metadata, :already_started, true), else: metadata

    :telemetry.execute(
      [:yellow_dog, :service, :started],
      %{count: 1},
      metadata
    )
  end

  defp emit_async_service_error(service, reason) do
    :telemetry.execute(
      [:yellow_dog, :application, :error],
      %{count: 1},
      %{
        source: __MODULE__,
        service: service,
        reason: service_start_error(service, reason),
        severity: :error
      }
    )
  end

  defp emit_server_agent_reconcile_pending do
    :telemetry.execute(
      [:yellow_dog, :service, :start_pending],
      %{count: 0},
      %{
        source: __MODULE__,
        service: :server_agent,
        reason: :restarting,
        severity: :info
      }
    )
  end

  # Starts the DNS Provider supervisor if the module is available.
  # Uses Code.ensure_loaded? to avoid a hard dependency on yellow_dog_dns_provider
  # (which would create a circular dependency since dns_provider depends on yellow_dog).
  defp maybe_start_dns_provider do
    module = YellowDog.DnsProvider.Supervisor

    if Code.ensure_loaded?(module) do
      case Supervisor.start_child(YellowDog.Supervisor, module) do
        {:ok, pid} ->
          :telemetry.execute(
            [:yellow_dog, :service, :started],
            %{count: 1},
            %{source: __MODULE__, service: :dns_provider, pid: inspect(pid), severity: :info}
          )

        {:error, reason} ->
          :telemetry.execute(
            [:yellow_dog, :application, :error],
            %{count: 1},
            %{
              source: __MODULE__,
              service: :dns_provider,
              reason: inspect(reason),
              severity: :error
            }
          )
      end
    end
  end

  # Note: config_change is not needed in the main YellowDog app
  # The console app handles its own config changes through YellowDog.Console.Application

  # Loads TOML configuration from the file path specified in runtime.exs.
  # Uses Schema.merge_defaults/1 to fill missing sections from loaded config,
  # so new service sections added in Schema appear automatically.
  defp load_toml_config do
    config_file_path = Application.get_env(:yellow_dog, :config_file_path)

    config =
      if config_file_path do
        case File.read(config_file_path) do
          {:ok, content} ->
            case Toml.decode(content) do
              {:ok, parsed} ->
                YellowDog.Config.Schema.merge_defaults(parsed)

              {:error, reason} ->
                :telemetry.execute(
                  [:yellow_dog, :config, :error],
                  %{count: 1},
                  %{
                    source: __MODULE__,
                    reason: :parse_error,
                    config_file: config_file_path,
                    error: inspect(reason),
                    severity: :warning
                  }
                )

                YellowDog.Config.Schema.defaults()
            end

          {:error, reason} ->
            :telemetry.execute(
              [:yellow_dog, :config, :error],
              %{count: 1},
              %{
                source: __MODULE__,
                reason: :read_error,
                config_file: config_file_path,
                error: inspect(reason),
                severity: :warning
              }
            )

            YellowDog.Config.Schema.defaults()
        end
      else
        :telemetry.execute(
          [:yellow_dog, :config, :error],
          %{count: 1},
          %{source: __MODULE__, reason: :no_config_path, severity: :warning}
        )

        YellowDog.Config.Schema.defaults()
      end

    config
    |> maybe_adjust_for_test()
    |> maybe_adjust_for_platform()
  end

  defp load_boot_config do
    bootstrap = load_toml_config()
    data_dir = managed_config_data_dir(bootstrap)
    server_id = managed_server_id(bootstrap)
    selection = BootConfig.select(bootstrap, data_dir, server_id)

    :telemetry.execute(
      [:yellow_dog, :config, :boot_selected],
      %{count: 1},
      %{
        source: selection.source,
        revision: selection.revision,
        error: selection.error,
        severity: boot_selection_severity(selection)
      }
    )

    case selection do
      %{config: config} when is_map(config) ->
        {:ok, %{bootstrap: bootstrap, effective: config}}

      %{source: :managed_unavailable, error: error} ->
        {:error, {:managed_config_unavailable, error}}

      _invalid ->
        {:error, {:managed_config_unavailable, :invalid_selection}}
    end
  end

  defp managed_server_id(bootstrap) do
    runtime_value(server_agent_runtime(), :server_id) ||
      bootstrap
      |> ProfileResolver.resolve()
      |> Map.get(:id)
      |> normalize_text()
  end

  defp boot_selection_severity(%{error: nil}), do: :info
  defp boot_selection_severity(%{source: :managed_unavailable}), do: :error
  defp boot_selection_severity(%{error: _reason}), do: :warning

  defp restore_process_flag(nil), do: Process.delete(@managed_reconcile_key)
  defp restore_process_flag(value), do: Process.put(@managed_reconcile_key, value)

  defp refresh_managed_server_agent_identity(config) do
    module = server_agent_module()
    resolved_profile = ProfileResolver.resolve(config)

    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :refresh_identity, 1),
         {:ok, config_revision} <- Digest.calculate(config),
         :ok <-
           apply(module, :refresh_identity, [
             %{
               profile: Atom.to_string(resolved_profile.profile),
               capabilities: server_capabilities(resolved_profile),
               config_revision: config_revision
             }
           ]) do
      :ok
    else
      _unavailable_or_inactive -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  # In test environment, disable most services and use default ports
  # to avoid privileged port conflicts and service interference.
  if @compile_env == :test do
    defp maybe_adjust_for_test(config) do
      config
      |> put_in(["core", "dns"], false)
      |> put_in(["core", "mdns"], false)
      |> put_in(["core", "dhcpv6"], false)
      |> put_in(["dns", "port"], 53)
      |> put_in(["dhcpv4", "port"], 67)
      |> put_in(["dhcpv6", "port"], 547)
    end
  else
    defp maybe_adjust_for_test(config), do: config
  end

  # Adjust configuration based on the runtime platform and execution mode.
  # When :netman_enabled is explicitly set to false (e.g. on macOS via runtime.exs),
  # force core.netman to false so the service is never started.
  # If :netman_only is set to true, disable all server-side services.
  defp maybe_adjust_for_platform(config) do
    config =
      if Application.get_env(:yellow_dog, :netman_enabled) == false do
        put_in(config, ["core", "netman"], false)
      else
        config
      end

    if Application.get_env(:yellow_dog, :netman_only, false) == true do
      config
      |> put_in(["core", "dns"], false)
      |> put_in(["core", "mdns"], false)
      |> put_in(["core", "dhcpv4"], false)
      |> put_in(["core", "dhcpv6"], false)
      |> put_in(["core", "netboot"], false)
    else
      config
    end
  end

  # Logs configuration information
  defp log_config_info(config) do
    config_file_path = Application.get_env(:yellow_dog, :config_file_path)
    default_config_path = Path.expand("../priv/yellow_dog_default_config.toml", __DIR__)

    is_default = config_file_path && config_file_path == default_config_path

    :telemetry.execute(
      [:yellow_dog, :config, :loaded],
      %{count: 1},
      %{
        source: __MODULE__,
        config_file: config_file_path,
        is_default: is_default,
        severity: :info
      }
    )

    # Log enabled services
    case Map.get(config, "core") do
      %{"dns" => dns, "mdns" => mdns, "dhcpv4" => dhcpv4, "dhcpv6" => dhcpv6} = core ->
        netboot = Map.get(core, "netboot", false)
        netman = Map.get(core, "netman", true)

        services = [
          {"DNS", dns},
          {"mDNS", mdns},
          {"DHCPv4", dhcpv4},
          {"DHCPv6", dhcpv6},
          {"Netboot", netboot},
          {"NetMan", netman}
        ]

        enabled_services = for({name, true} <- services, do: name)
        disabled_services = for({name, false} <- services, do: name)

        :telemetry.execute(
          [:yellow_dog, :config, :validated],
          %{
            count: 1,
            enabled_count: length(enabled_services),
            disabled_count: length(disabled_services)
          },
          %{
            source: __MODULE__,
            enabled_services: Enum.join(enabled_services, ", "),
            disabled_services: Enum.join(disabled_services, ", "),
            severity: :info
          }
        )

      _ ->
        :telemetry.execute(
          [:yellow_dog, :config, :error],
          %{count: 1},
          %{source: __MODULE__, reason: :no_core_config, severity: :warning}
        )
    end
  end

  # Gets the list of enabled service supervisors based on configuration.
  defp get_enabled_services(config) do
    resolved_profile = ProfileResolver.resolve(config)
    service_flags = resolved_profile.services
    services = startup_services(resolved_profile.source)

    # Filter services based on configuration and pass server options
    enabled_services =
      for metadata <- services,
          service_name = metadata.name,
          service_enabled?(service_flags, service_name) do
        case service_child_spec(config, resolved_profile, metadata) do
          nil -> nil
          child_spec -> {service_name, child_spec}
        end
      end
      |> Enum.reject(&is_nil/1)

    # Log which services are being started
    service_names =
      for %{name: service_name} <- services,
          service_enabled?(service_flags, service_name),
          do: service_name |> to_string() |> String.upcase()

    if service_names != [] do
      :telemetry.execute(
        [:yellow_dog, :application, :start],
        %{count: length(service_names)},
        %{source: __MODULE__, services: Enum.join(service_names, ", "), severity: :info}
      )
    end

    # Log disabled services
    disabled_services =
      for %{name: service_name} <- services,
          not service_enabled?(service_flags, service_name),
          do: service_name |> to_string() |> String.upcase()

    if disabled_services != [] do
      :telemetry.execute(
        [:yellow_dog, :application, :start],
        %{count: 0, skipped: length(disabled_services)},
        %{
          source: __MODULE__,
          skipped_services: Enum.join(disabled_services, ", "),
          severity: :info
        }
      )
    end

    enabled_services
  end

  defp service_child_spec(_config, resolved_profile, %{name: :server_agent}) do
    module = server_agent_module()

    if resolved_profile.source == :yellow_dog_server and Code.ensure_loaded?(module) and
         function_exported?(module, :start_link, 1) do
      server_agent_child_spec(module)
    end
  end

  defp service_child_spec(config, _resolved_profile, %{module: module, name: service_name}) do
    module = service_module(service_name, module)

    if Code.ensure_loaded?(module) do
      server_options = build_server_options(config, service_name)
      {module, server_options: server_options}
    end
  end

  @doc false
  @spec server_agent_child_spec(module()) :: Supervisor.child_spec()
  def server_agent_child_spec(module) when is_atom(module) do
    %{
      id: @default_server_agent_module,
      start: {__MODULE__, :start_server_agent, [module]},
      type: :supervisor
    }
  end

  defp start_or_recover_server_agent_child(child_spec) do
    start_or_recover_server_agent_child(child_spec, @server_agent_reconcile_attempts)
  end

  defp start_or_recover_server_agent_child(child_spec, attempts) do
    case Supervisor.start_child(YellowDog.Supervisor, child_spec) do
      {:ok, :undefined} ->
        reconcile_ignored_server_agent_child(child_spec, attempts)

      {:ok, pid, _info} ->
        {:ok, pid}

      {:error, :already_present} when attempts > 0 ->
        restart_server_agent_child_spec(child_spec, attempts)

      {:error, :already_present} ->
        terminal_server_agent_reconcile_result()

      result ->
        result
    end
  end

  defp restart_server_agent_child_spec(child_spec, attempts) do
    case Supervisor.restart_child(YellowDog.Supervisor, @default_server_agent_module) do
      {:ok, :undefined} ->
        reconcile_ignored_server_agent_child(child_spec, attempts)

      {:ok, pid, _info} ->
        {:ok, pid}

      {:ok, pid} ->
        {:ok, pid}

      {:error, :running} ->
        running_server_agent_child_result(child_spec, attempts)

      {:error, :not_found} when attempts > 0 ->
        start_or_recover_server_agent_child(child_spec, attempts - 1)

      {:error, :not_found} ->
        terminal_server_agent_reconcile_result()

      {:error, reason} when reason in [:restarting, :already_present] and attempts > 0 ->
        running_server_agent_child_result(child_spec, attempts - 1)

      {:error, reason} when reason in [:restarting, :already_present] ->
        terminal_server_agent_reconcile_result()

      {:error, _reason} ->
        terminal_server_agent_reconcile_result()
    end
  end

  defp reconcile_ignored_server_agent_child(child_spec, attempts) do
    if current_server_agent_enabled?() and attempts > 0 do
      restart_server_agent_child_spec(child_spec, attempts - 1)
    else
      delete_ignored_server_agent_child(child_spec, attempts)
    end
  end

  defp delete_ignored_server_agent_child(child_spec, attempts) do
    case Supervisor.delete_child(YellowDog.Supervisor, @default_server_agent_module) do
      :ok ->
        continue_after_ignored_delete(child_spec, attempts)

      {:error, :not_found} ->
        continue_after_ignored_delete(child_spec, attempts)

      {:error, :running} ->
        running_server_agent_child_result(child_spec, attempts)

      {:error, _reason} ->
        terminal_server_agent_reconcile_result()
    end
  end

  defp continue_after_ignored_delete(child_spec, attempts) do
    enabled? = current_server_agent_enabled?()

    cond do
      enabled? and attempts > 0 ->
        start_or_recover_server_agent_child(child_spec, attempts - 1)

      enabled? ->
        terminal_server_agent_reconcile_result()

      true ->
        :ignore
    end
  end

  defp running_server_agent_child_result(child_spec, attempts) do
    case Enum.find(
           Supervisor.which_children(YellowDog.Supervisor),
           &(elem(&1, 0) == @default_server_agent_module)
         ) do
      {_id, pid, _type, _modules} when is_pid(pid) ->
        {:error, {:already_started, pid}}

      {_id, child_state, _type, _modules}
      when child_state in [:undefined, :restarting] and attempts > 0 ->
        restart_server_agent_child_spec(child_spec, attempts - 1)

      nil when attempts > 0 ->
        start_or_recover_server_agent_child(child_spec, attempts - 1)

      _unresolved ->
        terminal_server_agent_reconcile_result()
    end
  end

  defp terminal_server_agent_reconcile_result do
    terminal_server_agent_reconcile_result(@server_agent_terminal_reconcile_attempts)
  end

  defp terminal_server_agent_reconcile_result(attempts) do
    reconcile_terminal_server_agent_child(
      attempts,
      &server_agent_child_entry/0,
      fn -> Supervisor.delete_child(YellowDog.Supervisor, @default_server_agent_module) end
    )
  end

  defp reconcile_terminal_server_agent_child(attempts, observe_child, delete_child) do
    case observe_child.() do
      {_id, pid, _type, _modules} when is_pid(pid) ->
        {:error, {:already_started, pid}}

      {_id, :undefined, _type, _modules} ->
        delete_terminal_server_agent_child(attempts, observe_child, delete_child)

      {_id, :restarting, _type, _modules} when attempts > 0 ->
        reconcile_terminal_server_agent_child(attempts - 1, observe_child, delete_child)

      {_id, :restarting, _type, _modules} ->
        {:ok, :restarting}

      nil ->
        {:error, :server_agent_reconcile_failed}
    end
  end

  defp delete_terminal_server_agent_child(attempts, observe_child, delete_child) do
    case delete_child.() do
      :ok ->
        {:error, :server_agent_reconcile_failed}

      {:error, :not_found} ->
        {:error, :server_agent_reconcile_failed}

      {:error, :running} when attempts > 0 ->
        reconcile_terminal_server_agent_child(attempts - 1, observe_child, delete_child)

      {:error, :running} ->
        {:ok, :restarting}

      {:error, :restarting} when attempts > 0 ->
        reconcile_terminal_server_agent_child(attempts - 1, observe_child, delete_child)

      {:error, :restarting} ->
        {:ok, :restarting}

      {:error, _reason} ->
        {:error, :server_agent_reconcile_failed}
    end
  end

  defp server_agent_child_entry do
    Enum.find(
      Supervisor.which_children(YellowDog.Supervisor),
      &(elem(&1, 0) == @default_server_agent_module)
    )
  end

  if @compile_env == :test do
    @doc false
    def reconcile_terminal_server_agent_child_for_test(
          attempts,
          observe_child,
          delete_child
        )
        when is_integer(attempts) and attempts >= 0 and is_function(observe_child, 0) and
               is_function(delete_child, 0) do
      reconcile_terminal_server_agent_child(attempts, observe_child, delete_child)
    end
  end

  defp current_server_agent_enabled? do
    current_config()
    |> ProfileResolver.resolve()
    |> server_agent_enabled?()
  end

  @doc false
  @spec start_server_agent(module()) :: {:ok, pid()} | :ignore | {:error, atom()}
  def start_server_agent(module) when is_atom(module) do
    config = current_config()
    resolved_profile = ProfileResolver.resolve(config)

    if server_agent_enabled?(resolved_profile) and Code.ensure_loaded?(module) and
         function_exported?(module, :start_link, 1) do
      module
      |> apply(:start_link, [server_agent_options(config, resolved_profile)])
      |> sanitize_server_agent_start()
    else
      :ignore
    end
  rescue
    _exception -> {:error, :server_agent_start_failed}
  catch
    _kind, _reason -> {:error, :server_agent_start_failed}
  end

  def start_server_agent(_module), do: :ignore

  defp server_agent_options(config, resolved_profile) do
    runtime = server_agent_runtime()
    server_id = runtime_value(runtime, :server_id) || normalize_text(resolved_profile.id)

    if server_id do
      durable_options(config, resolved_profile, runtime, server_id) ++
        outbound_options(config, resolved_profile, runtime, server_id)
    else
      []
    end
  end

  defp durable_options(config, resolved_profile, runtime, server_id) do
    [
      data_dir: runtime_value(runtime, :data_dir) || get_data_dir(config),
      server_id: server_id,
      profile: resolved_profile.profile,
      capabilities: server_capabilities(resolved_profile)
    ]
  end

  defp outbound_options(config, resolved_profile, runtime, server_id) do
    management_url =
      runtime_value(runtime, :management_url) ||
        resolved_profile.management
        |> config_value(:url)
        |> normalize_text()

    token = runtime_value(runtime, :management_token)
    server_name = normalize_text(resolved_profile.name) || server_id
    server_version = server_version()

    with management_url when is_binary(management_url) <- management_url,
         token when is_binary(token) <- token,
         server_name when is_binary(server_name) <- server_name,
         server_version when is_binary(server_version) <- server_version,
         {:ok, config_revision} <- Digest.calculate(config),
         {:ok, {reconnect_initial_ms, reconnect_max_ms}} <- reconnect_bounds(runtime) do
      [
        management_url: management_url,
        management_token: token,
        server_name: server_name,
        server_version: server_version,
        config_revision: config_revision,
        reconnect_initial_ms: reconnect_initial_ms,
        reconnect_max_ms: reconnect_max_ms
      ]
    else
      _incomplete -> []
    end
  end

  defp server_capabilities(resolved_profile) do
    enabled_domains =
      resolved_profile
      |> enabled_server_domains()
      |> MapSet.put("config")
      |> MapSet.put("runtime")

    ServerOperation.all()
    |> Map.values()
    |> Enum.map(& &1.capability)
    |> Enum.filter(fn capability ->
      capability_domain(capability) in enabled_domains and
        match?({:ok, _bounded}, Bounds.message(capability))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp enabled_server_domains(resolved_profile) do
    [
      {:dns, "dns"},
      {:mdns, "mdns"},
      {:dhcpv4, "dhcp"},
      {:dhcpv6, "dhcp"},
      {:netboot, "netboot"},
      {:identity, "identity"}
    ]
    |> Enum.reduce(MapSet.new(), fn {service, domain}, domains ->
      if service_enabled?(resolved_profile.services, service) and service_available?(service) do
        MapSet.put(domains, domain)
      else
        domains
      end
    end)
  end

  defp service_available?(service) do
    case ServiceRegistry.fetch(service) do
      {:ok, %{module: module}} -> Code.ensure_loaded?(service_module(service, module))
      :error -> false
    end
  end

  defp capability_domain(capability) do
    capability
    |> String.split(".", parts: 2)
    |> hd()
  end

  defp reconnect_bounds(runtime) do
    initial = Keyword.get(runtime, :reconnect_initial_ms)
    maximum = Keyword.get(runtime, :reconnect_max_ms)

    case {initial, maximum} do
      {nil, nil} ->
        {:ok, {@default_reconnect_initial_ms, @default_reconnect_max_ms}}

      {initial, maximum}
      when is_integer(initial) and initial > 0 and initial <= @max_reconnect_ms and
             is_integer(maximum) and maximum >= initial and maximum <= @max_reconnect_ms ->
        {:ok, {initial, maximum}}

      _invalid ->
        {:error, :invalid_reconnect_bounds}
    end
  end

  defp server_agent_runtime do
    case Application.get_env(:yellow_dog_server_agent, :runtime, []) do
      runtime when is_list(runtime) ->
        if Keyword.keyword?(runtime), do: runtime, else: []

      _invalid ->
        []
    end
  end

  defp runtime_value(runtime, key) do
    runtime
    |> Keyword.get(key)
    |> normalize_text()
  end

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_text(_value), do: nil

  defp config_value(config, key) when is_map(config) do
    Map.get(config, key) || Map.get(config, to_string(key))
  end

  defp config_value(_config, _key), do: nil

  defp server_version do
    case Application.spec(:yellow_dog, :vsn) do
      nil -> nil
      version -> version |> to_string() |> normalize_text()
    end
  end

  defp current_config do
    case YellowDog.Config.get_all() do
      config when is_map(config) -> config
      _invalid -> %{}
    end
  catch
    :exit, _reason -> %{}
  end

  defp server_agent_enabled?(resolved_profile) do
    resolved_profile.source == :yellow_dog_server and
      service_enabled?(resolved_profile.services, :server_agent)
  end

  defp server_agent_module do
    case Application.get_env(:yellow_dog, :server_agent_module, @default_server_agent_module) do
      module when is_atom(module) -> module
      _invalid -> @default_server_agent_module
    end
  end

  if @compile_env == :test do
    defp await_startup_selection do
      case Application.get_env(:yellow_dog, :application_test_startup_barrier) do
        {owner, ref} when is_pid(owner) and is_reference(ref) ->
          send(owner, {:application_startup_selection_waiting, self(), ref})

          receive do
            {:application_startup_selection_continue, ^ref} -> {owner, ref}
          after
            5_000 -> nil
          end

        _disabled ->
          nil
      end
    end

    defp notify_startup_selection_complete({owner, ref}) do
      send(owner, {:application_startup_selection_complete, ref})
    end

    defp notify_startup_selection_complete(_disabled), do: :ok

    defp service_module(service, default_module) do
      case Application.get_env(:yellow_dog, :service_module_overrides, %{}) do
        overrides when is_map(overrides) ->
          case Map.get(overrides, service, default_module) do
            module when is_atom(module) and not is_nil(module) -> module
            _invalid -> default_module
          end

        _invalid ->
          default_module
      end
    end
  else
    defp await_startup_selection, do: nil
    defp notify_startup_selection_complete(_disabled), do: :ok
    defp service_module(_service, default_module), do: default_module
  end

  defp refresh_server_agent_identity(:server_agent), do: :ok

  defp refresh_server_agent_identity(trigger_service) do
    case refresh_managed_server_agent_identity(YellowDog.Config.get_all()) do
      :ok -> :ok
      {:error, _reason} -> emit_server_agent_refresh_error(trigger_service)
    end
  rescue
    _exception -> emit_server_agent_refresh_error(trigger_service)
  catch
    _kind, _reason -> emit_server_agent_refresh_error(trigger_service)
  end

  defp emit_server_agent_refresh_error(trigger_service) do
    :telemetry.execute(
      [:yellow_dog, :application, :error],
      %{count: 1},
      %{
        source: __MODULE__,
        service: :server_agent,
        trigger_service: trigger_service,
        operation: :identity_refresh,
        reason: :refresh_failed,
        severity: :warning
      }
    )

    :ok
  end

  defp sanitize_server_agent_start({:ok, pid} = started) when is_pid(pid), do: started
  defp sanitize_server_agent_start(:ignore), do: :ignore
  defp sanitize_server_agent_start(_error), do: {:error, :server_agent_start_failed}

  defp service_start_error(:server_agent, _reason), do: :start_failed
  defp service_start_error(_service, reason), do: inspect(reason)

  defp startup_services(:legacy_core) do
    legacy_services = MapSet.new([:dns, :mdns, :dhcpv4, :dhcpv6, :netboot, :identity])

    ServiceRegistry.all()
    |> Enum.filter(&(&1.controllable? and MapSet.member?(legacy_services, &1.name)))
  end

  defp startup_services(_source) do
    ServiceRegistry.all()
    |> Enum.filter(& &1.controllable?)
  end

  # Builds server options for a specific service from the configuration.
  defp build_server_options(config, service_name) do
    service_config = Map.get(config, to_string(service_name), %{})

    case service_name do
      :dns ->
        # Get data directory from config
        data_dir = get_data_dir(config)
        dns_data_dir = Path.join(data_dir, "dns")

        [
          port: Map.get(service_config, "port", 53),
          listen: convert_ip(Map.get(service_config, "listen", "0.0.0.0")),
          data_dir: dns_data_dir
        ]

      :mdns ->
        services_config = Map.get(service_config, "services", %{})
        responder_config = Map.get(service_config, "responder", %{})
        monitor_config = Map.get(service_config, "monitor", %{})

        # Get data directory from config
        data_dir = get_data_dir(config)
        mdns_data_dir = Path.join(data_dir, "mdns")
        default_storage_file = Path.join(mdns_data_dir, "services.toml")

        [
          port: Map.get(service_config, "port", 5353),
          listen_address: convert_ip(Map.get(service_config, "listen", "0.0.0.0")),
          mode: parse_mdns_mode(Map.get(service_config, "mode", "hybrid")),
          # Service registry options
          storage_file: Map.get(services_config, "file", default_storage_file),
          storage_format: parse_storage_format(Map.get(services_config, "format", "toml")),
          auto_save: Map.get(services_config, "auto_save", true),
          watch_file: Map.get(services_config, "watch_file", true),
          load_on_start: Map.get(services_config, "load_on_start", true),
          data_dir: mdns_data_dir,
          # Responder options
          responder_enabled: Map.get(responder_config, "enabled", true),
          service_ttl: Map.get(responder_config, "service_ttl", 4500),
          host_ttl: Map.get(responder_config, "host_ttl", 120),
          enable_probing: Map.get(responder_config, "enable_probing", true),
          enable_announcements: Map.get(responder_config, "enable_announcements", true),
          announcement_interval: Map.get(responder_config, "announcement_interval", 3600),
          # Monitor options
          monitor_enabled: Map.get(monitor_config, "enabled", true),
          cache_responses: Map.get(monitor_config, "cache_responses", true),
          log_queries: Map.get(monitor_config, "log_queries", true),
          max_cache_size: Map.get(monitor_config, "max_cache_size", 10000),
          cleanup_interval: Map.get(monitor_config, "cleanup_interval", 300),
          cache_ttl: Map.get(monitor_config, "cache_ttl", 120)
        ]

      :dhcpv4 ->
        # Note: pools are NOT loaded from the main config file.
        # LeaseManager loads pools from PoolStore (data/dhcpv4/pools/*.toml) instead.
        # This allows pools to be managed via the UI without conflicting with config.
        static_reservations = Map.get(service_config, "static_reservations", %{})

        # Get data directory from config
        data_dir = get_data_dir(config)
        dhcpv4_data_dir = Path.join(data_dir, "dhcpv4")

        [
          port: Map.get(service_config, "port", 67),
          listen: convert_ip(Map.get(service_config, "listen", "0.0.0.0")),
          static_reservations: static_reservations,
          data_dir: dhcpv4_data_dir
        ]

      :dhcpv6 ->
        # Note: pools are NOT loaded from the main config file.
        # LeaseManager loads pools from PoolStore (data/dhcpv6/pools/*.toml) instead.
        # This allows pools to be managed via the UI without conflicting with config.
        static_reservations = Map.get(service_config, "static_reservations", %{})

        # Get data directory from config
        data_dir = get_data_dir(config)
        dhcpv6_data_dir = Path.join(data_dir, "dhcpv6")

        [
          port: Map.get(service_config, "port", 547),
          listen: convert_ipv6(Map.get(service_config, "listen", "::")),
          static_reservations: static_reservations,
          data_dir: dhcpv6_data_dir
        ]

      :netboot ->
        tftp_root = resolve_netboot_tftp_root(config, service_config)

        [
          tftp_port: Map.get(service_config, "tftp_port", Map.get(service_config, "port", 69)),
          tftp_root: tftp_root,
          default_profile: Map.get(service_config, "default_profile", "")
        ]

      :identity ->
        data_dir = get_data_dir(config)
        identity_data_dir = Path.join(data_dir, "identity")

        [
          data_dir: identity_data_dir
        ]

      :fingerprint ->
        data_dir = get_data_dir(config)

        [
          data_dir: Path.join(data_dir, "fingerprint")
        ]

      :server_agent ->
        []
    end
  end

  # Gets the data directory from config or CLI/ENV override.
  # Relative paths are resolved against the umbrella root so all apps
  # share a single data directory (not per-app data/ folders).
  defp get_data_dir(config) do
    dir =
      case Application.get_env(:yellow_dog, :data_dir) do
        nil ->
          # Fall back to config file or default
          Map.get(config, "data_dir", "data")

        dir ->
          dir
      end

    resolve_data_dir(dir)
  end

  defp resolve_data_dir("/" <> _ = absolute), do: absolute

  defp resolve_data_dir(relative) do
    Path.join(umbrella_root(), relative)
  end

  defp resolve_netboot_tftp_root(config, service_config) do
    default_root = Path.join(get_data_dir(config), "netboot/tftp")

    service_config
    |> Map.get("tftp_root", default_root)
    |> normalize_netboot_tftp_root(default_root)
  end

  defp normalize_netboot_tftp_root(root, default_root)
       when root in [nil, "", "data/netboot/tftp"],
       do: default_root

  defp normalize_netboot_tftp_root(root, _default_root) when is_binary(root) do
    resolve_config_path(root)
  end

  defp normalize_netboot_tftp_root(_root, default_root), do: default_root

  defp resolve_config_path("/" <> _ = absolute), do: absolute
  defp resolve_config_path(relative), do: Path.join(umbrella_root(), relative)

  defp umbrella_root do
    Application.app_dir(:yellow_dog)
    |> Path.join("../..")
    |> Path.expand()
  end

  @valid_mdns_modes ~w(hybrid responder browser)
  defp parse_mdns_mode(mode) when mode in @valid_mdns_modes, do: String.to_existing_atom(mode)
  defp parse_mdns_mode(_), do: :hybrid

  @valid_storage_formats ~w(toml json)
  defp parse_storage_format(fmt) when fmt in @valid_storage_formats,
    do: String.to_existing_atom(fmt)

  defp parse_storage_format(_), do: :toml

  # Converts IP address string to tuple format for mDNS
  defp convert_ip(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, {_, _, _, _} = ip_tuple} -> ip_tuple
      _ -> {0, 0, 0, 0}
    end
  end

  defp convert_ip(ip_tuple) when is_tuple(ip_tuple), do: ip_tuple
  defp convert_ip(_), do: {0, 0, 0, 0}

  # Converts IPv6 address string to tuple format for DHCPv6
  defp convert_ipv6("::"), do: {0, 0, 0, 0, 0, 0, 0, 0}

  defp convert_ipv6(ip_string) when is_binary(ip_string) do
    case :inet.parse_ipv6_address(String.to_charlist(ip_string)) do
      {:ok, ip_tuple} -> ip_tuple
      {:error, _} -> {0, 0, 0, 0, 0, 0, 0, 0}
    end
  end

  defp convert_ipv6(ip_tuple) when is_tuple(ip_tuple), do: ip_tuple
  defp convert_ipv6(_), do: {0, 0, 0, 0, 0, 0, 0, 0}

  # Gets the domain for dynamic DNS record creation from config.
  defp get_dyn_dns_domain(config) do
    get_in(config, ["dns", "domain"]) || "local"
  end

  defp service_enabled?(service_flags, service_name) do
    Map.get(service_flags, service_name, false)
  end
end
