defmodule YellowDog.Server.Control.Dns do
  @moduledoc false

  alias YellowDog.Server.Control.Revision
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Error

  @record_id_pattern ~r/\Arr-[0-9a-f]{64}\z/
  @mutation_operations [
    "server.dns.views.create",
    "server.dns.views.update",
    "server.dns.views.delete",
    "server.dns.zones.create",
    "server.dns.zones.update",
    "server.dns.zones.delete",
    "server.dns.records.create",
    "server.dns.records.update",
    "server.dns.records.delete",
    "server.dns.acls.create",
    "server.dns.acls.update",
    "server.dns.acls.delete",
    "server.dns.providers.create",
    "server.dns.providers.update",
    "server.dns.providers.delete",
    "server.dns.zones.import",
    "server.dns.zones.sync",
    "server.dns.conflicts.resolve"
  ]
  @unsupported_snapshot_operations [
    "server.dns.zones.import",
    "server.dns.zones.sync",
    "server.dns.conflicts.resolve"
  ]

  @production_dependencies %{
    view_manager: Module.concat(["YellowDog", "Dns", "ViewManager"]),
    zone_store: Module.concat(["YellowDog", "Store", "Zone"]),
    acl_registry: Module.concat(["YellowDog", "Dns", "AclRegistry"]),
    provider_store: Module.concat(["YellowDog", "Store", "Provider"]),
    query_logger: Module.concat(["YellowDog", "Dns", "QueryLogger"]),
    metrics_collector: Module.concat(["YellowDog", "Dns", "MetricsCollector"]),
    clock: DateTime
  }
  @test_environment Mix.env() == :test

  @spec dispatch(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch("server.dns.views.list", payload) when is_map(payload) do
    with {:ok, items} <- read_views() do
      list_result(items, payload, & &1["view_name"])
    end
  end

  def dispatch("server.dns.zones.list", %{"view_name" => view_name} = payload) do
    with {:ok, items} <- read_zones(view_name) do
      list_result(items, payload, & &1["zone_name"])
    end
  end

  def dispatch(
        "server.dns.records.list",
        %{"view_name" => view_name, "zone_name" => zone_name} = payload
      ) do
    with {:ok, items} <- read_records(view_name, zone_name) do
      list_result(items, payload, & &1["record_id"])
    end
  end

  def dispatch("server.dns.acls.list", payload) when is_map(payload) do
    with {:ok, items} <- read_acls() do
      list_result(items, payload, & &1["acl_id"])
    end
  end

  def dispatch("server.dns.providers.list", payload) when is_map(payload) do
    with {:ok, items} <- read_providers() do
      list_result(items, payload, & &1["provider_id"])
    end
  end

  def dispatch("server.dns.logs.list", %{"view_name" => view_name} = payload) do
    with {:ok, items} <- read_logs(view_name, payload) do
      list_result(items, payload, & &1["log_id"])
    end
  end

  def dispatch("server.dns.metrics.get", %{}) do
    with {:ok, metrics} <- dependency_call(:metrics_collector, :get_metrics, []),
         {:ok, result} <- metrics_result(metrics) do
      {:ok, result}
    end
  end

  def dispatch(operation, _payload) when operation in @mutation_operations,
    do: unsupported_error()

  def dispatch(operation, _payload) when is_binary(operation), do: unsupported_error()
  def dispatch(_operation, _payload), do: unsupported_error()

  @spec current(String.t(), map()) :: {:ok, map() | :missing} | {:error, Error.t()}
  def current(operation, %{"view_name" => view_name})
      when operation in [
             "server.dns.views.create",
             "server.dns.views.update",
             "server.dns.views.delete"
           ] do
    with {:ok, views} <- read_views() do
      current_resource(operation, Enum.find(views, &(&1["view_name"] == view_name)))
    end
  end

  def current(
        operation,
        %{"view_name" => view_name, "zone_name" => zone_name}
      )
      when operation in [
             "server.dns.zones.create",
             "server.dns.zones.update",
             "server.dns.zones.delete"
           ] do
    with {:ok, zones} <- read_zones(view_name) do
      current_resource(
        operation,
        Enum.find(zones, &(&1["zone_name"] == canonical_name(zone_name)))
      )
    end
  end

  def current(operation, %{"acl_id" => acl_id})
      when operation in [
             "server.dns.acls.create",
             "server.dns.acls.update",
             "server.dns.acls.delete"
           ] do
    with {:ok, acls} <- read_acls() do
      current_resource(operation, Enum.find(acls, &(&1["acl_id"] == acl_id)))
    end
  end

  def current(operation, %{"provider_id" => provider_id})
      when operation in [
             "server.dns.providers.create",
             "server.dns.providers.update",
             "server.dns.providers.delete"
           ] do
    with {:ok, providers} <- read_providers() do
      current_resource(operation, Enum.find(providers, &(&1["provider_id"] == provider_id)))
    end
  end

  def current(
        operation,
        %{
          "view_name" => view_name,
          "zone_name" => zone_name,
          "record_id" => requested_id
        } = payload
      )
      when operation in [
             "server.dns.records.create",
             "server.dns.records.update",
             "server.dns.records.delete"
           ] do
    with :ok <- validate_record_reference(operation, payload),
         {:ok, record} <- resolve_record_id(view_name, zone_name, requested_id) do
      {:ok, record}
    else
      {:error, %Error{code: :not_found}} when operation == "server.dns.records.create" ->
        {:ok, :missing}

      {:error, %Error{}} = error ->
        error
    end
  end

  def current(operation, _payload) when operation in @unsupported_snapshot_operations,
    do: unsupported_error()

  def current(operation, _payload) when operation in @mutation_operations, do: invalid_error()
  def current(_operation, _payload), do: unsupported_error()

  defp current_resource(operation, nil) do
    if String.ends_with?(operation, ".create"), do: {:ok, :missing}, else: not_found_error()
  end

  defp current_resource(_operation, resource), do: {:ok, resource}

  defp read_views do
    with {:ok, views} <- dependency_call(:view_manager, :list_views, []),
         true <- is_list(views),
         {:ok, stats} <- dependency_call(:view_manager, :stats, []),
         true <- is_map(stats) do
      stats_by_view = field(stats, :views, %{})

      items =
        views
        |> Enum.flat_map(&project_view(&1, stats_by_view))
        |> Enum.sort_by(& &1["view_name"])

      {:ok, items}
    else
      {:error, %Error{}} = error -> error
      _invalid -> apply_failed_error()
    end
  end

  defp project_view({name, _pid, _priority}, stats) when is_binary(name) do
    details = map_field(stats, name, %{})

    [
      %{
        "view_name" => name,
        "match_clients" => string_list(field(details, :match_clients, [])),
        "recursion" => field(details, :recursion_enabled, false) == true
      }
    ]
  end

  defp project_view(%{} = view, _stats) do
    case field(view, :name, field(view, :view_name)) do
      name when is_binary(name) ->
        [
          %{
            "view_name" => name,
            "match_clients" => string_list(field(view, :match_clients, [])),
            "recursion" => field(view, :recursion_enabled, field(view, :recursion, false)) == true
          }
        ]

      _invalid ->
        []
    end
  end

  defp project_view(_view, _stats), do: []

  defp read_zones(view_name) do
    with {:ok, result} <- dependency_call(:zone_store, :list_zones_for_view, [view_name]),
         {:ok, zones} <- unwrap_store_list(result) do
      items =
        zones |> Enum.flat_map(&project_zone(&1, view_name)) |> Enum.sort_by(& &1["zone_name"])

      {:ok, items}
    end
  end

  defp project_zone(%{} = zone, fallback_view) do
    with name when is_binary(name) <- field(zone, :origin, field(zone, :name)),
         {:ok, zone_type} <- wire_zone_type(field(zone, :zone_type)),
         view_name when is_binary(view_name) <- field(zone, :view_name, fallback_view) do
      [
        %{
          "view_name" => view_name,
          "zone_name" => canonical_name(name),
          "zone_type" => zone_type,
          "provider_id" => zone_provider_id(zone)
        }
      ]
    else
      _invalid -> []
    end
  end

  defp project_zone(_zone, _fallback_view), do: []

  defp wire_zone_type(:auth), do: {:ok, "authoritative"}
  defp wire_zone_type(:authoritative), do: {:ok, "authoritative"}
  defp wire_zone_type("auth"), do: {:ok, "authoritative"}
  defp wire_zone_type("authoritative"), do: {:ok, "authoritative"}
  defp wire_zone_type(:forward), do: {:ok, "forward"}
  defp wire_zone_type("forward"), do: {:ok, "forward"}
  defp wire_zone_type(_zone_type), do: :error

  defp zone_provider_id(zone) do
    provider_id =
      case field(zone, :provider_id) do
        provider_id when is_binary(provider_id) -> provider_id
        _other -> zone |> field(:cloud_mirror, %{}) |> field(:connector_name)
      end

    if is_binary(provider_id), do: provider_id, else: nil
  end

  defp read_records(view_name, zone_name) do
    with {:ok, result} <-
           dependency_call(:zone_store, :list_records, [view_name, zone_name]),
         {:ok, records} <- unwrap_store_list(result) do
      items =
        records
        |> Enum.flat_map(&project_record(&1, view_name, canonical_name(zone_name)))
        |> Enum.sort_by(& &1["record_id"])

      {:ok, items}
    end
  end

  defp project_record(%{} = record, view_name, zone_name) do
    with owner when is_binary(owner) <- field(record, :owner),
         {:ok, type} <- wire_record_type(field(record, :type)),
         rrset when is_list(rrset) <- field(record, :rrset, []),
         {:ok, ttl} <- record_ttl(record, rrset),
         {:ok, values} <- record_values(type, rrset),
         true <- values != [],
         true <- type != "CNAME" or length(values) == 1 do
      owner = canonical_owner(owner)

      [
        %{
          "view_name" => view_name,
          "zone_name" => zone_name,
          "record_id" => record_id(owner, type),
          "name" => owner,
          "type" => type,
          "ttl" => ttl,
          "values" => values
        }
      ]
    else
      _invalid -> []
    end
  end

  defp project_record(_record, _view_name, _zone_name), do: []

  for {store, wire} <- [
        a: "A",
        aaaa: "AAAA",
        cname: "CNAME",
        mx: "MX",
        ns: "NS",
        ptr: "PTR",
        srv: "SRV",
        txt: "TXT"
      ] do
    defp wire_record_type(unquote(store)), do: {:ok, unquote(wire)}
  end

  for type <- ["A", "AAAA", "CNAME", "MX", "NS", "PTR", "SRV", "TXT"] do
    defp validate_wire_record_type(unquote(type)), do: :ok
  end

  defp wire_record_type(_type), do: :error
  defp validate_wire_record_type(_type), do: invalid_error()

  defp record_ttl(record, [first | _rest]) do
    value = field(first, :ttl, field(record, :ttl, field(record_data(first), :ttl, 0)))

    if is_integer(value) and value in 0..2_147_483_647,
      do: {:ok, value},
      else: :error
  end

  defp record_ttl(record, []) do
    value = field(record, :ttl, 0)
    if is_integer(value) and value in 0..2_147_483_647, do: {:ok, value}, else: :error
  end

  defp record_values(type, rrset) do
    Enum.reduce_while(rrset, {:ok, []}, fn entry, {:ok, values} ->
      case record_value(type, entry) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> Enum.uniq()}
      :error -> :error
    end
  end

  defp record_data(%{} = entry), do: field(entry, :rdata, entry)
  defp record_data(entry), do: entry

  defp record_value(type, entry) when type in ["A", "AAAA"] do
    value = record_data(entry)
    value = if is_map(value), do: field(value, :address), else: value

    cond do
      is_binary(value) -> {:ok, value}
      is_tuple(value) -> format_ip(value)
      true -> :error
    end
  end

  defp record_value("CNAME", entry), do: domain_record_value(record_data(entry), :cname)
  defp record_value("NS", entry), do: domain_record_value(record_data(entry), :nsdname)
  defp record_value("PTR", entry), do: domain_record_value(record_data(entry), :ptrdname)

  defp record_value("MX", %{rdata: target} = entry) when is_binary(target) do
    case field(entry, :priority, field(entry, :preference)) do
      priority when is_integer(priority) -> {:ok, "#{priority} #{canonical_name(target)}"}
      _invalid -> :error
    end
  end

  defp record_value("MX", %{"rdata" => target} = entry) when is_binary(target) do
    case field(entry, :priority, field(entry, :preference)) do
      priority when is_integer(priority) -> {:ok, "#{priority} #{canonical_name(target)}"}
      _invalid -> :error
    end
  end

  defp record_value("MX", entry) do
    mx_record_value(record_data(entry))
  end

  defp record_value("SRV", entry), do: srv_record_value(record_data(entry))

  defp record_value("TXT", entry) do
    case record_data(entry) do
      %{} = value -> text_record_value(field(value, :txtdata))
      value -> text_record_value(value)
    end
  end

  defp record_value(_type, _value), do: :error

  defp mx_record_value({priority, target})
       when is_integer(priority) and is_binary(target),
       do: {:ok, "#{priority} #{canonical_name(target)}"}

  defp mx_record_value(%{} = value) do
    with priority when is_integer(priority) <- field(value, :preference, field(value, :priority)),
         target when is_binary(target) <- field(value, :exchange, field(value, :target)) do
      {:ok, "#{priority} #{canonical_name(target)}"}
    else
      _invalid -> :error
    end
  end

  defp mx_record_value(_value), do: :error

  defp srv_record_value({priority, weight, port, target})
       when is_integer(priority) and is_integer(weight) and is_integer(port) and
              is_binary(target),
       do: {:ok, "#{priority} #{weight} #{port} #{canonical_name(target)}"}

  defp srv_record_value(%{} = value) do
    with priority when is_integer(priority) <- field(value, :priority),
         weight when is_integer(weight) <- field(value, :weight),
         port when is_integer(port) <- field(value, :port),
         target when is_binary(target) <- field(value, :target) do
      {:ok, "#{priority} #{weight} #{port} #{canonical_name(target)}"}
    else
      _invalid -> :error
    end
  end

  defp srv_record_value(_value), do: :error

  defp domain_record_value(%{} = value, key), do: domain_record_value(field(value, key), key)

  defp domain_record_value(value, _key) when is_binary(value),
    do: {:ok, canonical_name(value)}

  defp domain_record_value(_value, _key), do: :error

  defp text_record_value(value) when is_binary(value), do: {:ok, value}

  defp text_record_value(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: {:ok, Enum.join(value)}, else: :error
  end

  defp text_record_value(_value), do: :error

  defp format_ip(tuple) do
    case :inet.ntoa(tuple) do
      address when is_list(address) -> {:ok, List.to_string(address)}
      _invalid -> :error
    end
  rescue
    _exception -> :error
  end

  defp validate_record_reference(operation, payload)
       when operation in ["server.dns.records.create", "server.dns.records.update"] do
    with owner when is_binary(owner) <- Map.get(payload, "name"),
         type when is_binary(type) <- Map.get(payload, "type"),
         :ok <- validate_wire_record_type(type),
         requested_id when is_binary(requested_id) <- Map.get(payload, "record_id"),
         true <- valid_record_id?(requested_id),
         true <- requested_id == record_id(canonical_owner(owner), type) do
      :ok
    else
      _invalid -> invalid_error()
    end
  end

  defp validate_record_reference("server.dns.records.delete", %{"record_id" => record_id}) do
    if valid_record_id?(record_id), do: :ok, else: invalid_error()
  end

  defp resolve_record_id(view_name, zone_name, requested_id) do
    if valid_record_id?(requested_id) do
      with {:ok, records} <- read_records(view_name, zone_name) do
        case Enum.filter(records, &(&1["record_id"] == requested_id)) do
          [record] -> {:ok, record}
          [] -> not_found_error()
          [_first | _rest] -> conflict_error()
        end
      end
    else
      invalid_error()
    end
  end

  defp valid_record_id?(record_id) when is_binary(record_id),
    do: Regex.match?(@record_id_pattern, record_id)

  defp valid_record_id?(_record_id), do: false

  defp record_id(owner, type) do
    digest = :crypto.hash(:sha256, canonical_owner(owner) <> <<0>> <> type)
    "rr-" <> Base.encode16(digest, case: :lower)
  end

  defp read_acls do
    with {:ok, acls} <- dependency_call(:acl_registry, :list_acls, []),
         true <- is_list(acls) do
      items = acls |> Enum.flat_map(&project_acl/1) |> Enum.sort_by(& &1["acl_id"])
      {:ok, items}
    else
      {:error, %Error{}} = error -> error
      _invalid -> apply_failed_error()
    end
  end

  defp project_acl(%{} = acl) do
    with acl_id when is_binary(acl_id) <- field(acl, :name, field(acl, :acl_id)),
         {:ok, action, networks} <- acl_fields(acl) do
      [%{"acl_id" => acl_id, "networks" => networks, "action" => action}]
    else
      _invalid -> []
    end
  end

  defp project_acl(_acl), do: []

  defp acl_fields(acl) do
    rules = field(acl, :rules, [])

    if is_list(rules) and rules != [] do
      entries =
        Enum.flat_map(rules, fn rule ->
          case {wire_acl_action(field(rule, :action)), field(rule, :network)} do
            {{:ok, action}, network} when is_binary(network) -> [{action, network}]
            _invalid -> []
          end
        end)

      case entries do
        [{action, _network} | _rest] ->
          networks = for {^action, network} <- entries, do: network
          {:ok, action, Enum.sort(Enum.uniq(networks))}

        [] ->
          :error
      end
    else
      with {:ok, action} <- wire_acl_action(field(acl, :action, :deny)),
           networks when is_list(networks) <- field(acl, :networks, []) do
        {:ok, action, string_list(networks) |> Enum.sort()}
      else
        _invalid -> :error
      end
    end
  end

  defp wire_acl_action(:allow), do: {:ok, "allow"}
  defp wire_acl_action("allow"), do: {:ok, "allow"}
  defp wire_acl_action(:deny), do: {:ok, "deny"}
  defp wire_acl_action("deny"), do: {:ok, "deny"}
  defp wire_acl_action(_action), do: :error

  defp read_providers do
    with {:ok, result} <- dependency_call(:provider_store, :list_configs, []),
         {:ok, providers} <- unwrap_store_list(result) do
      items = providers |> Enum.flat_map(&project_provider/1) |> Enum.sort_by(& &1["provider_id"])
      {:ok, items}
    end
  end

  defp project_provider(%{} = provider) do
    with provider_id when is_binary(provider_id) <-
           field(provider, :name, field(provider, :provider_id)),
         {:ok, provider_type} <- wire_provider_type(field(provider, :type)) do
      [
        %{
          "provider_id" => provider_id,
          "provider_type" => provider_type,
          "endpoint" => nil,
          "credential_ref" => credential_ref(provider_id)
        }
      ]
    else
      _invalid -> []
    end
  end

  defp project_provider(_provider), do: []

  defp wire_provider_type(:route53), do: {:ok, "route53"}
  defp wire_provider_type(:aws), do: {:ok, "route53"}
  defp wire_provider_type("route53"), do: {:ok, "route53"}
  defp wire_provider_type("aws"), do: {:ok, "route53"}
  defp wire_provider_type(:cloudflare), do: {:ok, "cloudflare"}
  defp wire_provider_type("cloudflare"), do: {:ok, "cloudflare"}
  defp wire_provider_type(_type), do: :error

  defp credential_ref(provider_id) do
    digest = :crypto.hash(:sha256, provider_id)
    "local-provider-" <> Base.encode16(digest, case: :lower)
  end

  defp read_logs(view_name, payload) do
    opts = if is_integer(payload["limit"]), do: [limit: payload["limit"]], else: []

    with {:ok, logs} <-
           dependency_call(:query_logger, :get_logs_by_view, [view_name, opts]),
         true <- is_list(logs) do
      items = logs |> Enum.flat_map(&project_log/1) |> Enum.sort_by(& &1["log_id"])
      {:ok, items}
    else
      {:error, %Error{}} = error -> error
      _invalid -> apply_failed_error()
    end
  end

  defp project_log(%{} = log) do
    with query_name when is_binary(query_name) <- field(log, :qname, field(log, :query_name)),
         {:ok, occurred_at} <- format_datetime(field(log, :timestamp, field(log, :occurred_at))),
         {:ok, action} <- log_action(log) do
      query_name = canonical_name(query_name)

      log_id =
        field(log, :id, field(log, :log_id, generated_log_id(query_name, action, occurred_at)))

      if is_binary(log_id) do
        [
          %{
            "log_id" => log_id,
            "query_name" => query_name,
            "action" => action,
            "occurred_at" => occurred_at
          }
        ]
      else
        []
      end
    else
      _invalid -> []
    end
  end

  defp project_log(_log), do: []

  defp log_action(log) do
    response_code = field(log, :response_code, field(log, :rcode))
    resolution = field(log, :resolution_type)

    cond do
      response_code in [:refused, "refused", "REFUSED"] ->
        {:ok, "refused"}

      response_code in [:noerror, :ok, "noerror", "NOERROR"] and
          resolution in [:recursive, :forward, :forwarded, :fallback, "recursive", "forward"] ->
        {:ok, "forwarded"}

      response_code in [:noerror, :ok, "noerror", "NOERROR"] ->
        {:ok, "answered"}

      true ->
        {:ok, "failed"}
    end
  end

  defp generated_log_id(query_name, action, occurred_at) do
    digest = :crypto.hash(:sha256, query_name <> <<0>> <> action <> <<0>> <> occurred_at)
    "log-" <> Base.encode16(digest, case: :lower)
  end

  defp metrics_result(%{} = metrics) do
    counters = field(metrics, :counters, metrics)
    queries = field(counters, :queries_total, field(metrics, :queries_total, 0))
    responses = field(metrics, :responses_by_code, [])

    if is_integer(queries) and queries >= 0 do
      {:ok, %{"queries" => queries, "failures" => failure_count(responses)}}
    else
      apply_failed_error()
    end
  end

  defp metrics_result(_metrics), do: apply_failed_error()

  defp failure_count(responses) when is_map(responses),
    do: responses |> Map.to_list() |> failure_count()

  defp failure_count(responses) when is_list(responses) do
    Enum.reduce(responses, 0, fn
      {code, count}, total when is_integer(count) and count >= 0 ->
        if code in [:noerror, :ok, "noerror", "NOERROR"], do: total, else: total + count

      _invalid, total ->
        total
    end)
  end

  defp failure_count(_responses), do: 0

  defp list_result(items, payload, id_fun) do
    bounded = sort_and_bound(items, id_fun)

    with {:ok, revision} <- Revision.calculate(bounded),
         {:ok, page} <- paginate(bounded, payload, id_fun),
         {:ok, observed_at} <- observation_time() do
      {:ok, %{"items" => page, "revision" => revision, "observed_at" => observed_at}}
    end
  end

  defp paginate(items, payload, id_fun) do
    cursor = Map.get(payload, "cursor")
    limit = Map.get(payload, "limit", Bounds.max_list_entries())

    cond do
      not is_integer(limit) or limit < 1 or limit > Bounds.max_list_entries() ->
        invalid_error()

      not is_nil(cursor) and not is_binary(cursor) ->
        invalid_error()

      true ->
        page =
          if cursor do
            Enum.drop_while(items, fn item -> id_fun.(item) <= cursor end)
          else
            items
          end

        {:ok, Enum.take(page, limit)}
    end
  end

  defp observation_time do
    with {:ok, value} <- dependency_call(:clock, :utc_now, []),
         {:ok, timestamp} <- format_datetime(value) do
      {:ok, timestamp}
    end
  end

  defp format_datetime(%DateTime{utc_offset: 0, std_offset: 0} = value),
    do: {:ok, DateTime.to_iso8601(value)}

  defp format_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, 0} -> {:ok, value}
      _invalid -> :error
    end
  end

  defp format_datetime(_value), do: :error

  defp sort_and_bound(items, id_fun) do
    items
    |> Enum.sort_by(id_fun)
    |> Enum.take(Bounds.max_list_entries())
  end

  defp unwrap_store_list({:ok, items}) when is_list(items), do: {:ok, items}
  defp unwrap_store_list({:error, :not_found}), do: not_found_error()
  defp unwrap_store_list({:error, _reason}), do: apply_failed_error()
  defp unwrap_store_list(_result), do: apply_failed_error()

  defp dependency_call(key, function, arguments) do
    module = Map.fetch!(dependencies(), key)
    {:ok, apply(module, function, arguments)}
  rescue
    UndefinedFunctionError -> not_found_error()
    ArgumentError -> apply_failed_error()
    _exception -> apply_failed_error()
  catch
    :exit, :noproc -> not_found_error()
    :exit, {:noproc, _details} -> not_found_error()
    :exit, _reason -> apply_failed_error()
    _kind, _reason -> apply_failed_error()
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp field(_map, _key, default), do: default

  defp map_field(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error when is_binary(key) -> Map.get(map, key, default)
      :error -> default
    end
  end

  defp string_list(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp string_list(_values), do: []

  defp canonical_owner("@"), do: "@"
  defp canonical_owner(owner), do: canonical_name(owner)

  defp canonical_name(name) do
    name
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
  defp not_found_error, do: {:error, Error.new(:not_found, "resource not found", %{})}
  defp conflict_error, do: {:error, Error.new(:conflict, "operation conflict", %{})}
  defp unsupported_error, do: {:error, Error.new(:unsupported, "unsupported operation", %{})}
  defp apply_failed_error, do: {:error, Error.new(:apply_failed, "apply failed", %{})}

  if @test_environment do
    defp dependencies do
      config = Application.get_env(:yellow_dog, __MODULE__, [])

      if Keyword.keyword?(config) and
           Enum.all?(Keyword.keys(config), &Map.has_key?(@production_dependencies, &1)) do
        Map.merge(@production_dependencies, Map.new(config))
      else
        @production_dependencies
      end
    end
  else
    defp dependencies, do: @production_dependencies
  end
end
