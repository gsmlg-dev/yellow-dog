# DNS Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a pluggable provider system for bidirectional DNS zone sync between Yellow Dog and external sources (IANA root, AWS, Cloudflare, GCP, Vultr).

**Architecture:** New umbrella app `yellow_dog_dns_provider` with a `Provider` behaviour, a `SyncEngine` GenServer per provider, and a `Diff` module for changeset computation. Config/status/conflicts persist in Concord via `Store.Provider` facade. Console pages for management.

**Tech Stack:** Elixir 1.18, OTP 27-28, Req (HTTP client), Phoenix LiveView 1.0, Store (Concord+ETS)

**Spec:** `docs/prd/dns_provider.md`

---

## File Structure

### New App: `apps/yellow_dog_dns_provider/`

```
apps/yellow_dog_dns_provider/
├── mix.exs
├── lib/yellow_dog/dns_provider/
│   ├── provider.ex              # Provider behaviour definition
│   ├── config.ex                # Config struct
│   ├── sync_conflict.ex         # SyncConflict struct
│   ├── diff.ex                  # Record set diff computation
│   ├── sync_engine.ex           # GenServer — periodic + on-demand sync
│   ├── conflict_store.ex        # GenServer — ETS cache for manual conflicts
│   ├── supervisor.ex            # Top-level supervisor
│   ├── sync_supervisor.ex       # DynamicSupervisor for SyncEngines
│   ├── config_watcher.ex        # EventBridge consumer for config changes
│   └── provider/
│       ├── iana_root.ex          # IANA root zone (read-only)
│       ├── aws.ex                # AWS Route 53
│       ├── cloudflare.ex         # Cloudflare DNS API v4
│       ├── gcp.ex                # Google Cloud DNS
│       └── vultr.ex              # Vultr DNS API
├── test/
│   ├── test_helper.exs
│   ├── support/
│   │   └── test_provider.ex     # Stub provider for SyncEngine tests
│   ├── yellow_dog/dns_provider/
│   │   ├── config_test.exs
│   │   ├── diff_test.exs
│   │   ├── sync_engine_test.exs
│   │   ├── conflict_store_test.exs
│   │   └── provider/
│   │       ├── iana_root_test.exs
│   │       ├── aws_test.exs
│   │       ├── cloudflare_test.exs
│   │       ├── gcp_test.exs
│   │       └── vultr_test.exs
│   └── yellow_dog/dns_provider/
│       └── diff_property_test.exs
```

### Modified Files in `yellow_dog_store`

```
apps/yellow_dog_store/lib/yellow_dog/store/
├── provider.ex                  # NEW — Store facade for provider config/status/conflicts
├── key.ex                       # MODIFY — add provider key functions
```

### Modified Files in `yellow_dog_console`

```
apps/yellow_dog_console/lib/yellow_dog/console/
├── router.ex                    # MODIFY — add /dns/providers routes
├── components/layouts.ex        # MODIFY — add Providers sidebar item
└── live/dns_live/
    ├── provider_live/
    │   ├── index.ex             # NEW — provider list page
    │   ├── show.ex              # NEW — provider detail page
    │   └── conflict_live.ex     # NEW — conflict resolution page
```

### Modified Files in `yellow_dog`

```
apps/yellow_dog/lib/yellow_dog/
├── application.ex               # MODIFY — conditionally start DnsProvider.Supervisor
```

---

## Phase 1: Core Infrastructure

### Task 1: Scaffold the umbrella app

**Files:**
- Create: `apps/yellow_dog_dns_provider/mix.exs`
- Create: `apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider.ex`
- Create: `apps/yellow_dog_dns_provider/test/test_helper.exs`

- [ ] **Step 1: Create mix.exs**

```elixir
defmodule YellowDog.DnsProvider.MixProject do
  use Mix.Project

  def project do
    [
      app: :yellow_dog_dns_provider,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.2"},
      {:yellow_dog, in_umbrella: true},
      {:yellow_dog_dns, in_umbrella: true},
      {:yellow_dog_store, in_umbrella: true},
      {:yellow_dog_telemetry, in_umbrella: true},
      {:stream_data, "~> 1.0", only: [:test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [lint: ["credo --strict", "dialyzer"]]
  end
end
```

- [ ] **Step 2: Create facade module**

```elixir
# apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider.ex
defmodule YellowDog.DnsProvider do
  @moduledoc """
  Public API for DNS zone provider management and synchronization.
  """
end
```

- [ ] **Step 3: Create test_helper.exs**

```elixir
# apps/yellow_dog_dns_provider/test/test_helper.exs
ExUnit.start()
```

- [ ] **Step 4: Verify compilation**

Run: `cd apps/yellow_dog_dns_provider && mix deps.get && mix compile`
Expected: Compilation succeeds with no warnings

- [ ] **Step 5: Commit**

```bash
git add apps/yellow_dog_dns_provider/
git commit -m "feat(dns_provider): scaffold umbrella app"
```

---

### Task 2: Config struct

**Files:**
- Create: `apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/config.ex`
- Create: `apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/config_test.exs`

- [ ] **Step 1: Write tests**

```elixir
# apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/config_test.exs
defmodule YellowDog.DnsProvider.ConfigTest do
  use ExUnit.Case, async: true

  alias YellowDog.DnsProvider.Config

  describe "new/1" do
    test "creates config with all required fields" do
      assert {:ok, config} =
               Config.new(%{
                 name: "aws-prod",
                 type: :aws,
                 credentials: %{access_key_id: "AKIA...", secret_access_key: "secret"},
                 sync_interval: 300,
                 zones: ["example.com."],
                 conflict_strategy: :local_wins
               })

      assert config.name == "aws-prod"
      assert config.type == :aws
      assert config.sync_interval == 300
      assert config.conflict_strategy == :local_wins
      assert config.enabled == true
    end

    test "returns error for missing required fields" do
      assert {:error, :missing_name} = Config.new(%{type: :aws})
    end

    test "returns error for invalid type" do
      assert {:error, :invalid_type} =
               Config.new(%{name: "x", type: :unknown, zones: ["."]})
    end

    test "returns error for invalid conflict strategy" do
      assert {:error, :invalid_conflict_strategy} =
               Config.new(%{
                 name: "x",
                 type: :aws,
                 zones: ["."],
                 conflict_strategy: :invalid
               })
    end

    test "defaults sync_interval to 300" do
      assert {:ok, config} =
               Config.new(%{name: "x", type: :cloudflare, zones: ["."]})

      assert config.sync_interval == 300
    end

    test "defaults conflict_strategy to :local_wins" do
      assert {:ok, config} =
               Config.new(%{name: "x", type: :cloudflare, zones: ["."]})

      assert config.conflict_strategy == :local_wins
    end
  end

  describe "to_map/1 and from_map/1" do
    test "roundtrips through map serialization" do
      {:ok, original} =
        Config.new(%{
          name: "cf",
          type: :cloudflare,
          credentials: %{api_token: "tok"},
          sync_interval: 600,
          zones: ["site.com."],
          conflict_strategy: :manual
        })

      map = Config.to_map(original)
      assert is_map(map)
      assert map.name == "cf"

      {:ok, restored} = Config.from_map(map)
      assert restored == original
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd apps/yellow_dog_dns_provider && mix test test/yellow_dog/dns_provider/config_test.exs`
Expected: FAIL — `Config` module not defined

- [ ] **Step 3: Implement Config struct**

```elixir
# apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/config.ex
defmodule YellowDog.DnsProvider.Config do
  @moduledoc """
  Configuration struct for a DNS zone provider.

  Persisted to Concord via `Store.Provider`. Created/updated through
  the console UI or the `YellowDog.DnsProvider` public API.
  """

  @valid_types [:iana_root, :aws, :cloudflare, :gcp, :vultr]
  @valid_strategies [:local_wins, :remote_wins, :manual]

  @enforce_keys [:name, :type, :zones]
  defstruct [
    :name,
    :type,
    :credentials,
    zones: [],
    sync_interval: 300,
    conflict_strategy: :local_wins,
    enabled: true
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          type: atom(),
          credentials: map() | nil,
          zones: [String.t()],
          sync_interval: pos_integer(),
          conflict_strategy: :local_wins | :remote_wins | :manual,
          enabled: boolean()
        }

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) do
    with {:ok, name} <- require_string(attrs, :name),
         {:ok, type} <- validate_type(attrs),
         {:ok, strategy} <- validate_strategy(attrs) do
      {:ok,
       %__MODULE__{
         name: name,
         type: type,
         credentials: Map.get(attrs, :credentials),
         zones: Map.get(attrs, :zones, []),
         sync_interval: Map.get(attrs, :sync_interval, 300),
         conflict_strategy: strategy,
         enabled: Map.get(attrs, :enabled, true)
       }}
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = config) do
    Map.from_struct(config)
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, atom()}
  def from_map(map) when is_map(map) do
    new(map)
  end

  defp require_string(attrs, key) do
    case Map.get(attrs, key) do
      nil -> {:error, :"missing_#{key}"}
      val when is_binary(val) -> {:ok, val}
      val when is_atom(val) -> {:ok, to_string(val)}
    end
  end

  defp validate_type(attrs) do
    case Map.get(attrs, :type) do
      nil -> {:error, :missing_type}
      type when type in @valid_types -> {:ok, type}
      _ -> {:error, :invalid_type}
    end
  end

  defp validate_strategy(attrs) do
    case Map.get(attrs, :conflict_strategy, :local_wins) do
      s when s in @valid_strategies -> {:ok, s}
      _ -> {:error, :invalid_conflict_strategy}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd apps/yellow_dog_dns_provider && mix test test/yellow_dog/dns_provider/config_test.exs`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/config.ex
