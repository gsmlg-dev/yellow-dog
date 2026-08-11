defmodule YellowDog.Server.Control do
  @moduledoc """
  Typed dispatch boundary for Server remote-management operations.
  """

  alias YellowDog.Server.Control.Dispatcher
  alias YellowDog.Config
  alias YellowDog.Config.Manager
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation

  @spec dispatch(Envelope.t()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch(envelope), do: Dispatcher.dispatch(envelope)

  @doc "Validates one complete management-owned Server config document."
  @spec validate_config(term()) :: :ok | {:error, :invalid_config}
  def validate_config(document) do
    manager = dependency(:manager, Manager)

    with {:ok, _document} <-
           Operation.validate_payload("server.config.replace", :server, :config, document),
         {:ok, :ok} <- safe_call(manager, :validate_document, [document]) do
      :ok
    else
      _invalid -> {:error, :invalid_config}
    end
  end

  @doc "Installs an immutable managed candidate without activating it."
  @spec install_config(term(), term()) :: {:ok, String.t()} | {:error, :install_failed}
  def install_config(document, opts) do
    manager = dependency(:manager, Manager)

    with :ok <- validate_config(document),
         :ok <- validate_install_options(opts),
         {:ok, data_dir} <- managed_data_dir(),
         {:ok, {:ok, revision}} <- safe_call(manager, :install, [data_dir, document]),
         {:ok, revision} <- Digest.validate(revision) do
      {:ok, revision}
    else
      _invalid -> {:error, :install_failed}
    end
  end

  @doc "Activates an installed revision and hot-reconciles affected services."
  @spec activate_config(term()) :: :ok | {:error, :activation_failed}
  def activate_config(revision), do: change_active_revision(:activate, revision)

  @doc "Restores an exact previous revision before the applier reactivates it."
  @spec restore_config(term()) :: :ok | {:error, :restore_failed}
  def restore_config(revision) do
    case change_active_revision(:restore, revision) do
      :ok -> :ok
      {:error, :activation_failed} -> {:error, :restore_failed}
    end
  end

  defp change_active_revision(operation, revision) when operation in [:activate, :restore] do
    config = dependency(:config, Config)
    manager = dependency(:manager, Manager)
    runtime = dependency(:runtime, YellowDog.Application)

    with {:ok, revision} <- Digest.validate(revision),
         {:ok, previous} <- config_map(config, :get_all),
         {:ok, bootstrap} <- config_map(config, :bootstrap),
         {:ok, data_dir} <- managed_data_dir(bootstrap),
         {:ok, {:ok, %{revision: ^revision, config: next, recovery: recovery}}}
         when is_map(next) and is_binary(recovery) <-
           safe_call(manager, operation, [data_dir, revision, bootstrap]) do
      case safe_call(runtime, :reconcile_config, [previous, next]) do
        {:ok, :ok} ->
          :ok

        _reconcile_failed ->
          compensate_activation(
            manager,
            runtime,
            data_dir,
            recovery,
            bootstrap,
            next,
            previous
          )

          {:error, :activation_failed}
      end
    else
      _invalid -> {:error, :activation_failed}
    end
  end

  defp compensate_activation(
         manager,
         runtime,
         data_dir,
         recovery,
         bootstrap,
         failed,
         previous
       ) do
    with {:ok, {:ok, %{config: ^previous}}} <-
           safe_call(manager, :compensate, [data_dir, recovery, bootstrap]),
         {:ok, :ok} <- safe_call(runtime, :reconcile_config, [failed, previous]) do
      :ok
    else
      _compensation_failed -> :error
    end
  end

  defp validate_install_options(opts) when is_list(opts) do
    allowed = [:version, :digest, :expected_revision, :operation, :profile]

    with true <- Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in allowed)),
         version when is_integer(version) and version > 0 <- Keyword.get(opts, :version),
         "server.config.replace" <- Keyword.get(opts, :operation),
         {:ok, _digest} <- Digest.validate(Keyword.get(opts, :digest)),
         :ok <- validate_expected_revision(Keyword.get(opts, :expected_revision)) do
      :ok
    else
      _invalid -> :error
    end
  end

  defp validate_install_options(_opts), do: :error

  defp validate_expected_revision(nil), do: :ok

  defp validate_expected_revision(revision) do
    case Digest.validate(revision) do
      {:ok, _revision} -> :ok
      _invalid -> :error
    end
  end

  defp managed_data_dir do
    config = dependency(:config, Config)

    with {:ok, bootstrap} <- config_map(config, :bootstrap) do
      managed_data_dir(bootstrap)
    end
  end

  defp managed_data_dir(bootstrap) do
    case dependency_options() do
      opts when is_list(opts) ->
        case Keyword.get(opts, :data_dir) do
          nil -> runtime_data_dir(bootstrap)
          data_dir -> absolute_data_dir(data_dir)
        end

      _invalid ->
        :error
    end
  end

  defp runtime_data_dir(bootstrap) do
    runtime = dependency(:runtime, YellowDog.Application)

    case safe_call(runtime, :managed_config_data_dir, [bootstrap]) do
      {:ok, data_dir} -> absolute_data_dir(data_dir)
      _invalid -> :error
    end
  end

  defp absolute_data_dir(value) when is_binary(value) do
    expanded = Path.expand(value)

    if Path.type(value) == :absolute and expanded == value,
      do: {:ok, value},
      else: :error
  end

  defp absolute_data_dir(_value), do: :error

  defp config_map(module, function) do
    case safe_call(module, function, []) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _invalid -> :error
    end
  end

  defp dependency(key, default) do
    case dependency_options() do
      opts when is_list(opts) -> Keyword.get(opts, key, default)
      _invalid -> default
    end
  end

  defp dependency_options, do: Application.get_env(:yellow_dog, __MODULE__, [])

  defp safe_call(module, function, arguments) do
    if is_atom(module) and Code.ensure_loaded?(module) and
         function_exported?(module, function, length(arguments)) do
      {:ok, apply(module, function, arguments)}
    else
      {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end
end
