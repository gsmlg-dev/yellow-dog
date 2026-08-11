defmodule YellowDog.NetmanAgent.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    case children(opts) do
      {:ok, children} -> Supervisor.init(children, strategy: :one_for_one)
      :error -> {:stop, :invalid_options}
    end
  end

  defp children(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.fetch(opts, :enabled) do
        {:ok, false} -> disabled_children(opts)
        {:ok, true} -> enabled_children(opts)
        :error -> :error
      end
    else
      :error
    end
  end

  defp children(_opts), do: :error

  defp disabled_children(opts) do
    allowed = [:enabled, :agent_id]
    agent_id = Keyword.get(opts, :agent_id, "netman-local")

    if Enum.all?(Keyword.keys(opts), &(&1 in allowed)) and is_binary(agent_id) and
         agent_id != "" do
      {:ok,
       [
         {YellowDog.NetmanAgent.Heartbeat, [agent_id: agent_id]},
         {YellowDog.NetmanAgent.Client, [enabled: false]}
       ]}
    else
      :error
    end
  end

  defp enabled_children(opts) do
    durable_children = durable_children(opts)
    client_children = client_children(opts, durable_children)

    case {durable_children, client_children} do
      {[_journal, _store, _apply_store, _rollback_timer, _applier], [_client]} ->
        {:ok,
         [{YellowDog.NetmanAgent.Heartbeat, heartbeat_opts(opts)}] ++
           durable_children ++ client_children}

      _incomplete ->
        :error
    end
  end

  defp heartbeat_opts(opts) do
    [agent_id: Keyword.get(opts, :agent_id, Keyword.fetch!(opts, :netman_id))]
  end

  defp client_children(opts, [
         _command_journal,
         _config_store,
         _config_apply_store,
         _rollback_timer,
         _config_applier
       ])
       when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, client_opts} <- Keyword.fetch(opts, :client_opts),
         true <- is_list(client_opts) and Keyword.keyword?(client_opts) do
      command_journal =
        Keyword.get(opts, :command_journal_name, YellowDog.NetmanAgent.CommandJournal)

      config_store = Keyword.get(opts, :config_store_name, YellowDog.NetmanAgent.ConfigStore)

      config_apply_store =
        Keyword.get(opts, :config_apply_store_name, YellowDog.NetmanAgent.ConfigApplyStore)

      config_applier =
        Keyword.get(opts, :config_applier_name, YellowDog.NetmanAgent.ConfigApplier)

      rollback_timer =
        Keyword.get(opts, :rollback_timer_name, YellowDog.NetmanAgent.RollbackTimer)

      configured =
        client_opts
        |> Keyword.put(:command_journal, command_journal)
        |> Keyword.put(:config_store, config_store)
        |> Keyword.put(:config_apply_store, config_apply_store)
        |> Keyword.put(:config_applier, config_applier)
        |> Keyword.put(:rollback_timer, rollback_timer)

      [{YellowDog.NetmanAgent.Client, configured}]
    else
      _missing_or_invalid -> []
    end
  end

  defp client_children(_opts, _durable_children), do: []

  defp durable_children(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?([:data_dir, :netman_id, :capabilities], &Keyword.has_key?(opts, &1)) do
      journal_opts =
        opts
        |> Keyword.take([
          :data_dir,
          :netman_id,
          :capabilities,
          :max_records,
          :clock,
          :directory_scanner,
          :storage_opts
        ])
        |> Keyword.put(
          :name,
          Keyword.get(opts, :command_journal_name, YellowDog.NetmanAgent.CommandJournal)
        )

      config_store_opts =
        opts
        |> Keyword.take([:data_dir, :netman_id, :max_bytes, :max_versions, :storage_opts])
        |> Keyword.put(
          :name,
          Keyword.get(opts, :config_store_name, YellowDog.NetmanAgent.ConfigStore)
        )

      base_children = [
        {YellowDog.NetmanAgent.CommandJournal, journal_opts},
        {YellowDog.NetmanAgent.ConfigStore, config_store_opts}
      ]

      case Keyword.get(opts, :config_runtime_adapter) do
        runtime_adapter when is_atom(runtime_adapter) and not is_nil(runtime_adapter) ->
          config_store_name =
            Keyword.get(opts, :config_store_name, YellowDog.NetmanAgent.ConfigStore)

          config_apply_store_name =
            Keyword.get(opts, :config_apply_store_name, YellowDog.NetmanAgent.ConfigApplyStore)

          rollback_timer_name =
            Keyword.get(opts, :rollback_timer_name, YellowDog.NetmanAgent.RollbackTimer)

          config_applier_name =
            Keyword.get(opts, :config_applier_name, YellowDog.NetmanAgent.ConfigApplier)

          config_apply_store_opts =
            opts
            |> Keyword.take([:data_dir, :netman_id, :max_bytes, :storage_opts])
            |> Keyword.put(:config_store, config_store_name)
            |> Keyword.put(:name, config_apply_store_name)

          config_applier_opts =
            [
              name: config_applier_name,
              netman_id: Keyword.fetch!(opts, :netman_id),
              config_store: config_store_name,
              config_apply_store: config_apply_store_name,
              rollback_timer: rollback_timer_name,
              runtime_adapter: runtime_adapter
            ]
            |> maybe_put_adapter_timeout(opts)

          rollback_timer_opts =
            [
              name: rollback_timer_name,
              data_dir: Keyword.fetch!(opts, :data_dir),
              netman_id: Keyword.fetch!(opts, :netman_id),
              config_applier: config_applier_name
            ]
            |> maybe_put_option(:rollback_window, opts, :rollback_window)
            |> maybe_put_option(:retry_interval, opts, :rollback_retry_interval)
            |> maybe_put_option(:clock, opts, :rollback_clock)
            |> maybe_put_option(:timer, opts, :rollback_timer_module)
            |> maybe_put_option(:max_bytes, opts, :max_bytes)
            |> maybe_put_option(:storage_opts, opts, :storage_opts)

          base_children ++
            [
              {YellowDog.NetmanAgent.ConfigApplyStore, config_apply_store_opts},
              {YellowDog.NetmanAgent.RollbackTimer, rollback_timer_opts},
              {YellowDog.NetmanAgent.ConfigApplier, config_applier_opts}
            ]

        _missing_or_invalid ->
          base_children
      end
    else
      []
    end
  end

  defp durable_children(_opts), do: []

  defp maybe_put_adapter_timeout(config_applier_opts, opts) do
    case Keyword.fetch(opts, :config_adapter_timeout) do
      {:ok, timeout} -> Keyword.put(config_applier_opts, :adapter_timeout, timeout)
      :error -> config_applier_opts
    end
  end

  defp maybe_put_option(destination, destination_key, source, source_key) do
    case Keyword.fetch(source, source_key) do
      {:ok, value} -> Keyword.put(destination, destination_key, value)
      :error -> destination
    end
  end
end
