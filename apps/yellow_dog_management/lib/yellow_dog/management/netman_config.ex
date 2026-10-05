defmodule YellowDog.Management.NetmanConfig do
  @moduledoc """
  Pure validation of Management-owned Netman desired configuration.

  The root requires string keys `profiles` and `resolved`. Profiles require a
  stable `profile_id` (at most 128 bytes) and `zone` (at most 64 bytes); optional
  fields default to Ethernet, no interface/MTU, autoconnect enabled, priority zero,
  and automatic IPv4/IPv6 with no address, gateway or resolver overrides.

  Profile DNS addresses must match their family's original configuration
  contract. Resolved upstreams accept both families. Domain names normalize to
  lowercase without a trailing dot; IP addresses normalize without changing host
  bits. Disabled families reject all address/gateway/DNS settings; IPv6 link-local
  rejects static address/gateway. No configuration is applied or persisted.
  """

  @max_bytes 256 * 1024
  @identifier ~r/\A[A-Za-z0-9_.-]+\z/
  @domain_label ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z/

  def default do
    %{"profiles" => [], "resolved" => %{"upstreams" => [], "search_domains" => []}}
  end

  def validate(document) do
    with :ok <- bounded_json(document),
         {:ok, root} <- object(document, default(), ["profiles", "resolved"], "document"),
         {:ok, profiles} <- items(root["profiles"], 128, "profiles", &profile/2),
         :ok <- unique_profiles(profiles),
         {:ok, resolved} <- resolved(root["resolved"]),
         normalized = %{"profiles" => profiles, "resolved" => resolved},
         :ok <- bounded_json(normalized) do
      {:ok, normalized}
    end
  end

  defp bounded_json(document) do
    case Jason.encode(document) do
      {:ok, encoded} when byte_size(encoded) <= @max_bytes -> :ok
      {:ok, _encoded} -> invalid("document", "JSON must not exceed 256 KiB")
      {:error, _error} -> invalid("document", "must contain valid JSON values")
    end
  end

  defp profile(value, path) do
    defaults = %{
      "profile_id" => nil,
      "type" => "ethernet",
      "interface" => nil,
      "zone" => nil,
      "autoconnect" => true,
      "autoconnect_priority" => 0,
      "ethernet" => %{"mtu" => nil},
      "ipv4" => ip_default(),
      "ipv6" => ip_default()
    }

    with {:ok, profile} <- object(value, defaults, ["profile_id", "zone"], path),
         :ok <- identifier(profile["profile_id"], 128, path <> ".profile_id"),
         :ok <- identifier(profile["zone"], 64, path <> ".zone"),
         :ok <- check(profile["type"] == "ethernet", path <> ".type", "must be ethernet"),
         :ok <- interface(profile["interface"], path <> ".interface"),
         :ok <-
           check(is_boolean(profile["autoconnect"]), path <> ".autoconnect", "must be Boolean"),
         :ok <-
           integer(
             profile["autoconnect_priority"],
             -1000..10_000,
             path <> ".autoconnect_priority"
           ),
         {:ok, ethernet} <- object(profile["ethernet"], %{"mtu" => nil}, [], path <> ".ethernet"),
         :ok <- nullable_integer(ethernet["mtu"], 68..65_535, path <> ".ethernet.mtu"),
         {:ok, ipv4} <- ip_config(profile["ipv4"], :ipv4, path <> ".ipv4"),
         {:ok, ipv6} <- ip_config(profile["ipv6"], :ipv6, path <> ".ipv6") do
      {:ok, Map.merge(profile, %{"ethernet" => ethernet, "ipv4" => ipv4, "ipv6" => ipv6})}
    end
  end

  defp ip_default do
    %{"method" => "auto", "address" => nil, "gateway" => nil, "dns" => [], "dns_search" => []}
  end

  defp ip_config(value, family, path) do
    methods =
      if family == :ipv4, do: ~w(auto manual disabled), else: ~w(auto manual disabled link-local)

    with {:ok, config} <- object(value, ip_default(), [], path),
         :ok <- check(config["method"] in methods, path <> ".method", "unsupported method"),
         {:ok, address} <- cidr(config["address"], family, path <> ".address"),
         {:ok, gateway} <- nullable_ip(config["gateway"], family, path <> ".gateway"),
         {:ok, dns} <- items(config["dns"], 32, path <> ".dns", &ip(&1, family, &2)),
         {:ok, domains} <- items(config["dns_search"], 32, path <> ".dns_search", &domain/2),
         normalized =
           Map.merge(config, %{
             "address" => address,
             "gateway" => gateway,
             "dns" => dns,
             "dns_search" => domains
           }),
         :ok <- method_settings(normalized, path) do
      {:ok, normalized}
    end
  end

  defp method_settings(%{"method" => "manual", "address" => nil}, path),
    do: invalid(path <> ".address", "manual configuration requires an address")

  defp method_settings(%{"method" => "disabled"} = config, path) do
    check(
      config["address"] == nil and config["gateway"] == nil and config["dns"] == [] and
        config["dns_search"] == [],
      path,
      "disabled configuration must not contain address, gateway or DNS settings"
    )
  end

  defp method_settings(%{"method" => "link-local"} = config, path) do
    check(
      config["address"] == nil and config["gateway"] == nil,
      path,
      "link-local configuration must not contain a static address or gateway"
    )
  end

  defp method_settings(_config, _path), do: :ok

  defp resolved(value) do
    with {:ok, resolved} <- object(value, default()["resolved"], [], "resolved"),
         {:ok, upstreams} <-
           items(resolved["upstreams"], 32, "resolved.upstreams", &ip(&1, :any, &2)),
         {:ok, domains} <-
           items(resolved["search_domains"], 32, "resolved.search_domains", &domain/2) do
      {:ok, %{"upstreams" => upstreams, "search_domains" => domains}}
    end
  end

  defp object(value, defaults, required, path) when is_map(value) and not is_struct(value) do
    if Enum.all?(Map.keys(value), &Map.has_key?(defaults, &1)) and
         Enum.all?(required, &Map.has_key?(value, &1)) do
      {:ok, Map.merge(defaults, value)}
    else
      invalid(path, "contains unknown keys or is missing required keys")
    end
  end

  defp object(_value, _defaults, _required, path), do: invalid(path, "must be an object")

  defp items(values, limit, path, validator) when is_list(values) do
    if length(values) <= limit do
      values
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, result} ->
        case validator.(value, "#{path}[#{index}]") do
          {:ok, normalized} -> {:cont, {:ok, [normalized | result]}}
          {:error, _error} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, result} -> {:ok, Enum.reverse(result)}
        error -> error
      end
    else
      invalid(path, "must contain at most #{limit} entries")
    end
  end

  defp items(_values, _limit, path, _validator), do: invalid(path, "must be a list")

  defp unique_profiles(profiles) do
    ids = Enum.map(profiles, & &1["profile_id"])

    check(
      MapSet.size(MapSet.new(ids)) == length(ids),
      "profiles",
      "profile_id values must be unique"
    )
  end

  defp identifier(value, limit, path) do
    check(
      is_binary(value) and byte_size(value) in 1..limit and value not in [".", ".."] and
        Regex.match?(@identifier, value),
      path,
      "must be a stable identifier of at most #{limit} bytes"
    )
  end

  defp interface(nil, _path), do: :ok

  defp interface(value, path) do
    check(
      is_binary(value) and byte_size(value) in 1..15 and
        not Regex.match?(~r/[\s\p{Z}\p{C}\/:]/u, value),
      path,
      "must be null or an interface of at most 15 bytes without whitespace, slash or colon"
    )
  end

  defp nullable_integer(nil, _range, _path), do: :ok
  defp nullable_integer(value, range, path), do: integer(value, range, path)

  defp integer(value, range, path),
    do:
      check(
        is_integer(value) and value in range,
        path,
        "must be an integer in #{range.first}..#{range.last}"
      )

  defp nullable_ip(nil, _family, _path), do: {:ok, nil}
  defp nullable_ip(value, family, path), do: ip(value, family, path)

  defp ip(value, family, path) when is_binary(value) and byte_size(value) in 1..64 do
    with false <- String.contains?(value, "%"),
         {:ok, address} <- :inet.parse_strict_address(String.to_charlist(value)),
         true <-
           family == :any or (family == :ipv4 and tuple_size(address) == 4) or
             (family == :ipv6 and tuple_size(address) == 8) do
      {:ok, address |> :inet.ntoa() |> List.to_string()}
    else
      _error -> invalid(path, "must be a #{family} IP address")
    end
  end

  defp ip(_value, family, path), do: invalid(path, "must be a #{family} IP address")

  defp cidr(nil, _family, _path), do: {:ok, nil}

  defp cidr(value, family, path) when is_binary(value) and byte_size(value) <= 68 do
    maximum = if family == :ipv4, do: 32, else: 128

    with [address, prefix] <- String.split(value, "/"),
         true <- Regex.match?(~r/\A[0-9]{1,3}\z/, prefix),
         {length, ""} <- Integer.parse(prefix),
         true <- length in 0..maximum,
         {:ok, normalized} <- ip(address, family, path) do
      {:ok, "#{normalized}/#{length}"}
    else
      _error -> invalid(path, "must be a #{family} CIDR with prefix 0..#{maximum}")
    end
  end

  defp cidr(_value, family, path), do: invalid(path, "must be null or a #{family} CIDR")

  defp domain(value, path) when is_binary(value) and byte_size(value) in 1..254 do
    name =
      if String.ends_with?(value, "."),
        do: binary_part(value, 0, byte_size(value) - 1),
        else: value

    labels = String.split(name, ".")

    if byte_size(name) in 1..253 and Enum.all?(labels, &Regex.match?(@domain_label, &1)) do
      {:ok, String.downcase(name)}
    else
      invalid(path, "must be a domain with labels of 1..63 bytes")
    end
  end

  defp domain(_value, path), do: invalid(path, "must be a domain name")

  defp check(true, _path, _message), do: :ok
  defp check(false, path, message), do: invalid(path, message)

  defp invalid(path, message) do
    {:error,
     %{
       code: "invalid_request",
       message: "Invalid Netman configuration: #{message}",
       details: %{path: path}
     }}
  end
end
