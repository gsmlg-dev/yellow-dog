# Optional DHCP native dependency

YellowDog uses the coordinated Abyss **0.9.0** release from Hex:

- [abyss 0.9.0](https://hex.pm/packages/abyss/0.9.0)
- [abyss_raw 0.9.0](https://hex.pm/packages/abyss_raw/0.9.0)
- [Completed upstream release](https://github.com/gsmlg-dev/abyss/releases/tag/0.9.0)

The retained `apps/yellow_dog_dhcp_client` selects `{:abyss_raw, "~> 0.9.0",
only: :prod}`. This replaces the Git dependency `abyss_dhcp_socket`, pinned to
`71ecf7883c0aaf666406d24634ff5c022382029d` with sparse directory
`packages/abyss_dhcp_socket`. There is no external Git, path, or local package
override. Existing internal umbrella dependencies retain their normal declarations.

All current core Abyss declarations use `~> 0.9.0`; the lockfile records the actual
Hex versions. Where both packages are selected they must resolve to the same
coordinated version. Resolve them together when updating this integration.

## Product selection

The root umbrella still selects only `yellow_dog_config_spec`,
`yellow_dog_management`, `yellow_dog_worker`, and `ex_dns`. It builds exactly the
Management and Worker releases. The retained DHCP client is excluded.

Worker uses core `abyss` for authoritative DNS. Management has no Abyss runtime.
Neither product selects or ships `abyss_raw`, the old `abyss_dhcp_socket`, or the
DHCP native artifact. A raw package entry in the shared lockfile records optional
consumer resolution; it does not activate that consumer. Management's unrelated
Markdown native dependency remains separate.

## Adapter contract

The YellowDog adapter continues to call `Abyss.DhcpSocket.Native` in core Abyss.
That facade loads `AbyssDhcpSocket.Native` from OTP application `:abyss_raw`.
Native socket creation returns an opaque reference; the YellowDog adapter wraps
that success as `{:ok, socket}` for `DhcpSocket.init/1`, preserving error tuples.
Broadcast, unicast, ARP probes, owner messages, and explicit close use the upstream
implementation. YellowDog adds neither a Rust crate nor a Rustler dependency.

When the optional package is absent, the documented result is
`{:error, {:missing_optional_dependency, :abyss_raw}}`. The default Worker archive
check asserts this result.

## Validation boundaries

Run commands through `devenv shell -- …`. Default product validation uses:

```sh
scripts/e2e/architecture_smoke.sh
scripts/e2e/phase1_postgres.sh scripts/e2e/release_smoke.sh yellow_dog_management
scripts/e2e/release_smoke.sh yellow_dog_worker
```

The architecture gate checks active dependency selection and both clean release
manifests, including negative cases. Worker release and Linux archive smoke tests
exercise actual DNS UDP/TCP and durable recovery, without enabling DHCP.

The excluded DHCP client requires separate scoped native validation:

```sh
devenv shell -- python3 scripts/e2e/dhcp_client_native.py
```

This creates a fresh isolated consumer from the real production dependency
declaration, compiles the actual YellowDog socket and adapter, runs the released
upstream contracts and isolated Linux namespace wire checks, and builds and
evaluates an explicit native consumer release. It records `evidence.json` in the
printed staging directory. The wire fixture requires noninteractive sudo and
Linux namespace capabilities; inability to create the topology exits 77.
`--no-wire` explicitly leaves packet exchange unverified.

A successful adapter compile or mocked socket test alone does not verify DHCP
packet exchange, a complete DHCP application release, or deployment. See the
[release notes](../releases/v1.2.10.md) for checks actually completed and limits.