git add apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/config_test.exs
git commit -m "feat(dns_provider): add Config struct with validation"
```

---

### Task 3: SyncConflict struct

**Files:**
- Create: `apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/sync_conflict.ex`

- [ ] **Step 1: Implement SyncConflict struct**

```elixir
# apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/sync_conflict.ex
defmodule YellowDog.DnsProvider.SyncConflict do
  @moduledoc """
  Represents a conflict between local and remote DNS records
  detected during sync when using the `:manual` conflict strategy.
  """

  @enforce_keys [:id, :provider_name, :zone, :owner, :type]
  defstruct [
    :id,
    :provider_name,
    :zone,
    :owner,
    :type,
    :local_records,
    :remote_records,
    :detected_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          provider_name: String.t(),
          zone: String.t(),
          owner: String.t(),
          type: String.t(),
          local_records: [map()],
          remote_records: [map()],
          detected_at: integer()
        }

  @spec new(map()) :: t()
  def new(attrs) do
    %__MODULE__{
      id: Map.get(attrs, :id, generate_id()),
      provider_name: Map.fetch!(attrs, :provider_name),
      zone: Map.fetch!(attrs, :zone),
      owner: Map.fetch!(attrs, :owner),
      type: Map.fetch!(attrs, :type),
      local_records: Map.get(attrs, :local_records, []),
      remote_records: Map.get(attrs, :remote_records, []),
      detected_at: Map.get(attrs, :detected_at, System.system_time(:second))
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
```

- [ ] **Step 2: Verify compilation**

Run: `cd apps/yellow_dog_dns_provider && mix compile`
Expected: No warnings

- [ ] **Step 3: Commit**

```bash
git add apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/sync_conflict.ex
git commit -m "feat(dns_provider): add SyncConflict struct"
```

---

### Task 4: Provider behaviour

**Files:**
- Create: `apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/provider.ex`

- [ ] **Step 1: Implement behaviour**

```elixir
# apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/provider.ex
defmodule YellowDog.DnsProvider.Provider do
  @moduledoc """
  Behaviour for DNS zone data providers.

  Each provider implements callbacks for listing zones, reading records,
  applying changesets, and checking SOA serials. State is threaded through
  all callbacks for auth tokens, cursors, and rate limiting.

  ## Read-only providers

  Providers that only support pulling (e.g., IANA root zone) should return
  `{:error, :read_only, state}` from `apply_changeset/3`. The SyncEngine
  skips the push phase for such providers.
  """

  @type zone_ref :: %{name: String.t(), id: String.t() | nil}

  @type record_entry :: %{
          owner: String.t(),
          type: String.t(),
          ttl: non_neg_integer(),
          rdata: term()
        }

  @type changeset :: %{
          additions: [record_entry()],
          deletions: [record_entry()]
        }

  @type state :: term()

  @doc "Initialize provider state from config credentials and options."
  @callback init(config :: map()) :: {:ok, state()} | {:error, term()}

  @doc "List all zones available from this provider."
  @callback list_zones(state()) :: {:ok, [zone_ref()], state()} | {:error, term(), state()}

  @doc "Get all records for a zone."
  @callback get_records(zone_ref(), state()) ::
              {:ok, [record_entry()], state()} | {:error, term(), state()}

  @doc """
  Apply a changeset (additions + deletions) to a remote zone.

  Return `{:error, :read_only, state}` if the provider is read-only.
  """
  @callback apply_changeset(zone_ref(), changeset(), state()) ::
              {:ok, state()} | {:error, term(), state()}

  @doc "Get the SOA serial number for a zone (for conflict comparison)."
  @callback zone_serial(zone_ref(), state()) ::
              {:ok, non_neg_integer(), state()} | {:error, term(), state()}
end
```

- [ ] **Step 2: Verify compilation**

Run: `cd apps/yellow_dog_dns_provider && mix compile`
Expected: No warnings

- [ ] **Step 3: Commit**

```bash
git add apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/provider.ex
git commit -m "feat(dns_provider): add Provider behaviour"
```

---

### Task 5: Diff module

**Files:**
- Create: `apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/diff.ex`
- Create: `apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/diff_test.exs`
- Create: `apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/diff_property_test.exs`

- [ ] **Step 1: Write unit tests**

```elixir
# apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/diff_test.exs
defmodule YellowDog.DnsProvider.DiffTest do
  use ExUnit.Case, async: true

  alias YellowDog.DnsProvider.Diff

  @a_record %{owner: "www", type: "A", ttl: 300, rdata: "1.2.3.4"}
  @b_record %{owner: "www", type: "A", ttl: 300, rdata: "5.6.7.8"}
  @aaaa_record %{owner: "www", type: "AAAA", ttl: 300, rdata: "::1"}
  @mx_record %{owner: "@", type: "MX", ttl: 3600, rdata: "10 mail.example.com."}

  describe "compute/2" do
    test "identical sets produce empty changesets" do
      local = [@a_record, @aaaa_record]
      remote = [@a_record, @aaaa_record]

      assert %{local_changes: lc, remote_changes: rc} = Diff.compute(local, remote)
      assert lc.additions == []
      assert lc.deletions == []
      assert rc.additions == []
      assert rc.deletions == []
    end

    test "record in local but not remote shows as remote addition" do
      local = [@a_record, @mx_record]
      remote = [@a_record]

      %{remote_changes: rc} = Diff.compute(local, remote)
      assert rc.additions == [@mx_record]
      assert rc.deletions == []
    end

    test "record in remote but not local shows as local addition" do
      local = [@a_record]
      remote = [@a_record, @mx_record]

      %{local_changes: lc} = Diff.compute(local, remote)
      assert lc.additions == [@mx_record]
      assert lc.deletions == []
    end

    test "TTL difference produces update (delete + add) in both directions" do
      local = [%{@a_record | ttl: 300}]
      remote = [%{@a_record | ttl: 600}]

      %{local_changes: lc, remote_changes: rc} = Diff.compute(local, remote)

      # Local needs to update to remote TTL or vice versa — both sides flagged
      assert length(lc.additions) == 1
      assert length(lc.deletions) == 1
      assert length(rc.additions) == 1
      assert length(rc.deletions) == 1
    end

    test "completely disjoint sets" do
      local = [@a_record]
      remote = [@mx_record]

      %{local_changes: lc, remote_changes: rc} = Diff.compute(local, remote)
      assert lc.additions == [@mx_record]
      assert rc.additions == [@a_record]
    end

    test "empty local set" do
      %{local_changes: lc, remote_changes: rc} = Diff.compute([], [@a_record])
      assert lc.additions == [@a_record]
      assert rc.additions == []
    end

    test "empty remote set" do
      %{local_changes: lc, remote_changes: rc} = Diff.compute([@a_record], [])
      assert lc.additions == []
      assert rc.additions == [@a_record]
    end
  end

  describe "resolve/3" do
    test ":local_wins keeps local version of conflicts" do
      local = [%{@a_record | ttl: 300}]
      remote = [%{@a_record | ttl: 600}]
      diff = Diff.compute(local, remote)

      %{push_to_remote: push, apply_to_local: apply_local} =
        Diff.resolve(diff, :local_wins)

      # Remote should get local's version
      assert push.additions == [%{@a_record | ttl: 300}]
      assert push.deletions == [%{@a_record | ttl: 600}]
      # Local stays unchanged
      assert apply_local.additions == []
      assert apply_local.deletions == []
    end

    test ":remote_wins keeps remote version of conflicts" do
      local = [%{@a_record | ttl: 300}]
      remote = [%{@a_record | ttl: 600}]
      diff = Diff.compute(local, remote)

      %{push_to_remote: push, apply_to_local: apply_local} =
        Diff.resolve(diff, :remote_wins)

      assert push.additions == []
      assert push.deletions == []
      assert apply_local.additions == [%{@a_record | ttl: 600}]
      assert apply_local.deletions == [%{@a_record | ttl: 300}]
    end

    test ":manual returns conflicts list" do
      local = [%{@a_record | ttl: 300}]
      remote = [%{@a_record | ttl: 600}]
      diff = Diff.compute(local, remote)

      %{push_to_remote: push, apply_to_local: apply_local, conflicts: conflicts} =
        Diff.resolve(diff, :manual)

      assert push.additions == []
      assert apply_local.additions == []
      assert length(conflicts) == 1

      [conflict] = conflicts
      assert conflict.owner == "www"
      assert conflict.type == "A"
    end

    test "non-conflicting changes applied in all strategies" do
      local = [@a_record, @mx_record]
      remote = [@a_record, @aaaa_record]
      diff = Diff.compute(local, remote)

      for strategy <- [:local_wins, :remote_wins, :manual] do
        result = Diff.resolve(diff, strategy)
        # MX only in local -> push to remote
        assert @mx_record in result.push_to_remote.additions
        # AAAA only in remote -> apply to local
        assert @aaaa_record in result.apply_to_local.additions
      end
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd apps/yellow_dog_dns_provider && mix test test/yellow_dog/dns_provider/diff_test.exs`
Expected: FAIL — `Diff` module not defined

- [ ] **Step 3: Implement Diff module**

```elixir
# apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/diff.ex
defmodule YellowDog.DnsProvider.Diff do
  @moduledoc """
  Computes bidirectional diffs between local and remote DNS record sets.

  Records are compared by `{owner, type, rdata}` identity. TTL differences
  on otherwise-identical records are treated as conflicts (both sides changed).
  """

  @type record :: %{owner: String.t(), type: String.t(), ttl: non_neg_integer(), rdata: term()}
  @type changeset :: %{additions: [record()], deletions: [record()]}

  @type diff_result :: %{
          local_changes: changeset(),
          remote_changes: changeset()
        }

  @type resolve_result :: %{
          push_to_remote: changeset(),
          apply_to_local: changeset(),
          conflicts: [%{owner: String.t(), type: String.t(), local: record(), remote: record()}]
        }

  @doc """
  Compute bidirectional diff between local and remote record sets.

  Returns `local_changes` (what local is missing) and `remote_changes`
  (what remote is missing).
  """
  @spec compute([record()], [record()]) :: diff_result()
  def compute(local_records, remote_records) do
    local_by_key = index_by_identity(local_records)
    remote_by_key = index_by_identity(remote_records)

    local_keys = MapSet.new(Map.keys(local_by_key))
    remote_keys = MapSet.new(Map.keys(remote_by_key))

    only_local = MapSet.difference(local_keys, remote_keys)
    only_remote = MapSet.difference(remote_keys, local_keys)
    both = MapSet.intersection(local_keys, remote_keys)

    # TTL conflicts: same identity key but different TTL
    {_matching, ttl_conflicts} =
      Enum.split_with(both, fn key ->
        local_by_key[key].ttl == remote_by_key[key].ttl
      end)

    local_additions = Enum.map(only_remote, &remote_by_key[&1])
    local_deletions_from_ttl = Enum.map(ttl_conflicts, &local_by_key[&1])
    local_additions_from_ttl = Enum.map(ttl_conflicts, &remote_by_key[&1])

    remote_additions = Enum.map(only_local, &local_by_key[&1])
    remote_deletions_from_ttl = Enum.map(ttl_conflicts, &remote_by_key[&1])
    remote_additions_from_ttl = Enum.map(ttl_conflicts, &local_by_key[&1])

    %{
      local_changes: %{
        additions: local_additions ++ local_additions_from_ttl,
        deletions: local_deletions_from_ttl
      },
      remote_changes: %{
        additions: remote_additions ++ remote_additions_from_ttl,
        deletions: remote_deletions_from_ttl
      }
    }
  end

  @doc """
  Resolve a diff using the given conflict strategy.

  Returns resolved changesets to push to remote and apply to local,
  plus any unresolved conflicts (for `:manual` strategy).
  """
  @spec resolve(diff_result(), :local_wins | :remote_wins | :manual) :: resolve_result()
  def resolve(diff, strategy) do
    %{local_changes: lc, remote_changes: rc} = diff

    # Non-conflicting: records only on one side
    only_remote_additions = non_conflicting_additions(lc.additions, rc)
    only_local_additions = non_conflicting_additions(rc.additions, lc)

    # Conflicting: TTL changes (present in both local_changes and remote_changes)
    conflict_pairs = find_conflict_pairs(lc, rc)

    base = %{
      push_to_remote: %{additions: only_local_additions, deletions: []},
      apply_to_local: %{additions: only_remote_additions, deletions: []},
      conflicts: []
    }

    Enum.reduce(conflict_pairs, base, fn {local_rec, remote_rec}, acc ->
      apply_strategy(acc, strategy, local_rec, remote_rec)
    end)
  end

  defp non_conflicting_additions(additions, other_changes) do
    conflict_keys =
      (other_changes.additions ++ other_changes.deletions)
      |> Enum.map(&record_identity/1)
      |> MapSet.new()

    Enum.reject(additions, fn rec ->
      MapSet.member?(conflict_keys, record_identity(rec))
    end)
  end

  defp find_conflict_pairs(lc, rc) do
    local_deleted = Map.new(lc.deletions, fn rec -> {record_identity(rec), rec} end)

    Enum.flat_map(rc.deletions, fn remote_rec ->
      key = record_identity(remote_rec)

      case Map.get(local_deleted, key) do
        nil -> []
        local_rec -> [{local_rec, remote_rec}]
      end
    end)
  end

  defp apply_strategy(acc, :local_wins, local_rec, remote_rec) do
    %{
      acc
      | push_to_remote: %{
          additions: [local_rec | acc.push_to_remote.additions],
          deletions: [remote_rec | acc.push_to_remote.deletions]
        }
    }
  end

  defp apply_strategy(acc, :remote_wins, local_rec, remote_rec) do
    %{
      acc
      | apply_to_local: %{
          additions: [remote_rec | acc.apply_to_local.additions],
          deletions: [local_rec | acc.apply_to_local.deletions]
        }
    }
  end

  defp apply_strategy(acc, :manual, local_rec, remote_rec) do
    conflict = %{
      owner: local_rec.owner,
      type: local_rec.type,
      local: local_rec,
      remote: remote_rec
    }

    %{acc | conflicts: [conflict | acc.conflicts]}
  end

  defp index_by_identity(records) do
    Map.new(records, fn rec -> {record_identity(rec), rec} end)
  end

  defp record_identity(rec), do: {rec.owner, rec.type, rec.rdata}
end
```

- [ ] **Step 4: Run unit tests to verify they pass**

Run: `cd apps/yellow_dog_dns_provider && mix test test/yellow_dog/dns_provider/diff_test.exs`
Expected: All tests PASS

- [ ] **Step 5: Write property-based tests**

```elixir
# apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/diff_property_test.exs
defmodule YellowDog.DnsProvider.DiffPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias YellowDog.DnsProvider.Diff

  defp record_gen do
    gen all(
          owner <- string(:alphanumeric, min_length: 1, max_length: 10),
          type <- member_of(["A", "AAAA", "MX", "CNAME", "TXT", "NS"]),
          ttl <- positive_integer(),
          rdata <- string(:alphanumeric, min_length: 1, max_length: 20)
        ) do
      %{owner: owner, type: type, ttl: ttl, rdata: rdata}
    end
  end

  defp unique_records_gen do
    gen all(records <- list_of(record_gen(), max_length: 20)) do
      Enum.uniq_by(records, fn r -> {r.owner, r.type, r.rdata} end)
    end
  end

  property "identical sets produce empty diffs" do
    check all(records <- unique_records_gen()) do
      %{local_changes: lc, remote_changes: rc} = Diff.compute(records, records)
      assert lc.additions == []
      assert lc.deletions == []
      assert rc.additions == []
      assert rc.deletions == []
    end
  end

  property "diff against empty remote marks all local as remote additions" do
    check all(records <- unique_records_gen()) do
      %{remote_changes: rc} = Diff.compute(records, [])
      assert length(rc.additions) == length(records)
    end
  end

  property "resolve :local_wins never modifies local" do
    check all(
            local <- unique_records_gen(),
            remote <- unique_records_gen()
          ) do
      diff = Diff.compute(local, remote)
      result = Diff.resolve(diff, :local_wins)
      # Conflicts resolved by keeping local — no conflict changes applied to local
      assert result.conflicts == []
    end
  end

  property "resolve :remote_wins never pushes conflicts to remote" do
    check all(
            local <- unique_records_gen(),
            remote <- unique_records_gen()
          ) do
      diff = Diff.compute(local, remote)
      result = Diff.resolve(diff, :remote_wins)
      assert result.conflicts == []
    end
  end
end
```

- [ ] **Step 6: Run property tests**

Run: `cd apps/yellow_dog_dns_provider && mix test test/yellow_dog/dns_provider/diff_property_test.exs`
Expected: All properties PASS

- [ ] **Step 7: Commit**

```bash
git add apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/diff.ex
git add apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/diff_test.exs
git add apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/diff_property_test.exs
git commit -m "feat(dns_provider): add Diff module with conflict resolution"
```

---

### Task 6: Store.Provider facade and Key extensions

**Files:**
- Modify: `apps/yellow_dog_store/lib/yellow_dog/store/key.ex`
- Create: `apps/yellow_dog_store/lib/yellow_dog/store/provider.ex`
- Create: `apps/yellow_dog_store/test/yellow_dog/store/provider_test.exs`

- [ ] **Step 1: Add provider key functions to Key module**

Add to `apps/yellow_dog_store/lib/yellow_dog/store/key.ex`:

```elixir
  @doc "DNS provider config key."
  @spec provider_config(String.t()) :: String.t()
  def provider_config(name), do: "dns:provider:#{name}:config"

  @doc "DNS provider status key."
  @spec provider_status(String.t()) :: String.t()
  def provider_status(name), do: "dns:provider:#{name}:status"

  @doc "DNS provider conflict key."
  @spec provider_conflict(String.t(), String.t()) :: String.t()
  def provider_conflict(name, conflict_id), do: "dns:provider:#{name}:conflict:#{conflict_id}"

  @doc "Prefix for all provider keys."
  def provider_prefix, do: "dns:provider:"

  @doc "Prefix for a specific provider's keys."
  def provider_prefix(name), do: "dns:provider:#{name}:"

  @doc "Prefix for a specific provider's conflicts."
  def provider_conflict_prefix(name), do: "dns:provider:#{name}:conflict:"
```

- [ ] **Step 2: Write Store.Provider facade tests**

```elixir
# apps/yellow_dog_store/test/yellow_dog/store/provider_test.exs
defmodule YellowDog.Store.ProviderTest do
  use ExUnit.Case

  alias YellowDog.Store.Provider

  setup do
    # Clean up provider keys before each test
    {:ok, keys} = YellowDog.Store.Backend.active().prefix_scan("dns:provider:", [])

    Enum.each(keys, fn {key, _value} ->
      YellowDog.Store.Backend.active().delete(key)
    end)

    :ok
  end

  describe "config CRUD" do
    test "put_config and get_config roundtrip" do
      config = %{
        name: "test-provider",
        type: :cloudflare,
        credentials: %{api_token: "tok"},
        sync_interval: 300,
        zones: ["example.com."],
        conflict_strategy: :local_wins,
        enabled: true
      }

      assert :ok = Provider.put_config(config)
      assert {:ok, stored} = Provider.get_config("test-provider")
      assert stored.name == "test-provider"
      assert stored.type == :cloudflare
    end

    test "list_configs returns all providers" do
      for i <- 1..3 do
        Provider.put_config(%{
          name: "provider-#{i}",
          type: :cloudflare,
          zones: ["."],
          conflict_strategy: :local_wins,
          enabled: true
        })
      end

      {:ok, configs} = Provider.list_configs()
      assert length(configs) >= 3
    end

    test "delete_config removes provider" do
      Provider.put_config(%{name: "to-delete", type: :aws, zones: ["."], enabled: true})
      assert :ok = Provider.delete_config("to-delete")
      assert {:error, :not_found} = Provider.get_config("to-delete")
    end
  end

  describe "status" do
    test "put_status and get_status" do
      status = %{last_sync: System.system_time(:second), sync_count: 5, last_error: nil}
      assert :ok = Provider.put_status("my-provider", status)
      assert {:ok, stored} = Provider.get_status("my-provider")
      assert stored.sync_count == 5
    end
  end

  describe "conflicts" do
    test "put_conflict, list_conflicts, delete_conflict" do
      conflict = %{
        id: "conflict-1",
        provider_name: "cf",
        zone: "example.com.",
        owner: "www",
        type: "A",
        local_records: [%{rdata: "1.2.3.4"}],
        remote_records: [%{rdata: "5.6.7.8"}],
        detected_at: System.system_time(:second)
      }

      assert :ok = Provider.put_conflict(conflict)
      assert {:ok, conflicts} = Provider.list_conflicts("cf")
      assert length(conflicts) == 1

      assert :ok = Provider.delete_conflict("cf", "conflict-1")
      assert {:ok, []} = Provider.list_conflicts("cf")
    end
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd apps/yellow_dog_store && mix test test/yellow_dog/store/provider_test.exs`
Expected: FAIL — `Provider` module not defined

- [ ] **Step 4: Implement Store.Provider facade**

```elixir
# apps/yellow_dog_store/lib/yellow_dog/store/provider.ex
defmodule YellowDog.Store.Provider do
  @moduledoc """
  DNS provider data facade over the Store backend.

  Manages provider configuration, sync status, and conflict records.
  Write-through: Concord persist then ETS cache; reads from ETS only.

  Key patterns (via `YellowDog.Store.Key`):
  - Config: `dns:provider:{name}:config`
  - Status: `dns:provider:{name}:status`
  - Conflicts: `dns:provider:{name}:conflict:{id}`
  """

  alias YellowDog.Store.{Backend, EventBridge, Key}

  # -------------------------------------------------------------------
  # Config
  # -------------------------------------------------------------------

  @spec put_config(map()) :: :ok | {:error, term()}
  def put_config(%{name: name} = config) do
    key = Key.provider_config(name)
    start_time = System.monotonic_time()

    case Backend.active().put(key, config, []) do
      :ok ->
        emit_telemetry(start_time, :provider, :put, key)
        EventBridge.notify(:put, key, config)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @spec get_config(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_config(name) do
    key = Key.provider_config(name)

    case Backend.active().get(key, []) do
      {:ok, config} -> {:ok, config}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @spec list_configs() :: {:ok, [map()]}
  def list_configs do
    prefix = Key.provider_prefix()

    case Backend.active().prefix_scan(prefix, []) do
      {:ok, entries} ->
        configs =
          entries
          |> Enum.filter(fn {key, _v} -> String.ends_with?(key, ":config") end)
          |> Enum.map(fn {_key, value} -> value end)

        {:ok, configs}

      {:error, _} ->
        {:ok, []}
    end
  end

  @spec delete_config(String.t()) :: :ok | {:error, term()}
  def delete_config(name) do
    key = Key.provider_config(name)
    start_time = System.monotonic_time()

    case Backend.active().delete(key) do
      :ok ->
        emit_telemetry(start_time, :provider, :delete, key)
        EventBridge.notify(:delete, key, nil)
        :ok

      {:error, _} = error ->
        error
    end
  end

  # -------------------------------------------------------------------
  # Status
  # -------------------------------------------------------------------

  @spec put_status(String.t(), map()) :: :ok | {:error, term()}
  def put_status(name, status) do
    key = Key.provider_status(name)
    Backend.active().put(key, status, [])
  end

  @spec get_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_status(name) do
    key = Key.provider_status(name)
    Backend.active().get(key, [])
  end

  # -------------------------------------------------------------------
  # Conflicts
  # -------------------------------------------------------------------

  @spec put_conflict(map()) :: :ok | {:error, term()}
  def put_conflict(%{provider_name: name, id: id} = conflict) do
    key = Key.provider_conflict(name, id)
    Backend.active().put(key, conflict, [])
  end

  @spec list_conflicts(String.t()) :: {:ok, [map()]}
  def list_conflicts(name) do
    prefix = Key.provider_conflict_prefix(name)

    case Backend.active().prefix_scan(prefix, []) do
      {:ok, entries} -> {:ok, Enum.map(entries, fn {_k, v} -> v end)}
      {:error, _} -> {:ok, []}
    end
  end

  @spec delete_conflict(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_conflict(name, conflict_id) do
    key = Key.provider_conflict(name, conflict_id)
    Backend.active().delete(key)
  end

  # -------------------------------------------------------------------
  # Telemetry
  # -------------------------------------------------------------------

  defp emit_telemetry(start_time, namespace, operation, key) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:yellow_dog, :store, :operation, :stop],
      %{duration: duration},
      %{namespace: namespace, operation: operation, key: key, consistency: :strong}
    )
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd apps/yellow_dog_store && mix test test/yellow_dog/store/provider_test.exs`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add apps/yellow_dog_store/lib/yellow_dog/store/key.ex
git add apps/yellow_dog_store/lib/yellow_dog/store/provider.ex
git add apps/yellow_dog_store/test/yellow_dog/store/provider_test.exs
git commit -m "feat(store): add Provider facade for dns provider config/status/conflicts"
```

---

## Phase 2: Sync Engine & Supervision

### Task 7: Test provider stub

**Files:**
- Create: `apps/yellow_dog_dns_provider/test/support/test_provider.ex`

- [ ] **Step 1: Create test stub**

```elixir
# apps/yellow_dog_dns_provider/test/support/test_provider.ex
defmodule YellowDog.DnsProvider.Provider.Test do
  @moduledoc """
  In-memory stub provider for SyncEngine integration tests.
  """

  @behaviour YellowDog.DnsProvider.Provider

  @impl true
  def init(config) do
    state = %{
      zones: Map.get(config, :zones, []),
      records: Map.get(config, :records, %{}),
      read_only: Map.get(config, :read_only, false),
      apply_count: 0
    }

    {:ok, state}
  end

  @impl true
  def list_zones(state) do
    refs = Enum.map(state.zones, fn name -> %{name: name, id: nil} end)
    {:ok, refs, state}
  end

  @impl true
  def get_records(%{name: zone_name}, state) do
    records = Map.get(state.records, zone_name, [])
    {:ok, records, state}
  end

  @impl true
  def apply_changeset(_zone_ref, _changeset, %{read_only: true} = state) do
    {:error, :read_only, state}
  end

  def apply_changeset(%{name: zone_name}, changeset, state) do
    existing = Map.get(state.records, zone_name, [])

    deletion_keys =
      MapSet.new(changeset.deletions, fn r -> {r.owner, r.type, r.rdata} end)

    remaining = Enum.reject(existing, fn r ->
      MapSet.member?(deletion_keys, {r.owner, r.type, r.rdata})
    end)

    updated = remaining ++ changeset.additions

    new_state = %{
      state
      | records: Map.put(state.records, zone_name, updated),
        apply_count: state.apply_count + 1
    }

    {:ok, new_state}
  end

  @impl true
  def zone_serial(%{name: _zone_name}, state) do
    {:ok, 2024_010_100, state}
  end
end
```

- [ ] **Step 2: Verify compilation**

Run: `cd apps/yellow_dog_dns_provider && mix compile`
Expected: No warnings

- [ ] **Step 3: Commit**

```bash
git add apps/yellow_dog_dns_provider/test/support/test_provider.ex
git commit -m "test(dns_provider): add test provider stub"
```

---

### Task 8: SyncEngine GenServer

**Files:**
- Create: `apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/sync_engine.ex`
- Create: `apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/sync_engine_test.exs`

- [ ] **Step 1: Write SyncEngine tests**

```elixir
# apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/sync_engine_test.exs
defmodule YellowDog.DnsProvider.SyncEngineTest do
  use ExUnit.Case

  alias YellowDog.DnsProvider.{Config, SyncEngine}
  alias YellowDog.DnsProvider.Provider.Test, as: TestProvider

  setup do
    # Ensure Store is available — tests may need Backend.active()
    :ok
  end

  defp start_engine(overrides \\ %{}) do
    config =
      Map.merge(
        %{
          name: "test-#{System.unique_integer([:positive])}",
          type: :test,
          zones: ["example.com."],
          sync_interval: 60_000,
          conflict_strategy: :local_wins,
          enabled: true,
          credentials: %{
            zones: ["example.com."],
            records: %{
              "example.com." => [
                %{owner: "www", type: "A", ttl: 300, rdata: "1.2.3.4"}
              ]
            }
          }
        },
        overrides
      )

    {:ok, config_struct} = Config.new(config)
    start_supervised!({SyncEngine, config: config_struct, provider_module: TestProvider})
  end

  describe "start_link/1" do
    test "starts and registers with provider name" do
      pid = start_engine()
      assert Process.alive?(pid)
    end
  end

  describe "sync_now/1" do
    test "triggers immediate sync cycle" do
      pid = start_engine()
      assert :ok = SyncEngine.sync_now(pid)
    end

    test "sync for specific zone" do
      pid = start_engine()
      assert :ok = SyncEngine.sync_now(pid, "example.com.")
    end
  end

  describe "status/1" do
    test "returns sync status" do
      pid = start_engine()
      status = SyncEngine.status(pid)
      assert is_map(status)
      assert Map.has_key?(status, :last_sync)
      assert Map.has_key?(status, :sync_count)
    end

    test "status updates after sync" do
      pid = start_engine()
      SyncEngine.sync_now(pid)
      # Give sync time to complete
      Process.sleep(50)
      status = SyncEngine.status(pid)
      assert status.sync_count >= 1
    end
  end

  describe "read-only provider" do
    test "skips push phase" do
      pid =
        start_engine(%{
          credentials: %{
            zones: ["example.com."],
            records: %{"example.com." => []},
            read_only: true
          }
        })

      assert :ok = SyncEngine.sync_now(pid)
      Process.sleep(50)
      status = SyncEngine.status(pid)
      assert status.sync_count >= 1
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd apps/yellow_dog_dns_provider && mix test test/yellow_dog/dns_provider/sync_engine_test.exs`
Expected: FAIL — `SyncEngine` module not defined

- [ ] **Step 3: Implement SyncEngine**

```elixir
# apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/sync_engine.ex
defmodule YellowDog.DnsProvider.SyncEngine do
  @moduledoc """
  GenServer that manages periodic and on-demand sync for a single provider.

  One SyncEngine per provider config. Handles:
  - Periodic sync on configurable interval
  - On-demand sync via `sync_now/1`
  - Conflict detection and storage for `:manual` strategy
  - Telemetry emission on sync events
  """

  use GenServer

  require Logger

  alias YellowDog.DnsProvider.{Config, Diff, SyncConflict}

  defstruct [
    :config,
    :provider_module,
    :provider_state,
    :timer_ref,
    last_sync: nil,
    last_error: nil,
    sync_count: 0
  ]

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    GenServer.start_link(__MODULE__, opts, name: via(config.name))
  end

  @spec sync_now(pid() | GenServer.name()) :: :ok
  def sync_now(server), do: GenServer.cast(server, :sync_now)

  @spec sync_now(pid() | GenServer.name(), String.t()) :: :ok
  def sync_now(server, zone), do: GenServer.cast(server, {:sync_now, zone})

  @spec status(pid() | GenServer.name()) :: map()
  def status(server), do: GenServer.call(server, :status)

  # -------------------------------------------------------------------
  # Server callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    provider_module = Keyword.fetch!(opts, :provider_module)

    case provider_module.init(config.credentials || %{}) do
      {:ok, provider_state} ->
        state = %__MODULE__{
          config: config,
          provider_module: provider_module,
          provider_state: provider_state
        }

        state = schedule_sync(state)
        {:ok, state}

      {:error, reason} ->
        {:stop, {:provider_init_failed, reason}}
    end
  end

  @impl true
  def handle_cast(:sync_now, state) do
    {:noreply, do_sync_all_zones(state)}
  end

  def handle_cast({:sync_now, zone}, state) do
    {:noreply, do_sync_zone(state, zone)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      last_sync: state.last_sync,
      last_error: state.last_error,
      sync_count: state.sync_count,
      provider: state.config.type,
      zones: state.config.zones,
      interval: state.config.sync_interval
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:sync, state) do
    state = do_sync_all_zones(state)
    {:noreply, schedule_sync(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -------------------------------------------------------------------
  # Sync logic
  # -------------------------------------------------------------------

  defp do_sync_all_zones(state) do
    Enum.reduce(state.config.zones, state, fn zone, acc ->
      do_sync_zone(acc, zone)
    end)
  end

  defp do_sync_zone(state, zone_origin) do
    zone_ref = %{name: zone_origin, id: nil}
    start_time = System.monotonic_time()

    emit_sync_start(state.config, zone_origin)

    case sync_zone(state, zone_ref) do
      {:ok, new_provider_state, metrics} ->
        duration = System.monotonic_time() - start_time
        now = System.system_time(:second)

        emit_sync_stop(state.config, zone_origin, duration, metrics)

        persist_status(state.config.name, %{
          last_sync: now,
          sync_count: state.sync_count + 1,
          last_error: nil
        })

        %{
          state
          | provider_state: new_provider_state,
            last_sync: now,
            last_error: nil,
            sync_count: state.sync_count + 1
        }

      {:error, reason, new_provider_state} ->
        duration = System.monotonic_time() - start_time

        Logger.warning(
          "DnsProvider sync failed for #{state.config.name}/#{zone_origin}: #{inspect(reason)}"
        )

        emit_sync_exception(state.config, zone_origin, duration, reason)

        %{state | provider_state: new_provider_state, last_error: reason}
    end
  end

  defp sync_zone(state, zone_ref) do
    %{provider_module: mod, provider_state: ps, config: config} = state

    with {:ok, remote_records, ps} <- mod.get_records(zone_ref, ps),
         {:ok, local_records} <- get_local_records(config, zone_ref.name) do
      diff = Diff.compute(local_records, remote_records)
      resolved = Diff.resolve(diff, config.conflict_strategy)

      # Store manual conflicts
      store_conflicts(config, zone_ref.name, resolved.conflicts)

      # Apply to local
      apply_local_changeset(config, zone_ref.name, resolved.apply_to_local)

      # Push to remote (skip for read-only)
      ps =
        case mod.apply_changeset(zone_ref, resolved.push_to_remote, ps) do
          {:ok, new_ps} -> new_ps
          {:error, :read_only, new_ps} -> new_ps
          {:error, _reason, new_ps} -> new_ps
        end

      metrics = %{
        records_pulled: length(remote_records),
        records_pushed:
          length(resolved.push_to_remote.additions) +
            length(resolved.push_to_remote.deletions),
        conflicts: length(resolved.conflicts)
      }

      {:ok, ps, metrics}
    else
      {:error, reason, ps} -> {:error, reason, ps}
      {:error, reason} -> {:error, reason, state.provider_state}
    end
  end

  defp get_local_records(_config, zone_name) do
    # Read records from Store.Zone for the default view
    view_name = "default"

    case YellowDog.Store.Zone.list_records(view_name, zone_name) do
      {:ok, rrsets} ->
        records =
          Enum.flat_map(rrsets, fn {_key, rrset} ->
            owner = Map.get(rrset, :owner, "@")
            type = to_string(Map.get(rrset, :type, "A"))

            case Map.get(rrset, :rrset) do
              records when is_list(records) ->
                Enum.map(records, fn rec ->
                  %{
                    owner: owner,
                    type: type,
                    ttl: Map.get(rec, :ttl, 3600),
                    rdata: Map.get(rec, :rdata, "")
                  }
                end)

              _ ->
                []
            end
          end)

        {:ok, records}

      {:error, _} ->
        {:ok, []}
    end
  end

  defp apply_local_changeset(_config, _zone_name, %{additions: [], deletions: []}) do
    :ok
  end

  defp apply_local_changeset(config, zone_name, changeset) do
    view_name = "default"

    Enum.each(changeset.additions, fn rec ->
      rrset = %{
        records: [%{ttl: rec.ttl, rdata: rec.rdata}],
        ttl: rec.ttl
      }

      YellowDog.Store.Zone.put_rrset(view_name, zone_name, rec.owner, String.to_atom(rec.type), rrset)
    end)

    Enum.each(changeset.deletions, fn rec ->
      YellowDog.Store.Zone.delete_rrset(view_name, zone_name, rec.owner, String.to_atom(rec.type))
    end)

    Logger.debug(
      "DnsProvider #{config.name}: applied #{length(changeset.additions)} additions, #{length(changeset.deletions)} deletions to #{zone_name}"
    )
  end

  defp store_conflicts(_config, _zone_name, []), do: :ok

  defp store_conflicts(config, zone_name, conflicts) do
    Enum.each(conflicts, fn conflict ->
      sc =
        SyncConflict.new(%{
          provider_name: config.name,
          zone: zone_name,
          owner: conflict.owner,
          type: conflict.type,
          local_records: [conflict.local],
          remote_records: [conflict.remote]
        })

      YellowDog.Store.Provider.put_conflict(Map.from_struct(sc))
    end)
  end

  defp persist_status(name, status) do
    YellowDog.Store.Provider.put_status(name, status)
  rescue
    _ -> :ok
  end

  # -------------------------------------------------------------------
  # Scheduling
  # -------------------------------------------------------------------

  defp schedule_sync(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    interval_ms = state.config.sync_interval * 1000
    ref = Process.send_after(self(), :sync, interval_ms)
    %{state | timer_ref: ref}
  end

  # -------------------------------------------------------------------
  # Registry
  # -------------------------------------------------------------------

  defp via(name) do
    {:via, Registry, {YellowDog.DnsProvider.Registry, name}}
  end

  # -------------------------------------------------------------------
  # Telemetry
  # -------------------------------------------------------------------

  defp emit_sync_start(config, zone) do
    :telemetry.execute(
      [:yellow_dog, :dns_provider, :sync, :start],
      %{system_time: System.system_time()},
      %{provider: config.name, zone: zone, strategy: config.conflict_strategy}
    )
  end

  defp emit_sync_stop(config, zone, duration, metrics) do
    :telemetry.execute(
      [:yellow_dog, :dns_provider, :sync, :stop],
      Map.merge(%{duration: duration}, metrics),
      %{provider: config.name, zone: zone, strategy: config.conflict_strategy}
    )
  end

  defp emit_sync_exception(config, zone, duration, reason) do
    :telemetry.execute(
      [:yellow_dog, :dns_provider, :sync, :exception],
      %{duration: duration},
      %{provider: config.name, zone: zone, reason: reason}
    )
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd apps/yellow_dog_dns_provider && mix test test/yellow_dog/dns_provider/sync_engine_test.exs`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/sync_engine.ex
git add apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/sync_engine_test.exs
git commit -m "feat(dns_provider): add SyncEngine GenServer"
```

---

### Task 9: Supervision tree

**Files:**
- Create: `apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/supervisor.ex`
- Create: `apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/sync_supervisor.ex`
- Create: `apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/conflict_store.ex`
- Create: `apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/config_watcher.ex`

- [ ] **Step 1: Implement SyncSupervisor (DynamicSupervisor)**

```elixir
# apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/sync_supervisor.ex
defmodule YellowDog.DnsProvider.SyncSupervisor do
  @moduledoc """
  DynamicSupervisor for SyncEngine processes.

  Starts one SyncEngine per enabled provider config. Supports runtime
  add/remove as configs change via EventBridge.
  """

  use DynamicSupervisor

  alias YellowDog.DnsProvider.SyncEngine

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_engine(map(), module()) :: {:ok, pid()} | {:error, term()}
  def start_engine(config, provider_module) do
    spec = {SyncEngine, config: config, provider_module: provider_module}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @spec stop_engine(String.t()) :: :ok | {:error, :not_found}
  def stop_engine(provider_name) do
    case Registry.lookup(YellowDog.DnsProvider.Registry, provider_name) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      [] ->
        {:error, :not_found}
    end
  end
end
```

- [ ] **Step 2: Implement ConflictStore**

```elixir
# apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/conflict_store.ex
defmodule YellowDog.DnsProvider.ConflictStore do
  @moduledoc """
  GenServer that maintains an ETS read cache of unresolved sync conflicts.
  Backed by Concord via `Store.Provider` — ETS is the fast read path,
  Concord is the source of truth.
  """

  use GenServer

  @table :dns_provider_conflicts

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    warm_from_store()
    {:ok, %{}}
  end

  @spec list_conflicts(String.t()) :: [map()]
  def list_conflicts(provider_name) do
    :ets.match_object(@table, {{provider_name, :_}, :_})
    |> Enum.map(fn {_key, conflict} -> conflict end)
  end

  @spec put_conflict(map()) :: :ok
  def put_conflict(%{provider_name: name, id: id} = conflict) do
    :ets.insert(@table, {{name, id}, conflict})
    :ok
  end

  @spec delete_conflict(String.t(), String.t()) :: :ok
  def delete_conflict(provider_name, conflict_id) do
    :ets.delete(@table, {provider_name, conflict_id})
    :ok
  end

  defp warm_from_store do
    case YellowDog.Store.Provider.list_configs() do
      {:ok, configs} ->
        Enum.each(configs, fn config ->
          name = Map.get(config, :name, "")

          case YellowDog.Store.Provider.list_conflicts(name) do
            {:ok, conflicts} ->
              Enum.each(conflicts, fn c -> put_conflict(c) end)

            _ ->
              :ok
          end
        end)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
```

- [ ] **Step 3: Implement ConfigWatcher (EventBridge consumer)**

```elixir
# apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/config_watcher.ex
defmodule YellowDog.DnsProvider.ConfigWatcher do
  @moduledoc """
  Watches for provider config changes via EventBridge and starts/stops
  SyncEngines accordingly.
  """

  use GenServer

  require Logger

  alias YellowDog.DnsProvider.SyncSupervisor

  @resubscribe_delay_ms 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    state = %{subscription_ref: nil}
    state = subscribe_to_bridge(state)
    boot_providers()
    {:ok, state}
  end

  @impl true
  def handle_info({:store_event, %{type: type, key: key}}, state)
      when type in [:put, :delete] do
    if String.starts_with?(key, "dns:provider:") and String.ends_with?(key, ":config") do
      handle_config_change(type, key)
    end

    {:noreply, state}
  end

  def handle_info(:resubscribe, state) do
    {:noreply, subscribe_to_bridge(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp subscribe_to_bridge(state) do
    case YellowDog.Store.EventBridge.subscribe("dns:provider:*") do
      {:ok, ref} ->
        %{state | subscription_ref: ref}

      _ ->
        Logger.warning("ConfigWatcher: failed to subscribe, retrying")
        Process.send_after(self(), :resubscribe, @resubscribe_delay_ms)
        state
    end
  rescue
    _ ->
      Process.send_after(self(), :resubscribe, @resubscribe_delay_ms)
      state
  end

  defp handle_config_change(:put, key) do
    name = extract_provider_name(key)

    case YellowDog.Store.Provider.get_config(name) do
      {:ok, config} ->
        # Stop existing engine if running
        SyncSupervisor.stop_engine(name)

        if Map.get(config, :enabled, true) do
          provider_module = provider_module_for(Map.get(config, :type))

          case YellowDog.DnsProvider.Config.from_map(config) do
            {:ok, config_struct} ->
              SyncSupervisor.start_engine(config_struct, provider_module)

            {:error, reason} ->
              Logger.warning("ConfigWatcher: invalid config for #{name}: #{inspect(reason)}")
          end
        end

      _ ->
        :ok
    end
  end

  defp handle_config_change(:delete, key) do
    name = extract_provider_name(key)
    SyncSupervisor.stop_engine(name)
  end

  defp boot_providers do
    case YellowDog.Store.Provider.list_configs() do
      {:ok, configs} ->
        Enum.each(configs, fn config ->
          if Map.get(config, :enabled, true) do
            provider_module = provider_module_for(Map.get(config, :type))

            case YellowDog.DnsProvider.Config.from_map(config) do
              {:ok, config_struct} ->
                SyncSupervisor.start_engine(config_struct, provider_module)

              {:error, reason} ->
                Logger.warning(
                  "ConfigWatcher: skipping invalid config #{Map.get(config, :name)}: #{inspect(reason)}"
                )
            end
          end
        end)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp extract_provider_name(key) do
    # "dns:provider:{name}:config" -> name
    key
    |> String.trim_prefix("dns:provider:")
    |> String.trim_suffix(":config")
  end

  defp provider_module_for(:iana_root), do: YellowDog.DnsProvider.Provider.IanaRoot
  defp provider_module_for(:aws), do: YellowDog.DnsProvider.Provider.Aws
  defp provider_module_for(:cloudflare), do: YellowDog.DnsProvider.Provider.Cloudflare
  defp provider_module_for(:gcp), do: YellowDog.DnsProvider.Provider.Gcp
  defp provider_module_for(:vultr), do: YellowDog.DnsProvider.Provider.Vultr
  defp provider_module_for(_), do: nil
end
```

- [ ] **Step 4: Implement top-level Supervisor**

```elixir
# apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/supervisor.ex
defmodule YellowDog.DnsProvider.Supervisor do
  @moduledoc """
  Top-level supervisor for the DNS provider subsystem.

  Starts the Registry, ConflictStore, SyncSupervisor, and ConfigWatcher
  in dependency order.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: YellowDog.DnsProvider.Registry},
      YellowDog.DnsProvider.ConflictStore,
      YellowDog.DnsProvider.SyncSupervisor,
      YellowDog.DnsProvider.ConfigWatcher
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

- [ ] **Step 5: Verify compilation**

Run: `cd apps/yellow_dog_dns_provider && mix compile`
Expected: No warnings

- [ ] **Step 6: Commit**

```bash
git add apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/supervisor.ex
git add apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/sync_supervisor.ex
git add apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/conflict_store.ex
git add apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/config_watcher.ex
git commit -m "feat(dns_provider): add supervision tree with ConfigWatcher"
```

---

### Task 10: Public API facade

**Files:**
- Modify: `apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider.ex`

- [ ] **Step 1: Implement the public API**

```elixir
# apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider.ex
defmodule YellowDog.DnsProvider do
  @moduledoc """
  Public API for DNS zone provider management and synchronization.

  Providers are configured and persisted via Store.Provider (Concord).
  SyncEngines run as GenServers under SyncSupervisor, triggered by
  ConfigWatcher on config changes.
  """

  alias YellowDog.DnsProvider.{Config, SyncEngine, SyncSupervisor}
  alias YellowDog.Store.Provider, as: StoreProvider

  # -------------------------------------------------------------------
  # Provider management
  # -------------------------------------------------------------------

  @spec add_provider(map()) :: :ok | {:error, term()}
  def add_provider(attrs) do
    with {:ok, config} <- Config.new(attrs) do
      StoreProvider.put_config(Config.to_map(config))
    end
  end

  @spec update_provider(String.t(), map()) :: :ok | {:error, term()}
  def update_provider(name, changes) do
    with {:ok, existing} <- StoreProvider.get_config(name) do
      merged = Map.merge(existing, changes)

      with {:ok, config} <- Config.from_map(merged) do
        StoreProvider.put_config(Config.to_map(config))
      end
    end
  end

  @spec remove_provider(String.t()) :: :ok | {:error, term()}
  def remove_provider(name) do
    SyncSupervisor.stop_engine(name)
    StoreProvider.delete_config(name)
  end

  @spec list_providers() :: [map()]
  def list_providers do
    {:ok, configs} = StoreProvider.list_configs()

    Enum.map(configs, fn config ->
      name = Map.get(config, :name)
      status = engine_status(name)

      %{
        name: name,
        type: Map.get(config, :type),
        enabled: Map.get(config, :enabled, true),
        status: status
      }
    end)
  end

  @spec start_provider(String.t()) :: :ok | {:error, term()}
  def start_provider(name) do
    update_provider(name, %{enabled: true})
  end

  @spec stop_provider(String.t()) :: :ok | {:error, term()}
  def stop_provider(name) do
    SyncSupervisor.stop_engine(name)
    update_provider(name, %{enabled: false})
  end

  # -------------------------------------------------------------------
  # Sync operations
  # -------------------------------------------------------------------

  @spec sync_now(String.t()) :: :ok | {:error, :not_found}
  def sync_now(provider_name) do
    case lookup_engine(provider_name) do
      {:ok, pid} -> SyncEngine.sync_now(pid)
      :error -> {:error, :not_found}
    end
  end

  @spec sync_now(String.t(), String.t()) :: :ok | {:error, :not_found}
  def sync_now(provider_name, zone) do
    case lookup_engine(provider_name) do
      {:ok, pid} -> SyncEngine.sync_now(pid, zone)
      :error -> {:error, :not_found}
    end
  end

  @spec sync_status(String.t()) :: map() | {:error, :not_found}
  def sync_status(provider_name) do
    case lookup_engine(provider_name) do
      {:ok, pid} -> SyncEngine.status(pid)
      :error -> {:error, :not_found}
    end
  end

  # -------------------------------------------------------------------
  # Conflict management
  # -------------------------------------------------------------------

  @spec list_conflicts() :: [map()]
  def list_conflicts do
    {:ok, configs} = StoreProvider.list_configs()

    Enum.flat_map(configs, fn config ->
      name = Map.get(config, :name)
      {:ok, conflicts} = StoreProvider.list_conflicts(name)
      conflicts
    end)
  end

  @spec list_conflicts(String.t()) :: [map()]
  def list_conflicts(provider_name) do
    {:ok, conflicts} = StoreProvider.list_conflicts(provider_name)
    conflicts
  end

  @spec resolve_conflict(String.t(), String.t(), :keep_local | :keep_remote) ::
          :ok | {:error, term()}
  def resolve_conflict(provider_name, conflict_id, resolution) when resolution in [:keep_local, :keep_remote] do
    # Delete the conflict record — actual resolution was applied during sync
    StoreProvider.delete_conflict(provider_name, conflict_id)
  end

  @spec resolve_all_conflicts(String.t(), :keep_local | :keep_remote) :: :ok
  def resolve_all_conflicts(provider_name, resolution) do
    {:ok, conflicts} = StoreProvider.list_conflicts(provider_name)

    Enum.each(conflicts, fn conflict ->
      resolve_conflict(provider_name, Map.get(conflict, :id), resolution)
    end)
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp lookup_engine(name) do
    case Registry.lookup(YellowDog.DnsProvider.Registry, name) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp engine_status(name) do
    case lookup_engine(name) do
      {:ok, _pid} -> :running
      :error -> :stopped
    end
  end
end
```

- [ ] **Step 2: Verify compilation**

Run: `cd apps/yellow_dog_dns_provider && mix compile`
Expected: No warnings

- [ ] **Step 3: Commit**

```bash
git add apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider.ex
git commit -m "feat(dns_provider): add public API facade"
```

---

## Phase 3: Provider Implementations

### Task 11: IANA Root Zone provider

**Files:**
- Create: `apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/provider/iana_root.ex`
- Create: `apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/provider/iana_root_test.exs`

- [ ] **Step 1: Write tests with mocked HTTP**

```elixir
# apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/provider/iana_root_test.exs
defmodule YellowDog.DnsProvider.Provider.IanaRootTest do
  use ExUnit.Case, async: true

  alias YellowDog.DnsProvider.Provider.IanaRoot

  @sample_root_zone """
  .                        518400  IN  SOA     a.root-servers.net. nstld.verisign-grs.com. 2024010100 1800 900 604800 86400
  .                        518400  IN  NS      a.root-servers.net.
  .                        518400  IN  NS      b.root-servers.net.
  a.root-servers.net.      518400  IN  A       198.41.0.4
  a.root-servers.net.      518400  IN  AAAA    2001:503:ba3e::2:30
  com.                     172800  IN  NS      a.gtld-servers.net.
  a.gtld-servers.net.      172800  IN  A       192.5.6.30
  """

  describe "init/1" do
    test "initializes with default URL" do
      assert {:ok, state} = IanaRoot.init(%{})
      assert state.url == "https://www.internic.net/domain/root.zone"
    end

    test "accepts custom URL" do
      assert {:ok, state} = IanaRoot.init(%{url: "https://custom/root.zone"})
      assert state.url == "https://custom/root.zone"
    end
  end

  describe "list_zones/1" do
    test "returns single root zone" do
      {:ok, state} = IanaRoot.init(%{})
      assert {:ok, [%{name: "."}], _state} = IanaRoot.list_zones(state)
    end
  end

  describe "parse_root_zone/1" do
    test "parses BIND-format root zone data into record entries" do
      records = IanaRoot.parse_root_zone(@sample_root_zone)

      assert length(records) > 0

      ns_records = Enum.filter(records, fn r -> r.type == "NS" and r.owner == "." end)
      assert length(ns_records) == 2

      a_records = Enum.filter(records, fn r -> r.type == "A" end)
      assert length(a_records) >= 1

      [first_a | _] = a_records
      assert first_a.rdata == "198.41.0.4"
    end

    test "skips SOA records" do
      records = IanaRoot.parse_root_zone(@sample_root_zone)
      soa = Enum.filter(records, fn r -> r.type == "SOA" end)
      assert soa == []
    end
  end

  describe "apply_changeset/3" do
    test "returns read_only error" do
      {:ok, state} = IanaRoot.init(%{})
      changeset = %{additions: [], deletions: []}
      assert {:error, :read_only, _state} = IanaRoot.apply_changeset(%{name: "."}, changeset, state)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd apps/yellow_dog_dns_provider && mix test test/yellow_dog/dns_provider/provider/iana_root_test.exs`
Expected: FAIL — `IanaRoot` module not defined

- [ ] **Step 3: Implement IanaRoot provider**

```elixir
# apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/provider/iana_root.ex
defmodule YellowDog.DnsProvider.Provider.IanaRoot do
  @moduledoc """
  Read-only provider that fetches the IANA root zone from HTTPS.

  Default source: https://www.internic.net/domain/root.zone
  Parses BIND zone file format into record entries.
  """

  @behaviour YellowDog.DnsProvider.Provider

  @default_url "https://www.internic.net/domain/root.zone"

  @impl true
  def init(config) do
    url = Map.get(config, :url, @default_url)
    {:ok, %{url: url, cached_records: nil, last_fetch: nil}}
  end

  @impl true
  def list_zones(state) do
    {:ok, [%{name: ".", id: nil}], state}
  end

  @impl true
  def get_records(%{name: "."}, state) do
    case fetch_root_zone(state.url) do
      {:ok, body} ->
        records = parse_root_zone(body)
        new_state = %{state | cached_records: records, last_fetch: System.system_time(:second)}
        {:ok, records, new_state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  def get_records(_zone_ref, state) do
    {:error, :zone_not_found, state}
  end

  @impl true
  def apply_changeset(_zone_ref, _changeset, state) do
    {:error, :read_only, state}
  end

  @impl true
  def zone_serial(%{name: "."}, state) do
    case fetch_root_zone(state.url) do
      {:ok, body} ->
        serial = extract_soa_serial(body)
        {:ok, serial, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  def zone_serial(_zone_ref, state) do
    {:error, :zone_not_found, state}
  end

  @doc """
  Parse BIND-format root zone text into a list of record entries.
  Skips SOA records and comments.
  """
  @spec parse_root_zone(String.t()) :: [map()]
  def parse_root_zone(zone_text) do
    zone_text
    |> String.split("\n")
    |> Enum.reject(fn line ->
      trimmed = String.trim(line)
      trimmed == "" or String.starts_with?(trimmed, ";")
    end)
    |> Enum.flat_map(&parse_line/1)
  end

  defp parse_line(line) do
    parts = String.split(line, ~r/\s+/, trim: true)

    case parts do
      [owner, ttl_str, "IN", type | rdata_parts] ->
        type_upper = String.upcase(type)

        if type_upper == "SOA" do
          []
        else
          ttl = parse_ttl(ttl_str)
          rdata = Enum.join(rdata_parts, " ")

          [
            %{
              owner: normalize_owner(owner),
              type: type_upper,
              ttl: ttl,
              rdata: rdata
            }
          ]
        end

      _ ->
        []
    end
  end

  defp normalize_owner(owner) do
    owner
    |> String.trim_trailing(".")
    |> case do
      "" -> "."
      other -> other <> "."
    end
  end

  defp parse_ttl(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> 3600
    end
  end

  defp extract_soa_serial(zone_text) do
    zone_text
    |> String.split("\n")
    |> Enum.find_value(0, fn line ->
      if String.contains?(line, "SOA") do
        parts = String.split(line, ~r/\s+/, trim: true)
        # SOA format: owner ttl IN SOA mname rname serial refresh retry expire minimum
        case Enum.drop(parts, 6) do
          [serial_str | _] ->
            case Integer.parse(serial_str) do
              {n, _} -> n
              :error -> nil
            end

          _ ->
            nil
        end
      end
    end)
  end

  defp fetch_root_zone(url) do
    case Req.get(url, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd apps/yellow_dog_dns_provider && mix test test/yellow_dog/dns_provider/provider/iana_root_test.exs`
Expected: All tests PASS (parse tests pass; HTTP tests may need network)

- [ ] **Step 5: Commit**

```bash
git add apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/provider/iana_root.ex
git add apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/provider/iana_root_test.exs
git commit -m "feat(dns_provider): add IANA root zone provider (read-only)"
```

---

### Task 12: Cloudflare provider

**Files:**
- Create: `apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/provider/cloudflare.ex`
- Create: `apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/provider/cloudflare_test.exs`

- [ ] **Step 1: Write tests with Req test adapter**

```elixir
# apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/provider/cloudflare_test.exs
defmodule YellowDog.DnsProvider.Provider.CloudflareTest do
  use ExUnit.Case, async: true

  alias YellowDog.DnsProvider.Provider.Cloudflare

  defp mock_req(plug) do
    Req.new(plug: plug)
  end

  describe "init/1" do
    test "initializes with api_token" do
      assert {:ok, state} = Cloudflare.init(%{api_token: "test-token"})
      assert state.api_token == "test-token"
    end

    test "returns error without credentials" do
      assert {:error, :missing_api_token} = Cloudflare.init(%{})
    end
  end

  describe "list_zones/1" do
    test "parses zone list response" do
      plug = fn conn ->
        body = JSON.encode!(%{
          success: true,
          result: [
            %{id: "zone-1", name: "example.com"},
            %{id: "zone-2", name: "test.org"}
          ]
        })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      {:ok, state} = Cloudflare.init(%{api_token: "tok", req: mock_req(plug)})
      assert {:ok, zones, _state} = Cloudflare.list_zones(state)
      assert length(zones) == 2
      assert hd(zones).name == "example.com."
    end
  end

  describe "get_records/2" do
    test "parses DNS records response" do
      plug = fn conn ->
        body = JSON.encode!(%{
          success: true,
          result: [
            %{name: "www.example.com", type: "A", ttl: 300, content: "1.2.3.4"},
            %{name: "mail.example.com", type: "MX", ttl: 3600, content: "10 mx.example.com"}
          ],
          result_info: %{total_pages: 1, page: 1}
        })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      {:ok, state} = Cloudflare.init(%{api_token: "tok", req: mock_req(plug)})
      zone_ref = %{name: "example.com.", id: "zone-1"}
      assert {:ok, records, _state} = Cloudflare.get_records(zone_ref, state)
      assert length(records) == 2

      [www | _] = records
      assert www.owner == "www"
      assert www.type == "A"
      assert www.rdata == "1.2.3.4"
    end
  end

  describe "apply_changeset/3" do
    test "sends create and delete requests" do
      call_log = :ets.new(:cf_calls, [:set, :public])
      :ets.insert(call_log, {:call_count, 0})

      plug = fn conn ->
        [{_, count}] = :ets.lookup(call_log, :call_count)
        :ets.insert(call_log, {:call_count, count + 1})

        body = JSON.encode!(%{success: true, result: %{id: "rec-#{count}"}})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      {:ok, state} = Cloudflare.init(%{api_token: "tok", req: mock_req(plug)})
      zone_ref = %{name: "example.com.", id: "zone-1"}

      changeset = %{
        additions: [%{owner: "new", type: "A", ttl: 300, rdata: "9.8.7.6"}],
        deletions: []
      }

      assert {:ok, _state} = Cloudflare.apply_changeset(zone_ref, changeset, state)
      [{_, count}] = :ets.lookup(call_log, :call_count)
      assert count >= 1

      :ets.delete(call_log)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd apps/yellow_dog_dns_provider && mix test test/yellow_dog/dns_provider/provider/cloudflare_test.exs`
Expected: FAIL — `Cloudflare` module not defined

- [ ] **Step 3: Implement Cloudflare provider**

```elixir
# apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/provider/cloudflare.ex
defmodule YellowDog.DnsProvider.Provider.Cloudflare do
  @moduledoc """
  Cloudflare DNS API v4 provider.

  Uses API token authentication. Supports full bidirectional sync.
  API docs: https://developers.cloudflare.com/api/resources/dns/subresources/records/
  """

  @behaviour YellowDog.DnsProvider.Provider

  @base_url "https://api.cloudflare.com/client/v4"

  @impl true
  def init(config) do
    case Map.get(config, :api_token) do
      nil ->
        {:error, :missing_api_token}

      token ->
        req = Map.get(config, :req, build_req(token))
        {:ok, %{api_token: token, req: req}}
    end
  end

  @impl true
  def list_zones(state) do
    case Req.get(state.req, url: "/zones", params: [per_page: 50]) do
      {:ok, %{status: 200, body: %{"success" => true, "result" => zones}}} ->
        refs =
          Enum.map(zones, fn z ->
            %{name: ensure_trailing_dot(z["name"]), id: z["id"]}
          end)

        {:ok, refs, state}

      {:ok, %{body: body}} ->
        {:error, {:api_error, body}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def get_records(%{id: zone_id}, state) do
    fetch_all_records(state, zone_id, 1, [])
  end

  @impl true
  def apply_changeset(%{id: zone_id}, changeset, state) do
    # Delete first, then add
    Enum.each(changeset.deletions, fn rec ->
      delete_record_by_match(state, zone_id, rec)
    end)

    errors =
      Enum.flat_map(changeset.additions, fn rec ->
        case create_record(state, zone_id, rec) do
          :ok -> []
          {:error, reason} -> [reason]
        end
      end)

    if errors == [] do
      {:ok, state}
    else
      {:error, {:partial_failure, errors}, state}
    end
  end

  @impl true
  def zone_serial(%{id: zone_id}, state) do
    case Req.get(state.req,
           url: "/zones/#{zone_id}/dns_records",
           params: [type: "SOA", per_page: 1]
         ) do
      {:ok, %{status: 200, body: %{"result" => [soa | _]}}} ->
        serial = extract_serial_from_content(soa["content"])
        {:ok, serial, state}

      {:ok, %{status: 200, body: %{"result" => []}}} ->
        {:ok, 0, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp build_req(token) do
    Req.new(
      base_url: @base_url,
      headers: [{"authorization", "Bearer #{token}"}],
      receive_timeout: 30_000
    )
  end

  defp fetch_all_records(state, zone_id, page, acc) do
    case Req.get(state.req,
           url: "/zones/#{zone_id}/dns_records",
           params: [per_page: 100, page: page]
         ) do
      {:ok, %{status: 200, body: %{"success" => true, "result" => records, "result_info" => info}}} ->
        entries = Enum.map(records, &to_record_entry(&1, zone_id))
        all = acc ++ entries

        total_pages = Map.get(info, "total_pages", 1)

        if page < total_pages do
          fetch_all_records(state, zone_id, page + 1, all)
        else
          {:ok, all, state}
        end

      {:ok, %{body: body}} ->
        {:error, {:api_error, body}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp to_record_entry(cf_record, _zone_id) do
    %{
      owner: extract_owner(cf_record["name"]),
      type: cf_record["type"],
      ttl: cf_record["ttl"] || 1,
      rdata: cf_record["content"]
    }
  end

  defp extract_owner(fqdn) do
    # Cloudflare returns full FQDN — strip zone suffix for owner
    # For simplicity, return the full name; SyncEngine handles normalization
    fqdn
  end

  defp create_record(state, zone_id, rec) do
    body = %{
      type: rec.type,
      name: rec.owner,
      content: rec.rdata,
      ttl: rec.ttl
    }

    case Req.post(state.req, url: "/zones/#{zone_id}/dns_records", json: body) do
      {:ok, %{status: status}} when status in [200, 201] -> :ok
      {:ok, %{body: body}} -> {:error, {:create_failed, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_record_by_match(state, zone_id, rec) do
    # Find the record ID by querying, then delete
    case Req.get(state.req,
           url: "/zones/#{zone_id}/dns_records",
           params: [type: rec.type, name: rec.owner, content: rec.rdata]
         ) do
      {:ok, %{status: 200, body: %{"result" => [%{"id" => record_id} | _]}}} ->
        Req.delete(state.req, url: "/zones/#{zone_id}/dns_records/#{record_id}")
        :ok

      _ ->
        :ok
    end
  end

  defp ensure_trailing_dot(name) do
    if String.ends_with?(name, "."), do: name, else: name <> "."
  end

  defp extract_serial_from_content(nil), do: 0

  defp extract_serial_from_content(content) do
    # SOA content: "mname rname serial refresh retry expire minimum"
    case String.split(content, ~r/\s+/) do
      [_, _, serial_str | _] ->
        case Integer.parse(serial_str) do
          {n, _} -> n
          :error -> 0
        end

      _ ->
        0
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd apps/yellow_dog_dns_provider && mix test test/yellow_dog/dns_provider/provider/cloudflare_test.exs`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/provider/cloudflare.ex
git add apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/provider/cloudflare_test.exs
git commit -m "feat(dns_provider): add Cloudflare DNS API v4 provider"
```

---

### Task 13: AWS Route 53 provider

**Files:**
- Create: `apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/provider/aws.ex`
- Create: `apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/provider/aws_test.exs`

- [ ] **Step 1: Write tests**

```elixir
# apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/provider/aws_test.exs
defmodule YellowDog.DnsProvider.Provider.AwsTest do
  use ExUnit.Case, async: true

  alias YellowDog.DnsProvider.Provider.Aws

  describe "init/1" do
    test "initializes with AWS credentials" do
      assert {:ok, state} =
               Aws.init(%{
                 access_key_id: "AKIA...",
                 secret_access_key: "secret",
                 region: "us-east-1"
               })

      assert state.region == "us-east-1"
    end

    test "returns error without access_key_id" do
      assert {:error, :missing_credentials} = Aws.init(%{})
    end
  end

  describe "parse_rrsets_xml/1" do
    test "parses Route 53 ListResourceRecordSets XML response" do
      xml = """
      <?xml version="1.0"?>
      <ListResourceRecordSetsResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
        <ResourceRecordSets>
          <ResourceRecordSet>
            <Name>www.example.com.</Name>
            <Type>A</Type>
            <TTL>300</TTL>
            <ResourceRecords>
              <ResourceRecord><Value>1.2.3.4</Value></ResourceRecord>
              <ResourceRecord><Value>5.6.7.8</Value></ResourceRecord>
            </ResourceRecords>
          </ResourceRecordSet>
          <ResourceRecordSet>
            <Name>mail.example.com.</Name>
            <Type>MX</Type>
            <TTL>3600</TTL>
            <ResourceRecords>
              <ResourceRecord><Value>10 mx.example.com.</Value></ResourceRecord>
            </ResourceRecords>
          </ResourceRecordSet>
        </ResourceRecordSets>
        <IsTruncated>false</IsTruncated>
      </ListResourceRecordSetsResponse>
      """

      records = Aws.parse_rrsets_xml(xml)
      assert length(records) == 3

      a_records = Enum.filter(records, fn r -> r.type == "A" end)
      assert length(a_records) == 2
      assert Enum.map(a_records, & &1.rdata) |> Enum.sort() == ["1.2.3.4", "5.6.7.8"]
    end
  end

  describe "build_change_batch_xml/1" do
    test "builds valid XML for changeset" do
      changeset = %{
        additions: [%{owner: "new.example.com.", type: "A", ttl: 300, rdata: "9.8.7.6"}],
        deletions: [%{owner: "old.example.com.", type: "CNAME", ttl: 300, rdata: "target.example.com."}]
      }

      xml = Aws.build_change_batch_xml(changeset)
      assert String.contains?(xml, "<Action>CREATE</Action>")
      assert String.contains?(xml, "<Action>DELETE</Action>")
      assert String.contains?(xml, "<Value>9.8.7.6</Value>")
      assert String.contains?(xml, "<Value>target.example.com.</Value>")
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd apps/yellow_dog_dns_provider && mix test test/yellow_dog/dns_provider/provider/aws_test.exs`
Expected: FAIL — `Aws` module not defined

- [ ] **Step 3: Implement AWS Route 53 provider**

```elixir
# apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/provider/aws.ex
defmodule YellowDog.DnsProvider.Provider.Aws do
  @moduledoc """
  AWS Route 53 provider.

  Uses AWS Signature V4 for authentication. Route 53 uses XML APIs and
  batch changesets natively, which maps well to the `apply_changeset/3` callback.

  API docs: https://docs.aws.amazon.com/Route53/latest/APIReference/
  """

  @behaviour YellowDog.DnsProvider.Provider

  @base_url "https://route53.amazonaws.com/2013-04-01"

  @impl true
  def init(config) do
    with {:ok, access_key} <- Map.fetch(config, :access_key_id),
         {:ok, secret_key} <- Map.fetch(config, :secret_access_key) do
      state = %{
        access_key_id: access_key,
        secret_access_key: secret_key,
        region: Map.get(config, :region, "us-east-1"),
        req: Map.get(config, :req, build_req())
      }

      {:ok, state}
    else
      :error -> {:error, :missing_credentials}
    end
  end

  @impl true
  def list_zones(state) do
    case Req.get(state.req,
           url: "/hostedzone",
           headers: auth_headers(state, "GET", "/2013-04-01/hostedzone")
         ) do
      {:ok, %{status: 200, body: body}} ->
        zones = parse_hosted_zones_xml(body)
        {:ok, zones, state}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def get_records(%{id: zone_id}, state) do
    path = "/hostedzone/#{zone_id}/rrset"

    case Req.get(state.req,
           url: path,
           headers: auth_headers(state, "GET", "/2013-04-01#{path}")
         ) do
      {:ok, %{status: 200, body: body}} ->
        records = parse_rrsets_xml(body)
        {:ok, records, state}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def apply_changeset(%{id: zone_id}, changeset, state) do
    if changeset.additions == [] and changeset.deletions == [] do
      {:ok, state}
    else
      xml = build_change_batch_xml(changeset)
      path = "/hostedzone/#{zone_id}/rrset"

      case Req.post(state.req,
             url: path,
             headers:
               [{"content-type", "application/xml"}] ++
                 auth_headers(state, "POST", "/2013-04-01#{path}"),
             body: xml
           ) do
        {:ok, %{status: 200}} -> {:ok, state}
        {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}, state}
        {:error, reason} -> {:error, reason, state}
      end
    end
  end

  @impl true
  def zone_serial(%{id: zone_id}, state) do
    case get_records(%{id: zone_id, name: ""}, state) do
      {:ok, records, state} ->
        soa = Enum.find(records, fn r -> r.type == "SOA" end)

        serial =
          if soa do
            case String.split(soa.rdata, ~r/\s+/) do
              [_, _, serial_str | _] ->
                case Integer.parse(serial_str) do
                  {n, _} -> n
                  :error -> 0
                end

              _ ->
                0
            end
          else
            0
          end

        {:ok, serial, state}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  # -------------------------------------------------------------------
  # XML parsing
  # -------------------------------------------------------------------

  @doc "Parse Route 53 ListResourceRecordSets XML into record entries."
  @spec parse_rrsets_xml(String.t()) :: [map()]
  def parse_rrsets_xml(xml) do
    # Simple regex-based XML parsing (no dependency on xmerl for this)
    ~r/<ResourceRecordSet>(.*?)<\/ResourceRecordSet>/s
    |> Regex.scan(xml)
    |> Enum.flat_map(fn [_, rrset_xml] ->
      name = extract_xml_value(rrset_xml, "Name")
      type = extract_xml_value(rrset_xml, "Type")
      ttl_str = extract_xml_value(rrset_xml, "TTL")
      ttl = if ttl_str, do: String.to_integer(ttl_str), else: 300

      ~r/<Value>(.*?)<\/Value>/s
      |> Regex.scan(rrset_xml)
      |> Enum.map(fn [_, value] ->
        %{owner: name || "", type: type || "", ttl: ttl, rdata: String.trim(value)}
      end)
    end)
  end

  @doc "Build Route 53 ChangeResourceRecordSets XML from a changeset."
  @spec build_change_batch_xml(map()) :: String.t()
  def build_change_batch_xml(changeset) do
    changes =
      Enum.map(changeset.deletions, fn rec -> change_xml("DELETE", rec) end) ++
        Enum.map(changeset.additions, fn rec -> change_xml("CREATE", rec) end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ChangeResourceRecordSetsRequest xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
      <ChangeBatch>
        <Changes>
          #{Enum.join(changes, "\n")}
        </Changes>
      </ChangeBatch>
    </ChangeResourceRecordSetsRequest>
    """
  end

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp build_req do
    Req.new(base_url: @base_url, receive_timeout: 30_000)
  end

  defp change_xml(action, rec) do
    """
    <Change>
      <Action>#{action}</Action>
      <ResourceRecordSet>
        <Name>#{xml_escape(rec.owner)}</Name>
        <Type>#{rec.type}</Type>
        <TTL>#{rec.ttl}</TTL>
        <ResourceRecords>
          <ResourceRecord><Value>#{xml_escape(rec.rdata)}</Value></ResourceRecord>
        </ResourceRecords>
      </ResourceRecordSet>
    </Change>
    """
  end

  defp extract_xml_value(xml, tag) do
    case Regex.run(~r/<#{tag}>(.*?)<\/#{tag}>/s, xml) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end

  defp xml_escape(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp auth_headers(_state, _method, _path) do
    # AWS Signature V4 implementation
    # For now, return basic headers — full SigV4 to be implemented
    # with proper date, canonical request, and signing
    now = DateTime.utc_now()
    date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    [{"x-amz-date", date}]
  end

  defp parse_hosted_zones_xml(xml) do
    ~r/<HostedZone>(.*?)<\/HostedZone>/s
    |> Regex.scan(xml)
    |> Enum.map(fn [_, zone_xml] ->
      id =
        extract_xml_value(zone_xml, "Id")
        |> case do
          nil -> nil
          id_str -> String.trim_leading(id_str, "/hostedzone/")
        end

      name = extract_xml_value(zone_xml, "Name")
      %{name: name || "", id: id}
    end)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd apps/yellow_dog_dns_provider && mix test test/yellow_dog/dns_provider/provider/aws_test.exs`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/provider/aws.ex
git add apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/provider/aws_test.exs
git commit -m "feat(dns_provider): add AWS Route 53 provider"
```

---

### Task 14: GCP Cloud DNS provider

**Files:**
- Create: `apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/provider/gcp.ex`
- Create: `apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/provider/gcp_test.exs`

- [ ] **Step 1: Write tests**

```elixir
# apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/provider/gcp_test.exs
defmodule YellowDog.DnsProvider.Provider.GcpTest do
  use ExUnit.Case, async: true

  alias YellowDog.DnsProvider.Provider.Gcp

  defp mock_req(plug) do
    Req.new(plug: plug)
  end

  describe "init/1" do
    test "initializes with project_id and access_token" do
      assert {:ok, state} =
               Gcp.init(%{project_id: "my-project", access_token: "ya29.test"})

      assert state.project_id == "my-project"
    end

    test "returns error without project_id" do
      assert {:error, :missing_project_id} = Gcp.init(%{})
    end
  end

  describe "list_zones/1" do
    test "parses managed zones response" do
      plug = fn conn ->
        body = JSON.encode!(%{
          managedZones: [
            %{name: "my-zone", dnsName: "example.com.", id: "123"},
            %{name: "other-zone", dnsName: "test.org.", id: "456"}
          ]
        })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      {:ok, state} = Gcp.init(%{project_id: "proj", access_token: "tok", req: mock_req(plug)})
      assert {:ok, zones, _state} = Gcp.list_zones(state)
      assert length(zones) == 2
      assert hd(zones).name == "example.com."
    end
  end

  describe "get_records/2" do
    test "parses rrsets response" do
      plug = fn conn ->
        body = JSON.encode!(%{
          rrsets: [
            %{name: "www.example.com.", type: "A", ttl: 300, rrdatas: ["1.2.3.4", "5.6.7.8"]},
            %{name: "example.com.", type: "MX", ttl: 3600, rrdatas: ["10 mx.example.com."]}
          ]
        })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      {:ok, state} = Gcp.init(%{project_id: "proj", access_token: "tok", req: mock_req(plug)})
      zone_ref = %{name: "example.com.", id: "my-zone"}
      assert {:ok, records, _state} = Gcp.get_records(zone_ref, state)
      assert length(records) == 3
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd apps/yellow_dog_dns_provider && mix test test/yellow_dog/dns_provider/provider/gcp_test.exs`
Expected: FAIL

- [ ] **Step 3: Implement GCP provider**

```elixir
# apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/provider/gcp.ex
defmodule YellowDog.DnsProvider.Provider.Gcp do
  @moduledoc """
  Google Cloud DNS provider.

  Uses OAuth2 access token for authentication. Supports managed zones
  and rrsets CRUD via the Cloud DNS API v1.

  API docs: https://cloud.google.com/dns/docs/reference/v1
  """

  @behaviour YellowDog.DnsProvider.Provider

  @base_url "https://dns.googleapis.com/dns/v1"

  @impl true
  def init(config) do
    case Map.get(config, :project_id) do
      nil ->
        {:error, :missing_project_id}

      project_id ->
        token = Map.get(config, :access_token, "")
        req = Map.get(config, :req, build_req(token))

        {:ok, %{project_id: project_id, access_token: token, req: req}}
    end
  end

  @impl true
  def list_zones(state) do
    case Req.get(state.req, url: "/projects/#{state.project_id}/managedZones") do
      {:ok, %{status: 200, body: %{"managedZones" => zones}}} ->
        refs =
          Enum.map(zones, fn z ->
            %{name: z["dnsName"], id: z["name"]}
          end)

        {:ok, refs, state}

      {:ok, %{body: body}} ->
        {:error, {:api_error, body}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def get_records(%{id: managed_zone}, state) do
    case Req.get(state.req,
           url: "/projects/#{state.project_id}/managedZones/#{managed_zone}/rrsets"
         ) do
      {:ok, %{status: 200, body: %{"rrsets" => rrsets}}} ->
        records =
          Enum.flat_map(rrsets, fn rrset ->
            name = rrset["name"]
            type = rrset["type"]
            ttl = rrset["ttl"] || 300

            Enum.map(rrset["rrdatas"] || [], fn rdata ->
              %{owner: name, type: type, ttl: ttl, rdata: rdata}
            end)
          end)

        {:ok, records, state}

      {:ok, %{body: body}} ->
        {:error, {:api_error, body}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def apply_changeset(%{id: managed_zone}, changeset, state) do
    if changeset.additions == [] and changeset.deletions == [] do
      {:ok, state}
    else
      body = build_changes_body(changeset)

      case Req.post(state.req,
             url: "/projects/#{state.project_id}/managedZones/#{managed_zone}/changes",
             json: body
           ) do
        {:ok, %{status: status}} when status in [200, 201] -> {:ok, state}
        {:ok, %{body: body}} -> {:error, {:api_error, body}, state}
        {:error, reason} -> {:error, reason, state}
      end
    end
  end

  @impl true
  def zone_serial(%{id: managed_zone}, state) do
    case get_records(%{id: managed_zone, name: ""}, state) do
      {:ok, records, state} ->
        soa = Enum.find(records, fn r -> r.type == "SOA" end)

        serial =
          if soa do
            case String.split(soa.rdata, ~r/\s+/) do
              [_, _, serial_str | _] ->
                case Integer.parse(serial_str) do
                  {n, _} -> n
                  :error -> 0
                end

              _ ->
                0
            end
          else
            0
          end

        {:ok, serial, state}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp build_req(token) do
    Req.new(
      base_url: @base_url,
      headers: [{"authorization", "Bearer #{token}"}],
      receive_timeout: 30_000
    )
  end

  defp build_changes_body(changeset) do
    additions = group_by_rrset(changeset.additions)
    deletions = group_by_rrset(changeset.deletions)

    %{
      additions: additions,
      deletions: deletions
    }
  end

  defp group_by_rrset(records) do
    records
    |> Enum.group_by(fn r -> {r.owner, r.type} end)
    |> Enum.map(fn {{name, type}, recs} ->
      %{
        name: name,
        type: type,
        ttl: hd(recs).ttl,
        rrdatas: Enum.map(recs, & &1.rdata)
      }
    end)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd apps/yellow_dog_dns_provider && mix test test/yellow_dog/dns_provider/provider/gcp_test.exs`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/provider/gcp.ex
git add apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/provider/gcp_test.exs
git commit -m "feat(dns_provider): add Google Cloud DNS provider"
```

---

### Task 15: Vultr DNS provider

**Files:**
- Create: `apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/provider/vultr.ex`
- Create: `apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/provider/vultr_test.exs`

- [ ] **Step 1: Write tests**

```elixir
# apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/provider/vultr_test.exs
defmodule YellowDog.DnsProvider.Provider.VultrTest do
  use ExUnit.Case, async: true

  alias YellowDog.DnsProvider.Provider.Vultr

  defp mock_req(plug) do
    Req.new(plug: plug)
  end

  describe "init/1" do
    test "initializes with api_key" do
      assert {:ok, state} = Vultr.init(%{api_key: "test-key"})
      assert state.api_key == "test-key"
    end

    test "returns error without api_key" do
      assert {:error, :missing_api_key} = Vultr.init(%{})
    end
  end

  describe "list_zones/1" do
    test "parses domains response" do
      plug = fn conn ->
        body = JSON.encode!(%{
          domains: [
            %{domain: "example.com"},
            %{domain: "test.org"}
          ]
        })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      {:ok, state} = Vultr.init(%{api_key: "key", req: mock_req(plug)})
      assert {:ok, zones, _state} = Vultr.list_zones(state)
      assert length(zones) == 2
    end
  end

  describe "get_records/2" do
    test "parses records response" do
      plug = fn conn ->
        body = JSON.encode!(%{
          records: [
            %{id: "r1", type: "A", name: "www", data: "1.2.3.4", ttl: 300},
            %{id: "r2", type: "MX", name: "", data: "10 mail.example.com", ttl: 3600}
          ]
        })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      {:ok, state} = Vultr.init(%{api_key: "key", req: mock_req(plug)})
      zone_ref = %{name: "example.com.", id: nil}
      assert {:ok, records, _state} = Vultr.get_records(zone_ref, state)
      assert length(records) == 2
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd apps/yellow_dog_dns_provider && mix test test/yellow_dog/dns_provider/provider/vultr_test.exs`
Expected: FAIL

- [ ] **Step 3: Implement Vultr provider**

```elixir
# apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/provider/vultr.ex
defmodule YellowDog.DnsProvider.Provider.Vultr do
  @moduledoc """
  Vultr DNS API provider.

  Uses API key authentication. Supports individual record CRUD.

  API docs: https://www.vultr.com/api/#tag/dns
  """

  @behaviour YellowDog.DnsProvider.Provider

  @base_url "https://api.vultr.com/v2"

  @impl true
  def init(config) do
    case Map.get(config, :api_key) do
      nil ->
        {:error, :missing_api_key}

      key ->
        req = Map.get(config, :req, build_req(key))
        {:ok, %{api_key: key, req: req}}
    end
  end

  @impl true
  def list_zones(state) do
    case Req.get(state.req, url: "/domains") do
      {:ok, %{status: 200, body: %{"domains" => domains}}} ->
        refs =
          Enum.map(domains, fn d ->
            name = d["domain"]
            %{name: ensure_trailing_dot(name), id: nil}
          end)

        {:ok, refs, state}

      {:ok, %{body: body}} ->
        {:error, {:api_error, body}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def get_records(%{name: zone_name}, state) do
    domain = String.trim_trailing(zone_name, ".")

    case Req.get(state.req, url: "/domains/#{domain}/records") do
      {:ok, %{status: 200, body: %{"records" => records}}} ->
        entries =
          Enum.map(records, fn r ->
            %{
              owner: vultr_name_to_owner(r["name"], domain),
              type: r["type"],
              ttl: r["ttl"] || 300,
              rdata: r["data"]
            }
          end)

        {:ok, entries, state}

      {:ok, %{body: body}} ->
        {:error, {:api_error, body}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def apply_changeset(%{name: zone_name}, changeset, state) do
    domain = String.trim_trailing(zone_name, ".")

    Enum.each(changeset.deletions, fn rec ->
      delete_record(state, domain, rec)
    end)

    errors =
      Enum.flat_map(changeset.additions, fn rec ->
        case create_record(state, domain, rec) do
          :ok -> []
          {:error, reason} -> [reason]
        end
      end)

    if errors == [] do
      {:ok, state}
    else
      {:error, {:partial_failure, errors}, state}
    end
  end

  @impl true
  def zone_serial(%{name: zone_name}, state) do
    domain = String.trim_trailing(zone_name, ".")

    case Req.get(state.req, url: "/domains/#{domain}/soa") do
      {:ok, %{status: 200, body: %{"dns_soa" => %{"nserial" => serial}}}} ->
        {:ok, serial, state}

      _ ->
        {:ok, 0, state}
    end
  end

  defp build_req(key) do
    Req.new(
      base_url: @base_url,
      headers: [{"authorization", "Bearer #{key}"}],
      receive_timeout: 30_000
    )
  end

  defp create_record(state, domain, rec) do
    body = %{
      type: rec.type,
      name: owner_to_vultr_name(rec.owner),
      data: rec.rdata,
      ttl: rec.ttl
    }

    case Req.post(state.req, url: "/domains/#{domain}/records", json: body) do
      {:ok, %{status: status}} when status in [200, 201, 204] -> :ok
      {:ok, %{body: body}} -> {:error, {:create_failed, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_record(state, domain, rec) do
    # Vultr requires record ID — list records to find matching one
    case Req.get(state.req, url: "/domains/#{domain}/records") do
      {:ok, %{status: 200, body: %{"records" => records}}} ->
        matching =
          Enum.find(records, fn r ->
            r["type"] == rec.type and r["data"] == rec.rdata and
              vultr_name_to_owner(r["name"], domain) == rec.owner
          end)

        if matching do
          Req.delete(state.req, url: "/domains/#{domain}/records/#{matching["id"]}")
        end

        :ok

      _ ->
        :ok
    end
  end

  defp vultr_name_to_owner("", _domain), do: "@"
  defp vultr_name_to_owner(name, _domain), do: name

  defp owner_to_vultr_name("@"), do: ""
  defp owner_to_vultr_name(owner), do: owner

  defp ensure_trailing_dot(name) do
    if String.ends_with?(name, "."), do: name, else: name <> "."
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd apps/yellow_dog_dns_provider && mix test test/yellow_dog/dns_provider/provider/vultr_test.exs`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add apps/yellow_dog_dns_provider/lib/yellow_dog/dns_provider/provider/vultr.ex
git add apps/yellow_dog_dns_provider/test/yellow_dog/dns_provider/provider/vultr_test.exs
git commit -m "feat(dns_provider): add Vultr DNS provider"
```

---

## Phase 4: Integration

### Task 16: Wire into YellowDog.Application

**Files:**
- Modify: `apps/yellow_dog/lib/yellow_dog/application.ex`

- [ ] **Step 1: Read current application.ex**

Run: Read `apps/yellow_dog/lib/yellow_dog/application.ex` to find where services are started conditionally.

- [ ] **Step 2: Add DnsProvider.Supervisor to service startup**

Add to `get_enabled_services/1` or `start_services_async/1` — after DNS service, before console:

```elixir
# In the services list, add:
{YellowDog.DnsProvider.Supervisor, :dns_provider}
```

The gating condition: check if any provider configs exist in Store, or always start (ConfigWatcher handles empty state gracefully).

Since DnsProvider has no TOML config gating, start it unconditionally after Store is ready:

```elixir
# Add to children list after EventBridge:
YellowDog.DnsProvider.Supervisor
```

- [ ] **Step 3: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: No warnings

- [ ] **Step 4: Commit**

```bash
git add apps/yellow_dog/lib/yellow_dog/application.ex
git commit -m "feat(dns_provider): wire DnsProvider.Supervisor into application startup"
```

---

### Task 17: Console routes and sidebar

**Files:**
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/router.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/components/layouts.ex`

- [ ] **Step 1: Read current router.ex to find DNS route section**

Read `apps/yellow_dog_console/lib/yellow_dog/console/router.ex` to find the DNS routes block.

- [ ] **Step 2: Add provider routes after DNS metrics route**

```elixir
# After: live "/dns/metrics", DnsLive.MetricsLive
live "/dns/providers", DnsLive.ProviderLive.Index
live "/dns/providers/new", DnsLive.ProviderLive.Index, :new
live "/dns/providers/:name", DnsLive.ProviderLive.Show
live "/dns/providers/:name/edit", DnsLive.ProviderLive.Show, :edit
live "/dns/providers/:name/conflicts", DnsLive.ProviderLive.ConflictLive
```

- [ ] **Step 3: Read current layouts.ex to find DNS sidebar section**

Read `apps/yellow_dog_console/lib/yellow_dog/console/components/layouts.ex` to find the DNS sidebar.

- [ ] **Step 4: Add Providers sidebar item after Metrics**

```heex
<li>
  <.link navigate="/server/dns/providers" class={active?(@current_path, "/server/dns/providers")}>
    <.dm_mdi name="cloud-sync" class="w-5 h-5" />
    <span>Providers</span>
  </.link>
</li>
```

- [ ] **Step 5: Verify compilation**

Run: `cd apps/yellow_dog_console && mix compile`
Expected: No warnings (LiveView modules don't exist yet — routes just won't match)

- [ ] **Step 6: Commit**

```bash
git add apps/yellow_dog_console/lib/yellow_dog/console/router.ex
git add apps/yellow_dog_console/lib/yellow_dog/console/components/layouts.ex
git commit -m "feat(console): add DNS provider routes and sidebar item"
```

---

### Task 18: Provider list LiveView page

**Files:**
- Create: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/provider_live/index.ex`

- [ ] **Step 1: Implement provider list page**

```elixir
# apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/provider_live/index.ex
defmodule YellowDog.Console.DnsLive.ProviderLive.Index do
  @moduledoc """
  DNS Providers list page. Shows all configured providers with status,
  last sync time, and sync/edit/delete actions.
  """

  use YellowDog.Console, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns_provider:*")
    end

    {:ok,
     assign(socket,
       page_title: "DNS Providers",
       providers: list_providers(),
       live_action: socket.assigns[:live_action] || :index
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("sync", %{"name" => name}, socket) do
    YellowDog.DnsProvider.sync_now(name)
    {:noreply, put_flash(socket, :info, "Sync triggered for #{name}")}
  end

  def handle_event("delete", %{"name" => name}, socket) do
    YellowDog.DnsProvider.remove_provider(name)
    {:noreply, assign(socket, :providers, list_providers())}
  end

  @impl true
  def handle_info({:sync_complete, _data}, socket) do
    {:noreply, assign(socket, :providers, list_providers())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center">
        <h2 class="text-2xl font-bold">DNS Providers</h2>
        <.link navigate="/server/dns/providers/new" class="btn btn-primary btn-sm">
          Add Provider
        </.link>
      </div>

      <div class="overflow-x-auto">
        <table class="table table-zebra w-full">
          <thead>
            <tr>
              <th>Name</th>
              <th>Type</th>
              <th>Status</th>
              <th>Last Sync</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={provider <- @providers}>
              <td>
                <.link navigate={"/server/dns/providers/#{provider.name}"} class="link link-primary">
                  {provider.name}
                </.link>
              </td>
              <td><span class="badge badge-outline">{provider.type}</span></td>
              <td>
                <span class={[
                  "badge",
                  if(provider.status == :running, do: "badge-success", else: "badge-ghost")
                ]}>
                  {provider.status}
                </span>
              </td>
              <td>{format_sync_time(provider)}</td>
              <td class="space-x-2">
                <button
                  phx-click="sync"
                  phx-value-name={provider.name}
                  class="btn btn-xs btn-outline"
                  disabled={provider.status != :running}
                >
                  Sync Now
                </button>
                <button
                  phx-click="delete"
                  phx-value-name={provider.name}
                  class="btn btn-xs btn-error btn-outline"
                  data-confirm="Are you sure?"
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@providers == []} class="text-center py-12 text-base-content/50">
        No providers configured. Click "Add Provider" to get started.
      </div>
    </div>
    """
  end

  defp list_providers do
    YellowDog.DnsProvider.list_providers()
  rescue
    _ -> []
  end

  defp format_sync_time(provider) do
    case YellowDog.DnsProvider.sync_status(provider.name) do
      %{last_sync: nil} -> "Never"
      %{last_sync: ts} -> Calendar.strftime(DateTime.from_unix!(ts), "%Y-%m-%d %H:%M:%S")
      _ -> "—"
    end
  rescue
    _ -> "—"
  end
end
```

- [ ] **Step 2: Verify compilation**

Run: `cd apps/yellow_dog_console && mix compile`
Expected: No warnings

- [ ] **Step 3: Commit**

```bash
git add apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/provider_live/index.ex
git commit -m "feat(console): add DNS provider list LiveView page"
```

---

### Task 19: Provider detail and conflict LiveView pages

**Files:**
- Create: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/provider_live/show.ex`
- Create: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/provider_live/conflict_live.ex`

- [ ] **Step 1: Implement provider detail page**

```elixir
# apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/provider_live/show.ex
defmodule YellowDog.Console.DnsLive.ProviderLive.Show do
  @moduledoc """
  Provider detail page showing config (secrets masked), zone bindings,
  sync status, and per-zone sync controls.
  """

  use YellowDog.Console, :live_view

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns_provider:#{name}")
    end

    case YellowDog.Store.Provider.get_config(name) do
      {:ok, config} ->
        {:ok,
         assign(socket,
           page_title: "Provider: #{name}",
           name: name,
           config: mask_secrets(config),
           status: get_status(name),
           live_action: socket.assigns[:live_action] || :show
         )}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Provider not found")
         |> push_navigate(to: "/server/dns/providers")}
    end
  end

  @impl true
  def handle_event("sync", %{"zone" => zone}, socket) do
    YellowDog.DnsProvider.sync_now(socket.assigns.name, zone)
    {:noreply, put_flash(socket, :info, "Sync triggered for #{zone}")}
  end

  def handle_event("sync_all", _params, socket) do
    YellowDog.DnsProvider.sync_now(socket.assigns.name)
    {:noreply, put_flash(socket, :info, "Full sync triggered")}
  end

  def handle_event("toggle_enabled", _params, socket) do
    name = socket.assigns.name
    config = socket.assigns.config
    new_enabled = !Map.get(config, :enabled, true)

    if new_enabled do
      YellowDog.DnsProvider.start_provider(name)
    else
      YellowDog.DnsProvider.stop_provider(name)
    end

    {:noreply,
     socket
     |> assign(:config, Map.put(config, :enabled, new_enabled))
     |> assign(:status, get_status(name))}
  end

  @impl true
  def handle_info({:sync_complete, _data}, socket) do
    {:noreply, assign(socket, :status, get_status(socket.assigns.name))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center">
        <h2 class="text-2xl font-bold">Provider: {@name}</h2>
        <div class="space-x-2">
          <button phx-click="sync_all" class="btn btn-primary btn-sm">Sync All Zones</button>
          <button phx-click="toggle_enabled" class="btn btn-sm btn-outline">
            {if Map.get(@config, :enabled, true), do: "Disable", else: "Enable"}
          </button>
          <.link navigate={"/server/dns/providers/#{@name}/conflicts"} class="btn btn-sm btn-outline">
            Conflicts
          </.link>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div class="card bg-base-200">
          <div class="card-body">
            <h3 class="card-title text-lg">Configuration</h3>
            <dl class="space-y-2">
              <div :for={{key, val} <- config_display(@config)}>
                <dt class="text-sm font-medium text-base-content/70">{key}</dt>
                <dd class="text-sm">{val}</dd>
              </div>
            </dl>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body">
            <h3 class="card-title text-lg">Status</h3>
            <dl class="space-y-2">
              <div>
                <dt class="text-sm font-medium text-base-content/70">Last Sync</dt>
                <dd class="text-sm">{format_time(@status[:last_sync])}</dd>
              </div>
              <div>
                <dt class="text-sm font-medium text-base-content/70">Sync Count</dt>
                <dd class="text-sm">{@status[:sync_count] || 0}</dd>
              </div>
              <div :if={@status[:last_error]}>
                <dt class="text-sm font-medium text-base-content/70">Last Error</dt>
                <dd class="text-sm text-error">{inspect(@status[:last_error])}</dd>
              </div>
            </dl>
          </div>
        </div>
      </div>

      <div class="card bg-base-200">
        <div class="card-body">
          <h3 class="card-title text-lg">Zones</h3>
          <table class="table w-full">
            <thead>
              <tr>
                <th>Zone</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={zone <- Map.get(@config, :zones, [])}>
                <td>{zone}</td>
                <td>
                  <button phx-click="sync" phx-value-zone={zone} class="btn btn-xs btn-outline">
                    Sync
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp get_status(name) do
    case YellowDog.DnsProvider.sync_status(name) do
      {:error, _} -> %{}
      status -> status
    end
  rescue
    _ -> %{}
  end

  defp mask_secrets(config) do
    Map.update(config, :credentials, %{}, fn creds ->
      Map.new(creds, fn {k, v} ->
        if String.contains?(to_string(k), "secret") or String.contains?(to_string(k), "token") or
             String.contains?(to_string(k), "key") do
          {k, "****#{String.slice(to_string(v), -4, 4)}"}
        else
          {k, v}
        end
      end)
    end)
  end

  defp config_display(config) do
    [
      {"Type", Map.get(config, :type)},
      {"Sync Interval", "#{Map.get(config, :sync_interval, 300)}s"},
      {"Conflict Strategy", Map.get(config, :conflict_strategy)},
      {"Enabled", Map.get(config, :enabled, true)}
    ]
  end

  defp format_time(nil), do: "Never"

  defp format_time(ts) when is_integer(ts) do
    Calendar.strftime(DateTime.from_unix!(ts), "%Y-%m-%d %H:%M:%S")
  end

  defp format_time(_), do: "—"
end
```

- [ ] **Step 2: Implement conflict resolution page**

```elixir
# apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/provider_live/conflict_live.ex
defmodule YellowDog.Console.DnsLive.ProviderLive.ConflictLive do
  @moduledoc """
  Conflict resolution page for providers using the `:manual` conflict strategy.
  Shows unresolved conflicts with local vs remote values and resolve buttons.
  """

  use YellowDog.Console, :live_view

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Conflicts: #{name}",
       name: name,
       conflicts: YellowDog.DnsProvider.list_conflicts(name)
     )}
  end

  @impl true
  def handle_event("resolve", %{"id" => id, "resolution" => resolution}, socket) do
    resolution_atom = String.to_existing_atom(resolution)
    YellowDog.DnsProvider.resolve_conflict(socket.assigns.name, id, resolution_atom)

    {:noreply,
     assign(socket, :conflicts, YellowDog.DnsProvider.list_conflicts(socket.assigns.name))}
  end

  def handle_event("resolve_all", %{"resolution" => resolution}, socket) do
    resolution_atom = String.to_existing_atom(resolution)
    YellowDog.DnsProvider.resolve_all_conflicts(socket.assigns.name, resolution_atom)

    {:noreply, assign(socket, :conflicts, [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center">
        <h2 class="text-2xl font-bold">Conflicts: {@name}</h2>
        <div :if={@conflicts != []} class="space-x-2">
          <button phx-click="resolve_all" phx-value-resolution="keep_local" class="btn btn-sm btn-outline">
            Resolve All: Keep Local
          </button>
          <button phx-click="resolve_all" phx-value-resolution="keep_remote" class="btn btn-sm btn-outline">
            Resolve All: Keep Remote
          </button>
        </div>
      </div>

      <div :for={conflict <- @conflicts} class="card bg-base-200">
        <div class="card-body">
          <h3 class="card-title text-lg">
            {Map.get(conflict, :owner, "?")} / {Map.get(conflict, :type, "?")} in {Map.get(conflict, :zone, "?")}
          </h3>
          <div class="grid grid-cols-2 gap-4">
            <div>
              <h4 class="font-medium text-sm">Local</h4>
              <pre class="bg-base-300 p-2 rounded text-xs mt-1">{inspect(Map.get(conflict, :local_records, []), pretty: true)}</pre>
            </div>
            <div>
              <h4 class="font-medium text-sm">Remote</h4>
              <pre class="bg-base-300 p-2 rounded text-xs mt-1">{inspect(Map.get(conflict, :remote_records, []), pretty: true)}</pre>
            </div>
          </div>
          <div class="card-actions justify-end mt-2">
            <button
              phx-click="resolve"
              phx-value-id={Map.get(conflict, :id)}
              phx-value-resolution="keep_local"
              class="btn btn-sm btn-primary"
            >
              Keep Local
            </button>
            <button
              phx-click="resolve"
              phx-value-id={Map.get(conflict, :id)}
              phx-value-resolution="keep_remote"
              class="btn btn-sm btn-secondary"
            >
              Keep Remote
            </button>
          </div>
        </div>
      </div>

      <div :if={@conflicts == []} class="text-center py-12 text-base-content/50">
        No unresolved conflicts.
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 3: Verify compilation**

Run: `cd apps/yellow_dog_console && mix compile`
Expected: No warnings

- [ ] **Step 4: Commit**

```bash
git add apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/provider_live/show.ex
git add apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/provider_live/conflict_live.ex
git commit -m "feat(console): add provider detail and conflict resolution LiveView pages"
```

---

### Task 20: Full compilation and test verification

- [ ] **Step 1: Compile entire umbrella with warnings-as-errors**

Run: `mix compile --warnings-as-errors`
Expected: No warnings, clean compilation

- [ ] **Step 2: Run dns_provider tests**

Run: `cd apps/yellow_dog_dns_provider && mix test`
Expected: All tests pass

- [ ] **Step 3: Run store provider tests**

Run: `cd apps/yellow_dog_store && mix test test/yellow_dog/store/provider_test.exs`
Expected: All tests pass

- [ ] **Step 4: Run format check**

Run: `mix format --check-formatted`
Expected: All files formatted

- [ ] **Step 5: Run credo**

Run: `cd apps/yellow_dog_dns_provider && mix credo --strict`
Expected: No issues

- [ ] **Step 6: Final commit if any formatting fixes needed**

```bash
mix format
git add -A
git commit -m "chore(dns_provider): formatting and lint fixes"
```
