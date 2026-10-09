# Anonymous Worker initialization

Approved by the user on 2026-10-09. Management may enable anonymous initialization
from the Workers page; it is disabled by default and persisted in PostgreSQL.
Worker needs only a Management URL. The user currently connects over a VPN:
accept HTTP origins as well as HTTPS; client certificates are optional.

Anonymous means no manually provisioned identity or credential. Before its first
request, Worker creates a UUID and random 32-byte connection credential under
the existing LocalStore exclusive lock, persists both privately and durably, and
then reuses the normal Bearer `/api/worker/connect` request. Management stores only
the hash. An unknown UUID with an empty initial runtime report may be enrolled
when the setting is enabled; retries with the same credential return the same
Worker. Existing IDs always require their existing credential, including after
rotation. Disabling initialization does not disconnect registered Workers.

Management serializes enrollment and setting changes using the singleton settings
row. Worker creation and setting writes go through Domain audit/idempotency;
tokens never enter Domain parameters, normal state or logs. Worker credentials
are bound to their Management origin. Invalid or uncertain local credentials fail
closed rather than silently generating another identity.

The default Worker state directory uses systemd STATE_DIRECTORY when present,
otherwise the user's XDG state directory. Explicit data_dir and existing local
or manually provisioned managed bootstrap remain supported. The minimal bootstrap
is `management_url = "http://VPN_MANAGEMENT_ADDRESS:4270"`.

An enrolled Worker has no services until the operator configures and publishes a
complete target in Management. Execution, rollback and durable snapshots continue
through the existing Worker ServiceManager; no legacy runtimes are introduced.

Verify persisted default-off settings/UI, one creation across retries/concurrent
requests, rejected wrong/revoked credentials, secret-safe reports, durable private
Worker credentials under failures/restarts, VPN HTTP origins, and actual independent
release registration plus UDP/TCP DNS start/stop and restart. Update Nix deployment
instructions to cover URL-only bootstrap and optional TLS. Target-host deployment
and changes to the public Caddy configuration are outside this implementation.
