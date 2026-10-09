# Worker management and authenticated connection

Approved by the user on 2026-10-09: `/management/servers` is the Worker management table; creation requires only a name, generates an ID and token, and provides a complete Worker connection configuration. New Workers start with no enabled services. Complete the real connection and DNS service-control loop, then add other services separately.

Management owns PostgreSQL configuration, immutable confirmed targets, credentials and observed status. Worker owns local bootstrap, state and network execution. Keep the two independent releases and pure ConfigSpec; do not reuse legacy Agents or execute network services in Management.

Worker actively polls a dedicated Bearer-authenticated endpoint. The token scopes all requests to one Worker; its hash is stored, never the plaintext. Creation and rotation reveal it once. Each request reports supported capabilities, actual service states, and the last successfully applied target revision/digest; responses return only this Worker's latest confirmed complete plan. Saving a draft is distinct from publishing it. Failed or stale plans never replace the last committed runtime; connection failure preserves services and durable snapshots.

Bootstrap supports local-file mode and explicit managed mode. The generated managed snippet includes worker ID, local data directory, Management URL and token. HTTPS validates peer certificates; optional CA/client-certificate/client-key paths support the deployed TLS boundary. Loopback HTTP is allowed for disposable integration tests. Tokens stay outside WorkerPlan and ordinary status/audit output.

The list shows name, actual connection state, reported services, last contact and management actions. Creation has one name field; connection configuration is shown after creation or token rotation. Detail shows service desired versus actual state and explicit publication of the complete confirmed target. Only DNS is executable today; do not present other services as supported.

Acceptance: name-only creation; no initial services; credentials absent from normal queries/audits; token rejection, isolation and rotation; actual Worker connection; DNS real socket start/stop; restart preserves stopped state; Management outage leaves the committed runtime intact; reconnection, stale-target rejection, and failed-target rollback. Run only scoped Management/Worker checks plus the new cross-product smoke, formatting and strict compilation.
