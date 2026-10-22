# Management integration security

The supported boundary is **UI / HTTP v1 / MCP → verified Caller → shared authorization and commands/queries → PostgreSQL**. Management is an external OAuth resource server. It does not provide login, consent, user registration, `/authorize`, `/token`, a security-settings editor, or Worker runtime execution. See the [finite HTTP contract](management-api-contract.md), [OpenAPI artifact](management-openapi.json), and [MCP transport/client guide](management-mcp.md).

## Deployment modes and exact settings

The release defaults to `disabled`. Dynamic UI requests and both remote adapters fail closed until a trust mode is explicitly selected. Public static assets do not establish access. HTTP and MCP each require their own enable flag. Remote mutation permission additionally requires the write flag and the operation's scope; enabling a release does not implicitly enable writes.

`trusted_local` is a single-operator development boundary. Its listener and canonical resource must be loopback; proxy/external-origin configuration is rejected at startup. Each caller must have a direct loopback peer, an allowed loopback Host, and no `Forwarded`, `X-Forwarded-For`, `X-Forwarded-Host`, `X-Forwarded-Proto`, or `X-Real-IP` header. Its identity is the configured local operator and its permissions are the deployment's allowed scopes. It never falls back from an invalid remote token to local trust.

`protected_remote` verifies external access tokens for HTTP/MCP and a separate signed gateway assertion for UI traffic. The canonical resource and both issuer URLs require HTTPS, except HTTP loopback fixtures. The resource must be an origin without credentials, path, query or fragment. Configure a stable secret key base of at least 64 bytes for UI session and LiveView signing.

Only the literal value `1` enables each flag below. Environment changes are deployment changes, not client parameters.

| Environment variable | Default / meaning |
| --- | --- |
| `YELLOW_DOG_MANAGEMENT_AUTH_MODE` | `disabled`; supported alternatives `trusted_local`, `protected_remote` |
| `YELLOW_DOG_MANAGEMENT_API_ENABLED` | Off; `1` enables `/api/v1` |
| `YELLOW_DOG_MANAGEMENT_MCP_ENABLED` | Off; `1` enables `/mcp` |
| `YELLOW_DOG_MANAGEMENT_REMOTE_WRITES_ENABLED` | Off; `1` permits scoped HTTP/MCP writes |
| `YELLOW_DOG_MANAGEMENT_RESOURCE` | Canonical resource origin / access-token audience. Falls back to `EXTERNAL_ORIGIN`, then `http://127.0.0.1:<PORT>` |
| `YELLOW_DOG_MANAGEMENT_OAUTH_ISSUER` | Required external access-token issuer in protected mode |
| `YELLOW_DOG_MANAGEMENT_OAUTH_JWKS_FILE` | Required trusted local **public** access-token JWKS file |
| `YELLOW_DOG_MANAGEMENT_GATEWAY_ISSUER` | Required issuer of UI gateway assertions |
| `YELLOW_DOG_MANAGEMENT_GATEWAY_AUDIENCE` | Required audience for UI gateway assertions |
| `YELLOW_DOG_MANAGEMENT_GATEWAY_JWKS_FILE` | Required trusted local **public** gateway JWKS file |
| `YELLOW_DOG_MANAGEMENT_LOCAL_OPERATOR` | `local-operator`; trusted-local principal name |
| `YELLOW_DOG_MANAGEMENT_POLICY_REVISION` | `1`; changing it invalidates already-created Callers, including mounted UI sessions |
| `YELLOW_DOG_MANAGEMENT_ALLOWED_SCOPES` | All fixed scopes below; a space-separated configured list is intersected with the fixed vocabulary |
| `YELLOW_DOG_MANAGEMENT_SECRET_KEY_BASE` | Required stable value of at least 64 bytes in protected mode. Do not put its value in examples, logs or UI |
| `YELLOW_DOG_MANAGEMENT_BIND_ADDRESS` | `127.0.0.1`; trusted-local requires loopback |
| `YELLOW_DOG_MANAGEMENT_PORT` | `4270`; listener port, range 1–65535 |
| `YELLOW_DOG_MANAGEMENT_EXTERNAL_ORIGIN` | Optional HTTPS UI origin. Set equal to the canonical resource for a TLS gateway deployment |
| `YELLOW_DOG_MANAGEMENT_TRUSTED_PROXY_IP` | Optional exact `127.0.0.1` or `::1` peer allowed to rewrite forwarded scheme/port. This does not authenticate users or trust identity headers |

