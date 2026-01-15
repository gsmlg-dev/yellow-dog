# Functional Core: DNS Zone Editor

## Overview

The functional core contains pure functions for DNS record validation, zone validation, and file parsing. These functions have no side effects and are easily testable.

## Module Structure

```
apps/ex_dns/lib/dns/zone/
├── validator/
│   ├── record.ex       # Per-record-type validation
│   ├── zone.ex         # Zone-wide validation rules
│   └── result.ex       # Validation result structure
├── parser/
│   ├── rdata.ex        # RDATA parsing by type
│   ├── bind.ex         # BIND zone file parser
│   └── formatter.ex    # Zone file formatting
└── impl/
    └── name_utils.ex   # Domain name utilities
```

## Record Validation

### Module: `DNS.Zone.Validator.Record`

```elixir
defmodule DNS.Zone.Validator.Record do
  @moduledoc """
  Pure validation functions for individual DNS records.
  All functions take record data and return {:ok, normalized} or {:error, reasons}.
  """

  @type validation_error :: %{
    field: atom(),
    code: atom(),
    message: String.t()
  }

  @type validation_result :: {:ok, map()} | {:error, [validation_error()]}

  # ============================================
  # A Record
  # ============================================

  @doc """
  Validate an A record.

  ## Examples

      iex> validate_a(%{name: "www", rdata: "192.0.2.1", ttl: 3600})
      {:ok, %{name: "www", type: :a, rdata: {192, 0, 2, 1}, ttl: 3600}}

      iex> validate_a(%{name: "www", rdata: "256.0.0.1", ttl: 3600})
      {:error, [%{field: :rdata, code: :invalid_ipv4, message: "Invalid IPv4 address"}]}
  """
  @spec validate_a(map()) :: validation_result()
  def validate_a(params) do
    with {:ok, name} <- validate_name(params[:name]),
         {:ok, ttl} <- validate_ttl(params[:ttl]),
         {:ok, ip} <- parse_ipv4(params[:rdata]) do
      {:ok, %{name: name, type: :a, class: :in, ttl: ttl, rdata: ip}}
    end
  end

  defp parse_ipv4(ip) when is_tuple(ip) and tuple_size(ip) == 4 do
    if Enum.all?(Tuple.to_list(ip), &(is_integer(&1) and &1 >= 0 and &1 <= 255)) do
      {:ok, ip}
    else
      {:error, [%{field: :rdata, code: :invalid_ipv4, message: "IPv4 octets must be 0-255"}]}
    end
  end

  defp parse_ipv4(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {a, b, c, d}} -> {:ok, {a, b, c, d}}
      _ -> {:error, [%{field: :rdata, code: :invalid_ipv4, message: "Invalid IPv4 address: #{ip}"}]}
    end
  end

  defp parse_ipv4(_), do: {:error, [%{field: :rdata, code: :invalid_ipv4, message: "Invalid IPv4 format"}]}

  # ============================================
  # AAAA Record
  # ============================================

  @doc """
  Validate an AAAA record.

  ## Examples

      iex> validate_aaaa(%{name: "www", rdata: "2001:db8::1", ttl: 3600})
      {:ok, %{name: "www", type: :aaaa, rdata: {8193, 3512, 0, 0, 0, 0, 0, 1}, ttl: 3600}}
  """
  @spec validate_aaaa(map()) :: validation_result()
  def validate_aaaa(params) do
    with {:ok, name} <- validate_name(params[:name]),
         {:ok, ttl} <- validate_ttl(params[:ttl]),
         {:ok, ip} <- parse_ipv6(params[:rdata]) do
      {:ok, %{name: name, type: :aaaa, class: :in, ttl: ttl, rdata: ip}}
    end
  end

  defp parse_ipv6(ip) when is_tuple(ip) and tuple_size(ip) == 8 do
    if Enum.all?(Tuple.to_list(ip), &(is_integer(&1) and &1 >= 0 and &1 <= 0xFFFF)) do
      {:ok, ip}
    else
      {:error, [%{field: :rdata, code: :invalid_ipv6, message: "IPv6 segments must be 0-65535"}]}
    end
  end

  defp parse_ipv6(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {a, b, c, d, e, f, g, h}} -> {:ok, {a, b, c, d, e, f, g, h}}
      _ -> {:error, [%{field: :rdata, code: :invalid_ipv6, message: "Invalid IPv6 address: #{ip}"}]}
    end
  end

  defp parse_ipv6(_), do: {:error, [%{field: :rdata, code: :invalid_ipv6, message: "Invalid IPv6 format"}]}

  # ============================================
  # CNAME Record
  # ============================================

  @doc """
  Validate a CNAME record.

  ## Examples

      iex> validate_cname(%{name: "www", rdata: "web.example.com.", ttl: 3600})
      {:ok, %{name: "www", type: :cname, rdata: "web.example.com.", ttl: 3600}}
  """
  @spec validate_cname(map()) :: validation_result()
  def validate_cname(params) do
    with {:ok, name} <- validate_name(params[:name]),
         {:ok, ttl} <- validate_ttl(params[:ttl]),
         {:ok, target} <- validate_domain_name(params[:rdata], :target) do
      {:ok, %{name: name, type: :cname, class: :in, ttl: ttl, rdata: target}}
    end
  end

  # ============================================
  # MX Record
  # ============================================

  @doc """
  Validate an MX record.

  ## Examples

      iex> validate_mx(%{name: "@", priority: 10, target: "mail.example.com.", ttl: 3600})
      {:ok, %{name: "", type: :mx, rdata: {10, "mail.example.com."}, ttl: 3600}}
  """
  @spec validate_mx(map()) :: validation_result()
  def validate_mx(params) do
    with {:ok, name} <- validate_name(params[:name]),
         {:ok, ttl} <- validate_ttl(params[:ttl]),
         {:ok, priority} <- validate_priority(params[:priority]),
         {:ok, target} <- validate_domain_name(params[:target], :target) do
      {:ok, %{name: name, type: :mx, class: :in, ttl: ttl, rdata: {priority, target}}}
    end
  end

  defp validate_priority(nil), do: {:error, [%{field: :priority, code: :required, message: "Priority is required"}]}
  defp validate_priority(p) when is_integer(p) and p >= 0 and p <= 65535, do: {:ok, p}
  defp validate_priority(p) when is_binary(p) do
    case Integer.parse(p) do
      {n, ""} when n >= 0 and n <= 65535 -> {:ok, n}
      _ -> {:error, [%{field: :priority, code: :invalid_range, message: "Priority must be 0-65535"}]}
    end
  end
  defp validate_priority(_), do: {:error, [%{field: :priority, code: :invalid, message: "Priority must be 0-65535"}]}

  # ============================================
  # TXT Record
  # ============================================

  @doc """
  Validate a TXT record.
  Each string segment must be max 255 bytes.

  ## Examples

      iex> validate_txt(%{name: "@", rdata: "v=spf1 include:_spf.google.com ~all", ttl: 3600})
      {:ok, %{name: "", type: :txt, rdata: "v=spf1 include:_spf.google.com ~all", ttl: 3600}}
  """
  @spec validate_txt(map()) :: validation_result()
  def validate_txt(params) do
    with {:ok, name} <- validate_name(params[:name]),
         {:ok, ttl} <- validate_ttl(params[:ttl]),
         {:ok, text} <- validate_txt_data(params[:rdata]) do
      {:ok, %{name: name, type: :txt, class: :in, ttl: ttl, rdata: text}}
    end
  end

  defp validate_txt_data(data) when is_binary(data) do
    if byte_size(data) <= 255 do
      {:ok, data}
    else
      # Split into 255-byte chunks
      chunks = for <<chunk::binary-size(255) <- data>>, do: chunk
      remainder = binary_part(data, div(byte_size(data), 255) * 255, rem(byte_size(data), 255))
      {:ok, chunks ++ [remainder]}
    end
  end

  defp validate_txt_data(data) when is_list(data) do
    if Enum.all?(data, &(is_binary(&1) and byte_size(&1) <= 255)) do
      {:ok, data}
    else
      {:error, [%{field: :rdata, code: :txt_too_long, message: "Each TXT string must be max 255 bytes"}]}
    end
  end

  defp validate_txt_data(_), do: {:error, [%{field: :rdata, code: :invalid, message: "Invalid TXT data"}]}

  # ============================================
  # SRV Record
  # ============================================

  @doc """
  Validate an SRV record.

  ## Examples

      iex> validate_srv(%{
      ...>   name: "_http._tcp",
      ...>   priority: 0, weight: 5, port: 443,
      ...>   target: "server.example.com.", ttl: 3600
      ...> })
      {:ok, %{name: "_http._tcp", type: :srv, rdata: {0, 5, 443, "server.example.com."}, ttl: 3600}}
  """
  @spec validate_srv(map()) :: validation_result()
  def validate_srv(params) do
    with {:ok, name} <- validate_srv_name(params[:name]),
         {:ok, ttl} <- validate_ttl(params[:ttl]),
         {:ok, priority} <- validate_priority(params[:priority]),
         {:ok, weight} <- validate_weight(params[:weight]),
         {:ok, port} <- validate_port(params[:port]),
         {:ok, target} <- validate_domain_name(params[:target], :target) do
      {:ok, %{name: name, type: :srv, class: :in, ttl: ttl, rdata: {priority, weight, port, target}}}
    end
  end

  defp validate_srv_name(nil), do: {:error, [%{field: :name, code: :required, message: "Name is required"}]}
  defp validate_srv_name(name) do
    # SRV names should be _service._proto or _service._proto.name
    if String.starts_with?(name, "_") do
      {:ok, name}
    else
      {:error, [%{field: :name, code: :invalid_srv_name, message: "SRV name must start with underscore (_service._proto)"}]}
    end
  end

  defp validate_weight(nil), do: {:error, [%{field: :weight, code: :required, message: "Weight is required"}]}
  defp validate_weight(w) when is_integer(w) and w >= 0 and w <= 65535, do: {:ok, w}
  defp validate_weight(w) when is_binary(w) do
    case Integer.parse(w) do
      {n, ""} when n >= 0 and n <= 65535 -> {:ok, n}
      _ -> {:error, [%{field: :weight, code: :invalid_range, message: "Weight must be 0-65535"}]}
    end
  end
  defp validate_weight(_), do: {:error, [%{field: :weight, code: :invalid, message: "Weight must be 0-65535"}]}

  defp validate_port(nil), do: {:error, [%{field: :port, code: :required, message: "Port is required"}]}
  defp validate_port(p) when is_integer(p) and p >= 0 and p <= 65535, do: {:ok, p}
  defp validate_port(p) when is_binary(p) do
    case Integer.parse(p) do
      {n, ""} when n >= 0 and n <= 65535 -> {:ok, n}
      _ -> {:error, [%{field: :port, code: :invalid_range, message: "Port must be 0-65535"}]}
    end
  end
  defp validate_port(_), do: {:error, [%{field: :port, code: :invalid, message: "Port must be 0-65535"}]}

  # ============================================
  # NS Record
  # ============================================

  @spec validate_ns(map()) :: validation_result()
  def validate_ns(params) do
    with {:ok, name} <- validate_name(params[:name]),
         {:ok, ttl} <- validate_ttl(params[:ttl]),
         {:ok, target} <- validate_domain_name(params[:rdata], :nameserver) do
      {:ok, %{name: name, type: :ns, class: :in, ttl: ttl, rdata: target}}
    end
  end

  # ============================================
  # PTR Record
  # ============================================

  @spec validate_ptr(map()) :: validation_result()
  def validate_ptr(params) do
    with {:ok, name} <- validate_name(params[:name]),
         {:ok, ttl} <- validate_ttl(params[:ttl]),
         {:ok, target} <- validate_domain_name(params[:rdata], :target) do
      {:ok, %{name: name, type: :ptr, class: :in, ttl: ttl, rdata: target}}
    end
  end

  # ============================================
  # CAA Record
  # ============================================

  @spec validate_caa(map()) :: validation_result()
  def validate_caa(params) do
    with {:ok, name} <- validate_name(params[:name]),
         {:ok, ttl} <- validate_ttl(params[:ttl]),
         {:ok, flags} <- validate_caa_flags(params[:flags]),
         {:ok, tag} <- validate_caa_tag(params[:tag]),
         {:ok, value} <- validate_caa_value(params[:value]) do
      {:ok, %{name: name, type: :caa, class: :in, ttl: ttl, rdata: {flags, tag, value}}}
    end
  end

  defp validate_caa_flags(nil), do: {:ok, 0}
  defp validate_caa_flags(f) when is_integer(f) and f >= 0 and f <= 255, do: {:ok, f}
  defp validate_caa_flags(_), do: {:error, [%{field: :flags, code: :invalid, message: "CAA flags must be 0-255"}]}

  defp validate_caa_tag(nil), do: {:error, [%{field: :tag, code: :required, message: "CAA tag is required"}]}
  defp validate_caa_tag(tag) when tag in ["issue", "issuewild", "iodef"], do: {:ok, tag}
  defp validate_caa_tag(_), do: {:error, [%{field: :tag, code: :invalid, message: "CAA tag must be issue, issuewild, or iodef"}]}

  defp validate_caa_value(nil), do: {:error, [%{field: :value, code: :required, message: "CAA value is required"}]}
  defp validate_caa_value(v) when is_binary(v), do: {:ok, v}
  defp validate_caa_value(_), do: {:error, [%{field: :value, code: :invalid, message: "Invalid CAA value"}]}

  # ============================================
  # Common Validators
  # ============================================

  defp validate_name(nil), do: {:ok, ""}  # @ is empty string
  defp validate_name("@"), do: {:ok, ""}
  defp validate_name(name) when is_binary(name) do
    cond do
      String.length(name) > 253 ->
        {:error, [%{field: :name, code: :too_long, message: "Domain name too long (max 253 characters)"}]}

      not valid_domain_labels?(name) ->
        {:error, [%{field: :name, code: :invalid_label, message: "Invalid domain name label"}]}

      true ->
        {:ok, name}
    end
  end
  defp validate_name(_), do: {:error, [%{field: :name, code: :invalid, message: "Invalid name format"}]}

  defp valid_domain_labels?(name) do
    labels = String.split(name, ".")

    Enum.all?(labels, fn label ->
      byte_size(label) <= 63 and
      Regex.match?(~r/^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$|^$/, label)
    end)
  end

  defp validate_ttl(nil), do: {:ok, 3600}  # Default TTL
  defp validate_ttl(ttl) when is_integer(ttl) and ttl >= 0 and ttl <= 2_147_483_647, do: {:ok, ttl}
  defp validate_ttl(ttl) when is_binary(ttl) do
    case Integer.parse(ttl) do
      {n, ""} when n >= 0 and n <= 2_147_483_647 -> {:ok, n}
      _ -> {:error, [%{field: :ttl, code: :invalid_range, message: "TTL must be 0-2147483647"}]}
    end
  end
  defp validate_ttl(_), do: {:error, [%{field: :ttl, code: :invalid, message: "Invalid TTL"}]}

  defp validate_domain_name(nil, field), do: {:error, [%{field: field, code: :required, message: "#{field} is required"}]}
  defp validate_domain_name(name, field) when is_binary(name) do
    cond do
      String.length(name) > 253 ->
        {:error, [%{field: field, code: :too_long, message: "Domain name too long"}]}

      not valid_domain_labels?(String.trim_trailing(name, ".")) ->
        {:error, [%{field: field, code: :invalid_label, message: "Invalid domain name"}]}

      true ->
        # Ensure trailing dot for FQDN
        {:ok, ensure_fqdn(name)}
    end
  end
  defp validate_domain_name(_, field), do: {:error, [%{field: field, code: :invalid, message: "Invalid domain name"}]}

  defp ensure_fqdn(name) do
    if String.ends_with?(name, "."), do: name, else: name <> "."
  end

  # ============================================
  # Dispatcher
  # ============================================

  @doc """
  Validate a record based on its type.
  """
  @spec validate(atom(), map()) :: validation_result()
  def validate(:a, params), do: validate_a(params)
  def validate(:aaaa, params), do: validate_aaaa(params)
  def validate(:cname, params), do: validate_cname(params)
  def validate(:mx, params), do: validate_mx(params)
  def validate(:txt, params), do: validate_txt(params)
  def validate(:srv, params), do: validate_srv(params)
  def validate(:ns, params), do: validate_ns(params)
  def validate(:ptr, params), do: validate_ptr(params)
  def validate(:caa, params), do: validate_caa(params)
  def validate(type, _), do: {:error, [%{field: :type, code: :unsupported, message: "Unsupported record type: #{type}"}]}
end
```

