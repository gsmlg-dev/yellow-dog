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
  @max_id_bytes 64
  @max_domain_bytes 253
  @max_revision 2_147_483_647
  @id_pattern ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/
  @domain_label ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

  @type error :: %{path: [String.t() | non_neg_integer()], code: atom(), message: String.t()}

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
         :ok <- listener_bindings(services) do
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

  defp dns_config(config, path) when is_map(config) do
    with :ok <- shape(config, ~w(listen_address port), [], path),
         {:ok, address} <- ipv4(config["listen_address"], path ++ ["listen_address"]),
         {:ok, port} <- integer(config["port"], 1, 65_535, path ++ ["port"]) do
      {:ok, %{"listen_address" => address, "port" => port}}
    end
  end

  defp dns_config(_, path), do: err(path, :invalid_type, "config must be a map")

  defp zone(content, path) when is_map(content) do
    with :ok <- shape(content, ~w(name records), [], path),
         {:ok, name} <- domain(content["name"], path ++ ["name"]),
         {:ok, records} <- bounded_list(content["records"], @max_records, path ++ ["records"]),
         {:ok, records} <- map_indexed(records, &record/2, path ++ ["records"]),
         :ok <- unique_values(Enum.map(records, &canonical/1), path ++ ["records"]),
         :ok <- rrset_ttls(records, path),
         :ok <- complete_zone(name, records, path) do
      {:ok, %{"name" => name, "records" => Enum.sort_by(records, &canonical/1)}}
    end
  end

  defp zone(_, path), do: err(path, :invalid_type, "content must be a map")

  defp record(record, path) when is_map(record) do
    with :ok <- shape(record, ~w(name type ttl data), [], path),
         {:ok, name} <- domain(record["name"], path ++ ["name"]),
         :ok <- member(record["type"], ~w(SOA NS A), path ++ ["type"]),
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

  defp record_data(_, _, path), do: err(path, :invalid_type, "invalid record data")

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
    a = Enum.filter(records, &(&1["type"] == "A"))

    cond do
      length(soa) != 1 ->
        err(path ++ ["records"], :invalid_zone, "zone requires exactly one SOA")

      hd(soa)["name"] != name ->
        err(path ++ ["records"], :invalid_zone, "SOA must be at the zone apex")

      apex_ns == [] ->
        err(path ++ ["records"], :invalid_zone, "zone requires an apex NS")

      a == [] ->
        err(path ++ ["records"], :invalid_zone, "zone requires an A record")

      Enum.any?(records, fn r ->
        r["name"] != name and not String.ends_with?(r["name"], "." <> name)
      end) ->
        err(path ++ ["records"], :invalid_zone, "record name must be inside zone")

      true ->
        :ok
    end
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

  defp listener_bindings(services) do
    running = Enum.filter(services, &(&1["desired_state"] == "running"))

    Enum.reduce_while(running, [], fn service, seen ->
      config = service["config"]
      address = config["listen_address"]
      port = config["port"]

      conflict? =
        Enum.any?(seen, fn {other_address, other_port} ->
          port == other_port and
            (address == other_address or address == "0.0.0.0" or other_address == "0.0.0.0")
        end)

      if conflict? do
        {:halt,
         err(
           ["services", service["id"], "config"],
           :listener_conflict,
           "running DNS services cannot share an overlapping listener"
         )}
      else
        {:cont, [{address, port} | seen]}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
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

  defp domain(value, path) when is_binary(value) do
    normalized = value |> String.trim_trailing(".") |> String.downcase()
    labels = String.split(normalized, ".")

    if not String.ends_with?(value, "..") and byte_size(normalized) in 1..@max_domain_bytes and
         Enum.all?(labels, &Regex.match?(@domain_label, &1)) do
      {:ok, normalized <> "."}
    else
      err(path, :invalid_domain, "invalid DNS domain name")
    end
  end

  defp domain(_, path), do: err(path, :invalid_domain, "domain must be a string")

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

  defp unique(items, key, path), do: unique_values(Enum.map(items, & &1[key]), path)

  defp unique_values(values, path) do
    if length(values) == length(Enum.uniq(values)),
      do: :ok,
      else: err(path, :duplicate, "duplicate entries are not allowed")
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

  defp toml(value) when is_binary(value), do: Jason.encode!(value)
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
