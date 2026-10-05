# DNS record and mDNS redevelopment readiness

**Prior architecture-only scope (2026-10-04).** Subsequent source-only UI transfer
is recorded in `ui-source-migration.md`; it does not add record types or mDNS.
Record-type/mDNS
redevelopment and shared-contract changes below are deferred, not acceptance gates
for this task. Management authors configuration; Worker executes network services.
Existing Worker runtime failures are acceptable and are not claimed fixed.

Checked 2026-10-02 against the current dirty `main`, baseline `d83442c0`.
This is source and primitive-codec evidence, **not implemented feature parity**.
The full Console migration remains future work. This audit proposed a future real
execution slice rather than substituting more desired-data CRUD for execution.

## DNS records: next proposed executable slice

The retained Console record editor exposes A/AAAA/CNAME/MX/NS/PTR/SRV/TXT
(`apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/index.ex`,
type selector). Historical `8550aa05` also contains broader type names; their
actual authoring/runtime behavior must remain in the full-scope audit. Six missing
common types are a next slice, not a claim that all historical DNS functions are
covered. Current shared ConfigSpec, native authoring/export and Worker resolution
only support SOA/NS/A.

The proposed native RDATA contract is:

| Type | Fields | Required behavior |
| --- | --- | --- |
| AAAA | `address` | Validate/canonicalize IPv6; return the actual 16-byte address. |
| CNAME | `target` | Domain target, one CNAME per owner and no conflicting data; authoritative alias handling, not just an exact-type lookup. |
| MX | `preference`, `exchange` | Unsigned 16-bit preference and domain exchange; do not preserve the codec constructor's misleading `weight` naming in the public contract. |
| PTR | `target` | Domain target; include reverse-Zone authoring and actual wire response. |
| SRV | `priority`, `weight`, `port`, `target` | Unsigned 16-bit fields and domain target; owner validation must accept service labels such as `_http._tcp`. |
| TXT | `strings` | Ordered character-string array; preserve empty segments, case and bytes; each segment at most 255 bytes. Never whitespace-split, concatenate, reorder or silently truncate. |

These are proposals awaiting the shared-contract confirmation already presented
to the user. No new validator, UI-only unsupported field, sidecar TOML, old
payload adapter or protocol/library dependency is introduced by this audit.
Management remains PostgreSQL/UI/API; Worker remains the independent local-TOML
executor. `ex_dns` stays outside the Management release.

### Verified readiness and remaining changes

- The actual embedded `DNS.Message.Record.new/5` constructors and encode/decode
  paths roundtrip all six proposed types byte-for-byte. Cases include IPv6,
  a reverse owner, `_http._tcp`, and TXT empty/escaped/Unicode/255-byte segments.
  This proves primitive codec availability, **not Worker answers**.
- Existing `management_rrsets` already has text `type` and `jsonb[]` data, with
  Zone/name/type uniqueness. These maps do not require a new type-column migration.
- ConfigSpec currently requires an A record in every Zone. The candidate should
  instead require exactly one apex SOA, apex NS, valid in-Zone owners, consistent
  RRset TTLs and CNAME exclusivity. A valid authoritative or IPv6-only Zone does
  not require an A record. Obsolete A-required tests must not dictate the design.
- The two native editors, owner/type filters, canonical bulk workflow and
  CSV/BIND exports all need the same supported types. TXT needs lossless ordered
  editing and separately escaped BIND strings, not a text-splitting adapter.
- Worker `Dns.Resolver` currently accepts only three type codes and selects
  exact types. CNAME queries through an alias require genuine resolution behavior;
  accepting a new map or returning only direct CNAME queries is insufficient.
- `ConfigSpec.toml/1` currently delegates string quoting to `Jason.encode!`.
  Executed quote probes preserve quotes/backslashes, newline and Unicode, but
  **DEL (`0x7F`) fails `Toml.decode/1` with `illegal control character`**.
  TXT integration must correct actual TOML quoting, not discard valid text to
  make the shared codec test pass. No shared-code change is made before approval.

Executed baseline command:

```sh
devenv shell -- mix do --app yellow_dog_worker --app yellow_dog_config_spec cmd mix compile --warnings-as-errors
```

Result: exit 0. The primitive record and quote probes also have a retained local
reproducer, executed with this exact command:

