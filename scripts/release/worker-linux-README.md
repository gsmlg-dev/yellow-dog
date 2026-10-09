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

Open Management → Workers (`/management/servers`), create a Worker using its name,
and save the generated connection configuration as `bootstrap.toml` in this directory.
It contains the Worker ID, Management URL, token and local data directory.
Use the generated values; `examples/managed-bootstrap.toml` is illustrative only.
Keep the bootstrap and optional TLS private key readable only by the Worker user.
For a private CA or mutual TLS, set `tls_ca_file`, `tls_cert_file`, and `tls_key_file`
to local file paths in the bootstrap. Paths resolve relative to the bootstrap file.

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
After rotating the token in Management, replace the bootstrap token and restart.

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
