# DNS Zones Menu Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make DNS zones a first-class console area with the visible hierarchy `Zones -> Resource Records`, backed by persisted zone UUIDs.

**Architecture:** Store owns zone identity. Every zone metadata record gets a generated UUID in `YellowDog.Store.Zone`; old records receive UUIDs through lazy backfill when zones are listed. The console `Zones` page manages only default-view zones in this phase and does not expose view selection. Existing view-nested zone routes are removed, so old `/server/dns/views/:view_name/zones...` URLs naturally 404. Existing `Views` CRUD remains, but view list UI no longer shows zone or query runtime columns.

**Tech Stack:** Elixir 1.18, Phoenix 1.8, Phoenix LiveView 1.0, YellowDog umbrella, YellowDog.Store, YellowDogConsole LiveViews, Duskmoon/PhoenixDuskmoon UI components.

## Global Constraints

- Do not add dependencies for UUID generation; use `:crypto.strong_rand_bytes/1` and standard Elixir formatting.
- Store owns `zone.id`; console code must consume the ID and must not generate or synthesize zone IDs.
- Assign UUIDs to all zones persisted through `YellowDog.Store.Zone`. Today that means auth, forward, and stub; any future persisted zone type must follow the same `id` contract.
- Lazy backfill must preserve existing zone key semantics: Store keys remain `dns:view:{view_name}:zone:{zone_name}`.
- This phase is default-view-only in the new Zones UI. Do not add `?view=...`, view dropdowns, or non-default view management.
- Remove old view-nested zone routes instead of aliasing or redirecting them.
- Only auth zones have resource-record pages.
- Existing duplicate-name checks within the same view remain unchanged; UUID routing does not permit duplicate zone names in the default view.
- The zones table must not show UUID as a visible column.
- Keep `DNS > Views` in the sidebar, and keep view CRUD available.
- Remove zone count, query count, and links to zones from the Views list.
- DNS overview may show total zone count, but must not show views or per-view runtime information.
- Do not modify unrelated user changes in `config/config.exs` or `config/runtime.exs`.

---

## File Structure

- `apps/yellow_dog_store/lib/yellow_dog/store/zone.ex`
  - Generate UUIDs on zone creation.
  - Lazily backfill missing UUIDs during zone listing.
  - Add `get_zone_by_id/1`.
- `apps/yellow_dog_store/test/yellow_dog/store/zone_test.exs`
  - Cover generated IDs, lazy backfill, and ID lookup.
- `apps/yellow_dog_console/lib/yellow_dog/console/router.ex`
  - Add canonical `/server/dns/zones...` routes.
  - Remove old `/server/dns/views/:view_name/zones...` routes.
- `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/zone_live/index.ex`
  - Load default-view zones from Store so rows include `id`.
  - Resolve edit/delete targets by Store UUID.
- `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/zone_live/index.html.heex`
  - Render canonical zone links by UUID.
  - Remove default-view wording from page copy.
- `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/index.ex`
  - Resolve `zone_id` through Store and allow records only for default-view auth zones.
- `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/index.html.heex`
  - Render record action links with `zone_id`.
- `apps/yellow_dog_console/lib/yellow_dog/console/components/sidebar.ex`
  - Add `DNS > Zones` and keep `DNS > Views`.
- `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/view_live/index.html.heex`
  - Keep view CRUD, remove zone/query columns and zone links.
- `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/index.html.heex`
  - Show service-level total zones but remove view summary/runtime sections.
- `apps/yellow_dog_console/test/yellow_dog/console/live/dns_live_test.exs`
  - Move zone and record tests to canonical routes.
  - Remove tests asserting old view-nested zone routes mount.
- `apps/yellow_dog_console/test/yellow_dog/console/live/service_pages_live_test.exs`
  - Cover sidebar `Zones` and `Views` entries.

---

### Task 1: Add Store Zone UUID Tests

**Files:**
- Modify: `apps/yellow_dog_store/test/yellow_dog/store/zone_test.exs`

**Interfaces:**
- Consumes: existing `YellowDog.Store.Zone` create/list/get APIs.
- Produces: failing tests for `zone.id`, lazy backfill, and `Zone.get_zone_by_id/1`.

- [ ] **Step 1: Add UUID test helper**

Add near the top of `YellowDog.Store.ZoneTest`, after `@test_soa`:

```elixir
  defp assert_uuid(value) do
    assert is_binary(value)
    assert value =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    value
  end
```

- [ ] **Step 2: Add create tests for all Store-created zone types**

Add these tests in the existing create describes:

