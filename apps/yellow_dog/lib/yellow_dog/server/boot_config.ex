defmodule YellowDog.Server.BootConfig do
  @moduledoc """
  Selects the exact acknowledged managed Server configuration at boot.

  The apply journal remains authoritative for which immutable revision is
  known-good. An active runtime pointer is never trusted on its own because a
  crash can occur after activation but before the applied acknowledgement is
  durable.
  """

  alias YellowDog.Config.Manager
  alias YellowDog.Sync.Bounds

  @default_selector :"Elixir.YellowDog.ServerAgent.BootConfig"

  @type selection :: %{
          config: map() | nil,
          source: :bootstrap | :managed_known_good | :managed_unavailable,
          revision: String.t() | nil,
          error: atom() | nil
        }

  @spec select(map(), term(), term()) :: selection()
  def select(bootstrap, data_dir, server_id) when is_map(bootstrap) do
    with {:ok, data_dir} <- absolute_data_dir(data_dir),
         {:ok, server_id} <- concrete_id(server_id) do
      select_managed(bootstrap, data_dir, server_id)
    else
      _incomplete -> bootstrap_selection(bootstrap)
    end
  end

  def select(_bootstrap, _data_dir, _server_id),
    do: unavailable_selection(nil, :invalid_bootstrap)

  defp select_managed(bootstrap, data_dir, server_id) do
    selector = dependency(:selector, @default_selector)

    case safe_call(selector, :select, [data_dir, server_id]) do
      {:ok, {:ok, revision}} -> select_revision(bootstrap, data_dir, revision)
      {:ok, :no_managed_config} -> select_without_journal(bootstrap, data_dir)
      {:ok, {:error, :corrupt}} -> unavailable_selection(nil, :corrupt_journal)
      {:ok, {:error, :invalid_options}} -> unavailable_selection(nil, :invalid_journal)
      {:ok, _invalid} -> unavailable_selection(nil, :invalid_journal)
      {:error, _unavailable} -> unavailable_selection(nil, :selector_unavailable)
    end
  end

  defp select_without_journal(bootstrap, data_dir) do
    manager = dependency(:manager, Manager)

    case safe_call(manager, :active_revision, [data_dir]) do
      {:ok, {:error, :not_found}} -> bootstrap_selection(bootstrap)
      {:ok, {:ok, revision}} -> unavailable_selection(revision, :missing_journal)
      {:ok, {:error, _reason}} -> unavailable_selection(nil, :managed_state_unavailable)
      {:ok, _invalid} -> unavailable_selection(nil, :invalid_managed_state)
      {:error, _unavailable} -> unavailable_selection(nil, :manager_unavailable)
    end
  end

  defp select_revision(bootstrap, data_dir, revision) do
    manager = dependency(:manager, Manager)

    case safe_call(manager, :boot_config, [data_dir, revision, bootstrap]) do
      {:ok, {:ok, %{revision: ^revision, config: config}}} when is_map(config) ->
        %{
          config: config,
          source: :managed_known_good,
          revision: revision,
          error: nil
        }

      {:ok, {:error, :corrupt}} ->
        unavailable_selection(revision, :corrupt_revision)

      {:ok, {:error, :not_found}} ->
        unavailable_selection(revision, :missing_revision)

      {:ok, {:error, _reason}} ->
        unavailable_selection(revision, :managed_revision_unavailable)

      {:ok, _invalid} ->
        unavailable_selection(revision, :invalid_selection)

      {:error, _unavailable} ->
        unavailable_selection(revision, :manager_unavailable)
    end
  end

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

  defp dependency(key, default) do
    case Application.get_env(:yellow_dog, __MODULE__, []) do
      opts when is_list(opts) -> Keyword.get(opts, key, default)
      _invalid -> default
    end
  end

  defp absolute_data_dir(value) when is_binary(value) do
    expanded = Path.expand(value)

    if Path.type(value) == :absolute and expanded == value,
      do: {:ok, value},
      else: :error
  end

  defp absolute_data_dir(_value), do: :error

  defp concrete_id(value) do
    with {:ok, value} <- Bounds.id(value),
         true <- value not in ["", ".", ".."],
         false <- String.contains?(value, ["/", "\\"]),
         false <- Regex.match?(~r/\A[A-Za-z]:/, value),
         normalized when is_binary(normalized) <- :unicode.characters_to_nfkc_binary(value),
         true <- normalized == value,
         false <- Regex.match?(~r/\p{C}/u, value) do
      {:ok, value}
    else
      _invalid -> :error
    end
  rescue
    _exception -> :error
  end

  defp bootstrap_selection(config),
    do: %{config: config, source: :bootstrap, revision: nil, error: nil}

  defp unavailable_selection(revision, error),
    do: %{config: nil, source: :managed_unavailable, revision: revision, error: error}
end
