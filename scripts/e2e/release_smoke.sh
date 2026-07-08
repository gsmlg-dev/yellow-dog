#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/e2e/release_smoke.sh <release>

Builds a Mix release and runs release-backed smoke assertions through the
release's own bin/<release> eval command.

Supported releases:
  yellow_dog_management_core
  yellow_dog_server
  yellow_dog_netman

Environment:
  BUILD_RELEASE=0       Skip mix release and only run eval assertions.
  RELEASE_VERSION=x.y.z Optional version passed to mix release --version.
EOF
}

if [ "$#" -ne 1 ]; then
  usage
  exit 64
fi

release="$1"

case "${release}" in
  yellow_dog_management_core | yellow_dog_server | yellow_dog_netman) ;;
  *)
    usage
    exit 64
    ;;
esac

export MIX_ENV="${MIX_ENV:-prod}"
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-release-smoke-secret-key-base-release-smoke-secret-key-base}"
export YELLOW_DOG_RELEASE_SMOKE_TARGET="${release}"

build_console_assets() {
  case "${release}" in
    yellow_dog_management_core | yellow_dog_server)
      (
        cd apps/yellow_dog_console
        mix assets.setup
        mix assets.deploy
      )
      ;;
  esac
}

build_netman_native() {
  if [ "${release}" != "yellow_dog_netman" ]; then
    return
  fi

  if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo is required to build the yellow_dog_netman release smoke target" >&2
    exit 1
  fi

  cargo build --release --manifest-path apps/yellow_dog_netman/native/netlink_helper/Cargo.toml
  mkdir -p apps/yellow_dog_netman/priv/native
  cp apps/yellow_dog_netman/native/netlink_helper/target/release/netlink_helper \
    apps/yellow_dog_netman/priv/native/
  chmod 755 apps/yellow_dog_netman/priv/native/netlink_helper
}

build_release() {
  build_console_assets
  build_netman_native

  args=("${release}")

  if [ -n "${RELEASE_VERSION:-}" ]; then
    args+=("--version" "${RELEASE_VERSION}")
  fi

  args+=("--overwrite")
  mix release "${args[@]}"
}

eval_file="$(mktemp)"
trap 'rm -f "${eval_file}"' EXIT

cat > "${eval_file}" <<'ELIXIR'
assert! = fn condition, message ->
  unless condition do
    raise message
  end
end

ensure_loaded! = fn module ->
  case Code.ensure_loaded(module) do
    {:module, ^module} -> :ok
    {:error, reason} -> raise "#{inspect(module)} is not available: #{inspect(reason)}"
  end
end

ensure_missing! = fn module ->
  case Code.ensure_loaded(module) do
    {:module, ^module} -> raise "#{inspect(module)} should not be part of this release"
    {:error, _reason} -> :ok
  end
end

target = System.fetch_env!("YELLOW_DOG_RELEASE_SMOKE_TARGET")
assert!.(System.get_env("RELEASE_NAME") == target, "unexpected RELEASE_NAME for #{target}")