```elixir
    test "creates auth zone with generated UUID" do
      assert :ok = Zone.create_zone(@view, "test-id-auth.example.com", @test_soa)

      assert {:ok, zone} = Zone.get_zone(@view, "test-id-auth.example.com")
      assert_uuid(zone.id)
    end
```

```elixir
    test "creates forward zone with generated UUID" do
      assert :ok =
               Zone.create_forward_zone(@view, "test-id-forward.example.com", [
                 %{ip: "10.0.0.1", port: 53}
               ])

      assert {:ok, zone} = Zone.get_zone(@view, "test-id-forward.example.com")
      assert_uuid(zone.id)
    end
```

```elixir
    test "creates stub zone with generated UUID" do
      assert :ok =
               Zone.create_stub_zone(@view, "test-id-stub.example.com", [
                 %{ip: "10.0.0.2", port: 53}
               ])

      assert {:ok, zone} = Zone.get_zone(@view, "test-id-stub.example.com")
      assert_uuid(zone.id)
    end
```

- [ ] **Step 3: Add lookup and lazy-backfill tests**

Add this new describe block before RRset tests:

```elixir
  describe "zone UUID lookup and backfill" do
    test "get_zone_by_id/1 returns zone metadata with view_name" do
      assert :ok = Zone.create_zone(@view, "lookup-id.example.com", @test_soa)
      assert {:ok, created} = Zone.get_zone(@view, "lookup-id.example.com")

      assert {:ok, found} = Zone.get_zone_by_id(created.id)
      assert found.id == created.id
      assert found.view_name == @view
      assert found.origin == "lookup-id.example.com"
      assert found.zone_type == :auth
    end

    test "get_zone_by_id/1 returns not_found for missing id" do
      assert {:error, :not_found} =
               Zone.get_zone_by_id("00000000-0000-4000-8000-000000000000")
    end

    test "list_zones_for_view/1 lazily backfills missing id" do
      key = YellowDog.Store.Key.zone(@view, "legacy-no-id.example.com")
      now = System.system_time(:second)

      legacy_zone = %{
        zone_type: :auth,
        origin: "legacy-no-id.example.com",
        soa: @test_soa,
        default_ttl: 3600,
        authoritative: true,
        allow_dynamic_update: false,
        serial_strategy: :date_serial,
        cloud_mirror: nil,
        created_at: now,
        updated_at: now
      }

      assert :ok = YellowDog.Store.Backend.active().put_if(key, legacy_zone, expected: nil)

      assert {:ok, zones} = Zone.list_zones_for_view(@view)
      assert zone = Enum.find(zones, &(&1.origin == "legacy-no-id.example.com"))
      assert_uuid(zone.id)

      assert {:ok, persisted} = Zone.get_zone(@view, "legacy-no-id.example.com")
      assert persisted.id == zone.id
    end
  end
```

- [ ] **Step 4: Run Store tests and confirm failures**

Run from the umbrella root:

```bash
direnv exec . mix cmd --app yellow_dog_store mix test test/yellow_dog/store/zone_test.exs
```

Expected: failures mention missing `id` and undefined or missing `Zone.get_zone_by_id/1`.

- [ ] **Step 5: Commit failing tests**

```bash
git add apps/yellow_dog_store/test/yellow_dog/store/zone_test.exs
git commit -m "test(store): cover dns zone uuid identity"
```

---

### Task 2: Implement Store Zone UUIDs

**Files:**
- Modify: `apps/yellow_dog_store/lib/yellow_dog/store/zone.ex`
- Test: `apps/yellow_dog_store/test/yellow_dog/store/zone_test.exs`

**Interfaces:**
- Consumes: failing tests from Task 1.
- Produces:
  - `Zone.get_zone_by_id(id) :: {:ok, map()} | {:error, :not_found | term()}`
  - `id` on newly created auth, forward, and stub zones.
  - lazy ID backfill from `list_zones/0` and `list_zones_for_view/1`.

- [ ] **Step 1: Add Bitwise import and UUID type**

In `apps/yellow_dog_store/lib/yellow_dog/store/zone.ex`, add after aliases:

```elixir
  import Bitwise, only: [&&&: 2, |||: 2]
```

Add near the existing type definitions:

```elixir
  @type zone_id :: String.t()
```

- [ ] **Step 2: Write UUID on create**

In each zone metadata `value` map in `create_zone/4`, `create_forward_zone/4`, and `create_stub_zone/4`, add:

```elixir
      id: generate_uuid(),
```

The field should be alongside `zone_type` and `origin`, before timestamps.

