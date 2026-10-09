# Yellow Dog Worker — Linux x86_64

This package contains the Worker, Erlang runtime and native socket library.
Elixir, Erlang, Nix, PostgreSQL and Docker are not required on the Worker host.
The supported baseline is Debian 12 x86_64 (glibc 2.36 and OpenSSL 3).
Alpine/musl and other architectures are not supported by this package.
Only authoritative DNS is currently executable.

Install the system libraries and durability helpers on Debian 12:

```sh
sudo apt-get update
sudo apt-get install -y ca-certificates libatomic1 libncurses6 libstdc++6 \
  openssl util-linux coreutils
```

## Download and unpack

Download the `.tar.gz` and its `.sha256` from the same GitHub Release.
Replace `VERSION` below with that release's version (without the `v` prefix).

```sh
sha256sum -c yellow-dog-worker-vVERSION-linux-x86_64.tar.gz.sha256
mkdir yellow-dog-worker
tar -xzf yellow-dog-worker-vVERSION-linux-x86_64.tar.gz -C yellow-dog-worker
cd yellow-dog-worker
```

## Connect to Management

Upgrade Management to this release and apply its database migrations first.
In Management → Workers (`/management/servers`), enable **Allow anonymous Worker
initialization** (off by default). For direct VPN access, save this as `bootstrap.toml`:

```toml
management_url = "http://VPN_MANAGEMENT_ADDRESS:4270"
```

Management must listen on an address reachable from the VPN. No client certificate
is required for direct VPN HTTP access. HTTPS, private CA and mutual TLS are optional;
an HTTPS gateway that requires client certificates still requires them.

Worker generates its ID and token once and saves private `connection.toml` (0600)
in its state directory (0700). The default is `$STATE_DIRECTORY`, otherwise
`$XDG_STATE_HOME/yellow-dog-worker` or `~/.local/state/yellow-dog-worker`.
You can set an absolute `data_dir` in the bootstrap. Preserve the entire directory
between restarts and upgrades; do not copy credentials to initialize another host.
Retries and restarts reuse the identity. Closing anonymous initialization prevents
new registrations while existing Workers continue authenticating.

Alternatively, create a Worker using its name in Management and save its generated
connection configuration as `bootstrap.toml`. It supplies the ID, URL and token;
use a persistent absolute `data_dir`. `examples/managed-bootstrap.toml` is illustrative.
Keep the bootstrap and optional TLS private key readable only by the Worker user.
For private CA or mutual TLS, set `tls_ca_file`, `tls_cert_file`, and `tls_key_file`
to local file paths (relative paths resolve against the bootstrap file).

```sh
chmod 600 bootstrap.toml
export YELLOW_DOG_WORKER_BOOTSTRAP="$PWD/bootstrap.toml"
export RELEASE_DISTRIBUTION=none
bin/yellow_dog_worker start
```

The command runs in the foreground. Worker waits for a confirmed target on first
boot. Configure and publish DNS services in Management; saving a draft does not
start them. Worker reports actual execution state to Management. If Management is
unavailable, Worker preserves its committed services and recovers them on restart.
After rotating the token in Management, use its new manual connection configuration,
preserving the same Worker ID and state directory, and restart. Revoked credentials
cannot register again, even when anonymous initialization is enabled.

Use a local Linux filesystem for `data_dir`; keep it between restarts and upgrades.
Only one Worker may own a data directory. DNS ports below 1024 require OS privileges;
use an unprivileged port when trying the package. Stop foreground execution with
Ctrl-C (then `a` if Erlang displays a break menu), or send SIGTERM from a service manager.

## Local configuration

To run independently of Management, copy `examples/bootstrap.toml` and
`examples/plan.toml` into the same configuration directory and point
`YELLOW_DOG_WORKER_BOOTSTRAP` at that bootstrap. The example answers authoritative
DNS on `127.0.0.1:1053`. Edit both files' Worker identity together.

`BUILD.txt` identifies the version, source commit and build baseline.
The SHA-256 file detects a damaged download; obtain both files from the trusted release.
