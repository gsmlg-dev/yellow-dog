defmodule YellowDog.ConfigSpec do
  @moduledoc """
  Pure Phase 1 WorkerPlan validation and TOML 1.0 subset codec.

  All public data uses string-key maps. The decoder is pinned to `toml` 0.7.0;
  the encoder emits only TOML 1.0 basic strings, integers, arrays and inline tables.
  Unknown fields and unsupported DNS data are errors, never ignored.
  """

  @max_toml_bytes 1_048_576
  @max_services 64
  @max_resources 256
  @max_records 1_024
  @record_types ~w(SOA NS A AAAA CNAME MX TXT PTR)
  @max_txt_strings 255
  @max_allow_query 128
  @max_views 128
  @max_view_priority 9_223_372_036_854_775_807
  @max_forward_zones 64
  @max_forwarders 8
  @max_listener_addresses 32
  @dns_transports ~w(udp tcp dot doq doh)
  @dns_policy_fields ~w(recursion allow_query forward_zones views)
  @max_id_bytes 64
  @max_domain_bytes 253
  @max_revision 2_147_483_647
  @id_pattern ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/
  @domain_label ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  @owner_label ~r/\A[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?\z/

  @type error :: %{path: [String.t() | non_neg_integer()], code: atom(), message: String.t()}

  def record_types, do: @record_types

  @spec normalize_resource(map()) :: {:ok, map()} | {:error, [error()]}
  def normalize_resource(resource) when is_map(resource) do
    with :ok <- shape(resource, ~w(id type schema_version version content), ~w(digest), []),
         {:ok, id} <- identity(resource["id"], ["id"]),
         :ok <- equal(resource["type"], "dns_zone", ["type"]),
         :ok <- equal(resource["schema_version"], 1, ["schema_version"]),
         {:ok, version} <- positive(resource["version"], ["version"]),
         {:ok, content} <- zone(resource["content"], ["content"]) do
      digest = semantic_digest(content)

      case {Map.has_key?(resource, "digest"), resource["digest"]} do
        {false, nil} ->
          {:ok,
           %{
             "id" => id,
             "type" => "dns_zone",
             "schema_version" => 1,
             "version" => version,
             "content" => content,
             "digest" => digest
           }}

        {true, ^digest} ->
          {:ok,
           %{
             "id" => id,
             "type" => "dns_zone",
             "schema_version" => 1,
             "version" => version,
             "content" => content,
             "digest" => digest
           }}

        {true, declared} when is_binary(declared) ->
          err(["digest"], :digest_mismatch, "expected digest does not match normalized content")

        _ ->
          err(["digest"], :invalid_type, "digest must be a lowercase SHA-256 hex string")
      end
    end
  end

  def normalize_resource(_), do: err([], :invalid_type, "resource must be a map")

  @spec normalize_plan(map()) :: {:ok, map()} | {:error, [error()]}
  def normalize_plan(plan) when is_map(plan) do
    with :ok <- shape(plan, ~w(schema_version worker_id revision services resources), [], []),
         :ok <- equal(plan["schema_version"], 1, ["schema_version"]),
         {:ok, worker_id} <- identity(plan["worker_id"], ["worker_id"]),
         {:ok, revision} <- positive(plan["revision"], ["revision"]),
         {:ok, services} <- bounded_list(plan["services"], @max_services, ["services"]),
         {:ok, resources} <- bounded_list(plan["resources"], @max_resources, ["resources"]),
         {:ok, services} <- map_indexed(services, &service/2, ["services"]),
         {:ok, resources} <- map_indexed(resources, &normalize_resource/1, ["resources"]),
         :ok <- unique(services, "id", ["services"]),
         :ok <- unique(resources, "id", ["resources"]),
         :ok <- references(services, resources),
         :ok <- target_zones(services, resources),
         :ok <- single_dns_service(services) do
      normalized = %{
        "schema_version" => 1,
        "worker_id" => worker_id,
        "revision" => revision,
        "services" => Enum.sort_by(services, & &1["id"]),
        "resources" => Enum.sort_by(resources, & &1["id"])
      }

      if byte_size(encode_normalized(normalized)) <= @max_toml_bytes do
        {:ok, normalized}
      else
        err([], :too_large, "normalized TOML exceeds #{@max_toml_bytes} bytes")
      end
    end
  end

  def normalize_plan(_), do: err([], :invalid_type, "plan must be a map")

  @doc "Returns a semantic target digest; plan revision is intentionally excluded."
  @spec plan_digest(map()) :: {:ok, String.t()} | {:error, [error()]}
  def plan_digest(plan) do
    with {:ok, normalized} <- normalize_plan(plan) do
      semantic = Map.take(normalized, ~w(worker_id services resources))
      {:ok, semantic_digest(semantic)}
    end
  end

  @spec encode(map()) :: {:ok, String.t()} | {:error, [error()]}
  def encode(plan) do
    with {:ok, normalized} <- normalize_plan(plan) do
      {:ok, encode_normalized(normalized)}
    end
  end

  defp encode_normalized(normalized) do
    [
      "schema_version = 1",
      "worker_id = #{toml(normalized["worker_id"])}",
      "revision = #{normalized["revision"]}",
      "services = #{toml(normalized["services"])}",
      "resources = #{toml(normalized["resources"])}"
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @spec decode(binary()) :: {:ok, map()} | {:error, [error()]}
  def decode(input) when is_binary(input) and byte_size(input) <= @max_toml_bytes do
    try do
      case Toml.decode(input) do
        {:ok, parsed} -> normalize_plan(parsed)
        {:error, reason} -> err([], :invalid_toml, inspect(reason))
      end
    rescue
      exception -> err([], :invalid_toml, Exception.message(exception))
    end
  end

  def decode(input) when is_binary(input),
    do: err([], :too_large, "TOML exceeds #{@max_toml_bytes} bytes")

  def decode(_), do: err([], :invalid_type, "TOML input must be a binary")

  @spec diff(map(), map()) :: {:ok, map()} | {:error, [error()]}
  def diff(old, new) do
    with {:ok, old} <- normalize_plan(old),
         {:ok, new} <- normalize_plan(new),
         :ok <- equal(new["worker_id"], old["worker_id"], ["worker_id"]) do
      {service_added, service_replaced, service_removed, lifecycle} =
        collection_diff(old["services"], new["services"], true)

      {resource_added, resource_replaced, resource_removed, _} =
        collection_diff(old["resources"], new["resources"], false)

      {:ok,
       %{
         "services" => %{
           "added" => service_added,
           "replaced" => service_replaced,
           "removed" => service_removed,
           "lifecycle" => lifecycle
         },
         "resources" => %{
           "added" => resource_added,
           "replaced" => resource_replaced,
           "removed" => resource_removed
         }
       }}
    end
  end

  defp collection_diff(old, new, lifecycle?) do
    old_by_id = Map.new(old, &{&1["id"], &1})
    new_by_id = Map.new(new, &{&1["id"], &1})
    old_ids = Map.keys(old_by_id) |> MapSet.new()
    new_ids = Map.keys(new_by_id) |> MapSet.new()

    added = MapSet.difference(new_ids, old_ids) |> Enum.sort()
    removed = MapSet.difference(old_ids, new_ids) |> Enum.sort()

    {replaced, lifecycle} =
      MapSet.intersection(old_ids, new_ids)
      |> Enum.sort()
      |> Enum.reduce({[], []}, fn id, {replaced, lifecycle} ->
        before = old_by_id[id]
        after_ = new_by_id[id]
        replaced = if before == after_, do: replaced, else: [id | replaced]

        lifecycle =
          if lifecycle? and before["desired_state"] != after_["desired_state"] do
            [
              %{"id" => id, "from" => before["desired_state"], "to" => after_["desired_state"]}
              | lifecycle
            ]
          else
            lifecycle
          end

        {replaced, lifecycle}
      end)

    {added, Enum.reverse(replaced), removed, Enum.reverse(lifecycle)}
  end

  defp service(service, path) when is_map(service) do
    with :ok <- shape(service, ~w(id type desired_state config resources), [], path),
         {:ok, id} <- identity(service["id"], path ++ ["id"]),
         :ok <- equal(service["type"], "dns", path ++ ["type"]),
         :ok <- member(service["desired_state"], ~w(running stopped), path ++ ["desired_state"]),
         {:ok, config} <- dns_config(service["config"], path ++ ["config"]),
         {:ok, refs} <- bounded_list(service["resources"], @max_resources, path ++ ["resources"]),
         {:ok, refs} <- map_indexed(refs, &identity/2, path ++ ["resources"]),
         :ok <- unique_values(refs, path ++ ["resources"]) do
      {:ok,
       %{
         "id" => id,
         "type" => "dns",
         "desired_state" => service["desired_state"],
         "config" => config,
         "resources" => Enum.sort(refs)
       }}
    end
  end

  defp service(_, path), do: err(path, :invalid_type, "service must be a map")

  defp dns_config(%{"listen" => listen} = config, path) do
    with :ok <- shape(config, ~w(listen), ["transports" | @dns_policy_fields], path),
         {:ok, listen} <- listener_scope(listen, path ++ ["listen"]),
         {:ok, transports} <-
           dns_transports(Map.get(config, "transports", %{}), path ++ ["transports"]),
         {:ok, policy} <- dns_policy(config, path) do
      {:ok, Map.merge(policy, %{"listen" => listen, "transports" => transports})}
    end
  end

  defp dns_config(config, path) when is_map(config) do
    with :ok <- shape(config, ~w(listen_address port), @dns_policy_fields, path),
         {:ok, address} <- ipv4(config["listen_address"], path ++ ["listen_address"]),
         {:ok, port} <- integer(config["port"], 1, 65_535, path ++ ["port"]),
         {:ok, policy} <- dns_policy(config, path) do
      {:ok, Map.merge(policy, %{"listen_address" => address, "port" => port})}
    end
  end

  defp dns_config(_, path), do: err(path, :invalid_type, "config must be a map")

  defp dns_policy(config, path) do
    with {:ok, recursion} <- boolean(Map.get(config, "recursion", false), path ++ ["recursion"]),
         {:ok, allow_query} <-
           allow_query(Map.get(config, "allow_query", []), path ++ ["allow_query"]),
         {:ok, zones} <-
           forward_zones(Map.get(config, "forward_zones", []), path ++ ["forward_zones"]),
         {:ok, views} <- optional_field(config, "views", &dns_views/2, path) do
      {:ok,
       Map.merge(views, %{
         "recursion" => recursion,
         "allow_query" => allow_query,
         "forward_zones" => zones
       })}
    end
  end

  defp dns_views(value, path) do
    with {:ok, views} <- bounded_list(value, @max_views, path),
         {:ok, views} <- map_indexed(views, &dns_view/2, path),
         :ok <- unique(views, "id", path),
         :ok <- single_default_view(views, path) do
      {:ok, Enum.sort_by(views, &{Map.get(&1, "priority", @max_view_priority + 1), &1["id"]})}
    end
  end

  defp dns_view(view, path) when is_map(view) do
    with :ok <- shape(view, ~w(id recursion_enabled client_rules), ["priority"], path),
         {:ok, id} <- identity(view["id"], path ++ ["id"]),
         {:ok, recursion} <- boolean(view["recursion_enabled"], path ++ ["recursion_enabled"]),
         {:ok, rules} <- view_rules(view["client_rules"], path ++ ["client_rules"]),
         {:ok, priority} <- optional_field(view, "priority", &view_priority/2, path) do
      {:ok,
       Map.merge(priority, %{
         "id" => id,
         "recursion_enabled" => recursion,
         "client_rules" => rules
       })}
    end
  end

  defp dns_view(_, path), do: err(path, :invalid_type, "DNS View must be a map")

  defp view_priority(value, path), do: integer(value, 0, @max_view_priority, path)

  defp single_default_view(views, path) do
    if Enum.count(views, &(not is_map_key(&1, "priority"))) <= 1,
      do: :ok,
      else: err(path, :duplicate, "only one default DNS View can omit priority")
  end

  defp view_rules(value, path) do
    with {:ok, rules} <- bounded_list(value, @max_allow_query, path),
         {:ok, rules} <- map_indexed(rules, &view_rule/2, path) do
      networks = Enum.sum(Enum.map(rules, &length(Map.get(&1, "networks", []))))

      if networks <= @max_allow_query,
        do: {:ok, rules},
        else: err(path, :too_many, "View rules exceed #{@max_allow_query} total networks")
    end
  end

  defp view_rule(rule, path) when is_map(rule) do
    kind = rule["kind"]

    with :ok <- member(rule["action"], ~w(allow deny), path ++ ["action"]),
         :ok <- member(kind, ~w(any networks), path ++ ["kind"]),
         {:ok, selector} <- view_selector(kind, rule, path) do
      {:ok, Map.merge(selector, %{"action" => rule["action"], "kind" => kind})}
    end
  end

  defp view_rule(_, path), do: err(path, :invalid_type, "View rule must be a map")

  defp view_selector("any", rule, path) do
    with :ok <- shape(rule, ~w(action kind), [], path), do: {:ok, %{}}
  end

  defp view_selector("networks", rule, path) do
    with :ok <- shape(rule, ~w(action kind networks), [], path),
         {:ok, networks} <- allow_query(rule["networks"], path ++ ["networks"]) do
      {:ok, %{"networks" => networks}}
    end
  end

  defp dns_transports(transports, path) when is_map(transports) do
    with :ok <- shape(transports, [], @dns_transports, path) do
      Enum.reduce_while(@dns_transports, {:ok, %{}}, fn protocol, {:ok, normalized} ->
        case dns_transport(protocol, Map.get(transports, protocol, %{}), path ++ [protocol]) do
          {:ok, config} -> {:cont, {:ok, Map.put(normalized, protocol, config)}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp dns_transports(_, path), do: err(path, :invalid_type, "transports must be a map")

  defp dns_transport(protocol, config, path) when is_map(config) do
    encrypted? = protocol in ~w(dot doq doh)

    optional =
      if encrypted?, do: ~w(enabled port listen certificate_id), else: ~w(enabled port listen)

    default_port = %{"udp" => 53, "tcp" => 53, "dot" => 853, "doq" => 853, "doh" => 443}[protocol]

    with :ok <- shape(config, [], optional, path),
         {:ok, enabled} <-
           boolean(Map.get(config, "enabled", not encrypted?), path ++ ["enabled"]),
         {:ok, port} <-
           integer(Map.get(config, "port", default_port), 1, 65_535, path ++ ["port"]),
         {:ok, listen} <- optional_field(config, "listen", &listener_scope/2, path),
         :ok <- require_certificate(config, enabled and encrypted?, path),
         {:ok, certificate} <- optional_field(config, "certificate_id", &identity/2, path) do
      {:ok, Map.merge(%{"enabled" => enabled, "port" => port}, Map.merge(listen, certificate))}
    end
  end

  defp dns_transport(_, _, path), do: err(path, :invalid_type, "transport must be a map")

  defp require_certificate(config, true, path),
    do: shape(config, ["certificate_id"], ~w(enabled port listen), path)

  defp require_certificate(_config, false, _path), do: :ok

  defp optional_field(config, key, validator, path) do
    case Map.fetch(config, key) do
      {:ok, value} ->
        with {:ok, normalized} <- validator.(value, path ++ [key]),
             do: {:ok, %{key => normalized}}

      :error ->
        {:ok, %{}}
    end
  end

  defp listener_scope(%{"mode" => "specific"} = scope, path) do
    address_path = path ++ ["addresses"]

    with :ok <- shape(scope, ~w(mode addresses), [], path),
         {:ok, addresses} <-
           bounded_list(scope["addresses"], @max_listener_addresses, address_path),
         :ok <- nonempty_addresses(addresses, address_path),
         {:ok, addresses} <- map_indexed(addresses, &listener_address/2, address_path),
         :ok <- unique_values(addresses, address_path) do
      {:ok, %{"mode" => "specific", "addresses" => Enum.sort(addresses)}}
    end
  end

  defp listener_scope(scope, path) when is_map(scope) do
    with :ok <- shape(scope, ["mode"], [], path),
         :ok <- member(scope["mode"], ~w(all all_ipv4 all_ipv6), path ++ ["mode"]),
         do: {:ok, scope}
  end

  defp listener_scope(_, path), do: err(path, :invalid_type, "listen must be a map")

  defp nonempty_addresses([], path),
    do: err(path, :missing_field, "at least one address is required")

  defp nonempty_addresses(_, _path), do: :ok

  defp listener_address(address, path) when is_binary(address) and byte_size(address) <= 45 do
    case :inet.parse_strict_address(String.to_charlist(address)) do
      {:ok, tuple} when tuple in [{0, 0, 0, 0}, {0, 0, 0, 0, 0, 0, 0, 0}] ->
        err(path, :invalid_address, "select an all-addresses mode for a wildcard listener")

      {:ok, tuple} ->
        {:ok, tuple |> :inet.ntoa() |> List.to_string()}

      {:error, _} ->
        err(path, :invalid_address, "invalid IP address")
    end
  end

  defp listener_address(_, path), do: err(path, :invalid_address, "IP address must be a string")

  defp zone(content, path) when is_map(content) do
    with :ok <- shape(content, ~w(name records), [], path),
         {:ok, name} <- domain(content["name"], path ++ ["name"]),
         {:ok, records} <- bounded_list(content["records"], @max_records, path ++ ["records"]),
         {:ok, records} <- map_indexed(records, &record/2, path ++ ["records"]),
         :ok <- unique_values(Enum.map(records, &canonical/1), path ++ ["records"]),
         :ok <- rrset_ttls(records, path),
         :ok <- exclusive_cnames(records, path),
         :ok <- complete_zone(name, records, path) do
      {:ok, %{"name" => name, "records" => Enum.sort_by(records, &canonical/1)}}
    end
  end

  defp zone(_, path), do: err(path, :invalid_type, "content must be a map")

  defp record(record, path) when is_map(record) do
    with :ok <- shape(record, ~w(name type ttl data), [], path),
         {:ok, name} <- record_owner(record["name"], path ++ ["name"]),
         :ok <- member(record["type"], @record_types, path ++ ["type"]),
         {:ok, ttl} <- integer(record["ttl"], 0, @max_revision, path ++ ["ttl"]),
         {:ok, data} <- record_data(record["type"], record["data"], path ++ ["data"]) do
      {:ok, %{"name" => name, "type" => record["type"], "ttl" => ttl, "data" => data}}
    end
  end

  defp record(_, path), do: err(path, :invalid_type, "record must be a map")

  defp record_data("SOA", data, path) when is_map(data) do
    with :ok <- shape(data, ~w(mname rname serial refresh retry expire minimum), [], path),
         {:ok, mname} <- domain(data["mname"], path ++ ["mname"]),
         {:ok, rname} <- soa_rname(data["rname"], path ++ ["rname"]),
         {:ok, serial} <- integer(data["serial"], 0, 4_294_967_295, path ++ ["serial"]),
         {:ok, refresh} <- integer(data["refresh"], 0, @max_revision, path ++ ["refresh"]),
         {:ok, retry} <- integer(data["retry"], 0, @max_revision, path ++ ["retry"]),
         {:ok, expire} <- integer(data["expire"], 0, @max_revision, path ++ ["expire"]),
         {:ok, minimum} <- integer(data["minimum"], 0, @max_revision, path ++ ["minimum"]) do
      {:ok,
       %{
         "mname" => mname,
         "rname" => rname,
         "serial" => serial,
         "refresh" => refresh,
         "retry" => retry,
         "expire" => expire,
         "minimum" => minimum
       }}
    end
  end

  defp record_data("NS", data, path) when is_map(data) do
    with :ok <- shape(data, ~w(host), [], path),
         {:ok, host} <- domain(data["host"], path ++ ["host"]) do
      {:ok, %{"host" => host}}
    end
  end

  defp record_data("A", data, path) when is_map(data) do
    with :ok <- shape(data, ~w(address), [], path),
         {:ok, address} <- ipv4(data["address"], path ++ ["address"]) do
      {:ok, %{"address" => address}}
    end
  end

  defp record_data("AAAA", data, path) when is_map(data) do
    with :ok <- shape(data, ~w(address), [], path),
         {:ok, address} <- ipv6(data["address"], path ++ ["address"]) do
      {:ok, %{"address" => address}}
    end
  end

  defp record_data(type, data, path) when type in ~w(CNAME PTR) and is_map(data) do
    with :ok <- shape(data, ~w(target), [], path),
         {:ok, target} <- dns_name(data["target"], path ++ ["target"], @owner_label, false) do
      {:ok, %{"target" => target}}
    end
  end

  defp record_data("MX", data, path) when is_map(data) do
    with :ok <- shape(data, ~w(preference exchange), [], path),
         {:ok, preference} <- integer(data["preference"], 0, 65_535, path ++ ["preference"]),
         {:ok, exchange} <- mx_exchange(data["exchange"], preference, path ++ ["exchange"]) do
      {:ok, %{"preference" => preference, "exchange" => exchange}}
    end
  end

  defp record_data("TXT", data, path) when is_map(data) do
    with :ok <- shape(data, ~w(strings), [], path),
         {:ok, strings} <- bounded_list(data["strings"], @max_txt_strings, path ++ ["strings"]),
         :ok <- txt_nonempty(strings, path ++ ["strings"]),
         {:ok, strings} <- map_indexed(strings, &txt_string/2, path ++ ["strings"]) do
      {:ok, %{"strings" => strings}}
    end
  end

  defp record_data(_, _, path), do: err(path, :invalid_type, "invalid record data")

  defp mx_exchange(".", 0, _path), do: {:ok, "."}
  defp mx_exchange(exchange, _preference, path), do: domain(exchange, path)

  defp txt_nonempty([], path),
    do: err(path, :invalid_record, "TXT requires at least one character-string")

  defp txt_nonempty(_, _path), do: :ok

  defp txt_string(value, path) do
    if is_binary(value) and byte_size(value) <= 255 and String.valid?(value) and
         not String.contains?(value, <<0>>) do
      {:ok, value}
    else
      err(path, :invalid_record, "TXT strings must contain at most 255 UTF-8 bytes without NUL")
    end
  end

  defp rrset_ttls(records, path) do
    inconsistent? =
      records
      |> Enum.group_by(&{&1["name"], &1["type"]})
      |> Enum.any?(fn {_rrset, members} ->
        members |> Enum.map(& &1["ttl"]) |> Enum.uniq() |> length() > 1
      end)

    if inconsistent?,
      do: err(path ++ ["records"], :inconsistent_ttl, "records in one RRset must share a TTL"),
      else: :ok
  end

  defp complete_zone(name, records, path) do
    soa = Enum.filter(records, &(&1["type"] == "SOA"))
    apex_ns = Enum.filter(records, &(&1["type"] == "NS" and &1["name"] == name))

    cond do
      length(soa) != 1 ->
        err(path ++ ["records"], :invalid_zone, "zone requires exactly one SOA")

      hd(soa)["name"] != name ->
        err(path ++ ["records"], :invalid_zone, "SOA must be at the zone apex")

      apex_ns == [] ->
        err(path ++ ["records"], :invalid_zone, "zone requires an apex NS")

      Enum.any?(records, fn r ->
        r["name"] != name and not String.ends_with?(r["name"], "." <> name)
      end) ->
        err(path ++ ["records"], :invalid_zone, "record name must be inside zone")

      true ->
        :ok
    end
  end

  defp exclusive_cnames(records, path) do
    conflicting? =
      records
      |> Enum.group_by(& &1["name"])
      |> Enum.any?(fn {_name, records} ->
        length(records) > 1 and Enum.any?(records, &(&1["type"] == "CNAME"))
      end)

    if conflicting?,
      do: err(path ++ ["records"], :invalid_zone, "CNAME must be the only record at its owner"),
      else: :ok
  end

  defp references(services, resources) do
    by_id = Map.new(resources, &{&1["id"], &1})

    missing =
      Enum.reduce_while(services, :ok, fn service, _ ->
        case Enum.find(service["resources"], &(not Map.has_key?(by_id, &1))) do
          nil ->
            {:cont, :ok}

          id ->
            {:halt,
             err(
               ["services", service["id"], "resources"],
               :missing_reference,
               "resource #{id} is not present in the plan"
             )}
        end
      end)

    with :ok <- missing do
      referenced = services |> Enum.flat_map(& &1["resources"]) |> MapSet.new()

      case Enum.find(resources, &(not MapSet.member?(referenced, &1["id"]))) do
        nil ->
          :ok

        resource ->
          err(
            ["resources", resource["id"]],
            :unreferenced_resource,
            "complete plan cannot contain an unassigned resource"
          )
      end
    end
  end

  defp target_zones(services, resources) do
    by_id = Map.new(resources, &{&1["id"], &1})

    Enum.reduce_while(services, :ok, fn service, _ ->
      names = Enum.map(service["resources"], &get_in(by_id[&1], ["content", "name"]))

      if length(names) == length(Enum.uniq(names)) do
        {:cont, :ok}
      else
        {:halt,
         err(
           ["services", service["id"], "resources"],
           :duplicate_zone,
           "one service cannot select two versions of the same DNS zone"
         )}
      end
    end)
  end

  defp single_dns_service(services) when length(services) <= 1, do: :ok

  defp single_dns_service(_) do
    err(["services"], :duplicate_service_type, "a Worker can configure only one DNS service")
  end

  defp shape(map, required, optional, path) do
    keys = Map.keys(map)
    missing = required -- keys
    unknown = keys -- (required ++ optional)

    cond do
      missing != [] -> err(path ++ [hd(missing)], :missing_field, "required field is missing")
      unknown != [] -> err(path ++ [hd(unknown)], :unsupported_field, "field is not supported")
      true -> :ok
    end
  end

  defp identity(value, path) when is_binary(value) do
    if byte_size(value) in 1..@max_id_bytes and Regex.match?(@id_pattern, value) do
      {:ok, value}
    else
      err(
        path,
        :invalid_identity,
        "ID must be 1..#{@max_id_bytes} ASCII letters, digits, _, . or -"
      )
    end
  end

  defp identity(_, path), do: err(path, :invalid_identity, "ID must be a string")

  defp domain(value, path), do: dns_name(value, path, @domain_label, false)
  defp record_owner(value, path), do: dns_name(value, path, @owner_label, true)

  defp dns_name(value, path, label, wildcard?) when is_binary(value) do
    normalized = value |> String.trim_trailing(".") |> String.downcase()

    labels =
      case String.split(normalized, ".") do
        ["*", first | rest] when wildcard? -> [first | rest]
        labels -> labels
      end

    if not String.ends_with?(value, "..") and byte_size(normalized) in 1..@max_domain_bytes and
         Enum.all?(labels, &Regex.match?(label, &1)) do
      {:ok, normalized <> "."}
    else
      err(path, :invalid_domain, "invalid DNS domain name")
    end
  end

  defp dns_name(_, path, _label, _wildcard?),
    do: err(path, :invalid_domain, "domain must be a string")

  defp soa_rname(value, path) when is_binary(value) do
    with {:ok, normalized} <- domain(value, path) do
      case String.split(value, ".", parts: 2) do
        [local, _domain] ->
          [_normalized_local | domain_labels] = String.split(normalized, ".")
          {:ok, local <> "." <> Enum.join(domain_labels, ".")}

        _ ->
          err(path, :invalid_domain, "SOA rname requires a mailbox label and domain")
      end
    end
  end

  defp soa_rname(_, path), do: err(path, :invalid_domain, "SOA rname must be a string")

  defp ipv4(value, path) when is_binary(value) do
    case :inet.parse_ipv4_address(String.to_charlist(value)) do
      {:ok, tuple} -> {:ok, tuple |> Tuple.to_list() |> Enum.join(".")}
      _ -> err(path, :invalid_address, "invalid IPv4 address")
    end
  end

  defp ipv4(_, path), do: err(path, :invalid_address, "IPv4 address must be a string")

  defp ipv6(value, path) when is_binary(value) do
    case :inet.parse_strict_address(String.to_charlist(value)) do
      {:ok, tuple} when tuple_size(tuple) == 8 -> {:ok, tuple_ntoa(tuple)}
      _ -> err(path, :invalid_address, "invalid IPv6 address")
    end
  end

  defp ipv6(_, path), do: err(path, :invalid_address, "IPv6 address must be a string")

  defp boolean(value, _path) when is_boolean(value), do: {:ok, value}
  defp boolean(_, path), do: err(path, :invalid_type, "value must be a boolean")

  defp allow_query(value, path) do
    with {:ok, list} <- bounded_list(value, @max_allow_query, path),
         {:ok, cidrs} <- map_indexed(list, &cidr/2, path) do
      {:ok, cidrs |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp cidr(value, path) when is_binary(value) do
    with [address, length] <- String.split(value, "/"),
         {:ok, tuple} <- :inet.parse_strict_address(String.to_charlist(address)),
         {prefix, ""} <- Integer.parse(length),
         {:ok, tuple, prefix} <- unmap_ipv4(tuple, prefix),
         {bits, width} = {tuple_to_bits(tuple), tuple_width(tuple)},
         true <- prefix in 0..width//1 do
      shift = width - prefix
      masked = bits |> Bitwise.bsr(shift) |> Bitwise.bsl(shift)
      {:ok, tuple_ntoa(bits_to_tuple(masked, width)) <> "/" <> Integer.to_string(prefix)}
    else
      :short_mapped ->
        err(
          path,
          :invalid_cidr,
          "IPv4-mapped CIDR needs a prefix of at least 96; use IPv4 notation"
        )

      _ ->
        err(path, :invalid_cidr, "expected IPv4 or IPv6 CIDR such as 10.0.0.0/24")
    end
  end

  defp cidr(_, path), do: err(path, :invalid_cidr, "CIDR must be a string")

  # IPv4 clients are matched as IPv4, so an IPv4-mapped CIDR (::ffff:a.b.c.d/N)
  # is stored as the IPv4 CIDR a.b.c.d/(N - 96); a shorter prefix would span
  # non-mapped IPv6 space as well and is rejected.
  defp unmap_ipv4({0, 0, 0, 0, 0, 0xFFFF, hi, lo}, prefix) when prefix >= 96 do
    octets =
      {Bitwise.bsr(hi, 8), Bitwise.band(hi, 0xFF), Bitwise.bsr(lo, 8), Bitwise.band(lo, 0xFF)}

    {:ok, octets, prefix - 96}
  end

  defp unmap_ipv4({0, 0, 0, 0, 0, 0xFFFF, _, _}, _prefix), do: :short_mapped
  defp unmap_ipv4(tuple, prefix), do: {:ok, tuple, prefix}

  defp tuple_width(tuple) when tuple_size(tuple) == 4, do: 32
  defp tuple_width(tuple) when tuple_size(tuple) == 8, do: 128

  defp tuple_to_bits(tuple) do
    group = if tuple_size(tuple) == 4, do: 8, else: 16

    tuple
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> Bitwise.bsl(acc, group) + part end)
  end

  defp bits_to_tuple(bits, 32), do: bits_to_tuple(bits, 4, 8)
  defp bits_to_tuple(bits, 128), do: bits_to_tuple(bits, 8, 16)

  defp bits_to_tuple(bits, count, group) do
    mask = Bitwise.bsl(1, group) - 1

    for i <- (count - 1)..0//-1 do
      bits |> Bitwise.bsr(i * group) |> Bitwise.band(mask)
    end
    |> List.to_tuple()
  end

  defp tuple_ntoa(tuple), do: tuple |> :inet.ntoa() |> to_string() |> String.downcase()

  @doc "Normalize the forwarding zones used by a Worker DNS service."
  def normalize_forward_zones(value), do: forward_zones(value, ["forward_zones"])

  defp forward_zones(value, path) do
    with {:ok, list} <- bounded_list(value, @max_forward_zones, path),
         {:ok, zones} <- map_indexed(list, &forward_zone/2, path),
         :ok <- unique(zones, "name", path, :duplicate_forward_zone) do
      {:ok, Enum.sort_by(zones, & &1["name"])}
    end
  end

  defp forward_zone(zone, path) when is_map(zone) do
    with :ok <- shape(zone, ~w(name forwarders), [], path),
         {:ok, name} <- forward_zone_name(zone["name"], path ++ ["name"]),
         {:ok, forwarders} <- forwarders(zone["forwarders"], path ++ ["forwarders"]) do
      {:ok, %{"name" => name, "forwarders" => forwarders}}
    end
  end

  defp forward_zone(_, path), do: err(path, :invalid_type, "forward zone must be a map")

  defp forward_zone_name(".", _path), do: {:ok, "."}
  defp forward_zone_name(value, path), do: domain(value, path)

  defp forwarders(value, path) do
    with {:ok, list} <- bounded_list(value, @max_forwarders, path),
         true <- list != [] or err(path, :invalid_value, "at least one forwarder is required") do
      map_indexed(list, &forwarder/2, path)
    end
  end

  defp forwarder(forwarder, path) when is_map(forwarder) do
    with :ok <- shape(forwarder, ~w(address), ~w(port), path),
         {:ok, address} <- ip_address(forwarder["address"], path ++ ["address"]),
         {:ok, port} <- integer(Map.get(forwarder, "port", 53), 1, 65_535, path ++ ["port"]) do
      {:ok, %{"address" => address, "port" => port}}
    end
  end

  defp forwarder(_, path), do: err(path, :invalid_type, "forwarder must be a map")

  defp ip_address(value, path) when is_binary(value) do
    case :inet.parse_strict_address(String.to_charlist(value)) do
      {:ok, tuple} -> {:ok, tuple_ntoa(tuple)}
      _ -> err(path, :invalid_address, "invalid IPv4 or IPv6 address")
    end
  end

  defp ip_address(_, path), do: err(path, :invalid_address, "address must be a string")

  defp positive(value, path), do: integer(value, 1, @max_revision, path)

  defp integer(value, min, max, _path) when is_integer(value) and value >= min and value <= max,
    do: {:ok, value}

  defp integer(_, min, max, path),
    do: err(path, :invalid_integer, "integer must be in #{min}..#{max}")

  defp equal(value, value, _path), do: :ok

  defp equal(_, expected, path),
    do: err(path, :unsupported_value, "expected #{inspect(expected)}")

  defp member(value, values, path) do
    if value in values,
      do: :ok,
      else: err(path, :unsupported_value, "expected one of #{inspect(values)}")
  end

  defp bounded_list(value, max, path) when is_list(value) do
    if length(value) <= max,
      do: {:ok, value},
      else: err(path, :too_many, "list exceeds #{max} entries")
  end

  defp bounded_list(_, _, path),
    do: err(path, :invalid_type, "required array is missing or invalid")

  defp map_indexed(list, fun, path) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      result = if is_function(fun, 2), do: fun.(item, path ++ [index]), else: fun.(item)

      case result do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, errors} -> {:halt, {:error, prefix_errors(errors, path ++ [index], fun)}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp prefix_errors(errors, path, fun) do
    if is_function(fun, 1),
      do: Enum.map(errors, &Map.update!(&1, :path, fn p -> path ++ p end)),
      else: errors
  end

  defp unique(items, key, path, code \\ :duplicate),
    do: unique_values(Enum.map(items, & &1[key]), path, code)

  defp unique_values(values, path, code \\ :duplicate) do
    if length(values) == length(Enum.uniq(values)),
      do: :ok,
      else: err(path, code, "duplicate entries are not allowed")
  end

  defp semantic_digest(content) do
    :crypto.hash(:sha256, canonical(content)) |> Base.encode16(case: :lower)
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, item} -> [key, canonical(item)] end)
    |> Jason.encode!()
  end

  defp canonical(value) when is_list(value), do: Jason.encode!(Enum.map(value, &canonical/1))
  defp canonical(value), do: Jason.encode!(value)

  defp toml(value) when is_binary(value),
    do: value |> Jason.encode!() |> String.replace(<<127>>, "\\u007F")

  defp toml(value) when is_boolean(value), do: Atom.to_string(value)
  defp toml(value) when is_integer(value), do: Integer.to_string(value)
  defp toml(value) when is_list(value), do: "[" <> Enum.map_join(value, ", ", &toml/1) <> "]"

  defp toml(value) when is_map(value) do
    "{ " <>
      (value
       |> Enum.sort_by(&elem(&1, 0))
       |> Enum.map_join(", ", fn {key, item} -> "#{key} = #{toml(item)}" end)) <>
      " }"
  end

  defp err(path, code, message), do: {:error, [%{path: path, code: code, message: message}]}
end