- [ ] **Step 3: Add `get_zone_by_id/1`**

Add after `get_zone/2`:

```elixir
  @doc """
  Get zone metadata by persisted UUID.

  This scans existing zone metadata records. Zone counts are expected to be
  small; a secondary index can be added later if this becomes hot.
  """
  @spec get_zone_by_id(zone_id()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_zone_by_id(id) when is_binary(id) do
    case list_zones() do
      {:ok, zones} ->
        case Enum.find(zones, &(&1[:id] == id)) do
          nil -> {:error, :not_found}
          zone -> {:ok, zone}
        end

      {:error, _} = error ->
        error
    end
  end
```

- [ ] **Step 4: Backfill missing IDs during listing**

Replace the `Enum.map` in `list_zones/0` with:

```elixir
          |> Enum.map(fn {key, value} ->
            view_name = extract_view_name_from_key(key)
            ensure_zone_id(key, Map.put(value, :view_name, view_name))
          end)
```

Replace the `Enum.map` in `list_zones_for_view/1` with:

```elixir
          |> Enum.map(fn {key, value} ->
            ensure_zone_id(key, Map.put(value, :view_name, view_name))
          end)
```

Add these private helpers near `extract_view_name_from_key/1`:

```elixir
  defp ensure_zone_id(_key, %{id: id} = zone) when is_binary(id) and id != "", do: zone

  defp ensure_zone_id(key, zone) do
    id = generate_uuid()
    now = System.system_time(:second)

    persisted =
      zone
      |> Map.delete(:view_name)
      |> Map.put(:id, id)
      |> Map.put(:updated_at, now)

    case Backend.active().put_if(key, persisted, condition: fn old -> old == Map.delete(zone, :view_name) end) do
      :ok ->
        Map.put(zone, :id, id)

      {:error, :condition_failed} ->
        reload_zone_with_view_name(key, zone.view_name)

      {:error, _} ->
        Map.put(zone, :id, id)
    end
  end

  defp reload_zone_with_view_name(key, view_name) do
    case Backend.active().get(key, consistency: :strong) do
      {:ok, refreshed} -> ensure_zone_id(key, Map.put(refreshed, :view_name, view_name))
      {:error, _} -> %{id: generate_uuid(), view_name: view_name}
    end
  end
```

Add UUID generator near private helpers:

```elixir
  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c_versioned = (c &&& 0x0FFF) ||| 0x4000
    d_variant = (d &&& 0x3FFF) ||| 0x8000

    :io_lib.format(
      "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
      [a, b, c_versioned, d_variant, e]
    )
    |> to_string()
  end
```

- [ ] **Step 5: Run Store tests**

Run from the umbrella root:

```bash
direnv exec . mix cmd --app yellow_dog_store mix test test/yellow_dog/store/zone_test.exs
```

Expected: all tests in `zone_test.exs` pass.

- [ ] **Step 6: Commit Store implementation**

```bash
git add apps/yellow_dog_store/lib/yellow_dog/store/zone.ex apps/yellow_dog_store/test/yellow_dog/store/zone_test.exs
git commit -m "feat(store): add uuid identity to dns zones"
```

---

### Task 3: Add Canonical Default-Only Zone Routes

**Files:**
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/router.ex`
- Modify: `apps/yellow_dog_console/test/yellow_dog/console/live/dns_live_test.exs`

**Interfaces:**
- Consumes: Store zone UUIDs from Task 2.
- Produces canonical routes:
  - `/server/dns/zones`
  - `/server/dns/zones/new`
  - `/server/dns/zones/import`
  - `/server/dns/zones/:zone_id/edit`
  - `/server/dns/zones/:zone_id/records`
  - `/server/dns/zones/:zone_id/records/new`
  - `/server/dns/zones/:zone_id/records/bulk`
  - `/server/dns/zones/:zone_id/records/:rr_index/edit`

- [ ] **Step 1: Update route tests**

In `apps/yellow_dog_console/test/yellow_dog/console/live/dns_live_test.exs`, replace tests that call `/server/dns/views/default/zones` with `/server/dns/zones`, replace `/server/dns/views/default/zones/new` with `/server/dns/zones/new`, and replace `/server/dns/views/default/zones/import` with `/server/dns/zones/import`.

Remove any test that asserts the legacy view-nested zones route still mounts.

Add this route expectation inside the DNS Zones describe:

```elixir
    test "canonical zones route does not expose default view wording", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dns/zones")

      assert html =~ "DNS Zones"
      refute html =~ "Zones in view"
      refute html =~ "default view"
    end
