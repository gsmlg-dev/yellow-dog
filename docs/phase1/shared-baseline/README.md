# Phase 1 C0 ConfigSpec handoff

Baseline inspected: `61a447a3`. This directory holds the proposed shared application only. It does not modify the root umbrella or either runtime track. Apply `../config-spec.patch` from the repository root with `git apply docs/phase1/config-spec.patch`, then have the shared-file owner wire the application into the root build and lockfile. Management and Worker must both depend on this one library.

## Contract

`YellowDog.ConfigSpec` exposes:

- `normalize_resource(map) -> {:ok, normalized_resource} | {:error, errors}`
- `normalize_plan(map) -> {:ok, normalized_plan} | {:error, errors}`
- `plan_digest(plan) -> {:ok, lowercase_sha256_hex} | {:error, errors}`
- `encode(plan) -> {:ok, toml} | {:error, errors}`
- `decode(toml) -> {:ok, normalized_plan} | {:error, errors}`
- `diff(old_plan, new_plan) -> {:ok, structured_diff} | {:error, errors}`

Errors are `%{path: [field_or_index, ...], code: atom, message: string}`. All contract maps have **string keys**. No atoms are created from untrusted strings. All fields shown below are required unless marked optional. Unknown fields are rejected.

```elixir
%{
  "schema_version" => 1,
  "worker_id" => "edge-01",
  "revision" => 1,
  "services" => [
    %{
      "id" => "dns-primary",
      "type" => "dns",
      "desired_state" => "running", # or "stopped"
      "config" => %{"listen_address" => "127.0.0.1", "port" => 1053},
      "resources" => ["zone-example"]
    }
  ],
  "resources" => [
    %{
      "id" => "zone-example",
      "type" => "dns_zone",
      "schema_version" => 1,
      "version" => 1,
      "content" => %{
        "name" => "example.com.",
        "records" => [
          %{"name" => "example.com.", "type" => "SOA", "ttl" => 3600,
            "data" => %{"mname" => "ns1.example.com.", "rname" => "hostmaster.example.com.",
              "serial" => 2026093001, "refresh" => 3600, "retry" => 600,
              "expire" => 86400, "minimum" => 300}},
          %{"name" => "example.com.", "type" => "NS", "ttl" => 3600,
            "data" => %{"host" => "ns1.example.com."}},
          %{"name" => "ns1.example.com.", "type" => "A", "ttl" => 300,
            "data" => %{"address" => "192.0.2.53"}}
        ]
      },
      "digest" => "..." # optional on input; computed and checked when supplied
    }
  ]
}
```

`worker_id`, service IDs, and resource IDs contain 1–64 ASCII letters, digits, `_`, `.`, or `-`, starting with a letter or digit. `revision` and resource `version` are positive integers through 2,147,483,647. DNS listen addresses and A data are IPv4; ports are 1–65,535. Domain labels follow DNS host-name syntax, normalize to lowercase with a trailing dot, and are at most 253 bytes before that dot. TTLs and SOA time fields are nonnegative bounded integers. The SOA serial allows 0–4,294,967,295. One zone requires exactly one apex SOA, an apex NS, and at least one A record. Only SOA, NS and A are supported in C0.

Service and resource arrays are required, including when empty. An empty resource array means an explicit empty target; a missing array is an error. Every service resource reference must name a resource in the same complete plan, and every included resource must be referenced by at least one service. A resource ID may be referenced by several services or several WorkerPlans, while each plan carries only its own assigned resources. Each plan contains one selected immutable version per resource ID. A single service cannot select two resource IDs for the same DNS zone name. Records in one name/type RRset must share a TTL. Two running DNS services cannot bind the same IPv4/port combination, including overlap with `0.0.0.0`; stopped services may share a configured listener. Normalization rejects any complete plan whose generated TOML would exceed 1 MiB, so a validated target remains exportable.

Normalization sorts services, resources, service references and DNS records because those collections are unordered. DNS owner names, SOA mname, and NS host names normalize to lowercase. SOA rname preserves the mailbox's first label case while normalizing the remaining domain labels; escaped mailbox labels are outside C0. A resource digest hashes normalized `content` only. A plan digest hashes normalized `worker_id`, `services`, and `resources`, excluding `revision`. Neither digest uses TOML formatting, comments, local paths, bootstrap identity configuration, or runtime observations. A supplied resource digest is recomputed and rejected on mismatch. Plan revision, resource version, and SOA serial remain separate values.

`diff/2` returns IDs in `services.added/replaced/removed`, IDs in `resources.added/replaced/removed`, and lifecycle transitions as `%{"id" => id, "from" => state, "to" => state}` under `services.lifecycle`. It does not execute changes. Exported TOML contains the complete plan and cannot rewrite machine-local bootstrap settings. The plan's `worker_id` is an intended-target check for the Worker, not an identity setter.

The `toml` parser is pinned to **0.7.0**. The supported TOML 1.0 subset is basic strings, decimal integers, arrays, inline tables and array-of-table syntax. Generated TOML uses the first four forms and round-trips through the pinned decoder. Source files may omit digests; generated files contain them.

## Validation

The proposed application uses normal umbrella paths for build output, dependencies, and the root lockfile. Validate the patch in a disposable assembly from the repository root, using the repository's pinned `devenv` and dependency checkout:

```sh
C0_DIR="$(mktemp -d)"
git -C "$C0_DIR" init -q
git -C "$C0_DIR" apply "$PWD/docs/phase1/config-spec.patch"
cp mix.lock "$C0_DIR/mix.lock"
ln -s "$PWD/deps" "$C0_DIR/deps"
devenv shell -- sh -c 'cd "$1/apps/yellow_dog_config_spec" && mix test && mix format --check-formatted && mix compile --warnings-as-errors' sh "$C0_DIR"
```

The shared-file owner should add the app to the umbrella and wire each runtime app that uses it, add the release/dependency wiring appropriate to the two final releases, and update the root lockfile only if dependency resolution requires it. The root currently already locks `toml` 0.7.0 and `jason`.