## Zone Validation

### Module: `DNS.Zone.Validator.Zone`

```elixir
defmodule DNS.Zone.Validator.Zone do
  @moduledoc """
  Zone-wide validation rules.
  Checks relationships between records and zone integrity.
  """

  alias DNS.Zone.Validator.Result

  @doc """
  Validate a complete zone.

  ## Checks performed:
  - SOA record exists at apex
  - NS records exist at apex
  - CNAME exclusivity (no other records at same name)
  - No CNAME at apex
  - MX/NS targets not pointing to CNAMEs
  - TTL consistency within RRSets
  - Orphaned record detection (warnings)
  """
  @spec validate(list(), String.t()) :: Result.t()
  def validate(records, zone_name) do
    Result.new()
    |> check_soa(records, zone_name)
    |> check_ns_at_apex(records, zone_name)
    |> check_cname_exclusivity(records)
    |> check_no_cname_at_apex(records, zone_name)
    |> check_mx_ns_targets(records)
    |> check_ttl_consistency(records)
    |> check_orphaned_targets(records)
  end

  @doc """
  Check if adding a record would create a conflict.
  Used for pre-insertion validation.
  """
  @spec check_would_conflict(map(), list(), String.t()) :: {:ok, :no_conflict} | {:error, map()}
  def check_would_conflict(new_record, existing_records, zone_name) do
    name = normalize_name(new_record.name)

    cond do
      # Check CNAME at apex
      new_record.type == :cname and is_apex?(name, zone_name) ->
        {:error, %{code: :cname_at_apex, message: "Cannot create CNAME at zone apex"}}

      # Check CNAME exclusivity - new CNAME conflicts with existing
      new_record.type == :cname ->
        existing_at_name = Enum.filter(existing_records, &(normalize_name(&1.name) == name))
        if Enum.any?(existing_at_name) do
          types = existing_at_name |> Enum.map(& &1.type) |> Enum.uniq()
          {:error, %{code: :cname_conflict, message: "CNAME would conflict with existing #{inspect(types)} records"}}
        else
          {:ok, :no_conflict}
        end

      # Check existing CNAME blocks new record
      true ->
        cnames_at_name = Enum.filter(existing_records, &(normalize_name(&1.name) == name and &1.type == :cname))
        if Enum.any?(cnames_at_name) do
          {:error, %{code: :blocked_by_cname, message: "Cannot add record: CNAME exists at this name"}}
        else
          {:ok, :no_conflict}
        end
    end
  end

  # ============================================
  # Individual Checks
  # ============================================

  defp check_soa(result, records, zone_name) do
    apex = normalize_name(zone_name)
    soa_records = Enum.filter(records, &(normalize_name(&1.name) == apex and &1.type == :soa))

    case length(soa_records) do
      0 ->
        Result.add_error(result, :missing_soa, "Zone must have exactly one SOA record at apex")
      1 ->
        result
      n ->
        Result.add_error(result, :multiple_soa, "Zone has #{n} SOA records, must have exactly one")
    end
  end

  defp check_ns_at_apex(result, records, zone_name) do
    apex = normalize_name(zone_name)
    ns_records = Enum.filter(records, &(normalize_name(&1.name) == apex and &1.type == :ns))

    case length(ns_records) do
      0 ->
        Result.add_error(result, :missing_ns, "Zone must have at least one NS record at apex")
      1 ->
        Result.add_warning(result, :single_ns, "Zone has only 1 NS record; recommend at least 2 for redundancy")
      _ ->
        result
    end
  end

  defp check_cname_exclusivity(result, records) do
    # Group records by name
    by_name = Enum.group_by(records, &normalize_name(&1.name))

    Enum.reduce(by_name, result, fn {name, recs}, acc ->
      types = Enum.map(recs, & &1.type) |> Enum.uniq()

      if :cname in types and length(types) > 1 do
        other_types = Enum.reject(types, &(&1 == :cname))
        Result.add_error(acc, :cname_conflict,
          "CNAME at #{name} conflicts with #{inspect(other_types)} records")
      else
        acc
      end
    end)
  end

  defp check_no_cname_at_apex(result, records, zone_name) do
    apex = normalize_name(zone_name)
    cname_at_apex = Enum.any?(records, &(normalize_name(&1.name) == apex and &1.type == :cname))

    if cname_at_apex do
      Result.add_error(result, :cname_at_apex, "CNAME record cannot exist at zone apex")
    else
      result
    end
  end

  defp check_mx_ns_targets(result, records) do
    cnames = records
             |> Enum.filter(&(&1.type == :cname))
             |> Enum.map(&normalize_name(&1.name))
             |> MapSet.new()

    mx_ns_records = Enum.filter(records, &(&1.type in [:mx, :ns]))

    Enum.reduce(mx_ns_records, result, fn record, acc ->
      target = get_target(record)

      if target && MapSet.member?(cnames, normalize_name(target)) do
        Result.add_error(acc, :target_is_cname,
          "#{record.type |> to_string() |> String.upcase()} target #{target} is a CNAME (forbidden by RFC 1034)")
      else
        acc
      end
    end)
  end

  defp check_ttl_consistency(result, records) do
    # Group by (name, type) = RRSet
    rrsets = Enum.group_by(records, &{normalize_name(&1.name), &1.type})

    Enum.reduce(rrsets, result, fn {{name, type}, recs}, acc ->
      ttls = Enum.map(recs, & &1.ttl) |> Enum.uniq()

      if length(ttls) > 1 do
        Result.add_warning(acc, :ttl_mismatch,
          "TTL mismatch in RRSet #{name}/#{type}: #{inspect(ttls)}")
      else
        acc
      end
    end)
  end

  defp check_orphaned_targets(result, records) do
    # Get all defined names with A/AAAA records
    names_with_address = records
                         |> Enum.filter(&(&1.type in [:a, :aaaa]))
                         |> Enum.map(&normalize_name(&1.name))
                         |> MapSet.new()

    # Check MX, NS, SRV targets
    target_records = Enum.filter(records, &(&1.type in [:mx, :ns, :srv]))

    Enum.reduce(target_records, result, fn record, acc ->
      target = get_target(record)

      if target && not MapSet.member?(names_with_address, normalize_name(String.trim_trailing(target, "."))) do
        Result.add_warning(acc, :orphaned_target,
          "#{record.type |> to_string() |> String.upcase()} target #{target} has no A/AAAA record in zone")
      else
        acc
      end
    end)
  end

  # ============================================
  # Helpers
  # ============================================

  defp normalize_name(name) when is_binary(name) do
    name |> String.downcase() |> String.trim_trailing(".")
  end
  defp normalize_name(%{value: value}), do: normalize_name(value)
  defp normalize_name(_), do: ""

  defp is_apex?(name, zone_name) do
    normalize_name(name) == normalize_name(zone_name) or name == "" or name == "@"
  end

  defp get_target(%{type: :mx, rdata: {_priority, target}}), do: target
  defp get_target(%{type: :ns, rdata: target}) when is_binary(target), do: target
  defp get_target(%{type: :srv, rdata: {_p, _w, _port, target}}), do: target
  defp get_target(_), do: nil
end
```

