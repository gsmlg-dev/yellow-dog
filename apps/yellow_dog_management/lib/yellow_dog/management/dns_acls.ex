defmodule YellowDog.Management.DnsAcls do
  @moduledoc "Management-owned named DNS ACL data; no attachment or runtime evaluation."

  import Ecto.Query
  import Bitwise

  alias YellowDog.Management.{Countries, DnsAcl, Repo, Service, Worker}

  @create_keys ~w(worker_id service_id name description rules)
  @scope_keys ~w(worker_id service_id id expected_revision)

  def preset_rules("any"), do: {:ok, [%{"action" => "allow", "kind" => "any"}]}
  def preset_rules("none"), do: {:ok, [%{"action" => "deny", "kind" => "any"}]}

  def preset_rules("localhost"),
    do: {:ok, [network_rule("allow", ["127.0.0.1/32", "::1/128"])]}

  def preset_rules("localnets"),
    do: {:ok, [network_rule("allow", ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"])]}

  def preset_rules(_name),
    do: {:error, %{code: "invalid_request", message: "Unknown DNS ACL preset", details: %{}}}

  def normalize_rules(rules), do: read(fn -> normalized_rules!(rules) end)

  def list(worker_id, service_id) do
    read(fn ->
      service = scope!(worker_id, service_id)

      Repo.all(from(acl in DnsAcl, where: acl.service_id == ^service.id, order_by: acl.name))
      |> Enum.map(&acl_map(&1, service.worker_id))
    end)
  end

  def get(worker_id, service_id, id) do
    read(fn ->
      service = scope!(worker_id, service_id)
      acl!(service.id, id) |> acl_map(service.worker_id)
    end)
  end

  def dispatch("create_dns_acl", params) do
    allowed_keys!(params, @create_keys)
    service = scope!(params["worker_id"], params["service_id"], "FOR UPDATE")
    fields = fields!(params)
    unique_name!(service.id, fields.name)

    struct!(DnsAcl, Map.put(fields, :service_id, service.id))
    |> Repo.insert!()
    |> acl_map(service.worker_id)
  end

  def dispatch("update_dns_acl", params) do
    allowed_keys!(params, @create_keys ++ ~w(id expected_revision))
    service = scope!(params["worker_id"], params["service_id"], "FOR UPDATE")
    acl = acl!(service.id, params["id"], "FOR UPDATE")
    expect_revision!(acl, params)
    fields = fields!(params)
    unique_name!(service.id, fields.name, acl.id)

    acl
    |> Ecto.Changeset.change(Map.put(fields, :revision, acl.revision + 1))
    |> Repo.update!()
    |> acl_map(service.worker_id)
  end

  def dispatch("delete_dns_acl", params) do
    allowed_keys!(params, @scope_keys)
    service = scope!(params["worker_id"], params["service_id"], "FOR UPDATE")
    acl = acl!(service.id, params["id"], "FOR UPDATE")
    expect_revision!(acl, params)
    Repo.delete!(acl) |> acl_map(service.worker_id)
  end

  def dispatch(_operation, _params), do: abort("invalid_request", "Unknown DNS ACL operation")

  defp read(callback) do
    {:ok, callback.()}
  catch
    {:management_abort, error} -> {:error, error}
  end

  defp scope!(worker_id, service_id, lock \\ nil) do
    unless is_binary(worker_id) and String.valid?(worker_id) and
             Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/, worker_id),
           do: abort("invalid_request", "worker_id must be a valid Worker identifier")

    service_id = uuid!(service_id, "service_id")
    worker_query = from(worker in Worker, where: worker.id == ^worker_id)
    worker = Repo.one(locked(worker_query, lock)) || abort("not_found", "Worker not found")

    service_query =
      from(service in Service,
        where: service.id == ^service_id and service.worker_id == ^worker.id
      )

    service =
      Repo.one(locked(service_query, lock)) ||
        abort("not_found", "DNS Service not found in Worker")

    if service.type != "dns", do: abort("invalid_request", "Service must be a DNS Service")
    service
  end

  defp acl!(service_id, id, lock \\ nil) do
    id = uuid!(id, "id")
    query = from(acl in DnsAcl, where: acl.id == ^id and acl.service_id == ^service_id)
    Repo.one(locked(query, lock)) || abort("not_found", "DNS ACL not found in Service")
  end

  defp locked(query, nil), do: query
  defp locked(query, "FOR UPDATE"), do: from(row in query, lock: "FOR UPDATE")

  defp uuid!(value, field) do
    if is_binary(value) and byte_size(value) == 36 do
      case Ecto.UUID.cast(value) do
        {:ok, id} -> id
        :error -> abort("invalid_request", "#{field} must be a UUID")
      end
    else
      abort("invalid_request", "#{field} must be a UUID")
    end
  end

  defp allowed_keys!(params, keys) do
    unless is_map(params) and Enum.all?(Map.keys(params), &(&1 in keys)),
      do: abort("invalid_request", "Unknown DNS ACL fields")
  end

  defp fields!(params) do
    name = params["name"]

    unless is_binary(name) and String.valid?(name) and
             Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/, name),
           do:
             abort(
               "invalid_request",
               "name must be 1–128 ASCII letters, digits, dot, underscore or hyphen, starting with a letter or digit"
             )

    description = Map.get(params, "description", "")

    unless is_binary(description) and String.valid?(description) and
             not String.contains?(description, <<0>>) and
             length(String.codepoints(description)) <= 255,
           do:
             abort(
               "invalid_request",
               "description must be at most 255 Unicode characters without NUL"
             )

    %{name: name, description: description, rules: normalized_rules!(params["rules"])}
  end

  defp normalized_rules!(rules) do
    unless is_list(rules) and length(rules) <= 128,
      do: abort("invalid_request", "rules must be a list of at most 128 rules")

    rules = Enum.map(rules, &rule!/1)

    total_networks =
      Enum.reduce(rules, 0, fn rule, count -> count + length(Map.get(rule, "networks", [])) end)

    if total_networks > 128,
      do: abort("invalid_request", "rules may contain at most 128 total networks")

    rules
  end

  defp rule!(%{"action" => action, "kind" => kind} = rule) when action in ~w(allow deny) do
    case kind do
      "any" ->
        allowed_keys!(rule, ~w(action kind))
        %{"action" => action, "kind" => "any"}

      "networks" ->
        allowed_keys!(rule, ~w(action kind networks))
        networks = rule["networks"]

        unless is_list(networks) and length(networks) <= 128,
          do:
            abort("invalid_request", "networks must be a list of at most 128 IP or CIDR strings")

        network_rule(action, Enum.map(networks, &network!/1))

      "countries" ->
        allowed_keys!(rule, ~w(action kind countries))
        countries = rule["countries"]

        unless is_list(countries) and countries != [] and length(countries) <= 249 and
                 Enum.all?(countries, &Countries.valid?/1),
               do: abort("invalid_request", "countries must be 1–249 uppercase ISO country codes")

        %{
          "action" => action,
          "kind" => "countries",
          "countries" => countries |> Enum.uniq() |> Enum.sort()
        }

      _invalid ->
        abort("invalid_request", "kind must be networks, countries or any")
    end
  end

  defp rule!(_rule),
    do: abort("invalid_request", "Each rule must have an explicit allow or deny action and kind")

  defp network_rule(action, networks),
    do: %{"action" => action, "kind" => "networks", "networks" => networks}

  defp network!(value) when is_binary(value) and byte_size(value) <= 64 do
    with true <- String.valid?(value),
         [address | prefixes] when length(prefixes) <= 1 <- String.split(value, "/"),
         true <- Regex.match?(~r/\A[0-9A-Fa-f:.]+\z/, address),
         {:ok, tuple} <- :inet.parse_strict_address(String.to_charlist(address)) do
      bits = if tuple_size(tuple) == 4, do: 8, else: 16
      width = tuple_size(tuple) * bits
      prefix = prefix!(prefixes, width)

      number = Enum.reduce(Tuple.to_list(tuple), 0, fn part, acc -> (acc <<< bits) + part end)
      network = (number >>> (width - prefix)) <<< (width - prefix)
      part_mask = (1 <<< bits) - 1

      parts =
        for index <- 1..tuple_size(tuple),
            do: network >>> (width - index * bits) &&& part_mask

      canonical = parts |> List.to_tuple() |> :inet.ntoa() |> to_string()
      canonical <> "/" <> Integer.to_string(prefix)
    else
      _invalid -> abort("invalid_request", "Each network must be an IPv4 or IPv6 IP or CIDR")
    end
  end

  defp network!(_value),
    do: abort("invalid_request", "Each network must be an IPv4 or IPv6 IP or CIDR")

  defp prefix!([], width), do: width

  defp prefix!([prefix], width) do
    unless Regex.match?(~r/\A[0-9]{1,3}\z/, prefix),
      do: abort("invalid_request", "CIDR prefix must be a nonnegative integer")

    prefix = String.to_integer(prefix)
    if prefix > width, do: abort("invalid_request", "CIDR prefix is out of bounds")
    prefix
  end

  defp expect_revision!(acl, params) do
    expected = params["expected_revision"]

    unless is_integer(expected) and expected > 0,
      do: abort("invalid_request", "expected_revision must be a positive integer")

    if expected != acl.revision,
      do: abort("revision_conflict", "Expected revision does not match current DNS ACL revision")
  end

  defp unique_name!(service_id, name, except_id \\ nil) do
    existing =
      Repo.one(from(acl in DnsAcl, where: acl.service_id == ^service_id and acl.name == ^name))

    if existing && existing.id != except_id,
      do: abort("conflict", "DNS ACL name already exists in Service")
  end

  defp acl_map(acl, worker_id) do
    %{
      "id" => acl.id,
      "worker_id" => worker_id,
      "service_id" => acl.service_id,
      "name" => acl.name,
      "description" => acl.description,
      "rules" => acl.rules,
      "revision" => acl.revision,
      "inserted_at" => DateTime.to_iso8601(acl.inserted_at),
      "updated_at" => DateTime.to_iso8601(acl.updated_at)
    }
  end

  defp abort(code, message),
    do: throw({:management_abort, %{code: code, message: message, details: %{}}})
end