```sh
devenv shell -- mix run --no-start /tmp/management-dns-rr-readiness-20261002.exs
```

Six record roundtrips pass; the diagnostic reports DEL as `NOT ROUNDTRIPPABLE`.
Its exit 0 is not an all-quotes-passing result or product acceptance. It does not
start Management, PostgreSQL, Worker listeners or legacy services, and is not
wired into default gates. No general test suite was run.

Required implementation acceptance is Management authoring and PG persistence
through immutable confirmation/export into an independent Worker, followed by
actual UDP/TCP answers for the six types, alias behavior and TXT segment fidelity.
Include IPv6-only and reverse Zones, validation rejection, original-revision CAS,
read-only previews, unchanged older immutable business exports, stopped-state
updates and restart recovery. Those checks are unexecuted and feature completion
remains unproven. Views, delegation, wildcard/RPZ/forwarding/provider effects and
the broader DNS inventory remain distinct work; this slice cannot replace them.

BIND import is independently blocked: upstream `gsmlg-dev/ex_dns#5` and `#6`
were rechecked and are still open. Six working record codecs do not fix either
parser or authorize importing `ex_dns` into Management.

## mDNS: complete source-backed business scope

Historical sources are `8550aa05` under
`apps/yellow_dog_console/lib/yellow_dog/console/live/mdns_live/`; protocol source
is under `apps/yellow_dog_mdns/lib/yellow_dog/mdns/`.

| Page | Functions and data that must be retained |
| --- | --- |
| Services | List, All/Enabled/Disabled filter, create/edit with validation, cancellation, toggle, confirmed deletion and filtered CSV. Inputs include name, type, port, TXT, **IPv4/IPv6 addresses and enabled**; the simpler later form is not a complete inventory. Domain/source are displayed, not editor inputs. |
| Discovery | Passive actual observations, name/type search, type filter, service/type/host counts, periodic refresh, detail modal and filtered CSV; host/port/addresses/TXT/last-seen are received data, not desired registration facts. No invented adoption or editing workflow. |
| Monitor | Actual query/response/host/service measurements, rate/top names, query time/source/name/type/class, search, 50/100/200/500 limits, refresh/pause, CSV and confirmed **runtime cache/history/discovery clearing**. Historical CSV covers retained observations/statistics, not just the displayed search. |
| Overview | Actual running/mode/registry/network state and refresh. Saving a Management draft does not establish any of these measurements. |

Historical registration identity is `name.type.local`; it belongs to the local
executing registry, not a global reusable catalogue. Registration TTL 4500 is
DNS cache lifetime, not a lease expiry. Original saves/deletes request local-file
persistence; the native Worker must instead use the one committed local plan.
Do not retain parallel legacy file persistence or identity-format compatibility.

### Actual reuse and defects, not feature claims

Reusable algorithms include PTR/SRV/TXT/A/AAAA construction, known-answer
suppression, response construction and Abyss multicast transport. The legacy
`yellow_dog_mdns` application cannot be enabled unchanged: it depends on
`yellow_dog`, `yellow_dog_store`, legacy telemetry/config/file watching and
Console notifications. Global names, named ETS and `persistent_term` also prevent
independent instances. Redevelop an owned Worker adapter; do not add a third
business runtime or import legacy Store into either product.

Historical toggling only changes `enabled`, while responder selection uses
`state == :registered`; editing also fails to rebuild the derived identity.
Those defects must not become native semantics. Goodbye sends are asynchronous;
removing a row is not proof of delivery. Comments about probing/announcing are
not evidence that the old registry implemented them.

The old TXT form silently drops malformed lines/duplicate keys and lacks wire
byte limits. Native validation must not preserve silent loss. Discovery expiry,
TTL-zero removals, actual packet/query counters and observation timestamps need
real execution evidence; incorrect old counters or a Management poll timestamp
are not acceptable substitutes.

Implementation still needs coordinated mDNS ConfigSpec/Worker scope, interface
and IPv4/IPv6 multicast policy, registration/rename/enable/delete lifecycle, and
an approved genuine observation/command boundary for Management Discovery,
Monitor and cache clearing. Management-only registration CRUD would remain a
partial desired-data feature and must not be selected as full mDNS migration.