### Module: `DNS.Zone.Validator.Result`

```elixir
defmodule DNS.Zone.Validator.Result do
  @moduledoc """
  Accumulates validation errors, warnings, and info messages.
  """

  defstruct valid: true, errors: [], warnings: [], info: []

  @type severity :: :error | :warning | :info
  @type entry :: %{severity: severity(), code: atom(), message: String.t()}
  @type t :: %__MODULE__{
    valid: boolean(),
    errors: [entry()],
    warnings: [entry()],
    info: [entry()]
  }

  def new, do: %__MODULE__{}

  def add_error(result, code, message) do
    entry = %{severity: :error, code: code, message: message}
    %{result | valid: false, errors: [entry | result.errors]}
  end

  def add_warning(result, code, message) do
    entry = %{severity: :warning, code: code, message: message}
    %{result | warnings: [entry | result.warnings]}
  end

  def add_info(result, code, message) do
    entry = %{severity: :info, code: code, message: message}
    %{result | info: [entry | result.info]}
  end

  def valid?(%{valid: valid}), do: valid

  def to_list(result) do
    result.errors ++ result.warnings ++ result.info
  end
end
```

## File Parsing

### Module: `DNS.Zone.Parser.Bind`

```elixir
defmodule DNS.Zone.Parser.Bind do
  @moduledoc """
  Parse BIND zone file format into records.
  """

  @doc """
  Parse zone file content.

  ## Options
  - `:origin` - Zone origin (default from $ORIGIN directive)
  - `:default_ttl` - Default TTL (default from $TTL directive)

  ## Returns
  `{:ok, records}` or `{:error, errors}`
  """
  @spec parse(String.t(), keyword()) :: {:ok, list()} | {:error, list()}
  def parse(content, opts \\ []) do
    state = %{
      origin: Keyword.get(opts, :origin),
      ttl: Keyword.get(opts, :default_ttl, 3600),
      last_name: nil,
      records: [],
      errors: [],
      line_number: 0
    }

    lines = String.split(content, ~r/\r?\n/)

    final_state = Enum.reduce(lines, state, &parse_line/2)

    if Enum.empty?(final_state.errors) do
      {:ok, Enum.reverse(final_state.records)}
    else
      {:error, Enum.reverse(final_state.errors)}
    end
  end

  defp parse_line(line, state) do
    state = %{state | line_number: state.line_number + 1}

    line = line
           |> String.trim()
           |> remove_comment()

    cond do
      line == "" ->
        state

      String.starts_with?(line, "$ORIGIN") ->
        parse_origin(line, state)

      String.starts_with?(line, "$TTL") ->
        parse_ttl_directive(line, state)

      String.starts_with?(line, "$INCLUDE") ->
        # Not supported in basic parser
        add_error(state, "$INCLUDE directive not supported")

      String.starts_with?(line, "$GENERATE") ->
        # Not supported in basic parser
        add_error(state, "$GENERATE directive not supported")

      true ->
        parse_record(line, state)
    end
  end

  defp remove_comment(line) do
    # Handle ; comments, but not inside quoted strings
    case Regex.run(~r/^([^;"]|"[^"]*")*/, line) do
      [match | _] -> String.trim(match)
      nil -> line
    end
  end

  defp parse_origin(line, state) do
    case Regex.run(~r/^\$ORIGIN\s+(\S+)/, line) do
      [_, origin] -> %{state | origin: String.trim_trailing(origin, ".")}
      nil -> add_error(state, "Invalid $ORIGIN directive")
    end
  end

  defp parse_ttl_directive(line, state) do
    case Regex.run(~r/^\$TTL\s+(\S+)/, line) do
      [_, ttl_str] ->
        case parse_ttl(ttl_str) do
          {:ok, ttl} -> %{state | ttl: ttl}
          {:error, _} -> add_error(state, "Invalid TTL value: #{ttl_str}")
        end
      nil ->
        add_error(state, "Invalid $TTL directive")
    end
  end

  defp parse_record(line, state) do
    # Parse record fields: [name] [ttl] [class] type rdata
    tokens = tokenize(line)

    case parse_record_tokens(tokens, state) do
      {:ok, record, last_name} ->
        %{state |
          records: [record | state.records],
          last_name: last_name
        }
      {:error, msg} ->
        add_error(state, msg)
    end
  end

  defp tokenize(line) do
    # Split on whitespace, preserving quoted strings
    Regex.scan(~r/"[^"]*"|\S+/, line)
    |> List.flatten()
  end

  defp parse_record_tokens([], _state), do: {:error, "Empty record"}
  defp parse_record_tokens(tokens, state) do
    # Determine if first token is name, TTL, or type
    {name, tokens} = extract_name(tokens, state)
    {ttl, tokens} = extract_ttl(tokens, state)
    {class, tokens} = extract_class(tokens)

    case tokens do
      [type_str | rdata_tokens] ->
        type = String.downcase(type_str) |> String.to_atom()
        rdata_str = Enum.join(rdata_tokens, " ")

        case parse_rdata(type, rdata_str) do
          {:ok, rdata} ->
            full_name = expand_name(name, state.origin)
            record = %{
              name: full_name,
              type: type,
              class: class,
              ttl: ttl,
              rdata: rdata
            }
            {:ok, record, name}

          {:error, msg} ->
            {:error, "Invalid RDATA for #{type}: #{msg}"}
        end

      [] ->
        {:error, "Missing record type"}
    end
  end

  defp extract_name([token | rest], state) do
    cond do
      # Continuation (starts with whitespace in original)
      token == "" ->
        {state.last_name || "@", rest}

      # @ means apex
      token == "@" ->
        {"@", rest}

      # Looks like TTL (all digits) or class (IN/CH/HS)
      Regex.match?(~r/^\d+$/, token) or token in ["IN", "CH", "HS", "in", "ch", "hs"] ->
        {state.last_name || "@", [token | rest]}

      # Looks like type
      is_record_type?(token) ->
        {state.last_name || "@", [token | rest]}

      # It's a name
      true ->
        {token, rest}
    end
  end

  defp extract_ttl([token | rest], state) do
    case parse_ttl(token) do
      {:ok, ttl} -> {ttl, rest}
      {:error, _} -> {state.ttl, [token | rest]}
    end
  end

  defp extract_class([token | rest]) when token in ["IN", "CH", "HS", "in", "ch", "hs"] do
    {String.downcase(token) |> String.to_atom(), rest}
  end
  defp extract_class(tokens), do: {:in, tokens}

  defp parse_ttl(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :invalid}
    end
  end
  defp parse_ttl(_), do: {:error, :invalid}

  defp is_record_type?(token) do
    String.upcase(token) in ~w(A AAAA CNAME MX NS TXT SRV PTR SOA CAA TLSA HTTPS SVCB DNSKEY DS RRSIG NSEC)
  end

  defp expand_name("@", origin), do: origin
  defp expand_name(name, origin) do
    if String.ends_with?(name, ".") do
      String.trim_trailing(name, ".")
    else
      "#{name}.#{origin}"
    end
  end

  defp parse_rdata(:a, str), do: parse_ipv4_rdata(str)
  defp parse_rdata(:aaaa, str), do: parse_ipv6_rdata(str)
  defp parse_rdata(:cname, str), do: {:ok, String.trim(str)}
  defp parse_rdata(:ns, str), do: {:ok, String.trim(str)}
  defp parse_rdata(:ptr, str), do: {:ok, String.trim(str)}
  defp parse_rdata(:mx, str), do: parse_mx_rdata(str)
  defp parse_rdata(:txt, str), do: parse_txt_rdata(str)
  defp parse_rdata(:srv, str), do: parse_srv_rdata(str)
  defp parse_rdata(:caa, str), do: parse_caa_rdata(str)
  defp parse_rdata(:soa, str), do: parse_soa_rdata(str)
  defp parse_rdata(type, str), do: {:ok, str}  # Fallback for unknown types

  defp parse_ipv4_rdata(str) do
    case :inet.parse_address(String.to_charlist(String.trim(str))) do
      {:ok, {a, b, c, d}} -> {:ok, {a, b, c, d}}
      _ -> {:error, "Invalid IPv4"}
    end
  end

  defp parse_ipv6_rdata(str) do
    case :inet.parse_address(String.to_charlist(String.trim(str))) do
      {:ok, {a, b, c, d, e, f, g, h}} -> {:ok, {a, b, c, d, e, f, g, h}}
      _ -> {:error, "Invalid IPv6"}
    end
  end

  defp parse_mx_rdata(str) do
    case String.split(str, ~r/\s+/, parts: 2) do
      [priority_str, target] ->
        case Integer.parse(priority_str) do
          {priority, ""} -> {:ok, {priority, String.trim(target)}}
          _ -> {:error, "Invalid priority"}
        end
      _ -> {:error, "Invalid MX format (expected: priority target)"}
    end
  end

  defp parse_txt_rdata(str) do
    # Handle quoted strings
    case Regex.scan(~r/"([^"]*)"/, str) do
      [] -> {:ok, String.trim(str)}
      matches -> {:ok, Enum.map(matches, fn [_, content] -> content end)}
    end
  end

  defp parse_srv_rdata(str) do
    case String.split(str, ~r/\s+/, parts: 4) do
      [p, w, port, target] ->
        with {priority, ""} <- Integer.parse(p),
             {weight, ""} <- Integer.parse(w),
             {port_num, ""} <- Integer.parse(port) do
          {:ok, {priority, weight, port_num, String.trim(target)}}
        else
          _ -> {:error, "Invalid SRV numeric fields"}
        end
      _ -> {:error, "Invalid SRV format (expected: priority weight port target)"}
    end
  end

  defp parse_caa_rdata(str) do
    case Regex.run(~r/^(\d+)\s+(\w+)\s+"?([^"]*)"?$/, str) do
      [_, flags_str, tag, value] ->
        {flags, ""} = Integer.parse(flags_str)
        {:ok, {flags, tag, value}}
      _ -> {:error, "Invalid CAA format (expected: flags tag value)"}
    end
  end

  defp parse_soa_rdata(str) do
    # SOA: mname rname (serial refresh retry expire minimum)
    case Regex.run(~r/^(\S+)\s+(\S+)\s+\(?\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*\)?$/, str) do
      [_, mname, rname, serial, refresh, retry, expire, minimum] ->
        {:ok, %{
          mname: mname,
          rname: rname,
          serial: String.to_integer(serial),
          refresh: String.to_integer(refresh),
          retry: String.to_integer(retry),
          expire: String.to_integer(expire),
          minimum: String.to_integer(minimum)
        }}
      _ -> {:error, "Invalid SOA format"}
    end
  end

  defp add_error(state, message) do
    error = %{line: state.line_number, message: message}
    %{state | errors: [error | state.errors]}
  end
end
```

