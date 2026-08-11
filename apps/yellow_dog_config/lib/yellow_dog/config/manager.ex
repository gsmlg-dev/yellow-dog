defmodule YellowDog.Config.Manager do
  @moduledoc """
  Process-free owner of aggregate managed runtime configuration.

  Managed documents use the canonical `server.config.replace` wire shape. They
  deliberately exclude bootstrap-local identity, management credentials,
  secrets, certificates, and machine paths. Immutable history therefore
  contains only management-owned state; callers provide the local bootstrap map
  whenever a revision is materialized for activation or boot.

  A typed `null` setting is retained exactly in history and materializes as an
  unset runtime path. Null list items are rejected because they have no unset
  position and cannot be represented by the runtime TOML pipeline.

  History uses a versioned deterministic Erlang external term envelope. Unlike
  TOML, that format preserves the wire contract's typed `null` and nested value
  variants exactly. Decoding is size- and digest-gated and uses safe term mode.

  Active and previous revisions are persisted together in one atomically
  replaced manifest. Activation also returns an opaque recovery token so a
  caller can compensate a failed runtime reconciliation back to the prior
  active/previous selection and its materialized effective config. The
  manifest generation keeps advancing so stale recovery tokens cannot replay.
  """

  alias YellowDog.Config
  alias YellowDog.Config.{Schema, TomlHelpers, Writer}

  @store_directory "managed-config"
  @revisions_directory "revisions"
  @pointer_manifest "pointers.etf"
  @pointer_storage_magic "YDMP\0"
  @pointer_storage_tag :yellow_dog_managed_config_pointers
  @pointer_storage_version 1
  @recovery_storage_magic "YDMR\0"
  @recovery_storage_tag :yellow_dog_managed_config_recovery
  @recovery_storage_version 1
  @max_pointer_bytes 512
  @max_recovery_bytes 1_024
  @storage_magic "YDMC\0"
  @storage_tag :yellow_dog_managed_config
  @storage_version 1
  @unset_marker :yellow_dog_managed_unset
  @max_document_bytes 1_048_576
  @managed_value_depth 5
  @max_collection_size 100
  @max_text_bytes 1_024
  @max_id_bytes 128
  @max_integer 9_223_372_036_854_775_807
  @digest_pattern ~r/\A[0-9a-f]{64}\z/
  @managed_setting_pattern ~r/\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+\z/
  @canonical_setting_segment ~r/\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/
  @server_profiles ~w(cloud_dns local_network dns_only dhcp_only netboot_only custom)
  @server_agent_profiles @server_profiles -- ["custom"]
  @managed_service_settings MapSet.new(~w(
                              services.dns.enabled
                              services.mdns.enabled
                              services.dhcpv4.enabled
                              services.dhcpv6.enabled
                              services.netboot.enabled
                              services.identity.enabled
                              services.fingerprint.enabled
                            ))
  @managed_namespaces MapSet.new(~w(dns mdns dhcpv4 dhcpv6 netboot identity fingerprint))
  @forbidden_setting_tokens MapSet.new(~w(
                              path file filename filepath directory dir root chroot socket
                              pid ets table handle bootstrap management agent server_agent
                            ))
  @nested_forbidden_setting_tokens MapSet.new(
                                     ~w(path file pid port ets table kernel manager handle)
                                   )
  @forbidden_setting_phrases ~w(
    expectedrevision localpath filepath pathname etstable kernelhandle
    kernelmanagerhandle managerhandle
  )
  @sensitive_setting_tokens MapSet.new(~w(
                              secret secrets credential credentials password passwords token tokens
                            ))
  @material_tokens MapSet.new(
                     ~w(raw payload body content blob byte cert certificate pem pkcs12 pfx)
                   )
  @material_plural_tokens %{
    "payloads" => "payload",
    "bodies" => "body",
    "contents" => "content",
    "blobs" => "blob",
    "bytes" => "byte",
    "certs" => "cert",
    "certificates" => "certificate",
    "keys" => "key",
    "pems" => "pem",
    "pfxs" => "pfx"
  }
  @private_key_prefixes MapSet.new(~w(private tls secret signing))
  @material_reference_suffixes ~w(digest hash uri url ref id)
  @glued_reference_suffixes ~w(reference digest hash uri url ref id)
  @local_machine_tokens MapSet.new(~w(
                           path file filename filepath directory dir root chroot socket pid ets table handle
                         ))
  @agent_roots MapSet.new(
                 ~w(yellow_dog_server_agent yellow_dog_netman_agent server_agent netman_agent)
               )
  @local_identity_keys MapSet.new(~w(hostname machine_id node_id node_name server_id netman_id))
  @identity_roots ~w(agent global server netman yellow_dog_server yellow_dog_netman)
  @identity_fields ~w(hostname id identity machine_id name netman_id node_id node_name server_id)

  @type revision :: String.t()
  @opaque recovery_token :: binary()
  @type materialized :: %{revision: revision(), config: map()}
  @type activation :: %{
          revision: revision(),
          config: map(),
          recovery: recovery_token()
        }
  @type compensation :: %{revision: revision() | nil, config: map()}
  @type error_reason ::
          :conflict
          | :corrupt
          | :invalid
          | :not_found
          | :not_started
          | :storage
          | {:invalid_document, [String.t()]}
          | {:validation_failed, [String.t()]}
  @type result(value) :: {:ok, value} | {:error, error_reason()}

  @doc "Validates a canonical management-owned aggregate document."
  @spec validate_document(term()) :: :ok | {:error, error_reason()}
  def validate_document(document) when is_map(document) do
    with :ok <- validate_document_keys(document),
         :ok <- validate_document_shape(document),
         {:ok, encoded} <- encode_document(document),
         :ok <- validate_document_size(encoded),
         :ok <- validate_managed_runtime(document) do
      :ok
    else
      {:error, {:validation_failed, _paths}} = error ->
        error

      {:error, {:invalid_document, _paths}} = error ->
        error

      {:error, :invalid} ->
        {:error, :invalid}

      _invalid ->
        {:error, :invalid}
    end
  end

  def validate_document(_document), do: {:error, :invalid}

  @doc "Materializes a full effective config from managed and local bootstrap state."
  @spec materialize(term(), term()) :: result(map())
  def materialize(document, bootstrap) when is_map(document) and is_map(bootstrap) do
    with :ok <- validate_document(document),
         {:ok, managed} <- managed_runtime(document) do
      runtime =
        managed
        |> deep_merge(local_bootstrap_projection(bootstrap))
        |> preserve_server_agent(bootstrap)

      with :ok <- validate_runtime(runtime),
           {:ok, encoded} <- Writer.encode_config(runtime, validate: false, header: nil),
           {:ok, ^runtime} <- TomlHelpers.parse_toml(encoded) do
        {:ok, runtime}
      else
        {:error, {:validation_failed, _paths}} = error -> error
        _not_toml_safe -> {:error, :invalid}
      end
    end
  end

  def materialize(_document, _bootstrap), do: {:error, :invalid}

  @doc "Installs a canonical immutable candidate without activating it."
  @spec install(term(), term()) :: result(revision())
  def install(data_dir, document) do
    with :ok <- validate_data_dir(data_dir),
         :ok <- validate_document(document),
         {:ok, encoded} <- encode_document(document),
         revision = digest(encoded),
         :ok <- ensure_store_layout(data_dir),
         :ok <- write_immutable(revision_path(data_dir, revision), encoded) do
      {:ok, revision}
    end
  end

  @doc "Reads and verifies an exact installed managed revision."
  @spec read_revision(term(), term()) :: result(map())
  def read_revision(data_dir, revision) do
    with :ok <- validate_data_dir(data_dir),
         :ok <- validate_revision(revision),
         :ok <- validate_store_layout(data_dir) do
      read_verified_revision(data_dir, revision)
    end
  end

  defp read_verified_revision(data_dir, revision) do
    with {:ok, encoded} <- read_file(revision_path(data_dir, revision)),
         :ok <- validate_document_size(encoded),
         true <- digest(encoded) == revision,
         {:ok, document} <- decode_document(encoded),
         :ok <- validate_document(document),
         {:ok, ^encoded} <- encode_document(document) do
      {:ok, document}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, :storage} -> {:error, :storage}
      _invalid_or_tampered -> {:error, :corrupt}
    end
  end

  @doc "Returns the revision selected by the atomic active pointer."
  @spec active_revision(term()) :: result(revision())
  def active_revision(data_dir), do: read_pointer(data_dir, :active)

  @doc "Returns the revision that preceded the current active revision."
  @spec previous_revision(term()) :: result(revision())
  def previous_revision(data_dir), do: read_pointer(data_dir, :previous)

  @doc "Reads and materializes the verified current runtime pointer."
  @spec read_active(term(), term()) :: result(materialized())
  def read_active(data_dir, bootstrap) when is_map(bootstrap) do
    with {:ok, revision} <- active_revision(data_dir) do
      materialize_revision(data_dir, revision, bootstrap)
    end
  end

  def read_active(_data_dir, _bootstrap), do: {:error, :invalid}

  @doc """
  Materializes the exact revision acknowledged as known-good by the apply journal.

  Boot selection intentionally does not consult the active pointer: activation
  can precede the durable `:applied` acknowledgement. The caller must pass the
  exact revision from its durable apply record.
  """
  @spec boot_config(term(), term(), term()) :: result(materialized())
  def boot_config(data_dir, acknowledged_revision, bootstrap) when is_map(bootstrap) do
    materialize_revision(data_dir, acknowledged_revision, bootstrap)
  end

  def boot_config(_data_dir, _acknowledged_revision, _bootstrap), do: {:error, :invalid}

  @doc "Activates an exact installed revision into `YellowDog.Config`."
  @spec activate(term(), term(), term()) :: result(activation())
  def activate(data_dir, revision, bootstrap) when is_map(bootstrap) do
    with :ok <- validate_data_dir(data_dir),
         :ok <- validate_revision(revision) do
      with_activation_lock(data_dir, fn -> do_activate(data_dir, revision, bootstrap) end)
    end
  end

  def activate(_data_dir, _revision, _bootstrap), do: {:error, :invalid}

  defp do_activate(data_dir, revision, bootstrap) do
    with :ok <- validate_store_layout(data_dir),
         :ok <- ensure_config_started(),
         {:ok, document} <- read_revision(data_dir, revision),
         {:ok, runtime} <- materialize(document, bootstrap),
         {:ok, pointers} <- pointer_snapshot(data_dir),
         :ok <- validate_pointer_snapshot(data_dir, pointers),
         {:ok, active_runtime} <- pointer_runtime(data_dir, pointers.active, bootstrap),
         {:ok, previous_runtime} <- pointer_runtime(data_dir, pointers.previous, bootstrap),
         {:ok, bootstrap_digest} <- term_digest(bootstrap),
         {:ok, recovery} <-
           activate_runtime(
             data_dir,
             revision,
             runtime,
             pointers,
             active_runtime,
             previous_runtime,
             bootstrap,
             bootstrap_digest
           ) do
      {:ok, %{revision: revision, config: runtime, recovery: recovery}}
    end
  end

  defp with_activation_lock(data_dir, function) do
    lock_id = {{__MODULE__, :activation, data_dir}, self()}

    case :global.trans(lock_id, function, [node()]) do
      :aborted -> {:error, :storage}
      {:aborted, _reason} -> {:error, :storage}
      result -> result
    end
  end

  @doc "Restores a caller-selected installed revision exactly."
  @spec restore(term(), term(), term()) :: result(activation())
  def restore(data_dir, revision, bootstrap), do: activate(data_dir, revision, bootstrap)

  @doc "Restores and activates the previous known-good revision."
  @spec restore_previous(term(), term()) :: result(activation())
  def restore_previous(data_dir, bootstrap) when is_map(bootstrap) do
    with :ok <- validate_data_dir(data_dir) do
      with_activation_lock(data_dir, fn -> do_restore_previous(data_dir, bootstrap) end)
    end
  end

  def restore_previous(_data_dir, _bootstrap), do: {:error, :invalid}

  defp do_restore_previous(data_dir, bootstrap) do
    with {:ok, %{previous: {:present, revision}}} <- pointer_snapshot(data_dir) do
      do_activate(data_dir, revision, bootstrap)
    else
      {:ok, %{previous: :missing}} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Restores the active/previous selection and effective config captured by activation.

  The opaque token is bound to the data directory and bootstrap used for the
  activation. It fails with `:conflict` after any later pointer transition.
  """
  @spec compensate(term(), term(), term()) :: result(compensation())
  def compensate(data_dir, recovery, bootstrap)
      when is_binary(recovery) and is_map(bootstrap) do
    with :ok <- validate_data_dir(data_dir) do
      with_activation_lock(data_dir, fn -> do_compensate(data_dir, recovery, bootstrap) end)
    end
  end

  def compensate(_data_dir, _recovery, _bootstrap), do: {:error, :invalid}

  defp do_compensate(data_dir, recovery, bootstrap) do
    with :ok <- validate_store_layout(data_dir),
         :ok <- ensure_config_started(),
         {:ok, bootstrap_digest} <- term_digest(bootstrap),
         {:ok, before, expected_after} <-
           decode_recovery(data_dir, bootstrap_digest, recovery),
         {:ok, ^expected_after} <- pointer_snapshot(data_dir),
         :ok <- validate_pointer_snapshot(data_dir, before),
         {:ok, runtime, revision} <- compensation_runtime(data_dir, before, bootstrap),
         {:ok, compensation_snapshot} <-
           compensation_pointer_snapshot(before, expected_after),
         :ok <-
           replace_runtime_with_snapshot(data_dir, runtime, compensation_snapshot) do
      {:ok, %{revision: revision, config: runtime}}
    else
      {:ok, _different_snapshot} -> {:error, :conflict}
      {:error, _reason} = error -> error
    end
  end

  # Compatibility for the existing Settings boundary. Aggregate runtime
  # delivery uses the APIs above; per-service Settings operations remain
  # explicitly unsupported until their adapter is migrated.
  @max_service_bytes 128
  @service_pattern ~r/\A[a-z][a-z0-9_]*\z/

  @spec effective(term()) :: {:error, :invalid | :unsupported}
  def effective(service), do: service_operation(service)

  @spec source(term()) :: {:error, :invalid | :unsupported}
  def source(service), do: service_operation(service)

  @spec revision(term()) :: {:error, :invalid | :unsupported}
  def revision(service), do: service_operation(service)

  @spec validation(term()) :: {:error, :invalid | :unsupported}
  def validation(service), do: service_operation(service)

  @spec update(term(), term()) :: {:error, :invalid | :unsupported}
  def update(service, entries) when is_list(entries), do: service_operation(service)
  def update(_service, _entries), do: {:error, :invalid}

  @spec apply(term()) :: {:error, :invalid | :unsupported}
  def apply(service), do: service_operation(service)

  @spec reload(term()) :: {:error, :invalid | :unsupported}
  def reload(service), do: service_operation(service)

  @spec rollback(term(), term()) :: {:error, :invalid | :unsupported}
  def rollback(service, target_revision) when is_binary(target_revision),
    do: service_operation(service)

  def rollback(_service, _target_revision), do: {:error, :invalid}

  defp validate_document_keys(document) do
    if Enum.all?(Map.keys(document), &is_binary/1), do: :ok, else: {:error, :invalid}
  end

  defp validate_document_shape(document) do
    with true <- exact_keys?(document, ~w(entries profile schema_version)),
         1 <- document["schema_version"],
         profile when profile in @server_profiles <- document["profile"],
         :ok <- validate_managed_entries(document["entries"]) do
      :ok
    else
      false -> invalid_document("document")
      _invalid -> invalid_document("document")
    end
  end

  defp validate_managed_entries(entries) do
    with :ok <- validate_bounded_list(entries),
         :ok <- validate_managed_entry_values(entries),
         settings = Enum.map(entries, & &1["setting"]),
         true <- settings == Enum.sort(settings),
         true <- length(settings) == length(Enum.uniq(settings)) do
      :ok
    else
      {:error, {:invalid_document, _paths}} = error -> error
      _invalid -> invalid_document("entries")
    end
  end

  defp validate_managed_entry_values(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {entry, index}, :ok ->
      case validate_managed_entry(entry, index) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_managed_entry(entry, index) do
    path = "entries.#{index}"

    with true <- exact_keys?(entry, ~w(setting value)),
         setting when is_binary(setting) <- entry["setting"],
         true <- byte_size(setting) > 0 and byte_size(setting) <= @max_text_bytes,
         :ok <- validate_setting_value(entry["value"], path <> ".value", @managed_value_depth),
         true <- safe_managed_setting?(setting, entry["value"]) do
      :ok
    else
      {:error, {:invalid_document, _paths}} = error -> error
      _invalid -> invalid_document(path)
    end
  end

  defp validate_setting_value(_value, path, depth) when depth <= 0,
    do: invalid_document(path)

  defp validate_setting_value(value, path, depth) when is_map(value) do
    case value do
      %{"type" => "string", "value" => text} ->
        if exact_keys?(value, ~w(type value)) and safe_setting_text?(text),
          do: :ok,
          else: invalid_document(path)

      %{"type" => "integer", "value" => integer} ->
        if exact_keys?(value, ~w(type value)) and is_integer(integer) and
             integer >= -@max_integer and integer <= @max_integer,
           do: :ok,
           else: invalid_document(path)

      %{"type" => "boolean", "value" => boolean} ->
        if exact_keys?(value, ~w(type value)) and is_boolean(boolean),
          do: :ok,
          else: invalid_document(path)

      %{"type" => "null", "value" => nil} ->
        if exact_keys?(value, ~w(type value)), do: :ok, else: invalid_document(path)

      %{"type" => "list", "items" => items} ->
        with true <- exact_keys?(value, ~w(items type)),
             :ok <- validate_bounded_list(items),
             true <- Enum.all?(items, &valid_setting_scalar?/1) do
          :ok
        else
          _invalid -> invalid_document(path)
        end

      %{"type" => "object", "entries" => entries} ->
        with true <- exact_keys?(value, ~w(entries type)),
             :ok <- validate_bounded_list(entries),
             :ok <- validate_object_entries(entries, path, depth - 3) do
          :ok
        else
          {:error, {:invalid_document, _paths}} = error -> error
          _invalid -> invalid_document(path)
        end

      _invalid ->
        invalid_document(path)
    end
  end

  defp validate_setting_value(_value, path, _depth), do: invalid_document(path)

  defp validate_object_entries(entries, path, depth) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {entry, index}, :ok ->
      entry_path = "#{path}.entries.#{index}"

      result =
        with true <- exact_keys?(entry, ~w(key value)),
             key when is_binary(key) <- entry["key"],
             true <- valid_identifier?(key),
             true <- safe_nested_setting_name?(key),
             :ok <- validate_setting_value(entry["value"], entry_path <> ".value", depth),
             true <- safe_named_setting_value?(key, entry["value"]) do
          :ok
        else
          {:error, {:invalid_document, _paths}} = error -> error
          _invalid -> invalid_document(entry_path)
        end

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_bounded_list(value) do
    if proper_bounded_list?(value, @max_collection_size),
      do: :ok,
      else: {:error, :invalid}
  end

  defp proper_bounded_list?([], _remaining), do: true
  defp proper_bounded_list?([_item | _rest], 0), do: false

  defp proper_bounded_list?([_item | rest], remaining),
    do: proper_bounded_list?(rest, remaining - 1)

  defp proper_bounded_list?(_value, _remaining), do: false

  defp exact_keys?(value, expected) when is_map(value) do
    keys = Map.keys(value)
    Enum.all?(keys, &is_binary/1) and Enum.sort(keys) == expected
  end

  defp exact_keys?(_value, _expected), do: false

  defp invalid_document(path), do: {:error, {:invalid_document, [path]}}

  defp valid_setting_scalar?(value) when is_boolean(value) or is_float(value),
    do: true

  defp valid_setting_scalar?(value) when is_integer(value),
    do: value >= -@max_integer and value <= @max_integer

  defp valid_setting_scalar?(value) when is_binary(value), do: safe_setting_text?(value)
  defp valid_setting_scalar?(_value), do: false

  defp safe_managed_setting?(setting, value) do
    with true <- Regex.match?(@managed_setting_pattern, setting),
         segments = String.split(setting, "."),
         true <- Enum.all?(segments, &Regex.match?(@canonical_setting_segment, &1)) do
      cond do
        MapSet.member?(@managed_service_settings, setting) ->
          match?(%{"type" => "boolean", "value" => enabled} when is_boolean(enabled), value)

        true ->
          safe_managed_service_setting?(segments, value)
      end
    else
      _invalid -> false
    end
  end

  defp safe_managed_service_setting?([namespace | setting_segments], value) do
    tokens = setting_tokens(setting_segments)

    MapSet.member?(@managed_namespaces, namespace) and setting_segments != [] and
      not Enum.any?(tokens, &MapSet.member?(@forbidden_setting_tokens, &1)) and
      safe_named_setting_value?(setting_segments, value)
  end

  defp safe_managed_service_setting?(_segments, _value), do: false

  defp safe_nested_setting_name?(name) do
    tokens = setting_tokens([name])
    canonical = String.replace(name, ~r/[^a-z0-9]/u, "")
    analysis = setting_analysis([name])

    Regex.match?(@canonical_setting_segment, name) and canonical != "" and
      not Enum.any?(@forbidden_setting_phrases, &String.contains?(canonical, &1)) and
      not Enum.any?(tokens, &MapSet.member?(@nested_forbidden_setting_tokens, &1)) and
      not glued_material_reference?([name]) and safe_nested_reference_name?(tokens, analysis)
  end

  defp safe_nested_reference_name?(tokens, analysis) do
    not Enum.any?(tokens, &(&1 in ["ref", "reference"])) or
      (material_setting?(analysis.base_tokens) and analysis.reference_form == :id)
  end

  defp safe_named_setting_value?(name, value) when is_binary(name),
    do: safe_named_setting_value?([name], value)

  defp safe_named_setting_value?(segments, value) when is_list(segments) do
    %{base_tokens: base_tokens, reference_form: reference_form} = setting_analysis(segments)

    not glued_material_reference?(segments) and
      (not sensitive_or_material_setting?(base_tokens) or
         safe_material_setting_value?(reference_form, value))
  end

  defp safe_material_setting_value?(reference_form, %{
         "type" => "string",
         "value" => value
       }) do
    valid_material_reference?(reference_form, value)
  end

  defp safe_material_setting_value?(_reference_form, _value), do: false

  defp setting_analysis(segments) do
    tokens = setting_tokens(segments)

    case List.pop_at(tokens, -1) do
      {suffix, base_tokens} when suffix in @material_reference_suffixes ->
        %{base_tokens: base_tokens, reference_form: reference_form(suffix)}

      _other ->
        %{base_tokens: tokens, reference_form: nil}
    end
  end

  defp setting_tokens(segments) do
    Enum.flat_map(segments, fn segment ->
      segment
      |> String.split("_")
      |> Enum.map(&Map.get(@material_plural_tokens, &1, &1))
    end)
  end

  defp glued_material_reference?(segments) do
    tokens = setting_tokens(segments)

    case List.pop_at(tokens, -1) do
      {last, prefix} ->
        Enum.any?(@glued_reference_suffixes, fn suffix ->
          if last != suffix and String.ends_with?(last, suffix) do
            stem = last |> String.replace_suffix(suffix, "") |> normalize_material_token()
            stem != "" and material_setting?(prefix ++ [stem])
          else
            false
          end
        end)

      _empty ->
        false
    end
  end

  defp normalize_material_token(token), do: Map.get(@material_plural_tokens, token, token)

  defp sensitive_or_material_setting?(tokens) do
    material_setting?(tokens) or
      Enum.any?(tokens, &MapSet.member?(@sensitive_setting_tokens, &1)) or
      sensitive_token_pair?(tokens)
  end

  defp material_setting?(tokens) do
    Enum.any?(tokens, &MapSet.member?(@material_tokens, &1)) or material_token_pair?(tokens) or
      compact_material?(tokens)
  end

  defp sensitive_token_pair?(tokens) do
    tokens
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn
      [prefix, "key"] when prefix in ["api", "access", "auth", "authentication", "encryption"] ->
        true

      ["private", "material"] ->
        true

      _pair ->
        false
    end)
  end

  defp material_token_pair?(tokens) do
    tokens
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn
      ["pkcs", "12"] -> true
      [prefix, "key"] -> MapSet.member?(@private_key_prefixes, prefix)
      _pair -> false
    end)
  end

  defp compact_material?(tokens) do
    Enum.any?(tokens, fn token ->
      compact_private_key?(token) or
        Enum.any?(MapSet.to_list(@material_tokens), fn root ->
          token != root and (String.starts_with?(token, root) or String.ends_with?(token, root))
        end)
    end)
  end

  defp compact_private_key?(token) do
    Enum.any?(MapSet.to_list(@private_key_prefixes), fn prefix ->
      token in [prefix <> "key", prefix <> "keys"]
    end)
  end

  defp reference_form(suffix) when suffix in ["uri", "url"], do: :uri
  defp reference_form(suffix) when suffix in ["digest", "hash"], do: :digest
  defp reference_form(suffix) when suffix in ["id", "ref"], do: :id

  defp valid_material_reference?(:uri, value), do: supported_http_uri?(value)

  defp valid_material_reference?(:digest, value) when is_binary(value),
    do: Regex.match?(@digest_pattern, value)

  defp valid_material_reference?(:id, value), do: valid_identifier?(value)
  defp valid_material_reference?(_form, _value), do: false

  defp valid_identifier?(value) when is_binary(value) do
    with true <- byte_size(value) in 1..@max_id_bytes,
         {:ok, normalized} <- normalize_unicode(value),
         true <- safe_text?(normalized),
         false <- identifier_path_value?(normalized) do
      true
    else
      _invalid -> false
    end
  end

  defp valid_identifier?(_value), do: false

  defp safe_setting_text?(value) when is_binary(value) do
    with true <- byte_size(value) <= @max_text_bytes,
         {:ok, normalized} <- normalize_unicode(value),
         true <- safe_text?(normalized),
         false <- raw_transport_body?(normalized),
         false <- local_path_value?(normalized) do
      true
    else
      _invalid -> false
    end
  end

  defp safe_setting_text?(_value), do: false

  defp safe_text?(value) do
    String.valid?(value) and String.printable?(value) and
      not Regex.match?(~r/\p{C}/u, value)
  end

  defp normalize_unicode(value) do
    case :unicode.characters_to_nfkc_binary(value) do
      normalized when is_binary(normalized) -> {:ok, normalized}
      _invalid -> {:error, :invalid}
    end
  rescue
    _exception -> {:error, :invalid}
  end

  defp local_path_value?(value) do
    not supported_http_uri?(value) and not valid_cidr_value?(value) and
      identifier_path_value?(value)
  end

  defp identifier_path_value?(value) do
    String.contains?(value, ["/", "\\"]) or Regex.match?(~r/\A[A-Za-z]:/, value) or
      value in [".", "..", "~"]
  end

  defp valid_cidr_value?(value) do
    case String.split(value, "/", parts: 2) do
      [address, prefix] ->
        with {prefix, ""} <- Integer.parse(prefix),
             {:ok, parsed} <- :inet.parse_address(String.to_charlist(address)) do
          maximum = if tuple_size(parsed) == 4, do: 32, else: 128
          prefix in 0..maximum
        else
          _invalid -> false
        end

      _not_cidr ->
        false
    end
  end

  defp supported_http_uri?(value) when is_binary(value) do
    with true <- String.starts_with?(value, ["http://", "https://"]),
         false <- String.contains?(value, ["%", "\\"]),
         false <- Regex.match?(~r/[\s\p{C}]/u, value),
         {:ok, uri} <- URI.new(value),
         true <- uri.scheme in ["http", "https"],
         true <- is_binary(uri.host),
         true <- valid_provider_host?(uri.host),
         true <- is_nil(uri.userinfo),
         true <- is_nil(uri.fragment),
         true <- is_nil(uri.port) or uri.port in 1..65_535,
         true <- safe_uri_path?(uri.path),
         true <- URI.to_string(uri) == value do
      true
    else
      _invalid -> false
    end
  end

  defp supported_http_uri?(_value), do: false

  defp safe_uri_path?(nil), do: true

  defp safe_uri_path?(path) do
    path
    |> String.split("/", trim: false)
    |> Enum.all?(&(&1 not in [".", ".."]))
  end

  defp valid_provider_host?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} when tuple_size(address) in [4, 8] -> true
      _invalid_address -> not Regex.match?(~r/\A[0-9.]+\z/, host) and valid_dns_host?(host)
    end
  end

  defp valid_dns_host?(host) do
    host =
      if String.ends_with?(host, "."),
        do: binary_part(host, 0, byte_size(host) - 1),
        else: host

    host != "" and byte_size(host) <= 253 and
      host
      |> String.split(".", trim: false)
      |> Enum.all?(&valid_dns_host_label?/1)
  end

  defp valid_dns_host_label?(label) when byte_size(label) in 1..63 do
    Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z/, label)
  end

  defp valid_dns_host_label?(_label), do: false

  defp raw_transport_body?(value),
    do: value |> String.upcase() |> String.contains?("-----BEGIN ")

  defp validate_managed_runtime(document) do
    with {:ok, managed} <- managed_runtime(document) do
      validate_runtime(managed)
    end
  end

  defp managed_runtime(document) do
    runtime =
      deep_put(
        Schema.defaults(),
        ["yellow_dog_server"],
        %{"profile" => document["profile"], "services" => %{}}
      )

    Enum.reduce_while(document["entries"], {:ok, runtime}, fn entry, {:ok, config} ->
      with {:ok, value} <- decode_setting_value(entry["value"]) do
        path = runtime_path(entry["setting"])

        config =
          if value == @unset_marker,
            do: deep_delete(config, path),
            else: deep_put(config, path, value)

        {:cont, {:ok, config}}
      else
        _invalid -> {:halt, {:error, :invalid}}
      end
    end)
  end

  defp runtime_path("services." <> remainder) do
    [service, "enabled"] = String.split(remainder, ".")
    ["yellow_dog_server", "services", service]
  end

  defp runtime_path(setting), do: String.split(setting, ".")

  defp decode_setting_value(%{"type" => "string", "value" => value}), do: {:ok, value}
  defp decode_setting_value(%{"type" => "integer", "value" => value}), do: {:ok, value}
  defp decode_setting_value(%{"type" => "boolean", "value" => value}), do: {:ok, value}
  defp decode_setting_value(%{"type" => "null", "value" => nil}), do: {:ok, @unset_marker}
  defp decode_setting_value(%{"type" => "list", "items" => items}), do: {:ok, items}

  defp decode_setting_value(%{"type" => "object", "entries" => entries}) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, object} ->
      case decode_setting_value(entry["value"]) do
        {:ok, @unset_marker} -> {:cont, {:ok, Map.delete(object, entry["key"])}}
        {:ok, value} -> {:cont, {:ok, Map.put(object, entry["key"], value)}}
        _invalid -> {:halt, {:error, :invalid}}
      end
    end)
  end

  defp decode_setting_value(_value), do: {:error, :invalid}

  defp deep_put(map, [key], value), do: Map.put(map, key, value)

  defp deep_put(map, [key | rest], value) do
    child =
      case Map.get(map, key) do
        child when is_map(child) -> child
        _missing_or_scalar -> %{}
      end

    Map.put(map, key, deep_put(child, rest, value))
  end

  defp deep_delete(map, [key]), do: Map.delete(map, key)

  defp deep_delete(map, [key | rest]) do
    case Map.get(map, key) do
      child when is_map(child) -> Map.put(map, key, deep_delete(child, rest))
      _missing_or_scalar -> map
    end
  end

  defp validate_runtime(config) do
    case Schema.validate(config) do
      :ok ->
        :ok

      {:error, errors} ->
        paths = errors |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
        {:error, {:validation_failed, paths}}
    end
  end

  defp encode_document(document) do
    encoded = :erlang.term_to_binary({@storage_tag, @storage_version, document}, [:deterministic])
    {:ok, @storage_magic <> encoded}
  rescue
    _exception -> {:error, :invalid}
  end

  defp decode_document(<<@storage_magic, payload::binary>>) do
    case payload do
      <<131, 104, 3, _term_body::binary>> ->
        decode_external_term(payload)

      _compressed_or_noncanonical ->
        {:error, :corrupt}
    end
  end

  defp decode_document(_encoded), do: {:error, :corrupt}

  defp decode_external_term(payload) do
    case :erlang.binary_to_term(payload, [:safe, :used]) do
      {{@storage_tag, @storage_version, document}, used} when used == byte_size(payload) ->
        {:ok, document}

      _invalid ->
        {:error, :corrupt}
    end
  rescue
    ArgumentError -> {:error, :corrupt}
  end

  defp validate_document_size(encoded) when byte_size(encoded) <= @max_document_bytes, do: :ok
  defp validate_document_size(_encoded), do: {:error, :invalid}

  defp deep_merge(base, overlay) when is_map(base) and is_map(overlay) do
    Map.merge(base, overlay, fn
      _key, base_value, overlay_value when is_map(base_value) and is_map(overlay_value) ->
        deep_merge(base_value, overlay_value)

      _key, _base_value, overlay_value ->
        overlay_value
    end)
  end

  defp local_bootstrap_projection(bootstrap), do: project_local(bootstrap, [])

  defp project_local(map, path) when is_map(map) do
    Enum.reduce(map, %{}, fn {raw_key, value}, projection ->
      case normalize_config_key(raw_key) do
        {:ok, key} ->
          nested_path = path ++ [key]

          cond do
            local_owned_path?(nested_path) ->
              Map.put(projection, key, normalize_config_value(value))

            is_map(value) ->
              case project_local(value, nested_path) do
                child when map_size(child) == 0 -> projection
                child -> Map.put(projection, key, child)
              end

            true ->
              projection
          end

        :error ->
          projection
      end
    end)
  end

  defp local_owned_path?([root | _rest] = path) do
    key = List.last(path)
    tokens = setting_tokens([key])
    analysis = setting_analysis([key])

    MapSet.member?(@agent_roots, root) or path == ["data_dir"] or
      (length(path) == 1 and MapSet.member?(@local_identity_keys, key)) or
      identity_path?(path) or
      "management" in path or "management" in tokens or "bootstrap" in tokens or
      "agent" in tokens or Enum.any?(tokens, &MapSet.member?(@local_machine_tokens, &1)) or
      (sensitive_or_material_setting?(analysis.base_tokens) and is_nil(analysis.reference_form))
  end

  defp identity_path?([root, field | _rest])
       when root in @identity_roots and field in @identity_fields,
       do: true

  defp identity_path?(_path), do: false

  defp normalize_config_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_config_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_config_key(_key), do: :error

  defp normalize_config_value(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {raw_key, nested}, normalized ->
      case normalize_config_key(raw_key) do
        {:ok, key} -> Map.put(normalized, key, normalize_config_value(nested))
        :error -> normalized
      end
    end)
  end

  defp normalize_config_value(value) when is_list(value),
    do: Enum.map(value, &normalize_config_value/1)

  defp normalize_config_value(value), do: value

  defp preserve_server_agent(runtime, bootstrap) do
    deep_put(
      runtime,
      ["yellow_dog_server", "services", "server_agent"],
      bootstrap_server_agent_enabled?(bootstrap)
    )
  end

  defp bootstrap_server_agent_enabled?(bootstrap) do
    case bootstrap_value(bootstrap, ["yellow_dog_server", "services", "server_agent"]) do
      enabled when is_boolean(enabled) ->
        enabled

      _missing ->
        normalize_profile(bootstrap_value(bootstrap, ["yellow_dog_server", "profile"])) in @server_agent_profiles
    end
  end

  defp bootstrap_value(config, []), do: config

  defp bootstrap_value(config, [key | rest]) when is_map(config) do
    value =
      case Map.fetch(config, key) do
        {:ok, value} -> value
        :error -> find_atom_key_value(config, key)
      end

    bootstrap_value(value, rest)
  end

  defp bootstrap_value(_config, _path), do: nil

  defp find_atom_key_value(map, key) do
    Enum.find_value(map, fn
      {map_key, value} when is_atom(map_key) -> if Atom.to_string(map_key) == key, do: value
      _entry -> nil
    end)
  end

  defp normalize_profile(profile) when is_atom(profile), do: Atom.to_string(profile)
  defp normalize_profile(profile), do: profile

  defp validate_data_dir(data_dir) when is_binary(data_dir) and data_dir != "" do
    if String.valid?(data_dir) and Path.type(data_dir) == :absolute and
         Path.expand(data_dir) == data_dir do
      :ok
    else
      {:error, :invalid}
    end
  end

  defp validate_data_dir(_data_dir), do: {:error, :invalid}

  defp validate_revision(revision) when is_binary(revision) do
    if Regex.match?(@digest_pattern, revision), do: :ok, else: {:error, :invalid}
  end

  defp validate_revision(_revision), do: {:error, :invalid}

  defp digest(encoded) do
    encoded
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp store_path(data_dir), do: Path.join(data_dir, @store_directory)

  defp revision_path(data_dir, revision) do
    Path.join([store_path(data_dir), @revisions_directory, revision <> ".etf"])
  end

  defp pointer_manifest_path(data_dir), do: Path.join(store_path(data_dir), @pointer_manifest)

  defp materialize_revision(data_dir, revision, bootstrap) do
    with {:ok, document} <- read_revision(data_dir, revision),
         {:ok, runtime} <- materialize(document, bootstrap) do
      {:ok, %{revision: revision, config: runtime}}
    end
  end

  defp read_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.read(path) do
          {:ok, contents} -> {:ok, contents}
          {:error, :enoent} -> {:error, :not_found}
          {:error, _reason} -> {:error, :storage}
        end

      {:ok, %File.Stat{}} ->
        {:error, :storage}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :storage}
    end
  end

  defp write_immutable(path, contents) do
    with :ok <- ensure_directory(Path.dirname(path)),
         {:ok, stage_path} <- write_stage(path, contents) do
      promote_immutable(stage_path, path, contents)
    end
  end

  defp promote_immutable(stage_path, path, contents) do
    result =
      case :file.make_link(stage_path, path) do
        :ok ->
          with :ok <- remove_stage(stage_path), do: sync_directory(Path.dirname(path))

        {:error, :eexist} ->
          with :ok <- remove_stage(stage_path), do: compare_immutable(path, contents)

        {:error, _reason} ->
          remove_stage(stage_path)
          {:error, :storage}
      end

    result
  end

  defp compare_immutable(path, contents) do
    case read_file(path) do
      {:ok, ^contents} -> sync_directory(Path.dirname(path))
      {:ok, _different} -> {:error, :conflict}
      {:error, _reason} -> {:error, :storage}
    end
  end

  defp write_stage(path, contents), do: write_stage(path, contents, 0)

  defp write_stage(_path, _contents, 32), do: {:error, :storage}

  defp write_stage(path, contents, attempt) do
    stage_path = temporary_path(path)

    case :file.open(stage_path, [:write, :exclusive, :binary, :raw]) do
      {:ok, device} ->
        result =
          with :ok <- :file.write(device, contents),
               :ok <- :file.sync(device) do
            :ok
          else
            {:error, _reason} -> {:error, :storage}
          end

        close_result = :file.close(device)

        case {result, close_result} do
          {:ok, :ok} -> {:ok, stage_path}
          _error -> cleanup_error(stage_path)
        end

      {:error, :eexist} ->
        write_stage(path, contents, attempt + 1)

      {:error, _reason} ->
        {:error, :storage}
    end
  end

  defp temporary_path(path) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    Path.join(Path.dirname(path), ".#{Path.basename(path)}.#{suffix}.stage")
  end

  defp ensure_directory(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, _reason} -> {:error, :storage}
    end
  end

  defp ensure_store_layout(data_dir) do
    with :ok <- ensure_directory(data_dir),
         :ok <- ensure_plain_directory(data_dir),
         :ok <- ensure_plain_directory(store_path(data_dir)),
         :ok <- ensure_plain_directory(Path.join(store_path(data_dir), @revisions_directory)) do
      :ok
    end
  end

  defp validate_store_layout(data_dir) do
    with :ok <- validate_plain_directory_if_present(data_dir),
         :ok <- validate_plain_directory_if_present(store_path(data_dir)),
         :ok <-
           validate_plain_directory_if_present(
             Path.join(store_path(data_dir), @revisions_directory)
           ) do
      :ok
    end
  end

  defp ensure_plain_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{}} ->
        {:error, :storage}

      {:error, :enoent} ->
        case File.mkdir(path) do
          :ok -> sync_directory(Path.dirname(path))
          {:error, :eexist} -> validate_plain_directory_if_present(path)
          {:error, _reason} -> {:error, :storage}
        end

      {:error, _reason} ->
        {:error, :storage}
    end
  end

  defp validate_plain_directory_if_present(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{}} -> {:error, :storage}
      {:error, :enoent} -> :ok
      {:error, _reason} -> {:error, :storage}
    end
  end

  defp remove_stage(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> {:error, :storage}
    end
  end

  defp cleanup_error(stage_path) do
    remove_stage(stage_path)
    {:error, :storage}
  end

  defp sync_directory(directory) do
    case :file.open(directory, [:read, :raw, :directory]) do
      {:ok, device} ->
        result =
          case :file.sync(device) do
            {:error, :enotsup} -> :ok
            other -> other
          end

        close_result = :file.close(device)

        case {result, close_result} do
          {:ok, :ok} -> :ok
          _error -> {:error, :storage}
        end

      {:error, :enotsup} ->
        :ok

      {:error, _reason} ->
        {:error, :storage}
    end
  end

  defp read_pointer(data_dir, pointer) when pointer in [:active, :previous] do
    with {:ok, pointers} <- pointer_snapshot(data_dir) do
      case Map.fetch!(pointers, pointer) do
        {:present, revision} -> {:ok, revision}
        :missing -> {:error, :not_found}
      end
    end
  end

  defp pointer_snapshot(data_dir) do
    with :ok <- validate_data_dir(data_dir),
         :ok <- validate_store_layout(data_dir) do
      case read_file(pointer_manifest_path(data_dir)) do
        {:ok, contents} -> decode_pointer_snapshot(contents)
        {:error, :not_found} -> {:ok, empty_pointer_snapshot()}
        {:error, _reason} = error -> error
      end
    end
  end

  defp empty_pointer_snapshot, do: %{generation: 0, active: :missing, previous: :missing}

  defp encode_pointer_snapshot(pointers) do
    {generation, active, previous} = pointer_snapshot_term(pointers)

    encoded =
      @pointer_storage_magic <>
        :erlang.term_to_binary(
          {@pointer_storage_tag, @pointer_storage_version, generation, active, previous},
          [:deterministic]
        )

    if byte_size(encoded) <= @max_pointer_bytes,
      do: {:ok, encoded},
      else: {:error, :storage}
  end

  defp decode_pointer_snapshot(contents)
       when is_binary(contents) and byte_size(contents) <= @max_pointer_bytes do
    with <<@pointer_storage_magic, payload::binary>> <- contents,
         <<131, 104, 5, _term_body::binary>> <- payload,
         {{@pointer_storage_tag, @pointer_storage_version, generation, active, previous}, used}
         when used == byte_size(payload) <- :erlang.binary_to_term(payload, [:safe, :used]),
         {:ok, pointers} <- pointer_snapshot_from_term(generation, active, previous),
         {:ok, ^contents} <- encode_pointer_snapshot(pointers) do
      {:ok, pointers}
    else
      _invalid -> {:error, :corrupt}
    end
  rescue
    ArgumentError -> {:error, :corrupt}
  end

  defp decode_pointer_snapshot(_contents), do: {:error, :corrupt}

  defp pointer_snapshot_term(%{generation: generation, active: active, previous: previous}) do
    {generation, pointer_term(active), pointer_term(previous)}
  end

  defp pointer_term(:missing), do: nil
  defp pointer_term({:present, revision}), do: revision

  defp pointer_snapshot_from_term(generation, active, previous) do
    with true <- is_integer(generation) and generation >= 0 and generation <= @max_integer,
         {:ok, active} <- pointer_from_term(active),
         {:ok, previous} <- pointer_from_term(previous),
         pointers = %{generation: generation, active: active, previous: previous},
         :ok <- valid_pointer_shape(pointers) do
      {:ok, pointers}
    else
      false -> {:error, :corrupt}
      {:error, _reason} = error -> error
    end
  end

  defp pointer_from_term(nil), do: {:ok, :missing}

  defp pointer_from_term(revision) when is_binary(revision) do
    case validate_revision(revision) do
      :ok -> {:ok, {:present, revision}}
      {:error, :invalid} -> {:error, :corrupt}
    end
  end

  defp pointer_from_term(_value), do: {:error, :corrupt}

  defp valid_pointer_shape(%{generation: generation, active: :missing, previous: :missing})
       when is_integer(generation) and generation >= 0 and generation <= @max_integer,
       do: :ok

  defp valid_pointer_shape(%{generation: generation, active: {:present, _revision}})
       when is_integer(generation) and generation > 0 and generation <= @max_integer,
       do: :ok

  defp valid_pointer_shape(%{active: :missing, previous: {:present, _revision}}),
    do: {:error, :corrupt}

  defp valid_pointer_shape(_pointers), do: {:error, :corrupt}

  defp validate_pointer_snapshot(_data_dir, %{active: :missing, previous: :missing}), do: :ok

  defp validate_pointer_snapshot(_data_dir, %{active: :missing, previous: {:present, _revision}}),
    do: {:error, :corrupt}

  defp validate_pointer_snapshot(data_dir, pointers) do
    with :ok <- verify_pointer_revision(data_dir, pointers.active),
         :ok <- verify_pointer_revision(data_dir, pointers.previous) do
      :ok
    end
  end

  defp verify_pointer_revision(_data_dir, :missing), do: :ok

  defp verify_pointer_revision(data_dir, {:present, revision}) do
    case read_revision(data_dir, revision) do
      {:ok, _document} -> :ok
      {:error, _reason} -> {:error, :corrupt}
    end
  end

  defp recovery_pointer_snapshot(
         current,
         pointers,
         active_runtime,
         previous_runtime,
         bootstrap
       ) do
    cond do
      active_runtime != :missing and current == active_runtime ->
        {:ok, pointers}

      previous_runtime != :missing and current == previous_runtime ->
        {:ok,
         %{
           generation: pointers.generation,
           active: pointers.previous,
           previous: pointers.active
         }}

      current == bootstrap ->
        {:ok, %{generation: pointers.generation, active: :missing, previous: :missing}}

      true ->
        {:error, :conflict}
    end
  end

  defp pointer_runtime(_data_dir, :missing, _bootstrap), do: {:ok, :missing}

  defp pointer_runtime(data_dir, {:present, revision}, bootstrap) do
    case materialize_revision(data_dir, revision, bootstrap) do
      {:ok, %{revision: ^revision, config: runtime}} -> {:ok, runtime}
      {:error, _reason} = error -> error
    end
  end

  defp activate_runtime(
         data_dir,
         revision,
         runtime,
         pointers,
         active_runtime,
         previous_runtime,
         bootstrap,
         bootstrap_digest
       ) do
    with {:ok, next_pointers} <- advance_pointer_snapshot(pointers, revision) do
      config_transaction(fn current ->
        with {:ok, recovery_pointers} <-
               recovery_pointer_snapshot(
                 current,
                 pointers,
                 active_runtime,
                 previous_runtime,
                 bootstrap
               ),
             :ok <- write_pointer_snapshot(data_dir, next_pointers) do
          recovery =
            encode_recovery(
              data_dir,
              bootstrap_digest,
              recovery_pointers,
              next_pointers
            )

          {{:ok, recovery}, runtime}
        else
          {:error, _reason} = error -> {error, current}
        end
      end)
    end
  end

  defp advance_pointer_snapshot(%{active: {:present, revision}} = pointers, revision) do
    with {:ok, generation} <- next_pointer_generation(pointers.generation) do
      {:ok, %{pointers | generation: generation}}
    end
  end

  defp advance_pointer_snapshot(pointers, revision) do
    with {:ok, generation} <- next_pointer_generation(pointers.generation) do
      {:ok,
       %{
         generation: generation,
         active: {:present, revision},
         previous: pointers.active
       }}
    end
  end

  defp next_pointer_generation(generation) when generation < @max_integer,
    do: {:ok, generation + 1}

  defp next_pointer_generation(_generation), do: {:error, :storage}

  defp compensation_pointer_snapshot(before, expected_after) do
    with {:ok, generation} <- next_pointer_generation(expected_after.generation) do
      {:ok, %{before | generation: generation}}
    end
  end

  defp replace_runtime_with_snapshot(data_dir, runtime, snapshot) do
    config_transaction(fn current ->
      case write_pointer_snapshot(data_dir, snapshot) do
        :ok -> {:ok, runtime}
        {:error, _reason} = error -> {error, current}
      end
    end)
  end

  defp config_transaction(function) do
    Config.get_and_update_effective(function, :infinity)
  catch
    :exit, _reason -> {:error, :not_started}
  end

  defp write_pointer_snapshot(data_dir, %{
         generation: 0,
         active: :missing,
         previous: :missing
       }) do
    path = pointer_manifest_path(data_dir)

    case File.rm(path) do
      :ok -> confirm_pointer_removal(path, sync_directory(Path.dirname(path)))
      {:error, :enoent} -> :ok
      {:error, _reason} -> {:error, :storage}
    end
  end

  defp write_pointer_snapshot(data_dir, pointers) do
    with :ok <- valid_pointer_shape(pointers),
         {:ok, encoded} <- encode_pointer_snapshot(pointers) do
      atomic_replace_pointer(pointer_manifest_path(data_dir), encoded)
    end
  end

  defp atomic_replace_pointer(path, contents) do
    with :ok <- ensure_directory(Path.dirname(path)),
         {:ok, stage_path} <- write_stage(path, contents) do
      case File.rename(stage_path, path) do
        :ok -> confirm_pointer_replace(path, contents, sync_directory(Path.dirname(path)))
        {:error, _reason} -> cleanup_error(stage_path)
      end
    end
  end

  defp confirm_pointer_replace(_path, _contents, :ok), do: :ok

  defp confirm_pointer_replace(path, contents, {:error, :storage}) do
    case read_file(path) do
      {:ok, ^contents} -> :ok
      _unknown_state -> {:error, :storage}
    end
  end

  defp confirm_pointer_removal(_path, :ok), do: :ok

  defp confirm_pointer_removal(path, {:error, :storage}) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      _unknown_state -> {:error, :storage}
    end
  end

  defp encode_recovery(data_dir, bootstrap_digest, before, next_snapshot) do
    before_term = pointer_snapshot_term(before)
    next_term = pointer_snapshot_term(next_snapshot)

    @recovery_storage_magic <>
      :erlang.term_to_binary(
        {
          @recovery_storage_tag,
          @recovery_storage_version,
          digest(data_dir),
          bootstrap_digest,
          before_term,
          next_term
        },
        [:deterministic]
      )
  end

  defp decode_recovery(data_dir, bootstrap_digest, recovery)
       when byte_size(recovery) <= @max_recovery_bytes do
    with <<@recovery_storage_magic, payload::binary>> <- recovery,
         <<131, 104, 6, _term_body::binary>> <- payload,
         {{@recovery_storage_tag, @recovery_storage_version, data_dir_digest,
           encoded_bootstrap_digest, {before_generation, before_active, before_previous},
           {after_generation, after_active, after_previous}}, used}
         when used == byte_size(payload) <- :erlang.binary_to_term(payload, [:safe, :used]),
         true <- data_dir_digest == digest(data_dir),
         true <- encoded_bootstrap_digest == bootstrap_digest,
         {:ok, before} <-
           pointer_snapshot_from_term(before_generation, before_active, before_previous),
         {:ok, after_snapshot} <-
           pointer_snapshot_from_term(after_generation, after_active, after_previous),
         ^recovery <-
           encode_recovery(data_dir, bootstrap_digest, before, after_snapshot) do
      {:ok, before, after_snapshot}
    else
      _invalid -> {:error, :invalid}
    end
  rescue
    ArgumentError -> {:error, :invalid}
  end

  defp decode_recovery(_data_dir, _bootstrap_digest, _recovery), do: {:error, :invalid}

  defp term_digest(term) do
    {:ok, term |> :erlang.term_to_binary([:deterministic]) |> digest()}
  rescue
    ArgumentError -> {:error, :invalid}
  end

  defp compensation_runtime(_data_dir, %{active: :missing}, bootstrap) do
    {:ok, bootstrap, nil}
  end

  defp compensation_runtime(data_dir, %{active: {:present, revision}}, bootstrap) do
    case materialize_revision(data_dir, revision, bootstrap) do
      {:ok, %{revision: ^revision, config: runtime}} -> {:ok, runtime, revision}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_config_started do
    if Process.whereis(Config), do: :ok, else: {:error, :not_started}
  end

  defp service_operation(service) do
    if valid_service?(service), do: {:error, :unsupported}, else: {:error, :invalid}
  end

  defp valid_service?(service)
       when is_binary(service) and byte_size(service) >= 1 and
              byte_size(service) <= @max_service_bytes do
    String.valid?(service) and Regex.match?(@service_pattern, service)
  end

  defp valid_service?(_service), do: false
end
