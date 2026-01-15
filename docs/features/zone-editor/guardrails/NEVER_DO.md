# NEVER DO: Critical Prohibitions for Zone Editor

These rules are absolute and must never be violated. Each violation can cause data corruption, security issues, or incorrect DNS behavior.

---

## 1. Never Allow CNAME to Coexist with Other Record Types

**Why:** RFC 2181 Section 10.1 explicitly prohibits this. Violating this causes unpredictable DNS resolution behavior.

```elixir
# ❌ NEVER allow this state
records = [
  %{name: "www.example.com", type: :cname, rdata: "other.com."},
  %{name: "www.example.com", type: :a, rdata: {192, 0, 2, 1}}  # FORBIDDEN
]

# ✅ ALWAYS check before inserting
def add_record(zone_pid, %{type: :cname} = record) do
  existing = Auth.get_records(zone_pid, record.name, :any)

  if Enum.any?(existing) do
    {:error, :cname_conflict}
  else
    Auth.add_record(zone_pid, record)
  end
end
```

---

## 2. Never Allow CNAME at Zone Apex

**Why:** Zone apex MUST have SOA and NS records, which would conflict with CNAME.

```elixir
# ❌ NEVER allow this
%{name: "example.com", type: :cname, rdata: "other.com."}  # At apex!

# ✅ ALWAYS check apex
def validate_cname(params, zone_name) do
  if is_apex?(params.name, zone_name) do
    {:error, :cname_at_apex}
  else
    # ... proceed with validation
  end
end

defp is_apex?(name, zone_name) do
  normalize(name) == normalize(zone_name) or name in ["", "@"]
end
```

---

## 3. Never Delete the Only SOA Record

**Why:** A zone without SOA is invalid and will cause DNS failures.

```elixir
# ❌ NEVER allow deleting SOA
def delete_record(zone_pid, name, :soa) do
  # Don't check, just delete - WRONG!
  Auth.remove_record(zone_pid, name, :soa)
end

# ✅ ALWAYS block SOA deletion
def delete_record(zone_pid, name, :soa) do
  {:error, {:cannot_delete, "Cannot delete SOA record"}}
end
```

---

## 4. Never Delete All NS Records at Apex

**Why:** Zone must have at least one NS record for delegation to work.

```elixir
# ❌ NEVER allow this to result in zero NS at apex
def delete_record(zone_pid, name, :ns) do
  # Just delete without checking - WRONG!
  Auth.remove_record(zone_pid, name, :ns)
end

# ✅ ALWAYS check NS count before delete
def delete_record(zone_pid, name, :ns) do
  if is_apex?(name, zone_name) do
    ns_count = length(Auth.get_records(zone_pid, zone_name, :ns))

    if ns_count <= 1 do
      {:error, {:cannot_delete, "Cannot delete last NS record at apex"}}
    else
      Auth.remove_record(zone_pid, name, :ns)
    end
  else
    Auth.remove_record(zone_pid, name, :ns)
  end
end
```

---

## 5. Never Accept Invalid IP Addresses

**Why:** Invalid IP addresses cause DNS resolution failures and potential security issues.

```elixir
# ❌ NEVER trust user input
def add_a_record(params) do
  record = %{
    name: params["name"],
    type: :a,
    rdata: params["ip"]  # Raw string - DANGEROUS!
  }
  Auth.add_record(zone_pid, record)
end

# ✅ ALWAYS parse and validate
def add_a_record(params) do
  case :inet.parse_address(String.to_charlist(params["ip"])) do
    {:ok, {a, b, c, d}} when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 ->
      record = %{name: params["name"], type: :a, rdata: {a, b, c, d}}
      Auth.add_record(zone_pid, record)

    _ ->
      {:error, :invalid_ipv4}
  end
end
```

---

## 6. Never Skip Version Check on Updates

**Why:** Without optimistic locking, concurrent edits cause lost updates.

```elixir
# ❌ NEVER update without version check
def update_record(zone_pid, name, type, new_data) do
  Auth.remove_record(zone_pid, name, type)
  Auth.add_record(zone_pid, new_data)
  # Lost update if another user modified between these calls!
end

# ✅ ALWAYS check version
def update_record(zone_pid, name, type, new_data, expected_version) do
  case get_record_with_version(zone_pid, name, type) do
    {:ok, %{version: ^expected_version}} ->
      # Safe to update
      Auth.remove_record(zone_pid, name, type)
      Auth.add_record(zone_pid, new_data)

    {:ok, %{version: _different}} ->
      {:error, :version_conflict}

    {:error, :not_found} ->
      {:error, :not_found}
  end
end
```

