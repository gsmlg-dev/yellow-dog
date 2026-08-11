#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

releases=(yellow_dog_management_core yellow_dog_server yellow_dog_netman)
e2e_dir=""
management_bin=""
server_bin=""
netman_bin=""
secret=""
cookie=""
management_node=""
server_node=""
netman_node=""
management_log=""
server_log=""
netman_log=""
proxy_log=""
dns_blocker_log=""
management_pid=""
server_pid=""
netman_pid=""
proxy_pid=""
dns_blocker_pid=""

usage() {
  echo "Usage: scripts/e2e/management_releases.sh <build|run>" >&2
}

release_bin() {
  local release="$1"
  echo "${repo_root}/_build/prod/rel/${release}/bin/${release}"
}

validate_binaries() {
  local release binary

  for release in "${releases[@]}"; do
    binary="$(release_bin "${release}")"

    if [ ! -x "${binary}" ]; then
      echo "release binary not found or not executable: ${binary}" >&2
      return 1
    fi
  done
}

build_releases() {
  local release

  for release in "${releases[@]}"; do
    MIX_ENV=prod RELEASE_SMOKE_BUILD_ONLY=1 scripts/e2e/release_smoke.sh "${release}"
  done

  validate_binaries
  echo "all coordinated release binaries built"
}