The `IntegrationSettings` application override is used by focused tests; it is not a remotely editable policy store. Its `allowed_hosts` override has no environment variable. Production Host checks default to the canonical resource hostname; trusted-local permits `localhost`, `127.0.0.1`, and `::1`. A present Origin must exactly match the canonical resource, with a matching loopback request origin also allowed in trusted-local mode. Duplicate Origin headers are rejected. An absent Origin is allowed for non-browser clients. Forwarding headers never establish a principal.

For a production gateway, terminate TLS at the gateway, preserve the canonical Host and Origin, and keep the Management listener reachable only from the intended gateway/private path. Configure `EXTERNAL_ORIGIN` and `RESOURCE` consistently. A trusted loopback proxy rewrites only scheme/port after checking the actual socket peer; it does not accept arbitrary forwarded hosts or user identity. This deployment requirement is independent of JWT signature validation.

## External access tokens and gateway assertions

HTTP/MCP accept one `Authorization: Bearer <access-token>` header. UI HTTP and WebSocket requests require one `X-Yellow-Dog-Gateway-Assertion` header in protected mode. The gateway must strip client-supplied assertion headers and inject its own assertion after authenticating the user. No unsigned actor, subject, scope, role, forwarding header, query field, form value or MCP `_meta` object can select a Caller.

Use distinct access-token and gateway issuers, audiences and signing-key distributions. The verifier selects the configured profile for the entry point; an access token is not a UI gateway credential, and a gateway assertion is not an API access token.

| Requirement | Access token | UI gateway assertion |
| --- | --- | --- |
| Signature algorithm | RS256 | RS256 |
| Protected `typ` | `at+jwt` | `yd-gateway+jwt` |
| Trusted issuer | `OAUTH_ISSUER` | `GATEWAY_ISSUER` |
| Required audience | Canonical `RESOURCE` | `GATEWAY_AUDIENCE` |
| Maximum `exp - iat` | 3600 seconds | 300 seconds |
| JWKS file | `OAUTH_JWKS_FILE` | `GATEWAY_JWKS_FILE` |

The protected header contains only `alg`, `typ`, and a nonempty `kid` of at most 128 bytes. A token has at most 16 KiB. Required claims are exact `iss`, matching `aud`, nonempty `sub` up to 256 bytes, nonempty `client_id` up to 128 bytes, integer `iat`/`exp`, and a space-separated `scope` string up to 1024 bytes. The audience may be a string or an array of at most eight strings containing the configured audience. Expiration must be in the future; issuance may be at most five seconds ahead; lifetime must be positive and within the profile limit. If present, integer `nbf` must already be reached. Encoded claims are limited to 8 KiB. Scope entries are bounded to 64 bytes and intersected with deployment permissions.

The deployment distributes issuer **public** JWKS to local trusted paths, ideally using atomic replacement and file ownership that prevents untrusted writes. Management does not download keys from request-controlled URLs or token headers. Each verification rereads its configured file: there is no stale-key fallback. A file is at most 64 KiB with 1–16 keys, and the requested `kid` must match exactly one key. The selected key is RSA with a decoded modulus of 256–1024 bytes; accepted fields are only `kty`, `n`, `e`, `kid`, optional `use: sig`, `alg: RS256`, and `key_ops: [verify]`. Private fields, `x5c`, `jku`, `x5u`, unknown selected-key fields, ambiguous or unknown key IDs, invalid JSON, missing files and oversized input fail closed.