```

- [ ] **Step 2: Update record route tests to use zone UUID**

Where record route tests need a concrete route, create a default-view auth zone through `YellowDog.Dns.ZoneController.start_zone/3`, then read its Store UUID:

```elixir
      zone_name = "records-route-#{System.unique_integer([:positive])}.example.com"
      start_supervised!({Registry, keys: :unique, name: YellowDog.Dns.ZoneRegistry})
      start_supervised!({YellowDog.Dns.ZoneController, []})

      assert {:ok, _pid} =
               YellowDog.Dns.ZoneController.start_zone(:auth, zone_name, view_name: "default")

      assert {:ok, store_zone} = YellowDog.Store.Zone.get_zone("default", zone_name)

      {:ok, _view, html} = live(conn, "/server/dns/zones/#{store_zone.id}/records")

      assert html =~ "Resource Records"
      assert html =~ zone_name
      assert html =~ ~s(href="/server/dns/zones/#{store_zone.id}/records/new")
      assert html =~ ~s(href="/server/dns/zones/#{store_zone.id}/records/bulk")
```

- [ ] **Step 3: Update router**

In `apps/yellow_dog_console/lib/yellow_dog/console/router.ex`, add canonical routes after `live "/dns", DnsLive.Index`:

```elixir
    live "/dns/zones", DnsLive.ZoneLive.Index, :index
    live "/dns/zones/new", DnsLive.ZoneLive.Index, :new
    live "/dns/zones/import", DnsLive.ZoneLive.Index, :import
    live "/dns/zones/:zone_id/edit", DnsLive.ZoneLive.Index, :edit
    live "/dns/zones/:zone_id/records", DnsLive.RrLive.Index, :index
    live "/dns/zones/:zone_id/records/new", DnsLive.RrLive.Index, :new
    live "/dns/zones/:zone_id/records/bulk", DnsLive.RrLive.Index, :bulk
    live "/dns/zones/:zone_id/records/:rr_index/edit", DnsLive.RrLive.Index, :edit
```

Delete these old routes:

```elixir
    live "/dns/views/:view_name/zones", DnsLive.ZoneLive.Index, :index
    live "/dns/views/:view_name/zones/new", DnsLive.ZoneLive.Index, :new
    live "/dns/views/:view_name/zones/import", DnsLive.ZoneLive.Index, :import
    live "/dns/views/:view_name/zones/:zone_type/:zone_name/edit", DnsLive.ZoneLive.Index, :edit
    live "/dns/views/:view_name/zones/:zone_type/:zone_name/records", DnsLive.RrLive.Index, :index
```

Also delete the legacy `records/new`, `records/bulk`, and `records/:rr_index/edit` route blocks under `/dns/views/:view_name/zones/...`.

- [ ] **Step 4: Run route tests and confirm remaining failures are LiveView implementation**

Run from the umbrella root:

```bash
direnv exec . mix cmd --app yellow_dog_console mix test test/yellow_dog/console/live/dns_live_test.exs
```

Expected: routing no longer fails for `/server/dns/zones`; tests may still fail because LiveViews still expect `view_name`, `zone_type`, and `zone_name` params.

- [ ] **Step 5: Commit route and test skeleton**

```bash
git add apps/yellow_dog_console/lib/yellow_dog/console/router.ex apps/yellow_dog_console/test/yellow_dog/console/live/dns_live_test.exs
git commit -m "test(console): move dns zones routes out of views"
```

---

### Task 4: Refactor ZoneLive to Default View and UUID Targets

**Files:**
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/zone_live/index.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/zone_live/index.html.heex`
- Test: `apps/yellow_dog_console/test/yellow_dog/console/live/dns_live_test.exs`

**Interfaces:**
- Consumes: `StoreZone.list_zones_for_view("default")`, `StoreZone.get_zone_by_id/1`.
- Produces default-view-only zone list, edit, import, create, and delete UI using UUIDs for existing zones.

- [ ] **Step 1: Add module default and path helpers**

In `ZoneLive.Index`, add:

```elixir
  @default_view_name "default"
```

Add helpers near private helpers:

```elixir
  defp zones_path, do: ~p"/server/dns/zones"
  defp new_zone_path, do: ~p"/server/dns/zones/new"
  defp import_zone_path, do: ~p"/server/dns/zones/import"
  defp edit_zone_path(zone_id), do: ~p"/server/dns/zones/#{zone_id}/edit"
  defp records_path(zone_id), do: ~p"/server/dns/zones/#{zone_id}/records"
```

