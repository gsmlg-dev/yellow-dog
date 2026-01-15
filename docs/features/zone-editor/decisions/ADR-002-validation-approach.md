# ADR-002: Validation Approach for Zone Editor

**Status:** Accepted
**Date:** 2026-01-13
**Deciders:** Architecture Team
**Context:** How to validate DNS records and zones

## Context

DNS records must be validated at multiple levels:
1. **Syntax** - Field format validation (IP addresses, domain names)
2. **Semantics** - Type-specific rules (CNAME exclusivity, MX targets)
3. **Zone integrity** - Zone-wide rules (SOA required, NS at apex)

We need to decide where validation logic lives and how it's applied.

## Decision

**Implement validation as pure functions in a functional core**, applied at the service boundary layer before any mutations.

Architecture:
```
LiveView Form
     │
     ▼
ZoneService (boundary)
     │
     ├──► RecordValidator (pure functions)
     ├──► ZoneValidator (pure functions)
     │
     ▼
Auth Zone (ETS storage)
```

## Rationale

### Pure Functions for Testability

Pure validation functions with no side effects:
- Easy to unit test with any inputs
- Composable for complex validation
- Reusable across contexts (UI, API, import)

### Centralized in Service Layer

Validation at the boundary layer ensures:
- All entry points get validated (LiveView, API, import)
- Storage layer stays simple
- Single source of truth for rules

### Separation of Concerns

| Layer | Responsibility |
|-------|----------------|
| LiveView | UI feedback, form handling |
| Service | Orchestration, validation coordination |
| Validator | Pure validation logic |
| Auth Zone | Storage operations only |

## Alternatives Considered

### Alternative 1: Validation in Auth Zone GenServer

```elixir
# Validate inside GenServer
def handle_call({:add_record, record}, _from, state) do
  case RecordValidator.validate(record) do
    {:ok, valid} ->
      :ets.insert(state.table, valid)
      {:reply, :ok, state}
    {:error, _} = error ->
      {:reply, error, state}
  end
end
```

**Pros:**
- Can't bypass validation
- Single point of enforcement

**Cons:**
- GenServer becomes bloated
- Hard to unit test (needs running process)
- Validation logic mixed with storage

**Why Rejected:** Violates single responsibility principle. Testing requires process setup.

### Alternative 2: Ecto Changeset Style

```elixir
defmodule DnsRecord do
  use Ecto.Schema
  import Ecto.Changeset

  schema "dns_records" do
    field :name, :string
    field :type, :string
    field :rdata, :map
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:name, :type, :rdata])
    |> validate_required([:name, :type])
    |> validate_rdata()
  end
end
```

**Pros:**
- Familiar Ecto patterns
- Built-in error formatting

**Cons:**
- Ecto is database-oriented (we use ETS)
- Schema overhead not needed
- Less flexible for DNS-specific rules

**Why Rejected:** Ecto patterns don't fit non-database storage.

### Alternative 3: LiveView-Only Validation

```elixir
# Validate only in LiveView
def handle_event("save", %{"record" => params}, socket) do
  case RecordValidator.validate(params) do
    {:ok, valid} ->
      Auth.add_record(socket.assigns.zone, valid)
      {:noreply, socket}
    {:error, errors} ->
      {:noreply, assign(socket, :errors, errors)}
  end
end
```

**Pros:**
- Simple
- Fast UI feedback

**Cons:**
- API calls bypass validation
- Import bypasses validation
- Duplicate validation logic

**Why Rejected:** Validation must be universal, not UI-specific.

## Consequences

### Positive

1. **100% test coverage** - Pure functions are trivial to test
2. **Consistent validation** - All entry points use same rules
3. **Clear separation** - Each layer has single responsibility
4. **Easy to extend** - Add new record types without touching storage

### Negative

1. **Two-step flow** - Validate then store (not atomic)
2. **Possible drift** - Zone could become invalid if rules change
3. **No database constraints** - Can't rely on DB to enforce rules

### Mitigations

| Issue | Mitigation |
|-------|------------|
| Non-atomic | Service layer serializes via GenServer |
| Rule drift | Background validation job (future) |
| No constraints | Thorough testing, zone-level validation |

## Implementation Guidelines

### DO: Pure Validation Functions

```elixir
# ✅ Pure function - easy to test
def validate_a(%{rdata: ip} = params) do
  case parse_ipv4(ip) do
    {:ok, tuple} -> {:ok, %{params | rdata: tuple}}
    :error -> {:error, [%{field: :rdata, message: "Invalid IPv4"}]}
  end
end
```

### DON'T: Side Effects in Validators

```elixir
# ❌ Don't fetch data in validators
def validate_mx(params) do
  # BAD: Database lookup in validation
  if Repo.exists?(DnsRecord, name: params.target) do
    {:ok, params}
  else
    {:error, [%{message: "Target not found"}]}
  end
end
```

### DO: Validate at Service Boundary

```elixir
# ✅ Service layer coordinates validation
def add_record(zone_pid, params) do
  with {:ok, validated} <- RecordValidator.validate(params.type, params),
       {:ok, :no_conflict} <- ZoneValidator.check_conflict(...),
       :ok <- Auth.add_record(zone_pid, ...) do
    {:ok, ...}
  end
end
```

### DO: Return Structured Errors

```elixir
# ✅ Structured errors for UI consumption
{:error, [
  %{field: :rdata, code: :invalid_ipv4, message: "Invalid IPv4 address"},
  %{field: :ttl, code: :out_of_range, message: "TTL must be 0-2147483647"}
]}
```

### DO: Compose Validators

```elixir
# ✅ Compose for complex validation
def validate_mx(params) do
  with {:ok, name} <- validate_name(params[:name]),
       {:ok, ttl} <- validate_ttl(params[:ttl]),
       {:ok, priority} <- validate_priority(params[:priority]),
       {:ok, target} <- validate_domain(params[:target]) do
    {:ok, %{name: name, type: :mx, ttl: ttl, rdata: {priority, target}}}
  end
end
```

## Validation Rules Reference

### Level 1: Syntax (per-record)

| Type | Field | Rule |
|------|-------|------|
| A | rdata | Valid IPv4 (0-255 per octet) |
| AAAA | rdata | Valid IPv6 |
| MX | priority | 0-65535 |
| MX | target | Valid domain name |
| SRV | port | 0-65535 |
| TXT | rdata | Each string ≤255 bytes |
| All | ttl | 0-2147483647 |
| All | name | Label ≤63 chars, total ≤253 chars |

### Level 2: Semantics (zone-context)

| Rule | Description |
|------|-------------|
| CNAME exclusivity | CNAME cannot coexist with other types |
| No CNAME at apex | Zone apex cannot have CNAME |
| MX target not CNAME | MX must not point to CNAME |
| NS target not CNAME | NS must not point to CNAME |
| TTL consistency | Same RRSet must have same TTL |

### Level 3: Zone Integrity

| Rule | Description |
|------|-------------|
| SOA required | Exactly one SOA at apex |
| NS required | At least one NS at apex |
| Valid serial | SOA serial must increment on changes |

## References

- [RFC 1035 - Domain Names](https://tools.ietf.org/html/rfc1035)
- [RFC 2181 - DNS Clarifications](https://tools.ietf.org/html/rfc2181)
- [Functional Core, Imperative Shell](https://www.destroyallsoftware.com/screencasts/catalog/functional-core-imperative-shell)

## Related ADRs

- ADR-001: Storage Strategy
- ADR-003: Change Tracking

## Review Schedule

**Last Reviewed:** 2026-01-13
**Next Review:** 2026-07-13
