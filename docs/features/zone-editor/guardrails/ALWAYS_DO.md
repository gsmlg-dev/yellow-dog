# ALWAYS DO: Mandatory Practices for Zone Editor

These practices must be followed in all zone editor implementations to ensure correctness, security, and maintainability.

---

## Data Integrity

### 1. Always Validate Before Storage

Every record must pass validation before being stored.

```elixir
# ✅ ALWAYS validate first
def add_record(zone_pid, params) do
  with {:ok, validated} <- RecordValidator.validate(params.type, params),
       {:ok, :no_conflict} <- ZoneValidator.check_conflict(validated, zone_pid),
       :ok <- Auth.add_record(zone_pid, build_record(validated)) do
    {:ok, validated}
  end
end
```

### 2. Always Use Optimistic Locking for Updates

Include version field in all update operations.

```elixir
# ✅ ALWAYS include version
def update_record(zone_pid, name, type, new_params, expected_version) do
  with {:ok, current} <- get_record_with_metadata(zone_pid, name, type),
       :ok <- check_version(current.metadata.version, expected_version),
       {:ok, validated} <- RecordValidator.validate(type, new_params),
       :ok <- perform_update(zone_pid, name, type, validated) do
    {:ok, %{validated | version: current.metadata.version + 1}}
  end
end
```

### 3. Always Normalize Domain Names

Consistent normalization prevents lookup mismatches.

```elixir
# ✅ ALWAYS normalize names
defp normalize_name(name) when is_binary(name) do
  name
  |> String.downcase()
  |> String.trim_trailing(".")
end

defp normalize_name(%DNS.Message.Domain{value: value}), do: normalize_name(value)
defp normalize_name(_), do: ""
```

### 4. Always Check Zone Rules Before Mutations

CNAME conflicts, apex rules, and other zone-wide constraints must be checked.

```elixir
# ✅ ALWAYS check zone rules
def add_record(zone_pid, record) do
  zone_name = Auth.get_name(zone_pid)
  existing = Auth.get_all_records(zone_pid)

  with {:ok, :no_conflict} <- ZoneValidator.check_would_conflict(record, existing, zone_name) do
    Auth.add_record(zone_pid, record)
  end
end
```

---

## Testing

### 5. Always Write Tests for Validation Logic

Every validation rule needs corresponding tests.

```elixir
# ✅ ALWAYS test validation
describe "validate_a/1" do
  test "accepts valid IPv4" do
    assert {:ok, %{rdata: {192, 0, 2, 1}}} =
      RecordValidator.validate_a(%{name: "www", rdata: "192.0.2.1", ttl: 3600})
  end

  test "rejects invalid IPv4" do
    assert {:error, [%{code: :invalid_ipv4}]} =
      RecordValidator.validate_a(%{name: "www", rdata: "256.0.0.1", ttl: 3600})
  end

  test "rejects non-numeric octets" do
    assert {:error, _} = RecordValidator.validate_a(%{name: "www", rdata: "a.b.c.d", ttl: 3600})
  end
end
```

### 6. Always Test Edge Cases

Include tests for boundary conditions and error paths.

```elixir
# ✅ ALWAYS test edge cases
describe "validate_ttl/1" do
  test "accepts minimum TTL (0)" do
    assert {:ok, 0} = RecordValidator.validate_ttl(0)
  end

  test "accepts maximum TTL (2147483647)" do
    assert {:ok, 2_147_483_647} = RecordValidator.validate_ttl(2_147_483_647)
  end

  test "rejects negative TTL" do
    assert {:error, _} = RecordValidator.validate_ttl(-1)
  end

  test "rejects TTL exceeding max" do
    assert {:error, _} = RecordValidator.validate_ttl(2_147_483_648)
  end
end
```

### 7. Always Test Concurrent Scenarios

Test optimistic locking and race conditions.

```elixir
# ✅ ALWAYS test concurrency
test "returns version_conflict when record was modified" do
  {:ok, pid} = Auth.start_link(name: "test.com", records: [])

  # Add record
  {:ok, record} = ZoneService.add_record(pid, %{name: "www", type: :a, rdata: "1.2.3.4"})

  # Simulate another user updating
  {:ok, _} = ZoneService.update_record(pid, "www", :a, %{rdata: "5.6.7.8"}, record.version)

  # Our update should fail with old version
  assert {:error, :version_conflict} =
    ZoneService.update_record(pid, "www", :a, %{rdata: "9.10.11.12"}, record.version)
end
```

---

## Code Quality

### 8. Always Use Typespecs

All public functions need typespecs for documentation and Dialyzer.

```elixir
# ✅ ALWAYS add typespecs
@type validation_error :: %{field: atom(), code: atom(), message: String.t()}
@type validation_result :: {:ok, map()} | {:error, [validation_error()]}

@spec validate_a(map()) :: validation_result()
def validate_a(params) do
  # ...
end
```

### 9. Always Document Public Functions

Include @doc with examples for all public API.

```elixir
# ✅ ALWAYS document
@doc """
Validate an MX record.

## Parameters
- `params` - Map with `:name`, `:priority`, `:target`, `:ttl`

## Examples

    iex> validate_mx(%{name: "@", priority: 10, target: "mail.example.com", ttl: 3600})
    {:ok, %{name: "", type: :mx, rdata: {10, "mail.example.com."}, ttl: 3600}}

    iex> validate_mx(%{name: "@", target: "mail.example.com"})
    {:error, [%{field: :priority, code: :required, message: "Priority is required"}]}
"""
@spec validate_mx(map()) :: validation_result()
def validate_mx(params), do: # ...
```