## Testing Pure Functions

```elixir
defmodule DNS.Zone.Validator.RecordTest do
  use ExUnit.Case, async: true

  alias DNS.Zone.Validator.Record

  describe "validate_a/1" do
    test "valid IPv4 string" do
      assert {:ok, %{rdata: {192, 0, 2, 1}}} =
        Record.validate_a(%{name: "www", rdata: "192.0.2.1", ttl: 3600})
    end

    test "valid IPv4 tuple" do
      assert {:ok, %{rdata: {10, 0, 0, 1}}} =
        Record.validate_a(%{name: "www", rdata: {10, 0, 0, 1}, ttl: 3600})
    end

    test "invalid IPv4" do
      assert {:error, [%{code: :invalid_ipv4}]} =
        Record.validate_a(%{name: "www", rdata: "256.0.0.1", ttl: 3600})
    end
  end

  describe "validate_mx/1" do
    test "valid MX" do
      assert {:ok, %{rdata: {10, "mail.example.com."}}} =
        Record.validate_mx(%{name: "@", priority: 10, target: "mail.example.com", ttl: 3600})
    end

    test "missing priority" do
      assert {:error, [%{field: :priority}]} =
        Record.validate_mx(%{name: "@", target: "mail.example.com", ttl: 3600})
    end
  end

  describe "validate_cname/1" do
    test "valid CNAME" do
      assert {:ok, %{rdata: "other.example.com."}} =
        Record.validate_cname(%{name: "www", rdata: "other.example.com", ttl: 3600})
    end
  end
end

defmodule DNS.Zone.Validator.ZoneTest do
  use ExUnit.Case, async: true

  alias DNS.Zone.Validator.Zone

  describe "check_would_conflict/3" do
    test "CNAME at apex blocked" do
      assert {:error, %{code: :cname_at_apex}} =
        Zone.check_would_conflict(
          %{name: "example.com", type: :cname, rdata: "other.com."},
          [],
          "example.com"
        )
    end

    test "CNAME blocked by existing A" do
      existing = [%{name: "www.example.com", type: :a, rdata: {1, 2, 3, 4}}]

      assert {:error, %{code: :cname_conflict}} =
        Zone.check_would_conflict(
          %{name: "www.example.com", type: :cname, rdata: "other.com."},
          existing,
          "example.com"
        )
    end

    test "A blocked by existing CNAME" do
      existing = [%{name: "www.example.com", type: :cname, rdata: "other.com."}]

      assert {:error, %{code: :blocked_by_cname}} =
        Zone.check_would_conflict(
          %{name: "www.example.com", type: :a, rdata: {1, 2, 3, 4}},
          existing,
          "example.com"
        )
    end

    test "no conflict" do
      existing = [%{name: "api.example.com", type: :a, rdata: {1, 2, 3, 4}}]

      assert {:ok, :no_conflict} =
        Zone.check_would_conflict(
          %{name: "www.example.com", type: :a, rdata: {5, 6, 7, 8}},
          existing,
          "example.com"
        )
    end
  end
end
```