require_absolute_dir() {
  case "${1:-}" in
    /*) ;;
    *)
      echo "MANAGEMENT_E2E_DIR must be an absolute path" >&2
      return 1
      ;;
  esac
}

require_port() {
  local name="$1"
  local value="$2"

  if ! [[ "${value}" =~ ^[0-9]+$ ]] || [ "${value}" -lt 1024 ] || [ "${value}" -gt 65535 ]; then
    echo "${name} must be a nonprivileged TCP port" >&2
    return 1
  fi
}

run_releases() {
  validate_binaries

  e2e_dir="${MANAGEMENT_E2E_DIR:-}"
  local http_port="${MANAGEMENT_E2E_HTTP_PORT:-}"
  local tls_port="${MANAGEMENT_E2E_TLS_PORT:-}"

  require_absolute_dir "${e2e_dir}"
  require_port MANAGEMENT_E2E_HTTP_PORT "${http_port}"
  require_port MANAGEMENT_E2E_TLS_PORT "${tls_port}"

  if [ "${http_port}" = "${tls_port}" ]; then
    echo "management HTTP and TLS ports must be distinct" >&2
    return 1
  fi

  management_bin="$(release_bin yellow_dog_management_core)"
  server_bin="$(release_bin yellow_dog_server)"
  netman_bin="$(release_bin yellow_dog_netman)"

  secret="management-release-e2e-secret-key-base-management-release-e2e-secret-key-base"
  local token="management-release-e2e-token"
  cookie="management_release_e2e_cookie"
  local server_id="management-e2e-server"
  local netman_id="management-e2e-netman"
  local suffix="${BASHPID}_${RANDOM}"
  management_node="yd_management_e2e_${suffix}"
  server_node="yd_server_e2e_${suffix}"
  netman_node="yd_netman_e2e_${suffix}"

  management_log="${e2e_dir}/management.log"
  server_log="${e2e_dir}/server.log"
  netman_log="${e2e_dir}/netman.log"
  proxy_log="${e2e_dir}/tls-proxy.log"
  dns_blocker_log="${e2e_dir}/dns-blocker.log"
  management_pid=""
  server_pid=""
  netman_pid=""
  proxy_pid=""
  dns_blocker_pid=""

  mkdir -p \
    "${e2e_dir}/management-data" \
    "${e2e_dir}/management-concord" \
    "${e2e_dir}/management-tmp" \
    "${e2e_dir}/server-data" \
    "${e2e_dir}/server-concord" \
    "${e2e_dir}/server-agent-data" \
    "${e2e_dir}/server-tmp" \
    "${e2e_dir}/netman-data" \
    "${e2e_dir}/netman-concord" \
    "${e2e_dir}/netman-agent-data" \
    "${e2e_dir}/netman-profiles" \
    "${e2e_dir}/netman-tmp"

  : > "${management_log}"
  : > "${server_log}"
  : > "${netman_log}"
  : > "${proxy_log}"
  : > "${dns_blocker_log}"

  show_logs() {
    local label path

    for label in management server netman tls-proxy dns-blocker; do
      path="${e2e_dir}/${label}.log"
      echo "===== ${label} release E2E log =====" >&2
      if [ -f "${path}" ]; then
        tail -n 300 "${path}" >&2
      else
        echo "missing log: ${path}" >&2
      fi
    done
  }

  management_rpc() {
    env \
      SECRET_KEY_BASE="${secret}" \
      CONCORD_CLUSTER_ENABLED=false \
      CONCORD_CLUSTERING=false \
      CONCORD_DATA_DIR="${e2e_dir}/management-concord" \
      RELEASE_NODE="${management_node}" \
      RELEASE_COOKIE="${cookie}" \
      RELEASE_TMP="${e2e_dir}/management-tmp" \
      "${management_bin}" rpc "$1"
  }

  server_rpc() {
    env \
      -u SECRET_KEY_BASE \
      -u RELEASE_VM_ARGS \
      CONCORD_CLUSTER_ENABLED=false \
      CONCORD_CLUSTERING=false \
      CONCORD_DATA_DIR="${e2e_dir}/server-concord" \
      YELLOW_DOG_CONFIG="${server_config}" \
      YELLOW_DOG_DATA_DIR="${e2e_dir}/server-data" \
      RELEASE_NODE="${server_node}" \
      RELEASE_COOKIE="${cookie}" \
      RELEASE_TMP="${e2e_dir}/server-tmp" \
      "${server_bin}" rpc "$1"
  }

  netman_rpc() {
    env \
      -u SECRET_KEY_BASE \
      -u RELEASE_VM_ARGS \
      CONCORD_CLUSTER_ENABLED=false \
      CONCORD_CLUSTERING=false \
      CONCORD_DATA_DIR="${e2e_dir}/netman-concord" \
      YELLOW_DOG_CONFIG="${netman_config}" \
      YELLOW_DOG_DATA_DIR="${e2e_dir}/netman-data" \
      RELEASE_NODE="${netman_node}" \
      RELEASE_COOKIE="${cookie}" \
      RELEASE_TMP="${e2e_dir}/netman-tmp" \
      "${netman_bin}" rpc "$1"
  }

  wait_for_exit() {
    local pid="$1"
    local deadline=$((SECONDS + 5))

    while kill -0 "${pid}" >/dev/null 2>&1 && [ "${SECONDS}" -lt "${deadline}" ]; do
      sleep 0.1
    done

    if kill -0 "${pid}" >/dev/null 2>&1; then
      kill "${pid}" >/dev/null 2>&1 || true
      sleep 0.1
    fi

    if kill -0 "${pid}" >/dev/null 2>&1; then
      kill -KILL "${pid}" >/dev/null 2>&1 || true
    fi

    wait "${pid}" 2>/dev/null || true
  }

  wait_for_clean_exit() {
    local label="$1"
    local pid="$2"
    local deadline=$((SECONDS + 5))

    while kill -0 "${pid}" >/dev/null 2>&1 && [ "${SECONDS}" -lt "${deadline}" ]; do
      sleep 0.1
    done

    if kill -0 "${pid}" >/dev/null 2>&1; then
      echo "${label} release did not stop cleanly" >&2
      return 1
    fi

    wait "${pid}" 2>/dev/null || true
  }

  stop_management() {
    if [ -n "${management_pid}" ]; then
      timeout 5s env \
        SECRET_KEY_BASE="${secret}" \
        CONCORD_CLUSTER_ENABLED=false \
        CONCORD_CLUSTERING=false \
        CONCORD_DATA_DIR="${e2e_dir}/management-concord" \
        RELEASE_NODE="${management_node}" \
        RELEASE_COOKIE="${cookie}" \
        RELEASE_TMP="${e2e_dir}/management-tmp" \
        "${management_bin}" stop >/dev/null 2>&1 || true
      wait_for_exit "${management_pid}"
      management_pid=""
    fi
  }

  stop_server() {
    local stop_mode="${1:-best_effort}"

    if [ -n "${server_pid}" ]; then
      local stop_status=0

      timeout 5s env \
        -u SECRET_KEY_BASE \
        CONCORD_CLUSTER_ENABLED=false \
        CONCORD_CLUSTERING=false \
        CONCORD_DATA_DIR="${e2e_dir}/server-concord" \
        RELEASE_NODE="${server_node}" \
        RELEASE_COOKIE="${cookie}" \
        RELEASE_TMP="${e2e_dir}/server-tmp" \
        "${server_bin}" stop >/dev/null 2>&1 || stop_status="$?"

      if [ "${stop_mode}" = "clean" ]; then
        if [ "${stop_status}" -ne 0 ]; then
          echo "server release stop command failed with status ${stop_status}" >&2
          return 1
        fi

        wait_for_clean_exit server "${server_pid}"
      else
        wait_for_exit "${server_pid}"
      fi

      server_pid=""
    fi
  }

  stop_netman() {
    local stop_mode="${1:-best_effort}"

    if [ -n "${netman_pid}" ]; then
      local stop_status=0

      timeout 5s env \
        -u SECRET_KEY_BASE \
        CONCORD_CLUSTER_ENABLED=false \
        CONCORD_CLUSTERING=false \
        CONCORD_DATA_DIR="${e2e_dir}/netman-concord" \
        RELEASE_NODE="${netman_node}" \
        RELEASE_COOKIE="${cookie}" \
        RELEASE_TMP="${e2e_dir}/netman-tmp" \
        "${netman_bin}" stop >/dev/null 2>&1 || stop_status="$?"

      if [ "${stop_mode}" = "clean" ]; then
        if [ "${stop_status}" -ne 0 ]; then
          echo "netman release stop command failed with status ${stop_status}" >&2
          return 1
        fi

        wait_for_clean_exit netman "${netman_pid}"
      else
        wait_for_exit "${netman_pid}"
      fi

      netman_pid=""
    fi
  }

  cleanup() {
    local status="$?"
    trap - EXIT INT TERM
    stop_netman
    stop_server
    stop_management

    if [ -n "${proxy_pid}" ]; then
      kill "${proxy_pid}" >/dev/null 2>&1 || true
      wait "${proxy_pid}" 2>/dev/null || true
      proxy_pid=""
    fi

    if [ -n "${dns_blocker_pid}" ]; then
      kill "${dns_blocker_pid}" >/dev/null 2>&1 || true
      wait "${dns_blocker_pid}" 2>/dev/null || true
      dns_blocker_pid=""
    fi

    if [ "${status}" -ne 0 ]; then
      show_logs
    fi

    exit "${status}"
  }

  trap cleanup EXIT INT TERM

  local server_config="${e2e_dir}/server.toml"
  local netman_config="${e2e_dir}/netman.toml"

  cat > "${server_config}" <<EOF
data_dir = "${e2e_dir}/server-data"

[yellow_dog_server]
profile = "custom"
id = "${server_id}"
name = "Management E2E Server"

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

  cat > "${netman_config}" <<EOF
data_dir = "${e2e_dir}/netman-data"

[yellow_dog_netman]
profile = "custom"
id = "${netman_id}"
name = "Management E2E Netman"

[yellow_dog_netman.management]
agent_enabled = true

[yellow_dog_netman.mode]
apply = "observe"

[yellow_dog_netman.features]
interfaces = false
dhcp_client = false
dns_client = false
routes = false
link_state = false
vpn = false
EOF

  local ca_key="${e2e_dir}/ca-key.pem"
  local ca_cert="${e2e_dir}/ca.pem"
  local tls_key="${e2e_dir}/localhost-key.pem"
  local tls_csr="${e2e_dir}/localhost.csr"
  local tls_cert="${e2e_dir}/localhost.pem"
  local tls_extensions="${e2e_dir}/localhost-ext.cnf"

  cat > "${tls_extensions}" <<'EOF'
basicConstraints = CA:FALSE
subjectAltName = DNS:localhost,IP:127.0.0.1
keyUsage = digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
EOF

  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -subj "/CN=YellowDog Management E2E CA" \
    -keyout "${ca_key}" -out "${ca_cert}" >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -sha256 \
    -subj "/CN=localhost" \
    -keyout "${tls_key}" -out "${tls_csr}" >/dev/null 2>&1
  openssl x509 -req -sha256 -days 1 \
    -in "${tls_csr}" -CA "${ca_cert}" -CAkey "${ca_key}" -CAcreateserial \
    -extfile "${tls_extensions}" -out "${tls_cert}" >/dev/null 2>&1

  make_trusted_vm_args() {
    local release="$1"
    local output="$2"
    local version_dir
    version_dir="$(find "${repo_root}/_build/prod/rel/${release}/releases" \
      -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)"

    if [ -z "${version_dir}" ] || [ ! -f "${version_dir}/vm.args" ]; then
      echo "release vm.args not found for ${release}" >&2
      return 1
    fi

    cp "${version_dir}/vm.args" "${output}"
    printf "%s\n" "-public_key cacerts_path '\"${ca_cert}\"'" >> "${output}"
  }

  local server_vm_args="${e2e_dir}/server.vm.args"
  local netman_vm_args="${e2e_dir}/netman.vm.args"
  make_trusted_vm_args yellow_dog_server "${server_vm_args}"
  make_trusted_vm_args yellow_dog_netman "${netman_vm_args}"

  start_management() {
    env \
      PHX_SERVER=true \
      PHX_HOST=localhost \
      PORT="${http_port}" \
      CONCORD_CLUSTER_ENABLED=false \
      CONCORD_CLUSTERING=false \
      CONCORD_DATA_DIR="${e2e_dir}/management-concord" \
      CONSOLE_AUTH_ENABLED=false \
      SECRET_KEY_BASE="${secret}" \
      YELLOW_DOG_MANAGEMENT_TOKEN="${token}" \
      YELLOW_DOG_DATA_DIR="${e2e_dir}/management-data" \
      RELEASE_NODE="${management_node}" \
      RELEASE_COOKIE="${cookie}" \
      RELEASE_TMP="${e2e_dir}/management-tmp" \
      "${management_bin}" start >> "${management_log}" 2>&1 &
    management_pid="$!"
  }

  start_server() {
    local trust_mode="${1:-trusted}"
    local -a vm_args=()

    case "${trust_mode}" in
      trusted) vm_args=(RELEASE_VM_ARGS="${server_vm_args}") ;;
      untrusted) ;;
      *) echo "unknown Server trust mode: ${trust_mode}" >&2; return 1 ;;
    esac

    env \
      -u SECRET_KEY_BASE \
      -u RELEASE_VM_ARGS \
      CONCORD_CLUSTER_ENABLED=false \
      CONCORD_CLUSTERING=false \
      CONCORD_DATA_DIR="${e2e_dir}/server-concord" \
      YELLOW_DOG_CONFIG="${server_config}" \
      YELLOW_DOG_DATA_DIR="${e2e_dir}/server-data" \
      YELLOW_DOG_SERVER_MANAGEMENT_URL="https://localhost:${tls_port}" \
      YELLOW_DOG_SERVER_MANAGEMENT_TOKEN="${token}" \
      YELLOW_DOG_SERVER_ID="${server_id}" \
      YELLOW_DOG_SERVER_AGENT_DATA_DIR="${e2e_dir}/server-agent-data" \
      YELLOW_DOG_SERVER_RECONNECT_INITIAL_MS=50 \
      YELLOW_DOG_SERVER_RECONNECT_MAX_MS=250 \
      RELEASE_NODE="${server_node}" \
      RELEASE_COOKIE="${cookie}" \
      RELEASE_TMP="${e2e_dir}/server-tmp" \
      "${vm_args[@]}" \
      "${server_bin}" start >> "${server_log}" 2>&1 &
    server_pid="$!"
  }

  start_netman() {
    local trust_mode="${1:-trusted}"
    local -a vm_args=()

    case "${trust_mode}" in
      trusted) vm_args=(RELEASE_VM_ARGS="${netman_vm_args}") ;;
      untrusted) ;;
      *) echo "unknown Netman trust mode: ${trust_mode}" >&2; return 1 ;;
    esac

    env \
      -u SECRET_KEY_BASE \
      -u RELEASE_VM_ARGS \
      CONCORD_CLUSTER_ENABLED=false \
      CONCORD_CLUSTERING=false \
      CONCORD_DATA_DIR="${e2e_dir}/netman-concord" \
      YELLOW_DOG_CONFIG="${netman_config}" \
      YELLOW_DOG_DATA_DIR="${e2e_dir}/netman-data" \
      YELLOW_DOG_NETMAN_MANAGEMENT_URL="https://localhost:${tls_port}" \
      YELLOW_DOG_NETMAN_MANAGEMENT_TOKEN="${token}" \
      YELLOW_DOG_NETMAN_ID="${netman_id}" \
      YELLOW_DOG_NETMAN_AGENT_DATA_DIR="${e2e_dir}/netman-agent-data" \
      YELLOW_DOG_NETMAN_RECONNECT_INITIAL_MS=50 \
      YELLOW_DOG_NETMAN_RECONNECT_MAX_MS=250 \
      YELLOW_DOG_NETMAN_PROFILE_DIR="${e2e_dir}/netman-profiles" \
      YELLOW_DOG_NETMAN_SOCKET="${e2e_dir}/netman.sock" \
      RELEASE_NODE="${netman_node}" \
      RELEASE_COOKIE="${cookie}" \
      RELEASE_TMP="${e2e_dir}/netman-tmp" \
      "${vm_args[@]}" \
      "${netman_bin}" start >> "${netman_log}" 2>&1 &
    netman_pid="$!"
  }

  wait_for_management() {
    local deadline=$((SECONDS + 30))

    until management_rpc ':ok' >/dev/null 2>&1; do
      if ! kill -0 "${management_pid}" >/dev/null 2>&1; then
        echo "management release exited before becoming ready" >&2
        return 1
      fi

      if [ "${SECONDS}" -ge "${deadline}" ]; then
        echo "management release RPC readiness timed out" >&2
        return 1
      fi

      sleep 0.1
    done
  }

  wait_for_agent_rpc() {
    local label="$1"
    local pid="$2"
    local rpc_function="$3"
    local deadline=$((SECONDS + 30))

    until "${rpc_function}" ':ok' >/dev/null 2>&1; do
      if ! kill -0 "${pid}" >/dev/null 2>&1; then
        echo "${label} release exited before becoming ready" >&2
        return 1
      fi

      if [ "${SECONDS}" -ge "${deadline}" ]; then
        echo "${label} release RPC readiness timed out" >&2
        return 1
      fi

      sleep 0.1
    done
  }

  start_management
  wait_for_management

  local register_script="${e2e_dir}/register.exs"
  cat > "${register_script}" <<EOF
{:ok, %{id: "${server_id}"}} =
  YellowDog.ManagementCore.register_server(%{
    id: "${server_id}",
    name: "Management E2E Server",
    profile: :custom,
    status: :offline,
    services: %{dns: false, server_agent: true}
  })

{:ok, %{id: "${netman_id}"}} =
  YellowDog.ManagementCore.register_netman(%{
    id: "${netman_id}",
    name: "Management E2E Netman",
    profile: :custom,
    status: :offline,
    apply_mode: :observe,
    features: %{
      interfaces: false,
      dhcp_client: false,
      dns_client: false,
      routes: false,
      link_state: false,
      vpn: false
    }
  })
EOF
  management_rpc "$(cat "${register_script}")" >/dev/null

  local proxy_script="${e2e_dir}/tls_proxy.py"
  cat > "${proxy_script}" <<'PYTHON'
import select
import socket
import ssl
import sys
import threading

listen_port = int(sys.argv[1])
backend_port = int(sys.argv[2])
cert_file = sys.argv[3]
key_file = sys.argv[4]

context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.minimum_version = ssl.TLSVersion.TLSv1_2
context.load_cert_chain(certfile=cert_file, keyfile=key_file)

def bridge(client):
    backend = None
    tls_client = None
    try:
        tls_client = context.wrap_socket(client, server_side=True)
        backend = socket.create_connection(("127.0.0.1", backend_port), timeout=5)
        tls_client.settimeout(None)
        backend.settimeout(None)
        peers = {tls_client: backend, backend: tls_client}

        while True:
            readable, _, exceptional = select.select(list(peers), [], list(peers), 30)
            if exceptional:
                return
            if not readable:
                continue
            for source in readable:
                data = source.recv(65536)
                if not data:
                    return
                peers[source].sendall(data)
    except (OSError, ssl.SSLError):
        return
    finally:
        for stream in (backend, tls_client, client):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", listen_port))
    listener.listen(128)
    print("ready", flush=True)
    while True:
        client, _address = listener.accept()
        threading.Thread(target=bridge, args=(client,), daemon=True).start()
PYTHON

  python3 -u "${proxy_script}" "${tls_port}" "${http_port}" "${tls_cert}" "${tls_key}" \
    >> "${proxy_log}" 2>&1 &
  proxy_pid="$!"

  local curl_args=(--fail --silent --show-error --location --resolve "localhost:${tls_port}:127.0.0.1")
  local deadline=$((SECONDS + 15))

  until curl "${curl_args[@]}" --cacert "${ca_cert}" "https://localhost:${tls_port}/management" >/dev/null 2>&1; do
    if ! kill -0 "${proxy_pid}" >/dev/null 2>&1; then
      echo "management TLS proxy exited before becoming ready" >&2
      return 1
    fi

    if [ "${SECONDS}" -ge "${deadline}" ]; then
      echo "management TLS proxy readiness timed out" >&2
      return 1
    fi

    sleep 0.1
  done

  if curl "${curl_args[@]}" "https://localhost:${tls_port}/management" >/dev/null 2>&1; then
    echo "generated management certificate was unexpectedly trusted" >&2
    return 1
  fi
  echo "untrusted management certificate rejected"

  curl "${curl_args[@]}" --cacert "${ca_cert}" "https://localhost:${tls_port}/management" >/dev/null
  echo "trusted management certificate accepted"

  start_server untrusted
  start_netman untrusted
  wait_for_agent_rpc server "${server_pid}" server_rpc
  wait_for_agent_rpc netman "${netman_pid}" netman_rpc

  server_rpc '
deadline = System.monotonic_time(:millisecond) + 20_000
wait = fn wait ->
  cond do
    YellowDog.ServerAgent.connection_state() == :backoff -> :ok
    System.monotonic_time(:millisecond) >= deadline -> raise "Server agent did not reject the untrusted certificate"
    true -> Process.sleep(10); wait.(wait)
  end
end
:ok = wait.(wait)
true = YellowDog.ServerAgent.status_snapshot().running
false = YellowDog.ServerAgent.connected?()
' >/dev/null

  netman_rpc '
deadline = System.monotonic_time(:millisecond) + 20_000
wait = fn wait ->
  cond do
    YellowDog.NetmanAgent.connection_state() == :backoff -> :ok
    System.monotonic_time(:millisecond) >= deadline -> raise "Netman agent did not reject the untrusted certificate"
    true -> Process.sleep(10); wait.(wait)
  end
end
:ok = wait.(wait)
true = YellowDog.NetmanAgent.status_snapshot().running
false = YellowDog.NetmanAgent.connected?()
' >/dev/null

  management_rpc "
{:ok, %{status: :offline}} = YellowDog.ManagementCore.get_server(\"${server_id}\")
{:ok, %{status: :offline}} = YellowDog.ManagementCore.get_netman(\"${netman_id}\")
false = YellowDog.Console.ServerConnections.connected?(\"${server_id}\")
false = YellowDog.Console.NetmanConnections.connected?(\"${netman_id}\")
" >/dev/null

  echo "server and netman release agents booted without SECRET_KEY_BASE and rejected untrusted management certificate"

  stop_netman clean
  stop_server clean
  echo "untrusted server and netman release agents stopped cleanly"

  local dns_blocker_script="${e2e_dir}/dns_blocker.py"
  local dns_blocker_port_file="${e2e_dir}/dns-blocker.port"
  local dns_blocker_port=""

  cat > "${dns_blocker_script}" <<'PYTHON'
import signal
import socket

tcp_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
tcp_socket.bind(("127.0.0.1", 0))
tcp_socket.listen(1)
blocked_port = tcp_socket.getsockname()[1]

udp_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp_socket.bind(("127.0.0.1", blocked_port))

print(blocked_port, flush=True)

while True:
    signal.pause()
PYTHON

  python3 -u "${dns_blocker_script}" > "${dns_blocker_port_file}" \
    2> "${dns_blocker_log}" &
  dns_blocker_pid="$!"
  deadline=$((SECONDS + 5))

  until [ -s "${dns_blocker_port_file}" ]; do
    if ! kill -0 "${dns_blocker_pid}" >/dev/null 2>&1; then
      echo "DNS activation blocker exited before becoming ready" >&2
      return 1
    fi

    if [ "${SECONDS}" -ge "${deadline}" ]; then
      echo "DNS activation blocker readiness timed out" >&2
      return 1
    fi

    sleep 0.05
  done

  dns_blocker_port="$(cat "${dns_blocker_port_file}")"
  require_port DNS_BLOCKER_PORT "${dns_blocker_port}"

  start_server
  start_netman

  local initial_assertions="${e2e_dir}/initial_assertions.exs"
  cat > "${initial_assertions}" <<EOF
wait = fn wait, predicate, message ->
  deadline = System.monotonic_time(:millisecond) + 30_000

  poll = fn poll ->
    cond do
      predicate.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> raise message
      true -> Process.sleep(50); poll.(poll)
    end
  end

  poll.(poll)
end

server_id = "${server_id}"
netman_id = "${netman_id}"

:ok = wait.(wait, fn -> match?({:ok, %{status: :online}}, YellowDog.ManagementCore.get_server(server_id)) end,
  "Server release agent did not register")
:ok = wait.(wait, fn -> match?({:ok, %{status: :online}}, YellowDog.ManagementCore.get_netman(netman_id)) end,
  "Netman release agent did not register")

{:ok, %{"capabilities" => server_capabilities}} =
  YellowDog.ManagementCore.query_server(
    server_id,
    "release.runtime.capabilities.server",
    "server.runtime.capabilities.get",
    %{}
  )

{:ok, %{"capabilities" => netman_capabilities}} =
  YellowDog.ManagementCore.query_netman(
    netman_id,
    "release.runtime.capabilities.netman",
    "netman.runtime.capabilities.get",
    %{}
  )

true = "runtime.services" in server_capabilities
true = "profiles.read" in netman_capabilities
false = server_capabilities == netman_capabilities

{:ok, %{"items" => service_items}} =
  YellowDog.ManagementCore.query_server(
    server_id,
    "release.runtime.services",
    "server.runtime.services.list",
    %{}
  )

dns_service = Enum.find(service_items, &(&1["service"] == "dns"))
{:ok, services_revision} = YellowDog.Sync.Digest.calculate(dns_service)

server_key = "21000000-0000-4000-8000-000000000001"
server_args = [
  server_id,
  "server.runtime.services.stop",
  %{"service" => "dns"},
  services_revision,
  server_key
]
{:ok, %{"service" => "dns", "state" => "stopped"} = stopped} =
  apply(YellowDog.ManagementCore, :command_server, server_args)
{:ok, ^stopped} = apply(YellowDog.ManagementCore, :command_server, server_args)

profile = %{
  "profile_id" => "management-e2e-profile",
  "type" => "ethernet",
  "interface" => nil,
  "autoconnect" => false,
  "autoconnect_priority" => 0,
  "zone" => "default",
  "ethernet" => %{"mtu" => nil},
  "ipv4" => %{
    "method" => "auto",
    "address" => nil,
    "gateway" => nil,
    "dns" => [],
    "dns_search" => []
  },
  "ipv6" => %{
    "method" => "disabled",
    "address" => nil,
    "gateway" => nil,
    "dns" => [],
    "dns_search" => []
  }
}

{:ok, %{"profile_id" => "management-e2e-profile", "valid" => true}} =
  YellowDog.ManagementCore.command_netman(
    netman_id,
    "netman.profiles.validate",
    profile,
    nil,
    "22000000-0000-4000-8000-000000000001"
  )

{:ok, netman_version} =
  YellowDog.ManagementCore.publish_netman_config(netman_id, %{
    operation: "netman.profiles.replace",
    payload: %{"profiles" => [profile]},
    expected_revision: nil
  })

:ok = wait.(wait, fn ->
  match?({:ok, %{state: :applied}},
    YellowDog.ManagementCore.get_netman_config_version(netman_id, netman_version.version))
end, "Netman release did not acknowledge the desired profile set")

{:ok, outcomes} = YellowDog.ManagementCore.list_command_outcomes()
true = length(outcomes) >= 2
IO.puts("server and netman release agents registered")
EOF
  management_rpc "$(cat "${initial_assertions}")"

  local servers_page="${e2e_dir}/management-servers.html"
  local netmans_page="${e2e_dir}/management-netmans.html"
  curl "${curl_args[@]}" --cacert "${ca_cert}" \
    "https://localhost:${tls_port}/management/servers" > "${servers_page}"
  grep -q "${server_id}" "${servers_page}"
  curl "${curl_args[@]}" --cacert "${ca_cert}" \
    "https://localhost:${tls_port}/management/netman" > "${netmans_page}"
  grep -q "${netman_id}" "${netmans_page}"

  stop_server

  local offline_server="${e2e_dir}/offline_server.exs"
  cat > "${offline_server}" <<EOF
deadline = System.monotonic_time(:millisecond) + 15_000
wait = fn wait ->
  cond do
    match?({:ok, %{status: :offline}}, YellowDog.ManagementCore.get_server("${server_id}")) -> :ok
    System.monotonic_time(:millisecond) >= deadline -> raise "Server did not become offline"
    true -> Process.sleep(50); wait.(wait)
  end
end
:ok = wait.(wait)

document = %{
  "schema_version" => 1,
  "profile" => "custom",
  "entries" => [
    %{
      "setting" => "services.dns.enabled",
      "value" => %{"type" => "boolean", "value" => false}
    }
  ]
}

{:ok, %{draft_revision: 1}} =
  YellowDog.ManagementCore.put_server_config("${server_id}", 0, document)
{:ok, %{version: 1, state: :desired}} =
  YellowDog.ManagementCore.publish_server_config("${server_id}", 1)
EOF
  management_rpc "$(cat "${offline_server}")"

  start_server

  local server_apply="${e2e_dir}/server_apply.exs"
  cat > "${server_apply}" <<EOF
deadline = System.monotonic_time(:millisecond) + 30_000
wait = fn wait ->
  case YellowDog.ManagementCore.get_server_config_version("${server_id}", 1) do
    {:ok, %{state: :applied}} -> :ok

    state ->
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(50)
        wait.(wait)
      else
        raise "offline Server config was not applied: #{inspect(state)}"
      end
  end
end
:ok = wait.(wait)
IO.puts("offline desired configuration applied")

activation_failure_document = %{
  "schema_version" => 1,
  "profile" => "custom",
  "entries" => [
    %{
      "setting" => "dns.listen",
      "value" => %{"type" => "string", "value" => "127.0.0.1"}
    },
    %{
      "setting" => "dns.port",
      "value" => %{"type" => "integer", "value" => ${dns_blocker_port}}
    },
    %{
      "setting" => "services.dns.enabled",
      "value" => %{"type" => "boolean", "value" => true}
    }
  ]
}

{:ok, %{draft_revision: 2}} =
  YellowDog.ManagementCore.put_server_config("${server_id}", 1, activation_failure_document)
{:ok, %{version: 2}} = YellowDog.ManagementCore.publish_server_config("${server_id}", 2)

deadline = System.monotonic_time(:millisecond) + 30_000
wait_failed = fn wait_failed ->
  case YellowDog.ManagementCore.get_server_config_version("${server_id}", 2) do
    {:ok, %{state: :failed, restored_version: 1, rollback: %{"succeeded" => true}}} -> :ok

    state ->
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(50)
        wait_failed.(wait_failed)
      else
        raise "invalid activation did not restore known-good state: #{inspect(state)}"
      end
  end
end
:ok = wait_failed.(wait_failed)
IO.puts("failed activation restored known-good configuration")
EOF
  management_rpc "$(cat "${server_apply}")"

  stop_management
  start_management
  wait_for_management

  local durable_assertions="${e2e_dir}/durable_assertions.exs"
  cat > "${durable_assertions}" <<EOF
deadline = System.monotonic_time(:millisecond) + 30_000
wait = fn wait ->
  online =
    match?({:ok, %{status: :online}}, YellowDog.ManagementCore.get_server("${server_id}")) and
      match?({:ok, %{status: :online}}, YellowDog.ManagementCore.get_netman("${netman_id}"))

  cond do
    online -> :ok
    System.monotonic_time(:millisecond) >= deadline -> raise "release agents did not reconnect"
    true -> Process.sleep(50); wait.(wait)
  end
end
:ok = wait.(wait)

{:ok, %{value: %{"capabilities" => server_capabilities}}} =
  YellowDog.ManagementCore.get_server_snapshot("${server_id}", "release.runtime.capabilities.server")
{:ok, %{value: %{"capabilities" => netman_capabilities}}} =
  YellowDog.ManagementCore.get_netman_snapshot("${netman_id}", "release.runtime.capabilities.netman")
false = server_capabilities == netman_capabilities

{:ok, %{state: :applied}} =
  YellowDog.ManagementCore.get_server_config_version("${server_id}", 1)
{:ok, %{state: :failed, restored_version: 1, rollback: %{"succeeded" => true}}} =
  YellowDog.ManagementCore.get_server_config_version("${server_id}", 2)
{:ok, netman_versions} = YellowDog.Management.ConfigVersions.list(:netman, "${netman_id}")
true = Enum.any?(netman_versions, &(&1.state == :applied))
{:ok, outcomes} = YellowDog.ManagementCore.list_command_outcomes()
true = length(outcomes) >= 2
events = YellowDog.ManagementCore.list_events()
true = length(events) >= 6
IO.puts("management restart preserved durable control-plane state")
EOF
  management_rpc "$(cat "${durable_assertions}")"

  curl "${curl_args[@]}" --cacert "${ca_cert}" \
    "https://localhost:${tls_port}/management/servers" > "${servers_page}"
  grep -q "${server_id}" "${servers_page}"
}

if [ "$#" -ne 1 ]; then
  usage
  exit 64
fi

case "$1" in
  build) build_releases ;;
  run) run_releases ;;
  *) usage; exit 64 ;;
esac
