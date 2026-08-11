defmodule YellowDog.Resolved.Config do
  @moduledoc """
  Configuration server for yellow_dog_resolved.
  Loads TOML config and watches for changes.
  """
  use GenServer

  require Logger

  @default_config %{
    listen: {127, 0, 0, 1},
    port: 53,
    upstreams: [{1, 1, 1, 1}, {8, 8, 8, 8}],
    search_domains: [],
    upstream_timeout_ms: 3000,
    upstream_failure_threshold: 3,
    cache: %{
      enabled: true,
      max_entries: 10_000,
      min_ttl_s: 30,
      max_ttl_s: 86_400,
      negative_ttl_s: 60,
      sweep_interval_s: 60
    },
    discovery: %{
      enabled: true,
      websocket: %{
        heartbeat_interval_s: 30,
        reconnect_base_s: 5,
        reconnect_max_s: 60
      }
    },
    rate_limit: %{
      burst: 50,
      rate: 20
    },
    intercept_rules: []
  }

  @persistent_term_key {__MODULE__, :config}
  @history_limit 32
  @state_filename "resolved-state.json"
  @state_format_version 1

  @doc false
  @spec parse_toml_for_test(map()) :: map()
  def parse_toml_for_test(toml), do: parse_toml(toml)

  @config_paths [
    "config/resolved.toml",
    "/etc/yellowdog/resolved.toml"
  ]

  # Client API

  @spec start_link(map() | {map(), keyword()}) :: GenServer.on_start()
  def start_link({config, opts}) when is_map(config) and is_list(opts) do
    with true <- Keyword.keyword?(opts),
         persist when is_function(persist, 2) <-
           Keyword.get(opts, :persist, &default_persist/2),
         runtime_apply when is_function(runtime_apply, 2) <-
           Keyword.get(opts, :runtime_apply, &apply_runtime_config/2) do
      durable_state? = not Keyword.has_key?(opts, :persist)

      GenServer.start_link(
        __MODULE__,
        {normalize_loaded_config(config), persist, runtime_apply, durable_state?},
        name: __MODULE__
      )
    else
      _ -> {:error, :invalid_options}
    end
  end

  def start_link(config) when is_map(config) do
    start_link({config, []})
  end

  @spec get() :: map()
  def get do
    :persistent_term.get(@persistent_term_key)
  end

  @spec get(atom()) :: term()
  def get(key) do
    Map.get(:persistent_term.get(@persistent_term_key), key)
  end

  @doc "Returns the canonical revision of the managed resolver configuration."
  @spec revision() :: {:ok, String.t()} | {:error, :not_running}
  def revision do
    GenServer.call(__MODULE__, :revision)
  catch
    :exit, _reason -> {:error, :not_running}
  end

  @doc false
  @spec update_managed(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_managed(config, opts \\ []) when is_map(config) and is_list(opts) do
    GenServer.call(__MODULE__, {:update_managed, config, opts})
  catch
    :exit, _reason -> {:error, :not_running}
  end

  @doc false
  @spec rollback_managed(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def rollback_managed(target_revision, opts \\ [])
      when is_binary(target_revision) and is_list(opts) do
    GenServer.call(__MODULE__, {:rollback_managed, target_revision, opts})
  catch
    :exit, _reason -> {:error, :not_running}
  end

  @doc """
  Loads config from TOML file or returns defaults.
  Called before supervisor starts.
  """
  @spec load() :: map()
  def load do
    config_path = find_config_file()

    config =
      case config_path do
        nil ->
          Logger.info("[Resolved] No config file found, using defaults")
          @default_config

        path ->
          Logger.info("[Resolved] Loading config from #{path}")
          load_from_file(path)
      end

    config
    |> normalize_loaded_config()
    |> load_persisted_current()
  end

  # Server callbacks

  @impl true
  def init({config, persist, runtime_apply, durable_state?}) do
    {config, history, history_order} =
      if durable_state? do
        load_persisted_state(config)
      else
        initial_history(config)
      end

    :persistent_term.put(@persistent_term_key, config)
    config_path = find_config_file()
    revision = managed_revision(config)

    state = %{
      config: config,
      config_path: config_path,
      watcher_pid: nil,
      revision: revision,
      version: nil,
      history: history,
      history_order: history_order,
      persist: persist,
      runtime_apply: runtime_apply
    }

    state = maybe_start_watcher(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:revision, _from, state) do
    {:reply, {:ok, state.revision}, state}
  end

  def handle_call({:update_managed, managed, opts}, _from, state) do
    with :ok <- validate_mutation_options(opts),
         :ok <- check_expected_revision(opts, state.revision),
         :ok <- check_version(Keyword.get(opts, :version), state.version),
         {:ok, candidate} <- merge_managed_config(state.config, managed) do
      apply_candidate(candidate, Keyword.get(opts, :version), state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:rollback_managed, target_revision, opts}, _from, state) do
    with :ok <- validate_mutation_options(opts),
         :ok <- check_expected_revision(opts, state.revision),
         :ok <- check_version(Keyword.get(opts, :version), state.version),
         {:ok, candidate} <- fetch_history(state.history, target_revision) do
      apply_candidate(candidate, Keyword.get(opts, :version), state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher, {path, _events}}, state) do
    if path == state.config_path do
      Logger.info("[Resolved] Config file changed, reloading")

      case load_from_file(path) do
        config when is_map(config) ->
          config = normalize_loaded_config(config)
          :persistent_term.put(@persistent_term_key, config)
          propagate_config(config, state.config)
          revision = managed_revision(config)
          {history, history_order} = remember_config(state, revision, config)

          {:noreply,
           %{
             state
             | config: config,
               revision: revision,
               version: nil,
               history: history,
               history_order: history_order
           }}

        _ ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :persistent_term.erase(@persistent_term_key)

    if is_pid(state.watcher_pid) and Process.alive?(state.watcher_pid) do
      GenServer.stop(state.watcher_pid, :normal, 1_000)
    end

    :ok
  end

  # Private

  defp apply_candidate(candidate, version, state) do
    previous_revision = state.revision
    previous_version = state.version

    case safe_callback(state.persist, candidate, state.config) do
      :ok ->
        :persistent_term.put(@persistent_term_key, candidate)

        case safe_callback(state.runtime_apply, candidate, state.config) do
          :ok ->
            revision = managed_revision(candidate)
            {history, history_order} = remember_config(state, revision, candidate)

            next_state = %{
              state
              | config: candidate,
                revision: revision,
                version: version,
                history: history,
                history_order: history_order
            }

            reply = %{
              revision: revision,
              previous_revision: previous_revision,
              previous_version: previous_version
            }

            {:reply, {:ok, reply}, next_state}

          {:error, apply_reason} ->
            restore_after_apply_failure(apply_reason, candidate, state)
        end

      {:error, reason} ->
        {:reply, {:error, {:write_failed, reason}}, state}
    end
  end

  defp restore_after_apply_failure(apply_reason, candidate, state) do
    :persistent_term.put(@persistent_term_key, state.config)

    with :ok <- safe_callback(state.persist, state.config, candidate),
         :ok <- safe_callback(state.runtime_apply, state.config, candidate) do
      {:reply, {:error, {:apply_failed, apply_reason}}, state}
    else
      {:error, reason} -> {:reply, {:error, {:rollback_failed, reason}}, state}
    end
  end

  defp safe_callback(callback, new_config, old_config) do
    case callback.(new_config, old_config) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_callback_result}
    end
  rescue
    _exception -> {:error, :callback_failed}
  catch
    _kind, _reason -> {:error, :callback_failed}
  end

  defp validate_mutation_options(opts) do
    keys = Keyword.keys(opts)

    if Keyword.keyword?(opts) and Enum.all?(keys, &(&1 in [:expected_revision, :version])) and
         length(keys) == length(Enum.uniq(keys)) do
      :ok
    else
      {:error, :invalid_options}
    end
  end

  defp check_expected_revision(opts, current_revision) do
    case Keyword.fetch(opts, :expected_revision) do
      {:ok, ^current_revision} -> :ok
      {:ok, _stale} -> {:error, {:conflict, current_revision}}
      :error -> {:error, :expected_revision_required}
    end
  end

  defp check_version(nil, _current), do: :ok
  defp check_version(version, nil) when is_integer(version) and version > 0, do: :ok

  defp check_version(version, current)
       when is_integer(version) and version > current and is_integer(current),
       do: :ok

  defp check_version(version, _current) when is_integer(version) and version > 0,
    do: {:error, :stale_version}

  defp check_version(_version, _current), do: {:error, :invalid_version}

  defp merge_managed_config(config, %{upstreams: upstreams, search_domains: search_domains})
       when is_list(upstreams) and is_list(search_domains) do
    {:ok, %{config | upstreams: upstreams, search_domains: search_domains}}
  rescue
    KeyError -> {:error, :invalid_config}
  end

  defp merge_managed_config(_config, _managed), do: {:error, :invalid_config}

  defp fetch_history(history, revision) do
    case Map.fetch(history, revision) do
      {:ok, config} -> {:ok, config}
      :error -> {:error, :revision_not_found}
    end
  end

  defp remember_config(state, revision, config) do
    order = [revision | Enum.reject(state.history_order, &(&1 == revision))]
    order = Enum.take(order, @history_limit)
    history = state.history |> Map.put(revision, config) |> Map.take(order)
    {history, order}
  end

  defp managed_revision(config) do
    canonical =
      {
        Enum.map(Map.get(config, :upstreams, []), &:inet.ntoa/1),
        Map.get(config, :search_domains, [])
      }

    canonical
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp default_persist(new_config, old_config) do
    path = persisted_state_path()

    with {:ok, document} <- read_persisted_document(path),
         document <- remember_persisted_configs(document, [old_config, new_config]),
         contents <- encode_persisted_document(document, managed_revision(new_config)),
         :ok <- atomic_write(path, contents) do
      :ok
    end
  end

  defp load_persisted_current(config) do
    case load_persisted_state(config) do
      {persisted, _history, _history_order} -> persisted
    end
  end

  defp load_persisted_state(config) do
    case read_persisted_document(persisted_state_path()) do
      {:ok, %{current_revision: current_revision} = document} ->
        history =
          Map.new(document.history, fn {revision, managed} ->
            {revision, merge_persisted_managed(config, managed)}
          end)

        case Map.fetch(history, current_revision) do
          {:ok, current} -> {current, history, document.history_order}
          :error -> initial_history(config)
        end

      {:ok, nil} ->
        initial_history(config)

      {:error, reason} ->
        Logger.warning("[Resolved] Ignoring invalid persisted state: #{inspect(reason)}")
        initial_history(config)
    end
  end

  defp initial_history(config) do
    revision = managed_revision(config)
    {config, %{revision => config}, [revision]}
  end

  defp read_persisted_document(path) do
    case File.read(path) do
      {:ok, contents} ->
        with {:ok, decoded} <- Jason.decode(contents),
             {:ok, document} <- decode_persisted_document(decoded) do
          {:ok, document}
        else
          _reason -> {:error, :invalid_persisted_state}
        end

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_persisted_document(%{
         "format_version" => @state_format_version,
         "current_revision" => current_revision,
         "history" => entries
       })
       when is_binary(current_revision) and is_list(entries) do
    with {:ok, history, history_order} <- decode_persisted_history(entries),
         true <- Map.has_key?(history, current_revision) do
      {:ok,
       %{
         current_revision: current_revision,
         history: history,
         history_order: history_order
       }}
    else
      _reason -> {:error, :invalid_persisted_state}
    end
  end

  defp decode_persisted_document(_document), do: {:error, :invalid_persisted_state}

  defp decode_persisted_history(entries) do
    entries
    |> Enum.take(@history_limit)
    |> Enum.reduce_while({:ok, %{}, []}, fn entry, {:ok, history, order} ->
      with {:ok, managed} <- decode_persisted_managed(entry),
           revision = managed_revision(managed),
           true <- Map.get(entry, "revision") == revision,
           false <- Map.has_key?(history, revision) do
        {:cont, {:ok, Map.put(history, revision, managed), order ++ [revision]}}
      else
        _reason -> {:halt, {:error, :invalid_persisted_state}}
      end
    end)
  end

  defp decode_persisted_managed(%{
         "upstreams" => upstreams,
         "search_domains" => search_domains
       })
       when is_list(upstreams) and is_list(search_domains) do
    with {:ok, upstreams} <- decode_persisted_upstreams(upstreams),
         true <- Enum.all?(search_domains, &valid_persisted_domain?/1) do
      {:ok, %{upstreams: upstreams, search_domains: search_domains}}
    else
      _reason -> {:error, :invalid_persisted_state}
    end
  end

  defp decode_persisted_managed(_entry), do: {:error, :invalid_persisted_state}

  defp decode_persisted_upstreams(upstreams) do
    Enum.reduce_while(upstreams, {:ok, []}, fn
      upstream, {:ok, decoded} when is_binary(upstream) ->
        case :inet.parse_address(String.to_charlist(upstream)) do
          {:ok, address} -> {:cont, {:ok, [address | decoded]}}
          {:error, _reason} -> {:halt, {:error, :invalid_persisted_state}}
        end

      _upstream, _acc ->
        {:halt, {:error, :invalid_persisted_state}}
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end
  end

  defp valid_persisted_domain?(domain) when is_binary(domain) do
    String.valid?(domain) and byte_size(domain) <= 253
  end

  defp valid_persisted_domain?(_domain), do: false

  defp remember_persisted_configs(nil, configs) do
    remember_persisted_configs(%{history: %{}, history_order: []}, configs)
  end

  defp remember_persisted_configs(document, configs) do
    Enum.reduce(configs, document, fn config, acc ->
      revision = managed_revision(config)
      managed = persisted_managed(config)
      order = [revision | Enum.reject(acc.history_order, &(&1 == revision))]
      order = Enum.take(order, @history_limit)

      %{
        acc
        | history: acc.history |> Map.put(revision, managed) |> Map.take(order),
          history_order: order
      }
    end)
  end

  defp encode_persisted_document(document, current_revision) do
    history =
      Enum.map(document.history_order, fn revision ->
        document.history
        |> Map.fetch!(revision)
        |> encode_persisted_managed(revision)
      end)

    Jason.encode!(%{
      "format_version" => @state_format_version,
      "current_revision" => current_revision,
      "history" => history
    }) <> "\n"
  end

  defp persisted_managed(config) do
    %{
      upstreams: Map.get(config, :upstreams, []),
      search_domains: Map.get(config, :search_domains, [])
    }
  end

  defp encode_persisted_managed(managed, revision) do
    %{
      "revision" => revision,
      "upstreams" => Enum.map(managed.upstreams, &(&1 |> :inet.ntoa() |> to_string())),
      "search_domains" => managed.search_domains
    }
  end

  defp merge_persisted_managed(config, managed) do
    config
    |> Map.put(:upstreams, managed.upstreams)
    |> Map.put(:search_domains, managed.search_domains)
  end

  defp persisted_state_path do
    config_path = configured_config_path() || find_config_file() || List.first(@config_paths)
    Path.join(Path.dirname(config_path), @state_filename)
  end

  defp atomic_write(path, contents) do
    directory = Path.dirname(path)

    temporary_path =
      Path.join(
        directory,
        ".#{Path.basename(path)}.#{System.unique_integer([:positive, :monotonic])}.tmp"
      )

    result =
      with :ok <- File.mkdir_p(directory),
           {:ok, device} <- :file.open(temporary_path, [:write, :exclusive, :binary, :raw]),
           :ok <- write_sync_close(device, contents),
           :ok <- File.rename(temporary_path, path),
           :ok <- sync_directory(directory) do
        :ok
      end

    if result != :ok, do: File.rm(temporary_path)
    result
  end

  defp write_sync_close(device, contents) do
    write_result =
      with :ok <- :file.write(device, contents),
           :ok <- :file.sync(device) do
        :ok
      end

    close_result = :file.close(device)

    case {write_result, close_result} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _close_result} -> {:error, reason}
      {:ok, {:error, reason}} -> {:error, {:close, reason}}
    end
  end

  defp sync_directory(directory) do
    case :file.open(directory, [:read, :raw, :directory]) do
      {:ok, device} ->
        sync_result = :file.sync(device)
        close_result = :file.close(device)

        case {sync_result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, :enotsup}, :ok} -> :ok
          {{:error, reason}, _close_result} -> {:error, reason}
          {:ok, {:error, reason}} -> {:error, {:close, reason}}
        end

      {:error, :enotsup} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_runtime_config(new_config, old_config) do
    if new_config.upstreams == old_config.upstreams do
      :ok
    else
      apply_forwarder_config(new_config)
    end
  end

  defp apply_forwarder_config(config) do
    case Process.whereis(YellowDog.Resolved.Forwarder) do
      nil ->
        {:error, :forwarder_not_running}

      pid ->
        runtime_config =
          if Process.whereis(YellowDog.Resolved.LinkDns) do
            %{config | upstreams: YellowDog.Resolved.LinkDns.effective_upstreams()}
          else
            config
          end

        GenServer.cast(pid, {:update_config, runtime_config})

        try do
          case :sys.get_state(pid, 5_000) do
            %{upstreams: upstreams} when upstreams == runtime_config.upstreams -> :ok
            _state -> {:error, :forwarder_rejected_config}
          end
        catch
          :exit, _reason -> {:error, :forwarder_apply_failed}
        end
    end
  end

  defp normalize_loaded_config(config) do
    Map.put_new(config, :search_domains, [])
  end

  defp find_config_file do
    paths =
      case configured_config_path() do
        nil -> @config_paths
        path -> [path]
      end

    Enum.find(paths, &File.exists?/1)
  end

  defp configured_config_path do
    case Application.get_env(:yellow_dog_resolved, :config_path) do
      path when is_binary(path) and path != "" -> path
      _path -> nil
    end
  end

  defp load_from_file(path) do
    case Toml.decode_file(path) do
      {:ok, toml} ->
        parse_toml(toml)

      {:error, reason} ->
        Logger.warning("[Resolved] Failed to parse config: #{inspect(reason)}")
        @default_config
    end
  end

  defp parse_toml(toml) do
    resolved = Map.get(toml, "resolved", %{})

    %{
      listen: parse_ip(Map.get(resolved, "listen", "127.0.0.1")),
      port: clamp_int(Map.get(resolved, "port", 53), 1, 65_535),
      upstreams: parse_upstreams(Map.get(resolved, "upstreams", ["1.1.1.1", "8.8.8.8"])),
      search_domains: parse_search_domains(Map.get(resolved, "search_domains", [])),
      upstream_timeout_ms: clamp_int(Map.get(resolved, "upstream_timeout_ms", 3000), 100, 30_000),
      upstream_failure_threshold:
        clamp_int(Map.get(resolved, "upstream_failure_threshold", 3), 1, 100),
      cache: parse_cache_config(Map.get(resolved, "cache", %{})),
      discovery: parse_discovery_config(Map.get(resolved, "discovery", %{})),
      rate_limit: parse_rate_limit_config(Map.get(resolved, "rate_limit", %{})),
      intercept_rules: parse_intercept_rules(Map.get(resolved, "intercept", []))
    }
  end

  defp parse_cache_config(cache) do
    min_ttl = clamp_int(Map.get(cache, "min_ttl_s", 30), 0, 86_400)
    max_ttl = clamp_int(Map.get(cache, "max_ttl_s", 86_400), 1, 604_800)

    if min_ttl > max_ttl do
      Logger.warning(
        "[Resolved] Cache min_ttl_s (#{min_ttl}) exceeds max_ttl_s (#{max_ttl}); clamping min_ttl_s to #{max_ttl}"
      )
    end

    %{
      enabled: Map.get(cache, "enabled", true),
      max_entries: clamp_int(Map.get(cache, "max_entries", 10_000), 1, 1_000_000),
      min_ttl_s: min(min_ttl, max_ttl),
      max_ttl_s: max_ttl,
      negative_ttl_s: clamp_int(Map.get(cache, "negative_ttl_s", 60), 0, 86_400),
      sweep_interval_s: clamp_int(Map.get(cache, "sweep_interval_s", 60), 1, 86_400)
    }
  end

  defp parse_discovery_config(discovery) do
    ws = Map.get(discovery, "websocket", %{})

    %{
      enabled: Map.get(discovery, "enabled", true),
      websocket: %{
        heartbeat_interval_s: clamp_int(Map.get(ws, "heartbeat_interval_s", 30), 5, 300),
        reconnect_base_s: clamp_int(Map.get(ws, "reconnect_base_s", 5), 1, 60),
        reconnect_max_s: clamp_int(Map.get(ws, "reconnect_max_s", 60), 5, 600)
      }
    }
  end

  defp parse_rate_limit_config(rl) do
    burst = clamp_int(Map.get(rl, "burst", 50), 1, 10_000)
    rate = clamp_int(Map.get(rl, "rate", 20), 1, 10_000)

    if burst < rate do
      Logger.warning(
        "[Resolved] Rate limiter burst (#{burst}) < rate (#{rate}); clamping burst to #{rate}"
      )
    end

    %{
      burst: max(burst, rate),
      rate: rate
    }
  end

  defp parse_intercept_rules(rules) when is_list(rules) do
    rules
    |> Enum.map(&parse_rule/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_intercept_rules(_), do: []

  defp parse_rule(rule) do
    match_str = Map.get(rule, "match", "")
    type_str = Map.get(rule, "type", "A")
    value = Map.get(rule, "value", "")
    ttl = clamp_int(Map.get(rule, "ttl", 300), 1, 604_800)
    type = parse_record_type(type_str)

    case validate_rule_value(type, value) do
      :ok ->
        %{
          match: parse_match_pattern(match_str),
          type: type,
          value: value,
          ttl: ttl
        }

      :error ->
        Logger.warning(
          "[Resolved] Skipping invalid intercept rule: type=#{type_str} value=#{inspect(value)} match=#{inspect(match_str)}"
        )

        nil
    end
  end

  defp validate_rule_value(:a, value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, {_, _, _, _}} -> :ok
      _ -> :error
    end
  end

  defp validate_rule_value(:aaaa, value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, {_, _, _, _, _, _, _, _}} -> :ok
      _ -> :error
    end
  end

  defp validate_rule_value(:mx, value) do
    case String.split(value, " ", parts: 2) do
      [priority_str, _exchange] ->
        case Integer.parse(priority_str) do
          {_, ""} -> :ok
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp validate_rule_value(:srv, value) do
    case String.split(value, " ", parts: 4) do
      [pri_s, weight_s, port_s, _target] ->
        with {_, ""} <- Integer.parse(pri_s),
             {_, ""} <- Integer.parse(weight_s),
             {_, ""} <- Integer.parse(port_s) do
          :ok
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp validate_rule_value(:unknown, _value), do: :error
  defp validate_rule_value(_type, _value), do: :ok

  defp parse_match_pattern("*." <> suffix),
    do: {:suffix, suffix |> String.downcase() |> String.trim_trailing(".")}

  defp parse_match_pattern(pattern) do
    if String.ends_with?(pattern, "*") do
      {:prefix, String.downcase(String.trim_trailing(pattern, "*"))}
    else
      {:exact, pattern |> String.downcase() |> String.trim_trailing(".")}
    end
  end

  defp parse_record_type("A"), do: :a
  defp parse_record_type("AAAA"), do: :aaaa
  defp parse_record_type("CNAME"), do: :cname
  defp parse_record_type("TXT"), do: :txt
  defp parse_record_type("MX"), do: :mx
  defp parse_record_type("SRV"), do: :srv
  defp parse_record_type("NS"), do: :ns
  defp parse_record_type("PTR"), do: :ptr
  defp parse_record_type(_), do: :unknown

  defp clamp_int(val, min_val, max_val) when is_integer(val) do
    val |> max(min_val) |> min(max_val)
  end

  defp clamp_int(val, min_val, max_val) when is_float(val) do
    rounded = round(val)

    Logger.warning(
      "[Resolved] Config value #{val} is a float; expected integer. Rounding to #{rounded}"
    )

    clamp_int(rounded, min_val, max_val)
  end

  defp clamp_int(_val, min_val, _max_val), do: min_val

  defp parse_ip(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip} -> ip
      _ -> {127, 0, 0, 1}
    end
  end

  defp parse_ip(ip) when is_tuple(ip), do: ip
  defp parse_ip(_), do: {127, 0, 0, 1}

  defp parse_upstreams(upstreams) when is_list(upstreams) do
    upstreams
    |> Enum.reduce([], fn upstream, acc ->
      case parse_upstream_ip(upstream) do
        {:ok, ip} ->
          [ip | acc]

        :error ->
          Logger.warning("[Resolved] Skipping invalid upstream address: #{inspect(upstream)}")
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp parse_upstreams(_), do: [{1, 1, 1, 1}, {8, 8, 8, 8}]

  defp parse_search_domains(domains) when is_list(domains) do
    Enum.filter(domains, &is_binary/1)
  end

  defp parse_search_domains(_domains), do: []

  # Returns {:ok, ip_tuple} or :error — used for upstream list validation so that
  # invalid entries are skipped (with a warning) rather than silently replaced with
  # the loopback address, which could cause DNS query loops.
  defp parse_upstream_ip(ip) when is_tuple(ip), do: {:ok, ip}

  defp parse_upstream_ip(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, ip_tuple} -> {:ok, ip_tuple}
      _ -> :error
    end
  end

  defp parse_upstream_ip(_), do: :error

  defp propagate_config(new_config, old_config) do
    # Note: Discovery is not explicitly notified here because it reads
    # Config.get(:upstreams) fresh on each :probe cycle, so upstream
    # changes are picked up automatically on the next probe interval.

    # Notify Forwarder if upstream settings changed
    if new_config.upstreams != old_config.upstreams or
         new_config.upstream_timeout_ms != old_config.upstream_timeout_ms or
         new_config.upstream_failure_threshold != old_config.upstream_failure_threshold do
      if Process.whereis(YellowDog.Resolved.Forwarder) do
        GenServer.cast(YellowDog.Resolved.Forwarder, {:update_config, new_config})
      end
    end

    # Notify Cache if cache settings changed
    if new_config.cache != old_config.cache do
      if Process.whereis(YellowDog.Resolved.Cache) do
        GenServer.cast(YellowDog.Resolved.Cache, {:update_config, new_config.cache})
      end
    end

    # Notify RateLimiter if rate_limit settings changed
    if new_config.rate_limit != old_config.rate_limit do
      if Process.whereis(YellowDog.Resolved.RateLimiter) do
        GenServer.cast(YellowDog.Resolved.RateLimiter, {:update_config, new_config})
      end
    end
  end

  defp maybe_start_watcher(%{config_path: nil} = state), do: state

  defp maybe_start_watcher(%{config_path: path} = state) do
    dir = Path.dirname(path)

    case FileSystem.start_link(dirs: [dir]) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        %{state | watcher_pid: pid}

      {:error, _} ->
        state
    end
  end
end