- [ ] **Step 2: Make actions default-view-only**

Replace `apply_action/3` heads so `:index`, `:new`, and `:import` ignore view params and assign `view_name: @default_view_name`. Replace edit handling with ID lookup:

```elixir
  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "DNS Zones")
    |> assign(:view_name, @default_view_name)
    |> assign(:zone_form, nil)
    |> assign(:import_form, nil)
    |> assign(:editing_zone, nil)
    |> load_zones()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Zone")
    |> assign(:view_name, @default_view_name)
    |> assign(:editing_zone, nil)
    |> assign(:zone_form, to_form(default_zone_form_data()))
    |> assign(:form_errors, %{})
    |> load_cloud_dns_connectors()
    |> load_zones()
  end

  defp apply_action(socket, :edit, %{"zone_id" => zone_id}) do
    case get_default_zone_by_id(zone_id) do
      {:ok, zone} ->
        socket
        |> assign(:page_title, "Edit Zone - #{zone.origin}")
        |> assign(:view_name, @default_view_name)
        |> assign(:editing_zone, %{id: zone.id, name: zone.origin, type: zone.zone_type})
        |> assign(:zone_form, to_form(zone_config_form_data(zone_config_from_store(zone))))
        |> load_cloud_dns_connectors()
        |> load_zones()

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Zone not found")
        |> push_navigate(to: zones_path())
    end
  end

  defp apply_action(socket, :import, _params) do
    socket
    |> assign(:page_title, "Import Zone")
    |> assign(:view_name, @default_view_name)
    |> assign(:import_form, to_form(%{"zone_data" => "", "format" => "zone"}))
    |> load_zones()
  end
```

Add:

```elixir
  defp get_default_zone_by_id(zone_id) do
    case StoreZone.get_zone_by_id(zone_id) do
      {:ok, %{view_name: @default_view_name} = zone} -> {:ok, zone}
      {:ok, _zone} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp zone_config_from_store(zone) do
    %{
      name: zone.origin,
      type: zone.zone_type,
      upstreams: Map.get(zone, :forwarders, []),
      ns_records: Map.get(zone, :primaries, []),
      cloud_mirror: Map.get(zone, :cloud_mirror)
    }
  end
```

- [ ] **Step 3: Load default zones from Store with runtime stats**

Replace `load_zones/1` with:

```elixir
  defp load_zones(socket) do
    zones =
      case StoreZone.list_zones_for_view(@default_view_name) do
        {:ok, zones} ->
          Enum.map(zones, &zone_row_from_store/1)

        {:error, _reason} ->
          []
      end

    assign(socket, :zones, zones)
  end

  defp zone_row_from_store(zone) do
    zone_stats = get_zone_stats(@default_view_name, zone.zone_type, zone.origin)

    %{
      id: zone.id,
      type: zone.zone_type,
      name: zone.origin,
      cloud_mirror: Map.get(zone, :cloud_mirror)
    }
    |> Map.merge(zone_stats)
  end
```

Keep helper names like `filtered_zones/3`, `zone_type_label/1`, and `zone_type_badge/1`.

- [ ] **Step 4: Resolve delete by zone ID**

Change delete confirmation params to use `id`:

```elixir
  def handle_event("confirm_delete", %{"id" => zone_id}, socket) do
    {:noreply, assign(socket, :delete_confirm, %{id: zone_id})}
  end
```

In `delete_zone`, resolve the stored zone by ID, then call:

```elixir
ZoneController.stop_zone(@default_view_name, zone.zone_type, zone.origin)
```

Use `zones_path()` for all post-delete navigation.

- [ ] **Step 5: Update post-save and import navigation**

Replace every `push_navigate(to: ~p"/server/dns/views/#{view_name}/zones")` with:

```elixir
push_navigate(to: zones_path())
```

Keep `view_name = @default_view_name` when calling `ZoneController.start_zone/3`, `ViewManager.get_view/1`, `View.register_zone/3`, and Store metadata helpers.

- [ ] **Step 6: Update ZoneLive template**

In `index.html.heex`:

Change breadcrumb to:

```heex
    <.dm_breadcrumb>
      <:crumb to={~p"/server/dns"}>DNS</:crumb>
      <:crumb>Zones</:crumb>
    </.dm_breadcrumb>
```

Change header to:

```heex
        <h1 class="text-3xl font-bold">DNS Zones</h1>
        <p class="text-sm text-on-surface-variant">
          Manage DNS zones and authoritative records
        </p>
```

Change links:

