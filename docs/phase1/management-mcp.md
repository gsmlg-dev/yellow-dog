# Management MCP

See the [final Step 3/4 acceptance report](management-step4-acceptance.md) for the
rebuilt-source SDK/browser evidence, package hashes and remaining platform limits.

Management serves MCP at `/mcp` inside its Gaoxy/Phoenix release. The supported protocol is **2025-11-25**, exercised by the official TypeScript SDK **1.32.1** pinned in the root npm lockfile. This adapter does not advertise the newer 2026-07-28 lifecycle. Its finite 42-tool contract is shared with [HTTP API v1](management-api-contract.md) through `Operations`, `ApplicationAPI`, and the existing transaction-backed Domain. It creates no additional configuration store or runtime service.

## Transport and lifecycle

Use Streamable HTTP. Send `Content-Type: application/json` with UTF-8 encoding and `Accept: application/json, text/event-stream`. POST bodies contain a single JSON-RPC 2.0 message; batching is rejected. The body limit is 1 MiB, with a five-second body read timeout. Request IDs must be integers or strings of at most 256 bytes. `_meta`, when present, must be an object and never establishes identity, permission, or implicit scope.

First send `initialize` with `protocolVersion`, object `capabilities`, and `clientInfo.name`/`version`; the server replies with its supported revision. If the client requested another revision, it must decide whether to use the returned version. Send `notifications/initialized` after accepting that response. Subsequent messages require `MCP-Protocol-Version: 2025-11-25`. Missing or unsupported subsequent versions receive HTTP 400. Initialization notifications are invalid.

The server advertises only tools, without list-change notifications. `ping`, `tools/list`, and `tools/call` are supported. Accepted notifications and client responses return HTTP 202 with an empty body. Responses to requests use JSON. GET and DELETE return 405 with `Allow: POST`; there is no GET event stream, session identifier, persistent transport session, server-initiated request, subscription, prompt, Resource catalog, or MCP task engine. Reconnect by initializing a fresh client. Business request identities survive transport disconnection independently.

Malformed JSON/envelopes produce JSON-RPC parse/invalid-request errors. Unknown methods use `-32601`; unknown tools or malformed method parameters use `-32602`. Transport failures use meaningful HTTP status codes (400, 401, 403, 405, 406, 413, 415, 503). Authentication failures include the OAuth protected-resource challenge. Executed-tool validation, authorization, concurrency and business failures return an MCP tool result with `isError: true` and canonical error data.

Every tool advertises a closed input schema and an output schema. Structured results contain either `{"data": ..., "correlation_id": "..."}` or `{"error": {"code": "...", "message": "...", "details": ...}, "correlation_id": "..."}`. A text content block contains the same serialized envelope. Tool output schemas wrap the registry's data schema and error alternative. HTTP and MCP preserve the same business error codes; for example a stale reviewed revision is `revision_conflict`.

## Authorization and setup

Both remote adapters are disabled by default. See [integration security](management-integration-security.md) for deployment settings and trust boundaries. Protected remote access requires the configured external OAuth issuer, canonical resource origin, public access-token JWKS file, and explicitly enabled API/MCP/write flags. Access tokens use RS256 with `typ: at+jwt`, trusted `kid`, matching `iss` and resource `aud`, bounded `sub` and `client_id`, valid `iat`/`exp`, and explicit scopes. Management verifies tokens; the external server owns login, consent and issuance. Management does not implement `/authorize` or `/token`.

`/.well-known/oauth-protected-resource` describes the canonical resource, external authorization server, supported scopes and Bearer-header token presentation. Follow the server's `WWW-Authenticate: Bearer resource_metadata="..."` challenge. Deployments distribute public issuer keys to the configured local JWKS file out of band. Validation rereads that file and does not follow token-controlled URLs. The UI uses a separate gateway assertion profile, signing trust and audience; API bearer tokens and Worker credentials do not establish a UI gateway session.

For an externally registered machine client, the supported official SDK setup is:

```js
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { ClientCredentialsProvider } from '@modelcontextprotocol/sdk/client/auth-extensions.js';

const provider = new ClientCredentialsProvider({
  clientId: process.env.OAUTH_CLIENT_ID,
  clientSecret: process.env.OAUTH_CLIENT_SECRET,
  expectedIssuer: process.env.OAUTH_ISSUER,
  scope: 'config:read data:write',
});
const client = new Client({name: 'management-client', version: '1.0.0'});
await client.connect(new StreamableHTTPClientTransport(
  new URL(process.env.MANAGEMENT_MCP_URL), {authProvider: provider}
));
const catalog = await client.listTools();
const result = await client.callTool({
  name: 'zone_get', arguments: {id: process.env.ZONE_ID}
});
await client.close();
```

The authorization server must support the chosen client grant; no credentials are supplied by the integration information page. The explicitly enabled trusted-local development mode accepts only direct loopback callers, without forwarding headers or a proxy. It is a separate trust mode, not an authentication fallback.

