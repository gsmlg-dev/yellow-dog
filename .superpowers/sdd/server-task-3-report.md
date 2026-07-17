# Server Task 3G Report

## Scope

Task 3G started at `b1d19fab27e49ade7146f5f752337c4cac367692` on
`codex/service-node-remote-management`. Owned changes are limited to:

- `apps/yellow_dog/test/yellow_dog/server/control/dns_test.exs`
- this report

The pre-existing dirty console files and root `mix.exs` were not modified,
formatted, staged, or reverted. No product behavior was changed: all decided
unsupported paths were already safe and correctly classified.

## Mutation Audit

| Server operation family | Current status | Boundary rationale |
| --- | --- | --- |
| Views create/update/delete | Unsupported | `ViewManager` has runtime methods, but no synchronous durable CRUD facade with activation rollback. |
| Zones create/update/delete | Supported for authoritative zones | Uses `Store.Zone` durability and `ZoneController` lifecycle compensation. Forward create is unsupported before any dependency call because the wire payload has no forwarders. |
| Zone import | Unsupported for both `current/2` and `dispatch/2` | No authenticated, materialized, verified, parsed source owner exists for provider/snapshot/blob metadata. |
| Zone sync | Supported for a valid enabled Cloudflare/Route53 mirror | Enqueues the durable cloud-zone task and returns accepted, not completed, semantics. |
| Records create/update/delete | Supported for fixed A/AAAA/CNAME/MX/NS/PTR/SRV/TXT RRsets | Fixed string-to-existing-atom mapping and Store/runtime rollback preserve exact RRset semantics. |
| ACL create/update/delete | Unsupported | `AclRegistry` writes are asynchronous; no synchronous durable ACL owner facade can prove persistence and rollback. Read/current projection remains available only when lossless. |
| Providers create | Unsupported | There is no authenticated credential materializer for the wire `credential_ref`. |
| Providers update/delete | Supported only for an existing supported provider | Update preserves the computed local credential reference; external references, non-nil endpoints, and RFC 2136 are unsupported before provider facade calls. |
| Conflict resolve | `use_cloud` and Cloudflare `use_local` supported; Route53 `use_local` unsupported | Route53 lacks complete signed remote application. The owner returns `unsupported` without changing DNS state. |

## Added Boundary Evidence

- Forward-zone create continues to return typed `unsupported` with zero calls.
- Provider/snapshot source and blob imports return typed `unsupported` from both
  `current/2` and `dispatch/2` with zero calls.
- Provider creation, external credential references, non-nil endpoints, and
  RFC 2136 all return typed `unsupported` before provider facade calls.
- Route53 `use_local` propagation returns typed `unsupported` without local DNS
  state mutation; the provider suite verifies the owner rejects it before a
  remote engine call.
- Malformed mutation values and 100 untrusted record-type strings return
  `invalid`, create no atoms, and make no dependency call.

## Verification

All commands ran through `devenv shell`.

| Command | Result |
| --- | --- |
| `cd apps/yellow_dog && mix test test/yellow_dog/server/control/dns_test.exs` | 71 tests, 0 failures |
| `cd apps/yellow_dog_store && mix test` | 404 tests, 26 properties, 0 failures, 9 skipped |
| `cd apps/yellow_dog_dns_provider && mix test` | 149 tests, 4 properties, 0 failures |
| `cd apps/yellow_dog_tasks && mix test` | 58 tests, 0 failures |
| `cd apps/yellow_dog_dns && mix test` | 1,168 tests, 0 failures |
| `cd apps/yellow_dog && mix test` | 326 tests, 0 failures |
| `cd apps/yellow_dog && MIX_ENV=dev mix compile --force --warnings-as-errors` | exit 0 |
| `cd apps/yellow_dog && MIX_ENV=test mix compile --force --warnings-as-errors` | exit 0 |
| `cd apps/yellow_dog && mix format --check-formatted test/yellow_dog/server/control/dns_test.exs` | exit 0 |
| `cd apps/yellow_dog && mix credo --strict test/yellow_dog/server/control/dns_test.exs` | 21 mods/funs, no issues |
| owned diff check and forbidden-path scan | clean; no packet handlers, raw UDP, direct Concord, new apps, or generic Node code |

The Store, DNS-provider, and Tasks suites emit expected warning logs from
failure-path fixtures; none are failures. Remaining limitations are intentional:
no durable view/ACL mutation owner, no authenticated import source or credential
materializer, and no complete Route53 `use_local` signing path.
