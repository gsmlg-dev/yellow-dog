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
  RELEASE_SMOKE_BUILD_ONLY=1
                        Build and validate the release binary, then stop.
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

console_lock_created=0
native_helper_created=0

build_console_assets() {
  case "${release}" in
    yellow_dog_management_core)
      if [ ! -e apps/yellow_dog_console/npm.lock ]; then
        console_lock_created=1
      fi

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

  if [ ! -e apps/yellow_dog_netman/priv/native/netlink_helper ]; then
    native_helper_created=1
  fi

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

smoke_dir="$(mktemp -d)"
eval_file="${smoke_dir}/release_smoke.exs"

cleanup() {
  local status="$?"
  trap - EXIT
  rm -rf "${smoke_dir}"

  if [ "${console_lock_created}" = "1" ]; then
    rm -f apps/yellow_dog_console/npm.lock
  fi

  if [ "${native_helper_created}" = "1" ]; then
    rm -f apps/yellow_dog_netman/priv/native/netlink_helper
    rmdir apps/yellow_dog_netman/priv/native >/dev/null 2>&1 || true
  fi

  exit "${status}"
}

trap cleanup EXIT

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

    mode = System.fetch_env!("YELLOW_DOG_RELEASE_SMOKE_SERVER_MODE")

    startup_barrier =
      if mode == "disabled" do
        handler_id = "release-smoke-disabled-server-agent"
        owner = self()

        {:ok, _apps} = Application.ensure_all_started(:telemetry)

        :ok =
          :telemetry.attach(
            handler_id,
            [:yellow_dog, :application, :start],
            fn _event, _measurements, metadata, owner ->
              skipped_services =
                metadata
                |> Map.get(:skipped_services, "")
                |> String.split(", ", trim: true)

              if "SERVER_AGENT" in skipped_services do
                send(owner, :server_agent_startup_skipped)
              end
            end,
            owner
          )

        handler_id
      end

    if startup_barrier do
      try do
        {:ok, _apps} = Application.ensure_all_started(:yellow_dog)

        receive do
          :server_agent_startup_skipped -> :ok
        after
          5_000 -> raise "disabled server agent startup selection did not complete"
        end
      after
        :telemetry.detach(startup_barrier)
      end
    else
      {:ok, _apps} = Application.ensure_all_started(:yellow_dog)
    end

    started_apps =
      Application.started_applications()
      |> Enum.map(&elem(&1, 0))

    refute.(
      :yellow_dog_server_agent in started_apps,
      "server agent OTP application must remain loaded-only"
    )

    wait_for = fn predicate, message ->
      deadline = System.monotonic_time(:millisecond) + 5_000

      waiter = fn waiter ->
        cond do
          predicate.() ->
            :ok

          System.monotonic_time(:millisecond) >= deadline ->
            raise message

          true ->
            Process.sleep(25)
            waiter.(waiter)
        end
      end

      waiter.(waiter)
    end

    case mode do
      "enabled" ->
        wait_for.(
          fn -> is_pid(Process.whereis(YellowDog.ServerAgent.Supervisor)) end,
          "YellowDog-owned server agent did not start"
        )

        assert!.(
          Enum.any?(
            Supervisor.which_children(YellowDog.Supervisor),
            &(elem(&1, 0) == YellowDog.ServerAgent)
          ),
          "server agent is not owned by YellowDog.Supervisor"
        )

        snapshot = YellowDog.ServerAgent.status_snapshot()
        assert!.(snapshot.agent == :yellow_dog_server, "server agent snapshot has wrong agent")
        assert!.(snapshot.running, "server agent did not start")
        assert!.(snapshot.agent_id == "release-server-enabled", "server agent ID mismatch")

        assert!.(
          is_nil(Process.whereis(YellowDog.ServerAgent.Client)),
          "credential-free agent started Client"
        )

      "disabled" ->
        assert!.(
          is_nil(Process.whereis(YellowDog.ServerAgent.Supervisor)),
          "disabled server agent started"
        )

        refute.(
          Enum.any?(
            Supervisor.which_children(YellowDog.Supervisor),
            &(elem(&1, 0) == YellowDog.ServerAgent)
          ),
          "disabled server agent child was installed"
        )

      other ->
        raise "unknown Server release smoke mode: #{inspect(other)}"
    end

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

