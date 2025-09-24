#!/usr/bin/env bash
# monitor-gateway-logs.sh
# Open terminals/tabs to live-monitor the API Gateway logs.
# - On macOS: opens Terminal with tabs for Kong proxy, Kuma sidecar, namespace events,
#   and KIC (if installed).
# - On Linux: uses tmux if available; otherwise runs commands sequentially in the current shell.
#
# Usage:
#   ./monitor-gateway-logs.sh [--namespace gateway] [--print-only]
# Environment:
#   GATEWAY_NS: override namespace (default: gateway)

set -euo pipefail

NS="${GATEWAY_NS:-gateway}"
PRINT_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      NS="${2:-$NS}"; shift 2;;
    --print-only)
      PRINT_ONLY=true; shift;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [options]
Options:
  -n, --namespace NS   Gateway namespace (default: ${NS})
      --print-only     Print the commands instead of opening terminals
  -h, --help           Show this help
EOF
      exit 0;;
    *) echo "Unknown option: $1" >&2; exit 1;;
  esac
done

need_cmd() { command -v "$1" >/dev/null 2>&1; }

info()  { printf "[info] %s\n" "$*"; }
warn()  { printf "[warn] %s\n" "$*"; }
error() { printf "[error] %s\n" "$*"; }

# Verify kubectl is available
if ! need_cmd kubectl; then
  error "kubectl not found in PATH"
  exit 1
fi

# Ensure namespace exists
if ! kubectl get ns "$NS" >/dev/null 2>&1; then
  error "Namespace '$NS' not found"
  exit 1
fi

# Discover Kong pod (data plane)
KONG_POD="$(kubectl -n "$NS" get pod \
  -l app.kubernetes.io/name=kong,app.kubernetes.io/component=app \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$KONG_POD" ]]; then
  error "Could not find Kong pod in namespace '$NS' (label app.kubernetes.io/name=kong,component=app)"
  exit 1
fi

# Determine if KIC is installed
HAS_KIC=false
if kubectl -n "$NS" get deploy kic-kong >/dev/null 2>&1; then
  HAS_KIC=true
fi

CMDS=()
CMDS+=("kubectl -n $NS logs $KONG_POD -c proxy --since=10m -f")
CMDS+=("kubectl -n $NS logs $KONG_POD -c kuma-sidecar --since=10m -f")
CMDS+=("kubectl -n $NS get events --sort-by=.lastTimestamp --watch")
if $HAS_KIC; then
  CMDS+=("kubectl -n $NS logs deploy/kic-kong -c ingress-controller --since=10m -f")
fi

print_commands() {
  echo "Monitoring commands (namespace: $NS):"
  for c in "${CMDS[@]}"; do
    echo "  $c"
  done
}

escape_for_applescript() {
  # Escape backslashes and quotes for AppleScript string literal
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/\"/\\\"/g'
}

open_macos_terminal_tabs() {
  if ! need_cmd osascript; then
    warn "osascript not found; falling back to current terminal"
    return 1
  fi
  local script="tell application \"Terminal\"\n  activate\n"
  local cmd
  for cmd in "${CMDS[@]}"; do
    local esc
    esc="$(escape_for_applescript "$cmd")"
    script+="  do script \"${esc}\"\n"
  done
  script+="end tell\n"
  /usr/bin/osascript -e "$script"
}

open_tmux_or_current_shell() {
  if need_cmd tmux; then
    info "Starting tmux session 'konglogs'..."
    # Start first pane
    tmux new-session -d -s konglogs "${CMDS[0]}"
    local i
    for ((i=1; i<${#CMDS[@]}; i++)); do
      tmux split-window -v "${CMDS[$i]}"
    done
    tmux select-layout even-vertical
    tmux attach-session -t konglogs
  else
    warn "tmux not found; running commands sequentially. Use Ctrl-C to stop each."
    local i
    for ((i=0; i<${#CMDS[@]}; i++)); do
      echo "--- (${i+1}/${#CMDS[@]}) ${CMDS[$i]}"
      bash -lc "${CMDS[$i]}"
    done
  fi
}

if $PRINT_ONLY; then
  print_commands
  exit 0
fi

case "$(uname -s)" in
  Darwin)
    if ! open_macos_terminal_tabs; then
      open_tmux_or_current_shell
    fi
    ;;
  *)
    open_tmux_or_current_shell
    ;;
esac

