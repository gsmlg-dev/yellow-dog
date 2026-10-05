# BIND import: business scope and verified parser blockers

Checked 2026-10-02 on dirty `main`, baseline `d83442c0`. This is source and
failure evidence, not an approved design or completed BIND migration.

## Business functions to retain

Historical `8550aa05` establishes two distinct functions:

- Create an authoritative Zone from pasted BIND content, using its parsed apex.
- Preview and append BIND records into an explicitly selected existing Zone.

Existing-Zone import **appends**, not replaces. The source is
`apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/zone_live/index.ex`
(`import_bind_zone/3`, historical line 561),
`dns_live/rr_live/index.ex` (`preview_bulk` and `bulk_add_rrs`, line 180), and
`apps/yellow_dog_dns/lib/yellow_dog/dns/zone/auth.ex` (historical import handler
line 521 and ETS bag insertion line 1335). Bulk preview shows actual record/type
counts and parse errors. The displayed CSV-import option is unsupported in the
historical handler; it is not evidence of a functioning CSV import.

The earlier coordinator suggestion to replace the existing draft is not a
faithful substitute for append. It is superseded by this source finding, not
implemented or approved. Do not treat an answer to that earlier suggestion as
permission to remove append from the migration scope.

Do not preserve historical SOA omission, incorrect success counts, partial
startup before validation, asynchronous persistence success claims, automatic
`imported.zone` naming, or unvalidated origin overrides. These are bugs or
unresolved design choices, not compatibility requirements.

## Verified upstream blockers

The pure `DNS.Zone.Parser` rejects the current Management BIND export because
it requires parentheses even for valid single-line SOA. It also rejects omitted
owners and does not retain each record's effective origin/default TTL context.
Tracked as [gsmlg-dev/ex_dns#5](https://github.com/gsmlg-dev/ex_dns/issues/5).

`DNS.Zone.FileParser` is not a safe alternative. It reports success after
dropping unknown record types and clearing accumulated parse errors. It shifts
parenthesized SOA numbers and interprets an inherited-owner TTL as a new owner.
Tracked as [gsmlg-dev/ex_dns#6](https://github.com/gsmlg-dev/ex_dns/issues/6).

Both issues are type `Bug`, labeled `internal request`, severity `blocker`.
The local embedded parsers were executed. Upstream
`main@aad4eadcf06d12d6179b226235c1656cf571673e` was source-inspected and retains
the implicated logic; it was not executed. The embedded sources differ from
upstream, including local exception-handling refinements. No upstream fix or
dependency update is claimed.

The reproducible standalone candidate-parser diagnostic is:

```sh
devenv shell -- mix run --no-start scripts/e2e/management_bind_parser_gate.exs
```

It invokes pure parsers and the current Management exporter without starting
Management, Worker, PostgreSQL, or DNS services. Its upstream fidelity assertions
are intentionally not skipped or inverted. It is a manually selected BIND
blocker diagnostic, not an added requirement that unrelated tests must pass. Passing
the gate alone would not prove complete BIND import, every parser requirement,
or full Console parity. Executed on 2026-10-02: **7 checks, 6 failures**, exit 2;
the supported parenthesized AST control passes, and each reported upstream
failure reproduces. This is a failing dependency gate, not a passing smoke test.
The exploratory 23 paired cases and exact outputs are
at `/tmp/management-bind-parser-audit-20261002.exs`,
`/tmp/management-bind-parser-audit-20261002-results.txt`, and
`/tmp/management-bind-parser-audit-20261002-command.log`.

Independent existing-export verification executed:

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh mix do --app yellow_dog_management cmd mix test test/dns_record_exports_test.exs
devenv shell -- bash -lc 'cd apps/yellow_dog_management && mix compile --warnings-as-errors'
devenv shell -- mix format --check-formatted scripts/e2e/management_bind_parser_gate.exs
```

All three pass: export tests are 5/0; disposable PostgreSQL evidence is
`/tmp/yellow-dog-phase1-pg.aTpynz`. This does not make the parser diagnostic green.
No release dependency, ConfigSpec, application data or development service is
changed by this audit. The existing management unit remains active and the
unauthenticated import page returns HTTP 200 on port 4270; it still imports
WorkerPlan TOML, not BIND.

Both candidate APIs currently fail the requirements; stop the blocked BIND
implementation. Do not rewrite
input, replace the parser locally, discard unsupported content, or change the
valid exporter merely to avoid a parser bug. Resume when at least one appropriate
upstream API is fixed and the embedded dependency is updated and rechecked against
the complete intended import scope. An unused alternative parser need not become
an all-green prerequisite. This diagnostic is not wired into existing product
acceptance or the default test suite.

## Separate decisions still pending

The current Management release forbids `ex_dns` in both
`scripts/e2e/check_release_boundary.exs` and
`apps/yellow_dog_management/test/release_smoke.py`. Allowing its pure parsing/
codec library without service execution has been presented for user confirmation;
the restriction has not been weakened. A parser fix alone does not authorize a
dependency-boundary change.

The current shared WorkerPlan accepts SOA/NS/A only. Additional original record
types remain required for the full goal and need coordinated shared-contract
evolution; partial import must never discard them. No codec change is made here.
View–Zone ownership, duplicate/apex/SOA merge policy, missing-origin behavior,
directive policy, input limits and actual import UI acceptance remain unresolved.
Native append must use original-revision CAS, preserve unrelated draft records,
fail atomically on malformed/out-of-zone/unsupported input, and leave immutable
versions and historical target exports unchanged. Preview must not write or
publish; runtime application must not be inferred from draft-import success.