```heex
patch={import_zone_path()}
patch={new_zone_path()}
navigate={records_path(zone.id)}
patch={edit_zone_path(zone.id)}
phx-value-id={zone.id}
```

Do not render a UUID column.

- [ ] **Step 7: Run DNS tests**

Run from the umbrella root:

```bash
direnv exec . mix cmd --app yellow_dog_console mix test test/yellow_dog/console/live/dns_live_test.exs
```

Expected: zone page tests pass except record-page tests that still depend on `RrLive`.

- [ ] **Step 8: Commit ZoneLive work**

```bash
git add apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/zone_live/index.ex apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/zone_live/index.html.heex apps/yellow_dog_console/test/yellow_dog/console/live/dns_live_test.exs
git commit -m "refactor(console): manage dns zones by uuid"
```

---

### Task 5: Refactor RrLive to Resolve Auth Zones by UUID

**Files:**
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/index.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/index.html.heex`
- Test: `apps/yellow_dog_console/test/yellow_dog/console/live/dns_live_test.exs`

**Interfaces:**
- Consumes: `StoreZone.get_zone_by_id/1`.
- Produces: `/server/dns/zones/:zone_id/records...` pages for default-view auth zones only.

- [ ] **Step 1: Add default-view and path helpers**

In `RrLive.Index`, alias Store:

```elixir
  alias YellowDog.Store.Zone, as: StoreZone
```

Add:

```elixir
  @default_view_name "default"
```

Replace `records_path/3` with:

```elixir
  defp zones_path, do: ~p"/server/dns/zones"
  defp records_path(zone_id), do: ~p"/server/dns/zones/#{zone_id}/records"
  defp new_record_path(zone_id), do: ~p"/server/dns/zones/#{zone_id}/records/new"
  defp bulk_records_path(zone_id), do: ~p"/server/dns/zones/#{zone_id}/records/bulk"
  defp edit_record_path(zone_id, rr_index), do: ~p"/server/dns/zones/#{zone_id}/records/#{rr_index}/edit"
```

- [ ] **Step 2: Resolve `zone_id` in actions**

Add helper:

```elixir
  defp get_default_auth_zone_by_id(zone_id) do
    case StoreZone.get_zone_by_id(zone_id) do
      {:ok, %{view_name: @default_view_name, zone_type: :auth} = zone} -> {:ok, zone}
      {:ok, _zone} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end
```

Replace `apply_action/3` heads to accept `%{"zone_id" => zone_id}`. For `:index`, use:

```elixir
  defp apply_action(socket, :index, %{"zone_id" => zone_id}) do
    case get_default_auth_zone_by_id(zone_id) do
      {:ok, zone} ->
        zone_pid = get_zone_pid(@default_view_name, :auth, zone.origin)

        socket
        |> assign(:page_title, "Records - #{zone.origin}")
        |> assign(:view_name, @default_view_name)
        |> assign(:zone_id, zone.id)
        |> assign(:zone_type, :auth)
        |> assign(:zone_name, zone.origin)
        |> assign(:zone_pid, zone_pid)
        |> assign(:bulk_form, nil)
        |> assign(:editing_rr, nil)
        |> load_records()

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Authoritative zone not found")
        |> push_navigate(to: zones_path())
    end
  end
```

Apply the same resolution pattern to `:new`, `:bulk`, and `:edit`. In `:edit`, keep the `rr_index` parsing logic.

- [ ] **Step 3: Update navigation after record actions**

Change all record redirects/cancels from `records_path(view_name, zone_type, zone_name)` to:

```elixir
records_path(socket.assigns.zone_id)
```

Where assigns are destructured, include `zone_id`.

- [ ] **Step 4: Update RrLive template links**

In `rr_live/index.html.heex`, change breadcrumb to:

```heex
    <.dm_breadcrumb>
      <:crumb to={~p"/server/dns"}>DNS</:crumb>
      <:crumb to={zones_path()}>Zones</:crumb>
      <:crumb>{@zone_name}</:crumb>
    </.dm_breadcrumb>