Key removal affects subsequent HTTP requests and new WebSocket handshakes immediately after the deployed public file changes. Management does not introspect tokens, poll a revocation endpoint, refresh issuer keys itself, or implement per-token `jti` revocation. Existing signed tokens retain their granted scopes until expiration unless the deployment removes a permitted scope, disables the applicable adapter/trust mode, or removes the signing key for subsequent verification. A policy-revision change invalidates existing Callers, but a still-valid JWT may authenticate a fresh Caller under the new revision; policy revision alone is not token revocation. Removing an issuer's scope grant alone does not alter an already-issued JWT. Connected UI callbacks use the verified Caller rather than re-reading JWKS on every event, so key removal alone does not instantly disconnect an existing socket; its bounded lifetime and current deployment policy still apply.

## UI session, socket and policy lifetime

Protected UI HTTP requests verify the gateway assertion before rendering and store a signed, HTTP-only, SameSite=Lax, Secure session cookie. The session contains the verified identity, permissions and expiry, never the raw assertion, bearer token, key or provider credential. The cookie is signed, not an encrypted credential vault. Trusted-local mode does not set the Secure flag, supporting its direct HTTP loopback workflow.

A connected LiveView mount independently authenticates the WebSocket handshake, checks Host/Origin and actual peer information, and matches issuer/subject/client identity against the signed HTTP session. The resulting lifetime is the earlier of the HTTP session and current handshake expiry; permissions are the intersection of both grants. A fresh assertion cannot extend the prior HTTP session silently. A reconnect after expiry requires fresh authorized HTTP/session state.

Every mounted callback (events, parameter changes, messages and async completions) checks expiration, current deployment policy revision, allowed scopes and entry-point provenance. Idle sockets schedule an expiry message and redirect when their Caller expires. LiveComponent commands separately authorize through the same shared boundary, including receipt replay. Policy changes are checked on callbacks; they do not promise immediate idle-socket push revocation before the scheduled expiry or next callback.

`config:read` is required to enter the UI. Audit pages additionally require `audit:read`; privileged diagnostic, log, backup, task-administration, enrollment, Worker-connection/credential, Netman and network-tool pages require UI-only `ui:admin`. Corresponding mutation scopes remain independently enforced. The API/MCP information page reports `IntegrationSettings.public()` only: mode, enabled flags, canonical resource, issuer, policy revision and allowed scopes. It renders no key paths, keys, tokens, provider credentials or nonfunctional policy toggles.

## Permission and command boundary

| Scope | Capability |
| --- | --- |
| `config:read` | Bounded configuration reads, exact immutable versions/targets/exports, supported task/job/artifact metadata |
| `nodes:write` | Update logical Worker metadata and create/update DNS service instances |
| `data:write` | Zone drafts, confirmations and complete assignment replacements; scoped DNS View/ACL configuration |
| `targets:publish` | Publish the exact reviewed Worker revision as a prepared immutable target |
| `sync:run` | Queue supported City/Country synchronization and receive a persistent job ID |
| `sync:settings` | Edit supported City/Country task settings with expected revision |
| `audit:read` | Read redacted audit metadata |
| `ui:admin` | UI-only administrative capabilities; never grants a remote generic dispatcher |

All remote operations are enumerated in the shared 42-entry registry. Closed schemas reject forged actor/source/scope fields and contradictory identities. Permission checks occur before queries or receipt lookup and again inside the locked mutation transaction, including replay. Worker IDs, service database UUIDs, Zone IDs and fixed resource-version ownership are explicit. A user-visible DNS instance label cannot stand in for a service UUID.

HTTP writes use `Idempotency-Key`; MCP writes require `logical_request_key`, each 1–128 bytes. The verified issuer/subject/client plus that stable logical key identify the receipt namespace, independently of source, transport request IDs and correlation IDs. Canonical operation/payload equality permits cross-adapter retry. Different payload under the same key conflicts. Revoked/expired permissions cannot retrieve a successful receipt through replay. New intents and corrected input after a reviewed conflict need new keys. Queries create no configuration changes.