case target do
  "yellow_dog_management_core" ->
    ensure_loaded!.(YellowDog.ManagementCore)
    ensure_loaded!.(YellowDog.Console.Plugs.ManagementReleaseOnly)
    ensure_missing!.(YellowDog.ServiceManager)
    ensure_missing!.(YellowDog.Netman.ProfileResolver)

    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)

    {:ok, server} =
      YellowDog.ManagementCore.register_server(%{
        id: "server-release-e2e",
        name: "Release E2E Server",
        profile: :cloud_dns,
        status: :online,
        services: %{dns: true, server_agent: true}
      })

    {:ok, netman} =
      YellowDog.ManagementCore.register_netman(%{
        id: "netman-release-e2e",
        name: "Release E2E Netman",
        profile: :cloud_server,
        status: :online,
        apply_mode: :observe_first,
        features: %{interfaces: true, link_state: true}
      })

    assert!.(server.id == "server-release-e2e", "management server registration failed")
    assert!.(netman.id == "netman-release-e2e", "management netman registration failed")
    assert!.(length(YellowDog.ManagementCore.list_server_profiles()) >= 6, "server profiles missing")
    assert!.(length(YellowDog.ManagementCore.list_netman_profiles()) >= 7, "netman profiles missing")
    assert!.(length(YellowDog.ManagementCore.list_events()) >= 2, "management events missing")
    assert!.(YellowDog.Console.Plugs.ManagementReleaseOnly.management_release_only?(), "management release guard inactive")

  "yellow_dog_server" ->
    ensure_loaded!.(YellowDog.ServiceManager)
    ensure_loaded!.(YellowDog.Server.ProfileResolver)
    ensure_loaded!.(YellowDog.Server.ServiceRegistry)
    ensure_loaded!.(YellowDog.ServerAgent)
    ensure_missing!.(YellowDog.ManagementCore)
    ensure_missing!.(YellowDog.Netman.ProfileResolver)

    profile =
      YellowDog.Server.ProfileResolver.resolve(%{
        "yellow_dog_server" => %{
          "profile" => "cloud_dns",
          "services" => %{"mdns" => true, "dhcpv4" => false}
        }
      })

    assert!.(profile.profile == :cloud_dns, "server profile was not resolved")
    assert!.(profile.services.dns, "cloud_dns should enable dns")
    assert!.(profile.services.server_agent, "cloud_dns should enable server_agent")
    assert!.(profile.services.mdns, "explicit mdns override should be true")
    refute = fn condition, message -> assert!.((not condition), message) end
    refute.(profile.services.dhcpv4, "explicit dhcpv4 override should be false")

    services = YellowDog.ServiceManager.list_services()

    Enum.each([:dns, :mdns, :dhcpv4, :dhcpv6, :netboot, :identity, :fingerprint, :server_agent], fn service ->
      assert!.(service in services, "server service #{service} missing")
    end)

    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_server_agent)
    snapshot = YellowDog.ServerAgent.status_snapshot()
    assert!.(snapshot.agent == :yellow_dog_server, "server agent snapshot has wrong agent")
    assert!.(snapshot.running, "server agent did not start")

  "yellow_dog_netman" ->
    ensure_loaded!.(YellowDog.Netman.ProfileResolver)
    ensure_loaded!.(YellowDog.Netman.FeatureRegistry)
    ensure_loaded!.(YellowDog.NetmanAgent)
    ensure_missing!.(YellowDog.Store)
    ensure_missing!.(YellowDog.ServiceManager)
    ensure_missing!.(YellowDog.ManagementCore)

    profile =
      YellowDog.Netman.ProfileResolver.resolve(%{
        "yellow_dog_netman" => %{
          "profile" => "cloud_server",
          "features" => %{"vpn" => false}
        }
      })

    assert!.(profile.profile == :cloud_server, "netman profile was not resolved")
    assert!.(profile.apply_mode == :observe_first, "cloud_server should default to observe_first")
    assert!.(profile.features.interfaces, "cloud_server should enable interfaces")
    assert!.(profile.features.link_state, "cloud_server should enable link_state")
    refute = fn condition, message -> assert!.((not condition), message) end
    refute.(profile.features.vpn, "explicit vpn override should be false")

    features = YellowDog.Netman.FeatureRegistry.list_features()
    Enum.each([:interfaces, :dhcp_client, :dns_client, :routes, :link_state, :vpn], fn feature ->
      assert!.(feature in features, "netman feature #{feature} missing")
    end)

    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_netman_agent)
    snapshot = YellowDog.NetmanAgent.status_snapshot()
    assert!.(snapshot.agent == :yellow_dog_netman, "netman agent snapshot has wrong agent")
    assert!.(snapshot.running, "netman agent did not start")
end

IO.puts("#{target} release smoke checks passed")
ELIXIR

if [ "${BUILD_RELEASE:-1}" != "0" ]; then
  build_release
fi

release_bin="_build/${MIX_ENV}/rel/${release}/bin/${release}"

if [ ! -x "${release_bin}" ]; then
  echo "release binary not found or not executable: ${release_bin}" >&2
  exit 1
fi

"${release_bin}" eval "$(cat "${eval_file}")"