```

Change links:

```heex
patch={bulk_records_path(@zone_id)}
patch={new_record_path(@zone_id)}
patch={edit_record_path(@zone_id, idx)}
```

- [ ] **Step 5: Run DNS tests**

Run from the umbrella root:

```bash
direnv exec . mix cmd --app yellow_dog_console mix test test/yellow_dog/console/live/dns_live_test.exs
```

Expected: zone and record route tests pass.

- [ ] **Step 6: Commit RrLive work**

```bash
git add apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/index.ex apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/index.html.heex apps/yellow_dog_console/test/yellow_dog/console/live/dns_live_test.exs
git commit -m "refactor(console): route dns records by zone uuid"
```

---

### Task 6: Update DNS Sidebar, Views Page, and Overview

**Files:**
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/components/sidebar.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/view_live/index.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/index.html.heex`
- Modify: `apps/yellow_dog_console/test/yellow_dog/console/live/service_pages_live_test.exs`
- Modify: `apps/yellow_dog_console/test/yellow_dog/console/live/dns_live_test.exs`

**Interfaces:**
- Consumes: canonical routes from Tasks 3-5.
- Produces: visible menu model with `DNS > Zones` and `DNS > Views`, while Views stays configuration-only.

- [ ] **Step 1: Update sidebar**

In `sidebar.ex`, add this item between DNS Overview and Views:

```heex
    <li>
      <.link navigate="/server/dns/zones" class={active?(@current_path, "/server/dns/zones")}>
        <.dm_mdi name="folder-outline" class="w-5 h-5" />
        <span>Zones</span>
      </.link>
    </li>
```

Keep the existing `Views` menu item label and route as `/server/dns/views`.

- [ ] **Step 2: Update sidebar tests**

In `service_pages_live_test.exs`, add:

```elixir
    test "DNS sidebar exposes zones and views separately", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dns")

      assert has_element?(view, ~s(a[href="/server/dns/zones"]), "Zones")
      assert has_element?(view, ~s(a[href="/server/dns/views"]), "Views")
    end
```

Add to `@active_pages`:

```elixir
      {"/server/dns/zones", "Zones"},
```

- [ ] **Step 3: Remove view runtime columns**

In `view_live/index.html.heex`, change the table headers from:

```heex
                      <th scope="col">Name</th>
                      <th scope="col">Status</th>
                      <th scope="col">Priority</th>
                      <th scope="col">Recursion</th>
                      <th scope="col">ECS</th>
                      <th scope="col">Zones</th>
                      <th scope="col">Queries</th>
                      <th class="text-right">Actions</th>
```

to:

```heex
                      <th scope="col">Name</th>
                      <th scope="col">Status</th>
                      <th scope="col">Priority</th>
                      <th scope="col">Recursion</th>
                      <th scope="col">ECS</th>
                      <th class="text-right">Actions</th>
```

Change the view name cell to plain text, remove the Zones column, remove the Queries column, and remove the row action with `title="View Zones"`.

- [ ] **Step 4: Add Views page assertion**

In `dns_live_test.exs`, inside `describe "DNS Views /dns/views" do`, add:

```elixir
    test "views list does not expose zone or query runtime columns", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dns/views")

      assert html =~ "DNS Views"
      refute html =~ "View Zones"
      refute html =~ ~r/<th[^>]*>\s*Zones\s*<\/th>/
      refute html =~ ~r/<th[^>]*>\s*Queries\s*<\/th>/
    end
```

- [ ] **Step 5: Remove view runtime sections from DNS overview**

In `dns_live/index.html.heex`, remove the `Views` stat card and remove the entire `Views Summary` table section. Keep the service-level `Total Zones` card.

Update Quick Actions to avoid view-management links:

```heex
    <.card title="Quick Actions">
      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <.link navigate={~p"/server/dns/zones"} class="btn btn-primary btn-lg gap-2">
          <.dm_mdi name="folder-outline" class="w-5 h-5" /> Manage Zones
        </.link>

        <.link navigate={~p"/server/dns/acl"} class="btn btn-secondary btn-lg gap-2">
          <.dm_mdi name="shield-check" class="w-5 h-5" /> Configure ACLs
        </.link>
      </div>
    </.card>
```

- [ ] **Step 6: Run console tests**

Run from the umbrella root:

```bash
direnv exec . mix cmd --app yellow_dog_console mix test test/yellow_dog/console/live/dns_live_test.exs test/yellow_dog/console/live/service_pages_live_test.exs
```

Expected: tests pass.

- [ ] **Step 7: Commit navigation and view cleanup**

```bash
git add apps/yellow_dog_console/lib/yellow_dog/console/components/sidebar.ex apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/view_live/index.html.heex apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/index.html.heex apps/yellow_dog_console/test/yellow_dog/console/live/service_pages_live_test.exs apps/yellow_dog_console/test/yellow_dog/console/live/dns_live_test.exs
git commit -m "refactor(console): separate zones from dns views"
```

---

### Task 7: Final Verification and Cleanup

