# Management exports and the next artifact integration boundary

## Current supported export

Management persists DNS Views, global Zone drafts, confirmed Zone versions and
logical Worker assignments in PostgreSQL. It also synchronizes a global,
versioned Country/City MMDB catalog. None of these saves proves Worker execution,
delivery, loading, availability or health.

The current pure `YellowDog.ConfigSpec` WorkerPlan represents DNS service
listener settings and confirmed Zone resources selected through assignments.
It does not represent DNS Views, their ACL/rule configuration, or IP database
artifact references. The supported export scope is `dns_zones`; an omitted
scope selects this same limited export.

The export response declares `X-Yellow-Dog-Export-Scope: dns_zones` and
`X-Yellow-Dog-Export-Excludes: dns_views,geoip_artifacts`. Requesting
`?scope=dns_zones` keeps the existing confirmed TOML bytes and digest unchanged.
Requesting `?scope=full` returns a structured `unsupported_export` response
instead of silently discarding unsupported configuration. Other scope values
are invalid requests. This serialization limit does not prevent saving valid
configuration drafts, confirming Zone versions or editing assignments.

Existing historical targets retain their immutable plans. This increment does
not extend the WorkerPlan schema or add a competing Management wire format.
Target preparation and export remain independent of a connected Worker.

## Current artifact publication

Management-local synchronization jobs download through controlled server-side
sources, bound compressed and decompressed data, validate MMDB structure and
kind, and publish read-only, SHA-256-addressed files in the configured durable
artifact directory. PostgreSQL holds immutable artifact metadata, independent
Country/City selections and immutable task receipts; MMDB bytes stay on disk.

A job succeeds only after a valid durable file and metadata publication.
File publication precedes the database transaction: a failed transaction may
leave an unreferenced immutable file but cannot select partial bytes. Duplicate
content reuses its artifact, and job claims and selection ordering prevent an
older retry or receipt from replacing a newer selection. No resident Management
GeoIP query process is required. Catalog reads return metadata only, with
unverified availability, and query a deterministic page of 20 historical rows
per kind (one extra SQL row detects the next page). The selected artifact is
fetched separately when outside that page.

The IP Database LiveView checks only selected files asynchronously, with at most
one pending check and one retained result per kind per mounted page. It shows
unverified/checking/available/unavailable states and the last integrity-check
time. Explicit Refresh revalidates; task updates reuse a result for up to 60
seconds and then revalidate on the next update. Pending checks are deduplicated;
selection changes cancel the prior task and reject stale results. Historical
rows remain unverified. These page-local results are discarded on unmount and
never authorize artifact access.

`TaskArtifacts.get/2` always checks actual immutable bytes, and publication
retains full size/digest/MMDB/kind validation. A missing or changed selected file
is reported unavailable after the asynchronous check even when metadata and a
successful historical job remain present. A later failed synchronization can
coexist with an available earlier selection.

No aggressive artifact garbage collection is implemented. Selections and
historical metadata must continue to retain their referenced files.

## Requirements for the next increment

The next increment must first extend the shared ConfigSpec deliberately for the
configuration and artifact references it will distribute. The following are
requirements for that work, not implemented transfer or Worker behavior:

- Derive required database kinds from a Worker's effective assigned service
  configuration, including relevant View/rule configuration. Country-dependent
  rules require an appropriate Country dataset. City data is required only when
  a configured feature actually consumes City fields. Do not add a separately
  maintained recipient list or manual per-Worker database assignment workflow.
- Freeze artifact references when creating a distributable target. Each logical
  reference identifies kind, format, content digest and byte size. Do not put
  Management absolute paths, source credentials or expiring download URLs into
  the contract. Historical targets must not resolve a mutable `latest`
  selection during delivery. Current limited target rows have no such artifact
  references and do not claim this freezing behavior.
- Transfer MMDB files separately from TOML. The Worker verifies digest, size and
  format, persists bytes durably, and switches only after successful local
  loading. On validation or loading failure it retains its last valid version.
  Runtime reporting must identify the digest actually in use.
- Initial installation without a required dataset reports the missing dependency
  and does not claim the dependent feature is ready. Disconnecting Management
  must not invalidate a dataset already accepted and persisted locally.

Worker enrollment, authentication, transfer clients, sockets, polling, delivery,
MMDB runtime loading and network-service repair remain outside this increment.