---

## 7. Never Store Raw User Input in Zone Files

**Why:** Zone file injection could corrupt data or cause parsing failures.

```elixir
# ❌ NEVER write raw input to zone file
def export_record(record) do
  "#{record.name} #{record.ttl} IN #{record.type} #{record.rdata}"
  # If rdata contains newlines or semicolons, file is corrupted!
end

# ✅ ALWAYS escape/validate before export
def export_record(record) do
  name = escape_zone_name(record.name)
  rdata = format_rdata(record.type, record.rdata)
  "#{name} #{record.ttl} IN #{record.type} #{rdata}"
end

defp escape_zone_name(name) do
  # Escape special characters
  String.replace(name, ~r/[;\(\)\n\r]/, "")
end
```

---

## 8. Never Trust Client-Side Validation Alone

**Why:** Client-side validation can be bypassed. Server must always validate.

```elixir
# ❌ NEVER rely only on client validation
def handle_event("save", params, socket) do
  # Assuming LiveView form already validated - WRONG!
  record = build_record(params)
  Auth.add_record(zone_pid, record)
  {:noreply, socket}
end

# ✅ ALWAYS validate server-side
def handle_event("save", params, socket) do
  case RecordValidator.validate(params) do
    {:ok, validated} ->
      case ZoneService.add_record(zone_pid, validated) do
        {:ok, record} ->
          {:noreply, put_flash(socket, :info, "Record added")}
        {:error, reason} ->
          {:noreply, assign(socket, :error, reason)}
      end

    {:error, errors} ->
      {:noreply, assign(socket, :errors, errors)}
  end
end
```

---

## 9. Never Allow TTL Values Outside Valid Range

**Why:** TTL must be 0-2147483647 per RFC 2181. Invalid values cause protocol violations.

```elixir
# ❌ NEVER allow arbitrary TTL
def build_record(params) do
  %{
    ttl: String.to_integer(params["ttl"])  # Could be negative or huge!
  }
end

# ✅ ALWAYS validate TTL range
@max_ttl 2_147_483_647

def validate_ttl(nil), do: {:ok, 3600}  # Default
def validate_ttl(ttl) when is_integer(ttl) and ttl >= 0 and ttl <= @max_ttl do
  {:ok, ttl}
end
def validate_ttl(ttl) when is_binary(ttl) do
  case Integer.parse(ttl) do
    {n, ""} when n >= 0 and n <= @max_ttl -> {:ok, n}
    _ -> {:error, :invalid_ttl}
  end
end
def validate_ttl(_), do: {:error, :invalid_ttl}
```

---

## 10. Never Log Sensitive Zone Data in Plain Text

**Why:** Zone data may contain sensitive information (internal hostnames, service locations).

```elixir
# ❌ NEVER log full zone data
def import_zone(content) do
  Logger.info("Importing zone: #{content}")  # Leaks all records!
  parse_and_import(content)
end

# ✅ ALWAYS sanitize logs
def import_zone(content) do
  record_count = count_records(content)
  Logger.info("Importing zone with #{record_count} records")
  parse_and_import(content)
end

# ❌ NEVER log record rdata
Logger.debug("Added record: #{inspect(record)}")

# ✅ Log minimal info
Logger.debug("Added #{record.type} record for #{record.name}")
```

---

## Summary Table

| # | Rule | Consequence of Violation |
|---|------|--------------------------|
| 1 | No CNAME with other types | Undefined DNS resolution |
| 2 | No CNAME at apex | Zone becomes invalid |
| 3 | Don't delete only SOA | Zone becomes invalid |
| 4 | Don't delete all apex NS | Zone delegation fails |
| 5 | Validate all IPs | DNS lookup failures |
| 6 | Always check versions | Lost updates |
| 7 | Sanitize zone file output | Data corruption |
| 8 | Server-side validation | Security bypass |
| 9 | Validate TTL range | Protocol violation |
| 10 | Don't log sensitive data | Information disclosure |