Audits record a hashed principal actor and verified issuer/subject/client/source/correlation/authentication context. Shared command request/result audit payloads use a narrow identity/revision/digest/status projection; versioned audit reads omit context and request/result payloads. They do not expose credentials, provider URLs or filesystem paths. Aggregate authentication/authorization-denial counts are bounded by fixed source/error categories and summarized every minute without request bodies or raw credentials; those counters are operational signals, not a durable audit of each rejected attempt.

## Finite limits and operational boundaries

HTTP write bodies and MCP bodies are limited to 1 MiB with five-second reads. List pages default to 20 rows and allow at most 100, with page numbers at most 100000. Zone input allows up to 1024 supported records; a complete assignment snapshot has a hard limit of 256 and is never silently paginated or truncated. Service/record/rule and target limits remain the shared schema/domain limits. No input schema dereferences a remote schema URL.

The shared limiter admits at most 32 concurrent facade calls. HTTP/MCP IP sync attempts are limited to ten per hashed principal in a process-local 60-second window, with at most 1024 active sync-principal entries. The quota is admission-based, including attempted receipt replays; it is not a durable distributed quota. Process restart resets these counters. Rate-limited calls return `rate_limited`; executed MCP calls represent it as a tool error, while HTTP uses 429. These application limits do not replace gateway connection/body/rate limits before authentication.

Saving, confirming, assigning and publishing are distinct operations. DNS Views/ACLs and IP artifacts remain excluded from current Worker exports. A completed queue job is not proof of artifact-byte verification or Worker loading; catalog reads report verification unknown. A prepared target reports actual runtime state unknown. No Management adapter starts a Worker service.

## Worker credentials, legacy paths and UI-only exclusions

Worker polling/connection under `/api/worker` uses its separate Worker credential boundary and explicit Worker identity. Opaque Worker tokens fail Management JWT verification. Management access tokens and gateway assertions do not become valid Worker tokens. UI registration/rotation requires `ui:admin`; issued bootstrap credentials are transient and are not returned by the finite remote API or MCP tools.

Protected-remote mode retires legacy `/api/...` commands and legacy reads with HTTP 410, rather than leaving an unscoped generic dispatcher. Two existing UI download paths remain: Worker target TOML export requires verified UI `config:read`, and backup download requires verified UI `ui:admin`. Neither accepts an API bearer token in place of the gateway assertion. Trusted-local development retains legacy routes under its explicit local UI authorization; legacy commands require UI administration and stable request identity. Disabled mode still denies them.

Enrollment policy, credential operations, Netman editing, backup operations, local MAC/OUI reload, network diagnostic tools, unsupported task types and platform security/settings are excluded from the versioned remote operation matrix. Existing UI administrative capabilities remain independently gated; a remote token with `ui:admin` is not a UI session and cannot open those paths. The permitted City/Country task operations use the shared facade; they do not accept arbitrary task keys, provider URLs, files or shell commands.

## Reproducible checks and CI

The scoped authorization suite exercises JWT types/issuers/audiences/lifetimes and JWKS limits; gateway/session/WebSocket identity; read-only and UI-only pages; callback expiry and policy changes; Host/Origin/local trust; legacy retirement and downloads; caller-key namespaces; cross-adapter receipt replay; and authorization after lock acquisition. Run it through disposable PostgreSQL in devenv:

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh mix do --app yellow_dog_management test test/integration_security_test.exs
devenv shell -- env MIX_ENV=test scripts/e2e/management_openapi.sh --check
devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/management_integration.sh
```

The [Phase 1 workflow](../../.github/workflows/phase1.yml) retains the Management PostgreSQL suite and both existing JavaScript suites. Its `management-integrations` job installs the configured BEAM/Node toolchains, locked npm dependencies, PostgreSQL and a Chromium-compatible Chrome executable, then runs real Redocly OpenAPI validation plus artifact comparison and the official SDK integration against a rebuilt release with disposable PostgreSQL. It uploads allowlisted logs and canonical test state; issuer private keys/client-credential files are excluded. The local SDK evidence and its limits are recorded in [Management MCP](management-mcp.md). Production identity-provider/gateway deployment and specific desktop client compatibility remain unverified until exercised there.
