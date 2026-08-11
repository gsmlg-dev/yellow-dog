defmodule YellowDog.Netman.Control.ConfigRuntimeAdapter do
  @moduledoc """
  Production apply boundary for management-owned Netman configuration.

  The agent's immutable `ConfigStore` owns durable delivered documents. This
  adapter accepts only the three declared Netman config operations and records
  an operation-specific restore checkpoint before activation.
  """

  @behaviour YellowDog.NetmanAgent.RuntimeAdapter

  alias YellowDog.Netman.Control.Profiles
  alias YellowDog.Netman.Control.Resolved
  alias YellowDog.NetmanAgent.ConfigStore
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Operation

  @operations [
    "netman.profiles.replace",
    "netman.resolved.config.update",
    "netman.resolved.config.rollback"
  ]
  @allowed_install_options [:version, :digest, :expected_revision, :operation]

  @impl true
  def validate_config(payload) do
    case Enum.filter(@operations, &valid_payload?(&1, payload)) do
      [_operation] -> :ok
      _none_or_ambiguous -> {:error, :invalid_config}
    end
  end

  @impl true
  def install_config(payload, opts) do
    with {:ok, install} <- validate_install_options(opts),
         :ok <- validate_operation_payload(install.operation, payload),
         :ok <- Digest.verify(payload, install.digest),
         {:ok, document} <- fetch(install.version, install.digest),
         :ok <- exact_document(document, payload, install),
         {:ok, checkpoint} <- capture_restore_checkpoint(install.operation, payload),
         :ok <- put_restore_checkpoint(install, checkpoint) do
      {:ok, install.digest}
    else
      _invalid -> {:error, :install_failed}
    end
  end

  @impl true
  def activate_config(revision), do: apply_revision(revision, :activation_failed)

  @impl true
  def restore_config({:candidate, revision}) do
    with {:ok, revision} <- Digest.validate(revision),
         {:ok, checkpoint} <- fetch_restore_checkpoint(revision),
         :ok <- apply_restore_checkpoint(checkpoint) do
      :ok
    else
      _invalid -> {:error, :restore_failed}
    end
  end

  def restore_config(revision), do: apply_revision(revision, :restore_failed)

  defp apply_revision(revision, failure) do
    with {:ok, revision} <- Digest.validate(revision),
         {:ok, document} <- fetch_revision(revision),
         :ok <- stored_document(document, revision),
         :ok <- apply_document(document) do
      :ok
    else
      _invalid -> {:error, failure}
    end
  end

  defp apply_document(document) do
    case document["operation"] do
      "netman.profiles.replace" ->
        apply_profiles(document)

      operation
      when operation in [
             "netman.resolved.config.update",
             "netman.resolved.config.rollback"
           ] ->
        apply_resolved(document)

      _invalid ->
        :error
    end
  end

  defp apply_profiles(document) do
    profiles = profiles_adapter()
    operation = document["operation"]
    payload = document["payload"]

    with {:ok, current_revision} <- safe_apply(profiles, :current, [operation, payload]),
         {:ok, current_revision} <- Digest.validate(current_revision),
         context = %{
           expected_revision: current_revision,
           current_revision: current_revision,
           precondition: {:revision, current_revision},
           config_version: document["version"]
         },
         {:ok, %{"state" => "applied"}} <-
           safe_apply(profiles, :dispatch, [operation, payload, context]) do
      :ok
    else
      _invalid -> :error
    end
  end

  defp apply_resolved(document) do
    case safe_apply(resolved_adapter(), :apply_config, [
           document["operation"],
           document["payload"]
         ]) do
      :ok -> :ok
      _failed -> :error
    end
  end

  defp capture_restore_checkpoint("netman.profiles.replace", _payload) do
    with {:ok, restore_payload, revision} <-
           safe_apply(profiles_adapter(), :replacement_snapshot, []),
         {:ok, _revision} <- Digest.validate(revision),
         :ok <- validate_operation_payload("netman.profiles.replace", restore_payload) do
      {:ok, %{operation: "netman.profiles.replace", payload: restore_payload}}
    else
      _invalid -> :error
    end
  end

  defp capture_restore_checkpoint(operation, payload)
       when operation in [
              "netman.resolved.config.update",
              "netman.resolved.config.rollback"
            ] do
    with {:ok, revision} <- safe_apply(resolved_adapter(), :current, [operation, payload]),
         {:ok, revision} <- Digest.validate(revision) do
      {:ok,
       %{
         operation: "netman.resolved.config.rollback",
         payload: %{"target_revision" => revision}
       }}
    else
      _invalid -> :error
    end
  end

  defp capture_restore_checkpoint(_operation, _payload), do: :error

  defp apply_restore_checkpoint(%{
         "restore_operation" => "netman.profiles.replace",
         "restore_payload" => payload,
         "version" => version
       }) do
    apply_profiles(%{
      "operation" => "netman.profiles.replace",
      "payload" => payload,
      "version" => version
    })
  end

  defp apply_restore_checkpoint(%{
         "restore_operation" => "netman.resolved.config.rollback",
         "restore_payload" => %{"target_revision" => revision}
       }) do
    case safe_apply(resolved_adapter(), :restore_config, [revision]) do
      :ok -> :ok
      _failed -> :error
    end
  end

  defp apply_restore_checkpoint(_checkpoint), do: :error

  defp validate_install_options(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- length(keys) == length(Enum.uniq(keys)),
         true <- Enum.all?(keys, &(&1 in @allowed_install_options)),
         true <- Enum.all?(@allowed_install_options, &Keyword.has_key?(opts, &1)),
         version when is_integer(version) and version > 0 <- Keyword.get(opts, :version),
         operation when operation in @operations <- Keyword.get(opts, :operation),
         {:ok, digest} <- Digest.validate(Keyword.get(opts, :digest)),
         {:ok, expected_revision} <- optional_revision(Keyword.get(opts, :expected_revision)) do
      {:ok,
       %{
         version: version,
         operation: operation,
         digest: digest,
         expected_revision: expected_revision
       }}
    else
      _invalid -> :error
    end
  end

  defp validate_install_options(_opts), do: :error

  defp optional_revision(nil), do: {:ok, nil}
  defp optional_revision(revision), do: Digest.validate(revision)

  defp valid_payload?(operation, payload) do
    match?({:ok, ^payload}, Operation.validate_payload(operation, :netman, :config, payload))
  end

  defp validate_operation_payload(operation, payload) do
    if valid_payload?(operation, payload), do: :ok, else: :error
  end

  defp exact_document(document, payload, install) when is_map(document) do
    if document["target_type"] == "netman" and
         document["operation"] == install.operation and
         document["version"] == install.version and
         document["digest"] == install.digest and
         document["expected_revision"] == install.expected_revision and
         document["payload"] == payload do
      :ok
    else
      :error
    end
  end

  defp exact_document(_document, _payload, _install), do: :error

  defp stored_document(document, revision) when is_map(document) do
    with operation when operation in @operations <- document["operation"],
         true <- document["digest"] == revision,
         version when is_integer(version) and version > 0 <- document["version"],
         payload when is_map(payload) <- document["payload"],
         :ok <- Digest.verify(payload, revision),
         :ok <- validate_operation_payload(operation, payload) do
      :ok
    else
      _invalid -> :error
    end
  end

  defp stored_document(_document, _revision), do: :error

  defp fetch(version, digest) do
    safe_config_store_call(:fetch, [version, digest, config_store()])
  end

  defp fetch_revision(revision) do
    safe_config_store_call(:fetch_revision, [revision, config_store()])
  end

  defp put_restore_checkpoint(install, checkpoint) do
    safe_config_store_call(:put_restore_checkpoint, [
      install.version,
      install.digest,
      checkpoint,
      config_store()
    ])
  end

  defp fetch_restore_checkpoint(revision) do
    safe_config_store_call(:fetch_restore_checkpoint, [revision, config_store()])
  end

  defp safe_config_store_call(function, arguments) do
    safe_apply(ConfigStore, function, arguments)
  end

  defp safe_apply(module, function, arguments)
       when is_atom(module) and is_atom(function) and is_list(arguments) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(arguments)) do
      apply(module, function, arguments)
    else
      :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp safe_apply(_module, _function, _arguments), do: :error

  defp config_store do
    dependency(:config_store, ConfigStore)
  end

  defp profiles_adapter do
    dependency(:profiles, Profiles)
  end

  defp resolved_adapter do
    dependency(:resolved, Resolved)
  end

  defp dependency(key, default) do
    case Application.get_env(:yellow_dog_netman, __MODULE__, []) do
      opts when is_list(opts) ->
        if Keyword.keyword?(opts), do: Keyword.get(opts, key, default), else: default

      _invalid ->
        default
    end
  end
end