### 10. Always Return Structured Errors

Use consistent error formats for UI consumption.

```elixir
# ✅ ALWAYS use structured errors
{:error, [
  %{
    field: :rdata,           # Which field has the error
    code: :invalid_ipv4,     # Machine-readable code
    message: "Invalid IPv4 address format"  # Human-readable message
  }
]}
```

---

## Architecture

### 11. Always Separate Validation from Storage

Pure functions for validation, side effects in service layer.

```elixir
# ✅ ALWAYS separate concerns
# validation.ex - Pure functions
defmodule RecordValidator do
  def validate_a(params) do
    # No side effects, just validation
  end
end

# service.ex - Orchestration with side effects
defmodule ZoneService do
  def add_record(zone_pid, params) do
    with {:ok, valid} <- RecordValidator.validate(params.type, params),
         :ok <- Auth.add_record(zone_pid, valid) do
      # Side effect: publish event
      broadcast(zone_name, {:record_added, valid})
      {:ok, valid}
    end
  end
end
```

### 12. Always Publish Events for Zone Changes

Enable real-time UI updates via PubSub.

```elixir
# ✅ ALWAYS publish events
def add_record(zone_pid, record) do
  zone_name = Auth.get_name(zone_pid)

  :ok = Auth.add_record(zone_pid, record)

  # Publish for subscribers
  Phoenix.PubSub.broadcast(
    YellowDog.Console.PubSub,
    "zone:#{zone_name}",
    {:record_added, record}
  )

  {:ok, record}
end
```

### 13. Always Handle PubSub Events in LiveView

Keep UI synchronized with zone changes.

```elixir
# ✅ ALWAYS subscribe and handle
def mount(params, _session, socket) do
  zone_name = params["zone_name"]

  if connected?(socket) do
    Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "zone:#{zone_name}")
  end

  {:ok, assign(socket, zone_name: zone_name)}
end

def handle_info({:record_added, record}, socket) do
  {:noreply, stream_insert(socket, :records, record)}
end

def handle_info({:record_updated, _old, new}, socket) do
  {:noreply, stream_insert(socket, :records, new)}
end

def handle_info({:record_deleted, record}, socket) do
  {:noreply, stream_delete(socket, :records, record)}
end
```

---

## User Experience

### 14. Always Provide Clear Error Messages

Errors should tell users what's wrong and how to fix it.

```elixir
# ✅ ALWAYS give actionable messages
def error_message(:cname_conflict) do
  "Cannot create CNAME: another record already exists at this name. " <>
  "Remove the existing record first, or use a different name."
end

def error_message(:cname_at_apex) do
  "CNAME records cannot be created at the zone apex (@). " <>
  "Use ALIAS or A/AAAA records instead."
end

def error_message(:version_conflict) do
  "This record was modified by another user. " <>
  "Please refresh the page and try again."
end
```

### 15. Always Show Validation Feedback in Real-Time

Use LiveView's phx-change for immediate validation feedback.

```elixir
# ✅ ALWAYS validate on change
def handle_event("validate", %{"record" => params}, socket) do
  type = String.to_atom(params["type"])

  errors = case RecordValidator.validate(type, params) do
    {:ok, _} -> %{}
    {:error, errs} -> format_errors(errs)
  end

  {:noreply, assign(socket, :errors, errors)}
end
```

### 16. Always Confirm Destructive Actions

Require confirmation for deletes and bulk operations.

```elixir
# ✅ ALWAYS confirm destructive actions
<button
  phx-click="delete"
  phx-value-id={record.id}
  data-confirm="Are you sure you want to delete this record? This action cannot be undone."
  class="btn btn-error btn-sm"
>
  Delete
</button>
```

---

## Persistence

### 17. Always Mark Zone Dirty on Changes

Track unsaved changes for save prompts and auto-save.

```elixir
# ✅ ALWAYS track dirty state
def handle_call({:add_record, record}, _from, state) do
  :ets.insert(state.table, {key, record})
  {:reply, :ok, %{state | dirty: true}}  # Mark dirty
end
```

### 18. Always Save Before Shutdown

Graceful shutdown should persist unsaved changes.

```elixir
# ✅ ALWAYS save on shutdown
def terminate(reason, state) do
  if state.dirty do
    case do_save(state) do
      :ok ->
        Logger.info("Zone #{state.name} saved on shutdown")
      {:error, reason} ->
        Logger.error("Failed to save zone #{state.name}: #{reason}")
    end
  end

  :ets.delete(state.table)
  :ok
end
```

---

## Summary Table

| # | Practice | Purpose |
|---|----------|---------|
| 1 | Validate before storage | Data integrity |
| 2 | Optimistic locking | Prevent lost updates |
| 3 | Normalize names | Consistent lookups |
| 4 | Check zone rules | Prevent invalid states |
| 5 | Test validation | Correctness |
| 6 | Test edge cases | Robustness |
| 7 | Test concurrency | Race condition safety |
| 8 | Add typespecs | Documentation, Dialyzer |
| 9 | Document functions | Maintainability |
| 10 | Structured errors | Consistent error handling |
| 11 | Separate validation | Clean architecture |
| 12 | Publish events | Real-time sync |
| 13 | Handle events | UI consistency |
| 14 | Clear error messages | User experience |
| 15 | Real-time feedback | Responsive UI |
| 16 | Confirm destructive | Prevent accidents |
| 17 | Track dirty state | Data persistence |
| 18 | Save on shutdown | No data loss |
