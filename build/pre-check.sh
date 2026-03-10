#!/usr/bin/env bash
set -euo pipefail

# Pre-check script for multi-instance Docker deployment.
# Run this BEFORE docker-setup.sh to detect and prevent conflicts.
#
# Usage:
#   OPENCLAW_GATEWAY_PORT=28789 OPENCLAW_BRIDGE_PORT=28790 ./pre-check.sh
#   # If all checks pass, proceed:
#   ./docker-setup.sh

fail() {
  echo "PRE-CHECK FAILED: $*" >&2
  exit 1
}

warn() {
  echo "PRE-CHECK WARNING: $*" >&2
}

OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
OPENCLAW_BRIDGE_PORT="${OPENCLAW_BRIDGE_PORT:-18790}"
INSTANCE_NAME="${INSTANCE_NAME:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCES_DIR="$SCRIPT_DIR/instances"

# ── Check 1: Port conflict with other registered instances ──────
check_instance_port_conflict() {
  local port="$1"
  local label="$2"
  if [[ ! -d "$INSTANCES_DIR" ]]; then return 0; fi
  local f
  for f in "$INSTANCES_DIR"/*.env; do
    if [[ ! -f "$f" ]]; then continue; fi
    local other_name
    other_name="$(basename "$f" .env)"
    # Skip self (when re-starting the same instance).
    if [[ -n "$INSTANCE_NAME" && "$other_name" == "$INSTANCE_NAME" ]]; then continue; fi
    local saved_gw saved_br
    saved_gw="$(grep '^OPENCLAW_GATEWAY_PORT=' "$f" | cut -d= -f2)" || true
    saved_br="$(grep '^OPENCLAW_BRIDGE_PORT=' "$f" | cut -d= -f2)" || true
    if [[ "$saved_gw" == "$port" || "$saved_br" == "$port" ]]; then
      fail "$label port $port conflicts with registered instance '$other_name'."
    fi
  done
}

echo "==> [1/3] Checking port conflicts with registered instances"
check_instance_port_conflict "$OPENCLAW_GATEWAY_PORT" "OPENCLAW_GATEWAY_PORT"
check_instance_port_conflict "$OPENCLAW_BRIDGE_PORT" "OPENCLAW_BRIDGE_PORT"
echo "  OK: no port conflicts with other instances"

# ── Check 2: Port availability (OS-level) ───────────────────────
check_port_available() {
  local port="$1"
  local label="$2"
  local detected=false
  # Try each tool in order; fall through on tool failure (not just absence).
  if [[ "$detected" == false ]] && command -v ss >/dev/null 2>&1; then
    local ss_out
    if ss_out="$(ss -ltno "sport = :$port" 2>/dev/null)"; then
      if printf '%s' "$ss_out" | grep -q "LISTEN"; then
        fail "$label port $port is already in use. Set $label to a different value."
      fi
      detected=true
    fi
  fi
  if [[ "$detected" == false ]] && command -v lsof >/dev/null 2>&1; then
    if lsof -iTCP:"$port" -sTCP:LISTEN -P -n >/dev/null 2>&1; then
      fail "$label port $port is already in use. Set $label to a different value."
    fi
    detected=true
  fi
  if [[ "$detected" == false ]] && command -v netstat >/dev/null 2>&1; then
    local ns_out
    if ns_out="$(netstat -an 2>/dev/null)"; then
      if printf '%s' "$ns_out" | grep -qE "[.:]${port}[[:space:]].*LISTEN"; then
        fail "$label port $port is already in use. Set $label to a different value."
      fi
      detected=true
    fi
  fi
  if [[ "$detected" == false ]]; then
    warn "No port-check tool found (ss/lsof/netstat). Skipping port availability check."
    return 0
  fi
  echo "  OK: port $port ($label) is available"
}

echo "==> [2/3] Checking port availability (OS-level)"
check_port_available "$OPENCLAW_GATEWAY_PORT" "OPENCLAW_GATEWAY_PORT"
check_port_available "$OPENCLAW_BRIDGE_PORT" "OPENCLAW_BRIDGE_PORT"

echo ""
echo "==> [3/3] Checking port self-collision"
if [[ "$OPENCLAW_GATEWAY_PORT" == "$OPENCLAW_BRIDGE_PORT" ]]; then
  fail "OPENCLAW_GATEWAY_PORT and OPENCLAW_BRIDGE_PORT cannot be the same ($OPENCLAW_GATEWAY_PORT)."
fi
echo "  OK: gateway and bridge ports are different"

echo ""
echo "All pre-checks passed."
