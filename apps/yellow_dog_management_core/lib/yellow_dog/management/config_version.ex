defmodule YellowDog.Management.ConfigVersion do
  @moduledoc """
  Immutable configuration content combined with its durable lifecycle state.
  """

  alias YellowDog.Management.Storage.Path, as: StoragePath
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation

  @max_version 9_223_372_036_854_775_807
  @states [:desired, :delivered, :applying, :applied, :failed]
  @failure_phases [:delivery, :validation, :apply, :rollback]
  @immutable_keys Enum.sort([
                    "digest",
                    "expected_revision",
                    "operation",
                    "payload",
                    "profile",
                    "published_at",
                    "schema_version",
                    "target_id",
                    "target_type",
                    "version"
                  ])
  @lifecycle_keys Enum.sort([
                    "applied_at",
                    "applied_revision",
                    "applying_at",
                    "delivered_at",
                    "digest",
                    "failed_at",
                    "failure_phase",
                    "failure_reason",
                    "previous_revision",
                    "previous_version",
                    "restored_revision",
                    "restored_version",
                    "rollback",
                    "state",
                    "state_changed_at",
                    "state_revision"
                  ])

  @enforce_keys [
    :target_type,
    :target_id,
    :version,
    :operation,
    :profile,
    :payload,
    :digest,
    :expected_revision,
    :state,
    :state_revision,
    :published_at,
    :state_changed_at
  ]
  defstruct @enforce_keys ++
              [
                :delivered_at,
                :applying_at,
                :applied_at,
                :failed_at,
                :applied_revision,
                :previous_version,
                :previous_revision,
                :failure_phase,
                :failure_reason,
                :rollback,
                :restored_version,
                :restored_revision
              ]

  @type target_type :: :server | :netman
  @type state :: :desired | :delivered | :applying | :applied | :failed
  @type failure_phase :: :delivery | :validation | :apply | :rollback
  @type t :: %__MODULE__{
          target_type: target_type(),
          target_id: String.t(),
          version: pos_integer(),
          operation: String.t(),
          profile: String.t(),
          payload: term(),
          digest: String.t(),
          expected_revision: String.t() | nil,
          state: state(),
          state_revision: non_neg_integer(),
          published_at: DateTime.t(),
          state_changed_at: DateTime.t(),
          delivered_at: DateTime.t() | nil,
          applying_at: DateTime.t() | nil,
          applied_at: DateTime.t() | nil,
          failed_at: DateTime.t() | nil,
          applied_revision: String.t() | nil,
          previous_version: pos_integer() | nil,
          previous_revision: String.t() | nil,
          failure_phase: failure_phase() | nil,
          failure_reason: String.t() | nil,
          rollback: map() | nil,
          restored_version: pos_integer() | nil,
          restored_revision: String.t() | nil
        }

  @doc false
  @spec new(
          target_type(),
          String.t(),
          pos_integer(),
          String.t(),
          String.t(),
          term(),
          term(),
          DateTime.t(),
          {pos_integer(), String.t()} | nil
        ) ::
          {:ok, t()} | {:error, Error.t()}
  def new(
        target_type,
        target_id,
        version,
        operation,
        profile,
        payload,
        expected_revision,
        published_at,
        previous
      ) do
    with {:ok, target_type} <- target_type(target_type),
         {:ok, target_id} <- target_id(target_id),
         {:ok, version} <- version(version),
         {:ok, operation} <- config_operation(operation, target_type, payload),
         {:ok, profile} <- profile(profile),
         {:ok, expected_revision} <- optional_digest(expected_revision),
         {:ok, published_at} <- utc_datetime(published_at),
         {:ok, previous_version, previous_revision} <- previous_pair(previous, version),
         true <- expected_revision == previous_revision,
         {:ok, digest} <- Digest.calculate(payload) do
      {:ok,
       %__MODULE__{
         target_type: target_type,
         target_id: target_id,
         version: version,
         operation: operation,
         profile: profile,
         payload: payload,
         digest: digest,
         expected_revision: expected_revision,
         state: :desired,
         state_revision: 0,
         published_at: published_at,
         state_changed_at: published_at,
         previous_version: previous_version,
         previous_revision: previous_revision
       }}
    else
      false -> conflict()
      {:error, %Error{}} = error -> error
      _invalid -> invalid()
    end
  end

  @doc false
  @spec immutable_document(t()) :: map()
  def immutable_document(%__MODULE__{} = version) do
    %{
      "schema_version" => 1,
      "target_type" => Atom.to_string(version.target_type),
      "target_id" => version.target_id,
      "version" => version.version,
      "operation" => version.operation,
      "profile" => version.profile,
      "payload" => version.payload,
      "digest" => version.digest,
      "expected_revision" => version.expected_revision,
      "published_at" => encode_datetime(version.published_at)
    }
  end

  @doc false
  @spec lifecycle_document(t()) :: map()
  def lifecycle_document(%__MODULE__{} = version) do
    %{
      "digest" => version.digest,
      "state" => Atom.to_string(version.state),
      "state_revision" => version.state_revision,
      "state_changed_at" => encode_datetime(version.state_changed_at),
      "delivered_at" => encode_datetime(version.delivered_at),
      "applying_at" => encode_datetime(version.applying_at),
      "applied_at" => encode_datetime(version.applied_at),
      "failed_at" => encode_datetime(version.failed_at),
      "applied_revision" => version.applied_revision,
      "previous_version" => version.previous_version,
      "previous_revision" => version.previous_revision,
      "failure_phase" => encode_atom(version.failure_phase),
      "failure_reason" => version.failure_reason,
      "rollback" => version.rollback,
      "restored_version" => version.restored_version,
      "restored_revision" => version.restored_revision
    }
  end

  @doc false
  @spec decode(map(), map(), target_type(), String.t(), Path.t()) ::
          {:ok, t()} | {:error, Error.t()}
  def decode(immutable, lifecycle, expected_type, expected_id, path)
      when is_map(immutable) and is_map(lifecycle) and is_binary(path) do
    with true <- Enum.sort(Map.keys(immutable)) == @immutable_keys,
         true <- Enum.sort(Map.keys(lifecycle)) == @lifecycle_keys,
         1 <- immutable["schema_version"],
         {:ok, target_type} <- target_type(immutable["target_type"]),
         true <- target_type == expected_type,
         {:ok, target_id} <- target_id(immutable["target_id"]),
         true <- target_id == expected_id,
         {:ok, version} <- version(immutable["version"]),
         {:ok, operation} <-
           config_operation(immutable["operation"], target_type, immutable["payload"]),
         {:ok, profile} <- profile(immutable["profile"]),
         {:ok, digest} <- Digest.validate(immutable["digest"]),
         :ok <- Digest.verify(immutable["payload"], digest),
         true <- lifecycle["digest"] == digest,
         {:ok, expected_revision} <- optional_digest(immutable["expected_revision"]),
         {:ok, published_at} <- utc_datetime(immutable["published_at"]),
         {:ok, expected_path} <- storage_path(target_type, target_id, version, digest),
         true <- expected_path == path,
         {:ok, decoded_lifecycle} <- decode_lifecycle(lifecycle, version),
         true <- expected_revision == decoded_lifecycle.previous_revision do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(decoded_lifecycle, %{
           target_type: target_type,
           target_id: target_id,
           version: version,
           operation: operation,
           profile: profile,
           payload: immutable["payload"],
           digest: digest,
           expected_revision: expected_revision,
           published_at: published_at
         })
       )}
    else
      {:error, %Error{}} = error -> error
      _invalid -> invalid()
    end
  end

  def decode(_immutable, _lifecycle, _expected_type, _expected_id, _path), do: invalid()

  defp decode_lifecycle(value, version) do
    with {:ok, state} <- enum(value["state"], @states),
         {:ok, state_revision} <- state_revision(value["state_revision"]),
         {:ok, state_changed_at} <- utc_datetime(value["state_changed_at"]),
         {:ok, delivered_at} <- optional_datetime(value["delivered_at"]),
         {:ok, applying_at} <- optional_datetime(value["applying_at"]),
         {:ok, applied_at} <- optional_datetime(value["applied_at"]),
         {:ok, failed_at} <- optional_datetime(value["failed_at"]),
         {:ok, applied_revision} <- optional_digest(value["applied_revision"]),
         {:ok, previous_version, previous_revision} <-
           previous_pair({value["previous_version"], value["previous_revision"]}, version),
         {:ok, failure_phase} <- optional_enum(value["failure_phase"], @failure_phases),
         {:ok, failure_reason} <- optional_reason(value["failure_reason"]),
         {:ok, rollback, restored_version, restored_revision} <-
           rollback(value["rollback"], value["restored_version"], value["restored_revision"]),
         :ok <-
           coherent_lifecycle(
             state,
             state_revision,
             delivered_at,
             applying_at,
             applied_at,
             failed_at,
             applied_revision,
             failure_phase,
             failure_reason,
             rollback,
             previous_version,
             previous_revision,
             restored_version,
             restored_revision
           ) do
      {:ok,
       %{
         state: state,
         state_revision: state_revision,
         state_changed_at: state_changed_at,
         delivered_at: delivered_at,
         applying_at: applying_at,
         applied_at: applied_at,
         failed_at: failed_at,
         applied_revision: applied_revision,
         previous_version: previous_version,
         previous_revision: previous_revision,
         failure_phase: failure_phase,
         failure_reason: failure_reason,
         rollback: rollback,
         restored_version: restored_version,
         restored_revision: restored_revision
       }}
    else
      {:error, %Error{}} = error -> error
      _invalid -> invalid()
    end
  end

  defp coherent_lifecycle(
         :desired,
         0,
         nil,
         nil,
         nil,
         nil,
         nil,
         nil,
         nil,
         nil,
         _previous_version,
         _previous_revision,
         nil,
         nil
       ),
       do: :ok

  defp coherent_lifecycle(
         :delivered,
         1,
         %DateTime{},
         nil,
         nil,
         nil,
         nil,
         nil,
         nil,
         nil,
         _previous_version,
         _previous_revision,
         nil,
         nil
       ),
       do: :ok

  defp coherent_lifecycle(
         :applying,
         2,
         %DateTime{},
         %DateTime{},
         nil,
         nil,
         nil,
         nil,
         nil,
         nil,
         _previous_version,
         _previous_revision,
         nil,
         nil
       ),
       do: :ok

  defp coherent_lifecycle(
         :applied,
         3,
         %DateTime{},
         %DateTime{},
         %DateTime{},
         nil,
         applied_revision,
         nil,
         nil,
         nil,
         _previous_version,
         _previous_revision,
         nil,
         nil
       )
       when is_binary(applied_revision),
       do: :ok

  defp coherent_lifecycle(
         :failed,
         revision,
         delivered_at,
         applying_at,
         nil,
         %DateTime{},
         nil,
         phase,
         reason,
         rollback,
         previous_version,
         previous_revision,
         restored_version,
         restored_revision
       )
       when revision in 1..3 and phase in @failure_phases and is_binary(reason) do
    coherent_failure(
      revision,
      delivered_at,
      applying_at,
      phase,
      rollback,
      previous_version,
      previous_revision,
      restored_version,
      restored_revision
    )
  end

  defp coherent_lifecycle(
         _state,
         _revision,
         _delivered_at,
         _applying_at,
         _applied_at,
         _failed_at,
         _applied_revision,
         _phase,
         _reason,
         _rollback,
         _previous_version,
         _previous_revision,
         _restored_version,
         _restored_revision
       ),
       do: invalid()

  defp coherent_failure(1, nil, nil, :delivery, nil, _pv, _pr, nil, nil), do: :ok
  defp coherent_failure(2, %DateTime{}, nil, :validation, nil, _pv, _pr, nil, nil), do: :ok

  defp coherent_failure(
         3,
         %DateTime{},
         %DateTime{},
         phase,
         rollback,
         previous_version,
         previous_revision,
         restored_version,
         restored_revision
       )
       when phase in [:apply, :rollback] do
    coherent_apply_rollback(
      rollback,
      previous_version,
      previous_revision,
      restored_version,
      restored_revision
    )
  end

  defp coherent_failure(
         _revision,
         _delivered_at,
         _applying_at,
         _phase,
         _rollback,
         _previous_version,
         _previous_revision,
         _restored_version,
         _restored_revision
       ),
       do: invalid()

  defp coherent_apply_rollback(nil, nil, nil, nil, nil), do: :ok

  defp coherent_apply_rollback(
         %{"succeeded" => true},
         previous_version,
         previous_revision,
         previous_version,
         previous_revision
       )
       when is_integer(previous_version) and is_binary(previous_revision),
       do: :ok

  defp coherent_apply_rollback(%{"succeeded" => false}, pv, pr, nil, nil)
       when is_integer(pv) and is_binary(pr),
       do: :ok

  defp coherent_apply_rollback(_rollback, _pv, _pr, _rv, _rr), do: invalid()

  defp rollback(nil, nil, nil), do: {:ok, nil, nil, nil}

  defp rollback(
         %{
           "succeeded" => true,
           "restored_version" => restored_version,
           "restored_revision" => restored_revision,
           "reason" => nil
         } = rollback,
         restored_version,
         restored_revision
       )
       when map_size(rollback) == 4 do
    with {:ok, restored_version} <- version(restored_version),
         {:ok, restored_revision} <- Digest.validate(restored_revision) do
      {:ok, rollback, restored_version, restored_revision}
    end
  end

  defp rollback(
         %{
           "succeeded" => false,
           "restored_version" => nil,
           "restored_revision" => nil,
           "reason" => reason
         } = rollback,
         nil,
         nil
       )
       when map_size(rollback) == 4 do
    with {:ok, _reason} <- nonempty_reason(reason) do
      {:ok, rollback, nil, nil}
    end
  end

  defp rollback(_rollback, _restored_version, _restored_revision), do: invalid()

  defp previous_pair(nil, _version), do: {:ok, nil, nil}
  defp previous_pair({nil, nil}, _version), do: {:ok, nil, nil}

  defp previous_pair({previous_version, previous_revision}, version) do
    with {:ok, previous_version} <- version(previous_version),
         true <- previous_version < version,
         {:ok, previous_revision} <- Digest.validate(previous_revision) do
      {:ok, previous_version, previous_revision}
    else
      _invalid -> invalid()
    end
  end

  defp previous_pair(_previous, _version), do: invalid()

  defp config_operation(operation, target_type, payload) do
    with {:ok, operation} <- Bounds.operation(operation),
         {:ok, %Operation{target_type: ^target_type, kind: :config} = concrete} <-
           Operation.lookup(operation),
         {:ok, _payload} <- Operation.validate_payload(concrete, payload) do
      {:ok, operation}
    else
      _invalid -> invalid()
    end
  end

  defp target_type(:server), do: {:ok, :server}
  defp target_type(:netman), do: {:ok, :netman}
  defp target_type("server"), do: {:ok, :server}
  defp target_type("netman"), do: {:ok, :netman}
  defp target_type(_value), do: invalid()

  defp target_id(value) do
    with {:ok, value} <- Bounds.id(value),
         true <- value != "" do
      {:ok, value}
    else
      _invalid -> invalid()
    end
  end

  defp profile(value) do
    with {:ok, value} <- Bounds.id(value),
         true <- value != "" do
      {:ok, value}
    else
      _invalid -> invalid()
    end
  end

  defp version(value) when is_integer(value) and value >= 1 and value <= @max_version,
    do: {:ok, value}

  defp version(_value), do: invalid()

  defp state_revision(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp state_revision(_value), do: invalid()

  defp enum(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> invalid()
      atom -> {:ok, atom}
    end
  end

  defp enum(value, allowed) when is_atom(value) do
    if value in allowed, do: {:ok, value}, else: invalid()
  end

  defp enum(_value, _allowed), do: invalid()

  defp optional_enum(nil, _allowed), do: {:ok, nil}
  defp optional_enum(value, allowed), do: enum(value, allowed)

  defp optional_digest(nil), do: {:ok, nil}
  defp optional_digest(value), do: Digest.validate(value)

  defp optional_reason(nil), do: {:ok, nil}
  defp optional_reason(value), do: nonempty_reason(value)

  defp nonempty_reason(value) do
    with {:ok, value} <- Bounds.message(value),
         true <- value != "" do
      {:ok, value}
    else
      _invalid -> invalid()
    end
  end

  defp utc_datetime(%DateTime{utc_offset: 0, std_offset: 0} = value), do: {:ok, value}

  defp utc_datetime(value) when is_binary(value) do
    with {:ok, datetime, 0} <- DateTime.from_iso8601(value),
         true <- String.ends_with?(value, "Z") do
      {:ok, datetime}
    else
      _invalid -> invalid()
    end
  end

  defp utc_datetime(_value), do: invalid()

  defp optional_datetime(nil), do: {:ok, nil}
  defp optional_datetime(value), do: utc_datetime(value)

  defp storage_path(:server, target_id, version, digest),
    do: StoragePath.server_version(target_id, version, digest)

  defp storage_path(:netman, target_id, version, digest),
    do: StoragePath.netman_version(target_id, version, digest)

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_atom(nil), do: nil
  defp encode_atom(value), do: Atom.to_string(value)

  defp invalid, do: {:error, Error.new(:invalid, "invalid config version", %{})}
  defp conflict, do: {:error, Error.new(:conflict, "stale runtime revision", %{})}
end