if [ "${RELEASE_SMOKE_BUILD_ONLY:-0}" = "1" ]; then
  echo "${release} release binary built"
  exit 0
fi

expect_missing_secret_failure() {
  local label="$1"
  shift
  local output

  if output="$(env -u SECRET_KEY_BASE "$@" 2>&1)"; then
    echo "${label} unexpectedly started without SECRET_KEY_BASE" >&2
    return 1
  fi

  if ! grep -q "environment variable SECRET_KEY_BASE is missing" <<< "${output}"; then
    echo "${label} failed without the expected SECRET_KEY_BASE error" >&2
    echo "${output}" >&2
    return 1
  fi
}

case "${release}" in
  yellow_dog_management_core)
    expect_missing_secret_failure "${release}" "${release_bin}" eval ':ok'
    expect_missing_secret_failure \
      "yellow_dog all-in-one runtime" \
      RELEASE_NAME=yellow_dog \
      "${release_bin}" eval ':ok'
    ;;

  yellow_dog_server | yellow_dog_netman)
    expect_missing_secret_failure \
      "${release} with PHX_SERVER" \
      PHX_SERVER=true \
      "${release_bin}" eval ':ok'
    ;;
esac

if [ "${release}" = "yellow_dog_server" ]; then
  enabled_config="${smoke_dir}/server-enabled.toml"
  disabled_config="${smoke_dir}/server-disabled.toml"

  cat > "${enabled_config}" <<EOF
data_dir = "${smoke_dir}/enabled-data"

[yellow_dog_server]
profile = "custom"
id = "release-server-enabled"
name = "Release Server Enabled"

[yellow_dog_server.services]
dns = false
mdns = false
dhcpv4 = false
dhcpv6 = false
netboot = false
identity = false
fingerprint = false
server_agent = true
EOF

  cat > "${disabled_config}" <<EOF
data_dir = "${smoke_dir}/disabled-data"

[yellow_dog_server]
profile = "custom"
id = "release-server-disabled"
name = "Release Server Disabled"

[yellow_dog_server.services]
dns = false
mdns = false
dhcpv4 = false
dhcpv6 = false
netboot = false
identity = false
fingerprint = false
server_agent = false
EOF

  env \
    -u SECRET_KEY_BASE \
    -u YELLOW_DOG_SERVER_MANAGEMENT_URL \
    -u YELLOW_DOG_SERVER_MANAGEMENT_TOKEN \
    -u YELLOW_DOG_SERVER_ID \
    -u YELLOW_DOG_SERVER_AGENT_DATA_DIR \
    -u YELLOW_DOG_SERVER_RECONNECT_INITIAL_MS \
    -u YELLOW_DOG_SERVER_RECONNECT_MAX_MS \
    YELLOW_DOG_CONFIG="${enabled_config}" \
    YELLOW_DOG_RELEASE_SMOKE_SERVER_MODE=enabled \
    "${release_bin}" eval "$(cat "${eval_file}")"

  env \
    -u SECRET_KEY_BASE \
    -u YELLOW_DOG_SERVER_MANAGEMENT_URL \
    -u YELLOW_DOG_SERVER_MANAGEMENT_TOKEN \
    -u YELLOW_DOG_SERVER_ID \
    -u YELLOW_DOG_SERVER_AGENT_DATA_DIR \
    -u YELLOW_DOG_SERVER_RECONNECT_INITIAL_MS \
    -u YELLOW_DOG_SERVER_RECONNECT_MAX_MS \
    YELLOW_DOG_CONFIG="${disabled_config}" \
    YELLOW_DOG_RELEASE_SMOKE_SERVER_MODE=disabled \
    "${release_bin}" eval "$(cat "${eval_file}")"
elif [ "${release}" = "yellow_dog_netman" ]; then
  env -u SECRET_KEY_BASE "${release_bin}" eval "$(cat "${eval_file}")"
else
  "${release_bin}" eval "$(cat "${eval_file}")"
fi
