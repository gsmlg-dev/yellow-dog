# ADR: Managed authoritative DNS response semantics

**Status:** Implemented for M2
**Date:** 2026-09-29
**Scope:** Managed zones published through the M1 Management and Server Agent path

## Decision

Managed zones support `IN` A, AAAA, NS, SOA, CNAME, MX and TXT RRsets. TXT data is an ordered list of wire segments, while RRsets and records have deterministic snapshot ordering. Management normalizes names and typed RDATA before publication; the shared manifest validates the same supported subset before the Server installs it. Unknown fields, unsupported types and child NS delegations are rejected. An apex SOA and NS are required, CNAME cannot coexist with other data at its owner, and local CNAME cycles are invalid. Management remains the only writer for managed zones.

The managed resolver uses the closest existing ancestor to choose a wildcard. Empty nonterminals exist for DNS lookup but have no RRset of their own. Negative authoritative answers include the published SOA, with its TTL capped by the SOA minimum. CNAME resolution follows a bounded in-zone chain and stops at the zone boundary; it never invokes recursion or a forwarder. Managed answers set AA and clear RA. Unsupported protocol operations return an explicit error instead of being interpreted as missing records.

UDP responses honor the classic 512-byte size or the advertised EDNS size, capped at 1232 bytes. Oversized UDP answers set TC so clients can retry over TCP. TCP responses use the DNS 16-bit frame limit rather than the UDP limit. A managed zone has a 60,000-byte uncompressed RR wire budget; wildcard records count a maximum-length synthesized owner. This leaves room for header, question and authority data in a TCP DNS message. Duplicate OPT records and unsupported EDNS versions are handled at the packet boundary before zone lookup.

These rules apply only to managed zones. Existing explicitly unmanaged zone and recursion behavior retains its own contracts. This milestone does not add DNSSEC, transfers, dynamic updates, child delegation service, or four-node lifecycle work.

## M2 gate

- [x] Table-driven Management and shared-manifest tests cover each supported type, canonical input, CNAME rules, apex/zone checks and size limits.
- [x] DNS runtime tests cover closest-encloser wildcard and empty-nonterminal responses, negative SOA TTL, CNAME bounds, unsupported queries, cache reload and EDNS.
- [x] Real UDP/TCP tests cover all seven types, positive/negative answers, AA/RA, truncation and complete TCP replies.
- [x] Separate-release HTTP → Agent → DNS tests cover expanded types without bypassing publication.
- [x] Scoped compile, formatting, unit and E2E gates pass; unrelated baseline failures remain recorded separately.

## Verification

On the M2 worktree, `devenv shell mix test.e2e.management` passed 2 tests, including the authenticated HTTP publication through the real Agent into a separate Server release. `devenv shell mix test.e2e.dns` passed 107 tests with 19 excluded, including direct UDP/TCP positive, negative, EDNS, truncation and TCP-frame checks. The DNS app suite passed 1,196 tests with 1 skipped; the Sync app suite passed 140 tests; focused Management DNS and Console API suites passed 13 and 3 tests. The `ex_dns` suite passed 4,765 tests and 4 doctests with 1 skipped after the authority-section serialization fix. Warnings-as-errors compilation and formatting checks passed.

The DNS E2E gate still emits existing test-helper compiler warnings and metrics-handler ETS teardown errors while exiting successfully. The unrelated Boot controller baseline failure is recorded in the M1 ADR; it was not changed for M2. Four-node convergence, lifecycle operations, load measurements and public deployment proof remain M3–M4 gates.