## Tools and write semantics

The [42-operation matrix](management-api-contract.md) is the canonical tool reference. `tools/list` filters by the caller's current permissions. All calls reauthorize, including direct calls to unlisted tools and stored receipt replay. Reads require `config:read`, audit reads `audit:read`; writes separately require `nodes:write`, `data:write`, `targets:publish`, `sync:run`, or `sync:settings`, and the deployment must enable remote writes.

Worker and service scope is explicit. Service database UUIDs and user-visible DNS instance labels are distinct. Zone versions and assignment snapshots use fixed resource identities. Lists are bounded, stable pages; the complete assignment snapshot is limited to 256 and is not silently truncated. Neither the protocol session, previous call, UI selection, nor `_meta` chooses a Worker or service.

Every command tool adds required `logical_request_key` (1–128 bytes). Generate a key once for a new user intent. Reuse the same key and identical canonical operation/payload after losing a response, including through a new connection or HTTP `Idempotency-Key`. The caller's verified issuer/subject/client identify the receipt namespace. Changed payload under the same key conflicts; corrected input after a reviewed conflict needs a new key. JSON-RPC IDs are never business request keys. Receipt replay cannot restore expired or revoked permissions.

Save a Zone draft, confirm a version, replace the complete assignment snapshot and publish a Worker target as distinct actions. Assignment replacement requires the current assignment token and revisions for the union of previous and proposed Workers. Publication requires the exact Worker revision returned by the reviewed preview. HTTP, UI and MCP use the same locks, revisions, receipts and audit boundary; a stale client cannot partially overwrite canonical state.

IP synchronization returns a persistent queue job ID. Query that job for completion separately. Catalog reads return metadata and `verification: unknown`, not filesystem byte verification or Worker loading. A failed replacement keeps the previous selected artifact. DNS Views, ACLs and IP artifacts remain excluded from current Worker target exports. A prepared target still reports actual runtime state as unknown.

Credential issuance/rotation, Worker registration, enrollment policy, Netman configuration, arbitrary task/provider URLs, filesystem resources, raw Domain command dispatch and Worker runtime controls are excluded. Use the existing UI registration workflow for logical Workers. No generic dispatcher tool bypasses this finite contract.

## Reproducible integration gate

Run from the Nix environment against disposable PostgreSQL:

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/management_integration.sh
```

The runner builds the actual release, starts a separate fixture OAuth issuer and IP download source, exports public access/gateway JWKS out of band, and executes the real SDK over HTTP. Chromium receives a distinct gateway assertion. Fixture signing keys and OAuth credentials are removed on shutdown; PostgreSQL, release, issuer and source processes are stopped by their owning shell.

The gate checks external discovery/token acquisition and the pinned lifecycle; schema-backed tool discovery; UI creation of two Workers, DNS instances and a Zone; HTTP draft update; MCP immutable confirmation and fixed assignments; UI canonical rereads; concurrent stale writes/publication; exact reviewed target/export; a committed response discarded at the HTTP boundary followed by new-connection and cross-adapter replay with exactly one receipt/audit; read-only replay denial; successful and failed fixture-backed sync; sanitized integration information; and Management restart with fresh SDK/Chromium clients reading the same durable configuration, immutable objects, export, audit and receipt identities.

This fixture validates the chosen external OAuth resource-server integration and maintained SDK. It does not claim compatibility with an unexecuted desktop client, a real production identity provider, ARM runtime, or target-host deployment.

## Validated evidence (2026-10-23)

The focused MCP, navigation and integration information suite passed **14 tests, 0 failures** against disposable PostgreSQL. JavaScript syntax checks and the integration shell syntax check passed.

The rebuilt x86_64 Linux Management release completed the full official SDK **1.32.1** integration command above with exit 0, including the external client-credentials flow, a separately registered read-only client whose grant is capped by the external fixture issuer, all cross-entry actions, dropped-response replay, fixture sync, and process restart. Restart assertions compare the final canonical assignment snapshot after the intentional Worker rename and publication, while independently asserting that assignment IDs and pinned version IDs did not change. No production identity provider or desktop MCP application was exercised.

Local evidence: `/tmp/yellow-dog-step4-mcp-final.log`, `/tmp/yellow-dog-step4-sdk-integration-final.log`, release/browser artifacts `/tmp/yellow-dog-management-integration.SX14XQ`, and disposable PostgreSQL artifacts `/tmp/yellow-dog-phase1-pg.p53tyv`. Owning shells stopped their processes; the fixture issuer's private signing keys and client credential file were removed.

`MIX_ENV=prod mix compile --warnings-as-errors` and the focused `mix format --check-formatted` command also passed; local logs are `/tmp/yellow-dog-step4-mcp-compile.log` and `/tmp/yellow-dog-step4-mcp-format.log`. The wider Management, OpenAPI, navigation/node/data browser, architecture and offline gates are recorded separately by their coordinating acceptance workflow.
