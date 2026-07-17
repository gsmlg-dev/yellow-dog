defmodule YellowDog.ServerAgent.Supervisor do
  @moduledoc false

  use Supervisor

  alias YellowDog.ServerAgent.CommandJournal
  alias YellowDog.ServerAgent.ConfigStore
  alias YellowDog.ServerAgent.Heartbeat

  @durable_options [:data_dir, :server_id, :profile, :capabilities]
  @allowed_options @durable_options ++
                     [
                       :name,
                       :agent_id,
                       :command_journal_name,
                       :config_store_name,
                       :supervisor_name,
                       :command_journal_opts,
                       :config_store_opts
                     ]
  @command_journal_options [:max_records, :clock, :directory_scanner, :storage_opts]
  @config_store_options [:max_bytes, :storage_opts]

  def start_link(opts \\ []) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         {:ok, _children} <- children(opts),
         {:ok, supervisor_name} <-
           supervisor_name(Keyword.get(opts, :supervisor_name, __MODULE__)) do
      start_supervisor(opts, supervisor_name)
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  @impl Supervisor
  def init(opts) do
    case children(opts) do
      {:ok, children} -> Supervisor.init(children, strategy: :one_for_one)
      {:error, :invalid_configuration} -> :ignore
    end
  end

  defp children(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         :ok <- validate_top_level(opts),
         {:ok, durable?} <- durable_mode(opts),
         {:ok, journal_opts} <-
           child_options(Keyword.get(opts, :command_journal_opts, []), @command_journal_options),
         {:ok, store_opts} <-
           child_options(Keyword.get(opts, :config_store_opts, []), @config_store_options) do
      build_children(opts, durable?, journal_opts, store_opts)
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  defp children(_opts), do: {:error, :invalid_configuration}

  defp build_children(opts, false, _journal_opts, _store_opts) do
    heartbeat_opts = Keyword.take(opts, [:name, :agent_id])
    heartbeat_name = Keyword.get(heartbeat_opts, :name, Heartbeat)

    if valid_name?(heartbeat_name) do
      {:ok, [child_spec(:heartbeat, Heartbeat, heartbeat_opts)]}
    else
      {:error, :invalid_configuration}
    end
  end

  defp build_children(opts, true, journal_opts, store_opts) do
    heartbeat_opts = Keyword.take(opts, [:name, :agent_id])
    journal_name = Keyword.get(opts, :command_journal_name, CommandJournal)
    store_name = Keyword.get(opts, :config_store_name, ConfigStore)
    heartbeat_name = Keyword.get(heartbeat_opts, :name, Heartbeat)

    with true <- valid_name?(heartbeat_name),
         true <- valid_name?(journal_name),
         true <- valid_name?(store_name),
         true <- distinct_names?([heartbeat_name, journal_name, store_name]) do
      shared = Keyword.take(opts, @durable_options)

      journal_opts =
        journal_opts
        |> Keyword.put(:name, journal_name)
        |> Keyword.put(:data_dir, Keyword.fetch!(shared, :data_dir))
        |> Keyword.put(:server_id, Keyword.fetch!(shared, :server_id))
        |> Keyword.put(:capabilities, Keyword.fetch!(shared, :capabilities))

      store_opts =
        store_opts
        |> Keyword.put(:name, store_name)
        |> Keyword.put(:data_dir, Keyword.fetch!(shared, :data_dir))
        |> Keyword.put(:server_id, Keyword.fetch!(shared, :server_id))
        |> Keyword.put(:profile, Keyword.fetch!(shared, :profile))

      {:ok,
       [
         child_spec(:heartbeat, Heartbeat, heartbeat_opts),
         child_spec(:command_journal, CommandJournal, journal_opts),
         child_spec(:config_store, ConfigStore, store_opts)
       ]}
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  defp validate_top_level(opts) do
    keys = Keyword.keys(opts)

    if Enum.all?(keys, &(&1 in @allowed_options)) and
         length(keys) == length(Enum.uniq(keys)) do
      :ok
    else
      {:error, :invalid_configuration}
    end
  end

  defp durable_mode(opts) do
    present = Enum.count(@durable_options, &Keyword.has_key?(opts, &1))

    case present do
      0 -> {:ok, false}
      4 -> {:ok, true}
      _partial -> {:error, :invalid_configuration}
    end
  end

  defp child_options(opts, allowed) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- Enum.all?(keys, &(&1 in allowed)),
         true <- length(keys) == length(Enum.uniq(keys)) do
      {:ok, opts}
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  defp valid_name?(name) when is_atom(name), do: not is_nil(name)
  defp valid_name?({:global, _term}), do: true

  defp valid_name?({:via, module, _term}) when is_atom(module) and not is_nil(module),
    do: true

  defp valid_name?(_name), do: false

  defp distinct_names?(names), do: length(names) == length(Enum.uniq(names))

  defp supervisor_name(nil), do: {:ok, nil}
  defp supervisor_name(name), do: if(valid_name?(name), do: {:ok, name}, else: :error)

  defp child_spec(id, module, opts) do
    Supervisor.child_spec({module, opts}, id: id)
  end

  defp start_supervisor(opts, nil),
    do: Supervisor.start_link(__MODULE__, opts)

  defp start_supervisor(opts, name),
    do: Supervisor.start_link(__MODULE__, opts, name: name)
end