**Files:**
- Verify all files changed in Tasks 1-6.

**Interfaces:**
- Consumes: Store UUID identity and console route refactor.
- Produces: formatted, compiling, scoped-tested implementation.

- [ ] **Step 1: Search for removed route shape**

Run from the umbrella root:

```bash
rg -n "/server/dns/views/.*/zones|views/#\\{|View Zones|zones/:zone_type|zone_type/:zone_name" apps/yellow_dog_console/lib apps/yellow_dog_console/test
```

Expected: no visible template links or tests remain for old view-nested zone routes. The router should not contain `/dns/views/:view_name/zones`.

- [ ] **Step 2: Search for forbidden view query shape**

Run from the umbrella root:

```bash
rg -n "\\?view=|view_name_from_params|view query|default view" apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live apps/yellow_dog_console/test/yellow_dog/console/live/dns_live_test.exs
```

Expected: no `?view=` route design remains in DNS zone/record UI.

- [ ] **Step 3: Format changed files**

Run from the umbrella root:

```bash
direnv exec . mix format apps/yellow_dog_store/lib/yellow_dog/store/zone.ex apps/yellow_dog_store/test/yellow_dog/store/zone_test.exs apps/yellow_dog_console/lib/yellow_dog/console/router.ex apps/yellow_dog_console/lib/yellow_dog/console/components/sidebar.ex apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/index.html.heex apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/view_live/index.html.heex apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/zone_live/index.ex apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/zone_live/index.html.heex apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/index.ex apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/index.html.heex apps/yellow_dog_console/test/yellow_dog/console/live/dns_live_test.exs apps/yellow_dog_console/test/yellow_dog/console/live/service_pages_live_test.exs
```

Expected: command exits 0.

- [ ] **Step 4: Run scoped tests**

Run from the umbrella root:

```bash
direnv exec . mix cmd --app yellow_dog_store mix test test/yellow_dog/store/zone_test.exs
direnv exec . mix cmd --app yellow_dog_console mix test test/yellow_dog/console/live/dns_live_test.exs test/yellow_dog/console/live/service_pages_live_test.exs
```

Expected: all scoped tests pass.

- [ ] **Step 5: Run compile check**

Run from the umbrella root:

```bash
direnv exec . mix compile --warnings-as-errors
```

Expected: compilation succeeds with no warnings.

- [ ] **Step 6: Check git status**

Run from the umbrella root:

```bash
git status --short
```

Expected: only files touched by this plan plus pre-existing user changes are listed. Do not stage pre-existing changes in `config/config.exs` or `config/runtime.exs` unless the user explicitly asks.

- [ ] **Step 7: Commit final formatting if needed**

If formatting changed files after the previous task commits, commit only those plan-scope files:

```bash
git add apps/yellow_dog_store/lib/yellow_dog/store/zone.ex apps/yellow_dog_store/test/yellow_dog/store/zone_test.exs apps/yellow_dog_console/lib/yellow_dog/console/router.ex apps/yellow_dog_console/lib/yellow_dog/console/components/sidebar.ex apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/index.html.heex apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/view_live/index.html.heex apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/zone_live/index.ex apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/zone_live/index.html.heex apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/index.ex apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/index.html.heex apps/yellow_dog_console/test/yellow_dog/console/live/dns_live_test.exs apps/yellow_dog_console/test/yellow_dog/console/live/service_pages_live_test.exs
git commit -m "chore(console): format dns zones uuid refactor"
```

If formatting made no changes, skip this commit.

---

## Self-Review

- Spec coverage: The plan now includes Store-owned UUIDs for all Store-persisted zone types, lazy backfill, `get_zone_by_id/1`, default-view-only Zones UI, UUID-based edit/delete/records routes, removal of view-nested zone routes, retained Views CRUD, removal of view zone/query columns, and DNS overview cleanup.
- Scope check: The plan touches Store zone metadata identity plus the console routes and DNS LiveViews needed to consume that identity. It does not change DNS runtime lookup semantics or allow duplicate zone names in the default view.
- Placeholder scan: The plan contains no placeholder sections or deferred implementation instructions inside tasks.
- Type consistency: `zone.id`, `zone.zone_type`, `zone.origin`, `zone.view_name`, `StoreZone.get_zone_by_id/1`, `zones_path/0`, `records_path/1`, and `edit_zone_path/1` are used consistently across tasks.
- Verification: The plan uses Store tests, DNS LiveView tests, sidebar tests, route-shape searches, formatting, and `mix compile --warnings-as-errors`.
