#!/usr/bin/env bash

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-n NETWORK] [--gateway URL] [http_endpoint]
Runs e2e tests using Google Chrome browser.
Available options:
-h, --help         Print this help and exit
-v, --verbose      Print script debug info
-n, --network      Docker network to use (Default: bridge)
-g, --gateway URL  Use Kong Gateway base URL (overrides positional http_endpoint). On Linux, defaults to --network host.
EOF
  exit
}

# Globals used for cleanup
PF_PID=""
PF_LOG=""

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # Stop any background port-forward if started
  if [[ -n "${PF_PID}" ]] && ps -p "${PF_PID}" >/dev/null 2>&1; then
    echo "Stopping port-forward (pid=${PF_PID})..." >&2
    kill "${PF_PID}" >/dev/null 2>&1 || true
    # Give it a moment to stop
    sleep 0.5 || true
  fi
  if [[ -n "${PF_LOG}" && -f "${PF_LOG}" ]]; then
    rm -f "${PF_LOG}" || true
  fi
}

setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

parse_params() {
  # default values of variables set from params
  network='bridge'
  gateway=""

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -n | --network)
      network="${2-}"
      shift
      ;;
    -g | --gateway)
      gateway="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # Determine endpoint precedence: --gateway overrides positional arg
  if [[ -n "$gateway" ]]; then
    endpoint="$gateway"
    # If user didn't override network and we're on Linux, default to host for gateway testing
    if [[ "$network" == "bridge" ]]; then
      case "$(uname -s)" in
        Linux) network="host" ;;
      esac
    fi
  else
    # No gateway flag; require positional endpoint
    if [[ ${#args[@]} -eq 0 ]]; then
      die "Error: Must specify endpoint argument or use --gateway URL"
    fi
    endpoint="${args[0]}"
  fi

  return 0
}

# Try to parse host and port from a URL like http://host:port/path
parse_host_port_from_url() {
  local url="$1"
  # Use parameter expansion to strip scheme
  local no_scheme
  no_scheme="${url#*://}"
  local hostport path
  hostport="${no_scheme%%/*}"
  # Extract host and optional :port
  if [[ "$hostport" == *:* ]]; then
    url_host="${hostport%%:*}"
    url_port="${hostport##*:}"
  else
    url_host="$hostport"
    url_port=""
  fi
}

wait_for_http() {
  local url="$1"
  local timeout="${2:-20}"
  local start ts
  start=$(date +%s)
  while true; do
    if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
      return 0
    fi
    ts=$(date +%s)
    if (( ts - start > timeout )); then
      return 1
    fi
    sleep 1
  done
}

maybe_start_port_forward() {
  # Only attempt if:
  # - endpoint is localhost/127.0.0.1/host.docker.internal and has a port
  # - kubectl is available
  # - kong-gw-kong-proxy service exists in the gateway namespace
  parse_host_port_from_url "$endpoint"
  local host="$url_host" port="$url_port"
  if [[ -z "$host" || -z "$port" ]]; then
    return 0
  fi
  case "$host" in
    localhost|127.0.0.1|host.docker.internal) ;;
    *) return 0 ;;
  esac

  if ! command -v kubectl >/dev/null 2>&1; then
    msg "${YELLOW}Note:${NOFORMAT} kubectl not found; skipping auto port-forward."
    return 0
  fi

  # Check service exists
  if ! kubectl -n gateway get svc kong-gw-kong-proxy >/dev/null 2>&1; then
    msg "${YELLOW}Note:${NOFORMAT} Service gateway/kong-gw-kong-proxy not found; skipping auto port-forward."
    return 0
  fi

  # Check if something is already listening
  if curl -fsS --max-time 3 "$endpoint" >/dev/null 2>&1; then
    return 0
  fi

  # When using host.docker.internal, kubectl port-forward must listen on 0.0.0.0
  # so that the container can reach the host's IP. We'll probe readiness via 127.0.0.1.
  local check_url="$endpoint"
  if [[ "$host" == "host.docker.internal" ]]; then
    check_url="http://127.0.0.1:${port}"
  fi

  msg "Attempting to port-forward gateway/kong-gw-kong-proxy  ${port}:80 ..."
  PF_LOG="$(mktemp -t kong-pf.XXXXXX.log)"
  # Use kubectl port-forward in background, binding to all addresses
  (kubectl -n gateway port-forward --address 0.0.0.0 svc/kong-gw-kong-proxy "${port}:80" &>"${PF_LOG}" & echo $! >&3) 3>"${PF_LOG}.pid" &
  # Read the background kubectl PID from the side channel
  sleep 0.2 || true
  if [[ -f "${PF_LOG}.pid" ]]; then
    PF_PID="$(cat "${PF_LOG}.pid" | tail -n1 || true)"
    rm -f "${PF_LOG}.pid" || true
  fi

  # Wait up to ~20s for the endpoint to become reachable
  if wait_for_http "$check_url" 20; then
    msg "${GREEN}Port-forward ready${NOFORMAT} (pid=${PF_PID})."
  else
    msg "${YELLOW}Warning:${NOFORMAT} Port-forward did not become ready. Logs:"
    sed -n '1,80p' "${PF_LOG}" || true
  fi
}

parse_params "$@"
setup_colors

cd $script_dir/../

# Auto-start a port-forward if --gateway looks like a local URL and it's not reachable
maybe_start_port_forward || true

# Quick reachability probe (non-fatal)
if command -v curl >/dev/null 2>&1; then
  if ! curl -fsS --max-time 5 "$endpoint" >/dev/null 2>&1; then
    msg "${YELLOW}Warning:${NOFORMAT} Unable to reach $endpoint quickly; continuing to run tests anyway."
  fi
fi

docker build -t retail-store-sample-e2e:run --pull --quiet -f Dockerfile.run .

# Run tests pointing Cypress to the resolved endpoint
msg "Using Docker network: $network"
msg "CYPRESS_BASE_URL: $endpoint"

docker run -i --rm --network "$network" -v "$PWD":/e2e --env CYPRESS_BASE_URL="$endpoint" -w /e2e retail-store-sample-e2e:run
