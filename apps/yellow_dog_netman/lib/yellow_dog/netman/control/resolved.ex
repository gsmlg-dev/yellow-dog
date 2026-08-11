defmodule YellowDog.Netman.Control.Resolved do
  @moduledoc false

  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation

  @runtime YellowDog.Resolved
  @link_dns YellowDog.Resolved.LinkDns
  @config_operations [
    "netman.resolved.config.update",
    "netman.resolved.config.rollback"
  ]

  @spec current(String.t(), map()) :: {:ok, String.t()} | {:error, Error.t()}
  def current(operation, _payload) when operation in @config_operations do
    case @runtime.config_revision() do
      {:ok, revision} -> {:ok, revision}
      {:error, reason} -> adapter_error(reason)
    end
  end

  def current("netman.resolved.cache.flush", _payload), do: cache_revision()
  def current(_operation, _payload), do: unsupported_error()

  @doc false
  @spec apply_config(String.t(), map()) :: :ok | {:error, :apply_failed}
  def apply_config(operation, payload) when operation in @config_operations do
    with {:ok, ^payload} <- Operation.validate_payload(operation, :netman, :config, payload),
         {:ok, current_revision} <- @runtime.config_revision(),
         {:ok, _transition} <- apply_runtime_config(operation, payload, current_revision) do
      :ok
    else
      _invalid_or_failed -> {:error, :apply_failed}
    end
  rescue
    _exception -> {:error, :apply_failed}
  catch
    _kind, _reason -> {:error, :apply_failed}
  end

  def apply_config(_operation, _payload), do: {:error, :apply_failed}

  @doc false
  @spec restore_config(String.t()) :: :ok | {:error, :restore_failed}
  def restore_config(target_revision) do
    with {:ok, target_revision} <- Digest.validate(target_revision),
         {:ok, current_revision} <- @runtime.config_revision(),
         {:ok, _transition} <-
           @runtime.rollback_config(target_revision, expected_revision: current_revision) do
      :ok
    else
      _invalid_or_failed -> {:error, :restore_failed}
    end
  rescue
    _exception -> {:error, :restore_failed}
  catch
    _kind, _reason -> {:error, :restore_failed}
  end

  @spec dispatch(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch("netman.resolved.upstreams.list", _payload) do
    items =
      Enum.map(@runtime.upstreams(), fn upstream ->
        %{
          "address" => encode_ip(upstream.address),
          "source" => Atom.to_string(upstream.source)
        }
      end)

    with {:ok, result} <- list_result(items),
         {:ok, config_revision} <- @runtime.config_revision() do
      {:ok, Map.put(result, "config_revision", config_revision)}
    else
      {:error, %Error{}} = error -> error
      {:error, reason} -> adapter_error(reason)
    end
  end

  def dispatch("netman.resolved.search_domains.list", _payload) do
    items =
      Enum.map(@runtime.search_domains(), fn domain ->
        %{
          "domain" => domain.domain,
          "routing_only" => domain.routing_only
        }
      end)

    list_result(items)
  end

  def dispatch("netman.resolved.link_dns.list", payload) do
    items =
      @link_dns.list_all()
      |> Enum.map(fn {interface, config} ->
        %{
          "link_id" => interface,
          "servers" => Enum.map(config.servers, &encode_ip/1),
          "search_domains" => config.search,
          "priority" => config.priority
        }
      end)

    list_result(items, payload, "link_id")
  end

  def dispatch("netman.resolved.queries.list", payload) do
    limit = Map.get(payload, "limit", 50)

    entries =
      @runtime.recent_queries(limit)
      |> Enum.map(fn entry ->
        %{
          "timestamp" => DateTime.to_iso8601(entry.timestamp),
          "domain" => entry.domain,
          "type" => to_string(entry.type),
          "source" => to_string(entry.source),
          "duration_us" => entry.duration_us
        }
      end)

    list_result(entries)
  end

  def dispatch("netman.resolved.cache.get", _payload) do
    entries =
      Enum.map(@runtime.cache_entries(), fn entry ->
        %{
          "domain" => entry.domain,
          "address" => encode_ip(entry.address),
          "expires_at" => DateTime.to_iso8601(entry.expires_at)
        }
      end)

    with {:ok, revision} <- cache_revision() do
      {:ok, %{"entries" => entries, "revision" => revision}}
    end
  end

  def dispatch("netman.resolved.counters.get", _payload) do
    counters = @runtime.cache_counters()
    {:ok, %{"hits" => counters.hits, "misses" => counters.misses}}
  end

  def dispatch(_operation, _payload), do: unsupported_error()

  @spec dispatch(String.t(), map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch("netman.resolved.config.update", payload, context) do
    with {:ok, version} <- config_version(context),
         {:ok, expected_revision} <- owner_revision(context),
         {:ok, transition} <-
           @runtime.update_config(payload,
             expected_revision: expected_revision,
             version: version
           ),
         {:ok, digest} <- Digest.calculate(payload) do
      {:ok, config_state(version, digest, transition)}
    else
      {:error, %Error{}} = error -> error
      {:error, reason} -> adapter_error(reason)
    end
  end

  def dispatch(
        "netman.resolved.config.rollback",
        %{"target_revision" => target_revision} = payload,
        context
      ) do
    with {:ok, version} <- config_version(context),
         {:ok, expected_revision} <- owner_revision(context),
         {:ok, transition} <-
           @runtime.rollback_config(target_revision,
             expected_revision: expected_revision,
             version: version
           ),
         {:ok, digest} <- Digest.calculate(payload) do
      {:ok, config_state(version, digest, transition)}
    else
      {:error, %Error{}} = error -> error
      {:error, reason} -> adapter_error(reason)
    end
  end

  def dispatch("netman.resolved.cache.flush", _payload, context) do
    with {:ok, expected_revision} <- owner_revision(context),
         {:ok, ^expected_revision} <- cache_revision(),
         count when is_integer(count) and count >= 0 <- @runtime.flush_cache() do
      {:ok, %{"cleared_entries" => count}}
    else
      {:ok, _current_revision} -> conflict_error()
      {:error, %Error{}} = error -> error
      _other -> internal_error()
    end
  end

  def dispatch(_operation, _payload, _context), do: unsupported_error()

  defp apply_runtime_config("netman.resolved.config.update", payload, current_revision) do
    @runtime.update_config(payload, expected_revision: current_revision)
  end

  defp apply_runtime_config(
         "netman.resolved.config.rollback",
         %{"target_revision" => target_revision},
         current_revision
       ) do
    @runtime.rollback_config(target_revision, expected_revision: current_revision)
  end

  defp list_result(items) do
    case Digest.calculate(items) do
      {:ok, revision} ->
        {:ok,
         %{
           "items" => items,
           "revision" => revision,
           "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
         }}

      {:error, _reason} ->
        internal_error()
    end
  end

  defp list_result(items, payload, cursor_field) do
    items = Enum.sort_by(items, &{Map.fetch!(&1, cursor_field), &1})

    case Digest.calculate(items) do
      {:ok, revision} ->
        {:ok,
         %{
           "items" => page(items, payload, cursor_field),
           "revision" => revision,
           "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
         }}

      {:error, _reason} ->
        internal_error()
    end
  end

  defp page(items, payload, cursor_field) do
    items =
      case Map.get(payload, "cursor") do
        nil -> items
        cursor -> Enum.drop_while(items, &(Map.fetch!(&1, cursor_field) <= cursor))
      end

    Enum.take(items, Map.get(payload, "limit", length(items)))
  end

  defp cache_revision do
    case Digest.calculate(@runtime.cache_revision_material()) do
      {:ok, revision} -> {:ok, revision}
      {:error, _reason} -> internal_error()
    end
  end

  defp config_state(version, digest, transition) do
    {previous_version, previous_revision} =
      if is_integer(transition.previous_version) do
        {transition.previous_version, transition.previous_revision}
      else
        {nil, nil}
      end

    %{
      "state" => "applied",
      "version" => version,
      "digest" => digest,
      "applied_revision" => transition.revision,
      "previous_version" => previous_version,
      "previous_revision" => previous_revision,
      "failure" => nil,
      "rollback" => nil
    }
  end

  defp config_version(%{config_version: version}) when is_integer(version) and version > 0,
    do: {:ok, version}

  defp config_version(_context), do: invalid_error()

  defp owner_revision(%{precondition: {:revision, revision}}) when is_binary(revision),
    do: {:ok, revision}

  defp owner_revision(_context), do: invalid_error()

  defp encode_ip(address), do: address |> :inet.ntoa() |> List.to_string()

  defp adapter_error(%Error{} = error), do: {:error, error}
  defp adapter_error(:revision_not_found), do: not_found_error()
  defp adapter_error(:not_running), do: apply_failed_error()
  defp adapter_error(:expected_revision_required), do: invalid_error()
  defp adapter_error(:invalid_config), do: invalid_error()
  defp adapter_error(:invalid_options), do: invalid_error()
  defp adapter_error(:invalid_version), do: invalid_error()
  defp adapter_error(:stale_version), do: conflict_error()
  defp adapter_error({:conflict, _revision}), do: conflict_error()
  defp adapter_error({:write_failed, _reason}), do: apply_failed_error()
  defp adapter_error({:apply_failed, _reason}), do: apply_failed_error()
  defp adapter_error({:rollback_failed, _reason}), do: rollback_failed_error()
  defp adapter_error(_reason), do: internal_error()

  defp not_found_error, do: {:error, Error.new(:not_found, "resource not found", %{})}
  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
  defp conflict_error, do: {:error, Error.new(:conflict, "operation conflict", %{})}
  defp apply_failed_error, do: {:error, Error.new(:apply_failed, "apply failed", %{})}

  defp rollback_failed_error,
    do: {:error, Error.new(:rollback_failed, "rollback failed", %{})}

  defp unsupported_error,
    do: {:error, Error.new(:unsupported, "unsupported operation", %{})}

  defp internal_error, do: {:error, Error.new(:internal, "internal error", %{})}
end
