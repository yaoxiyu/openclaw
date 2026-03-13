#!/usr/bin/env bash
set -euo pipefail

# Multi-instance management script for OpenClaw Docker deployments.
#
# Usage:
#   ./manage.sh <instance> start   [--gateway-port PORT] [--bridge-port PORT] [--allow-insecure-ws] [--image IMAGE] [--custom-bind-host IP]
#   ./manage.sh <instance> stop
#   ./manage.sh <instance> restart  [--rebuild]
#   ./manage.sh <instance> status
#   ./manage.sh <instance> logs     [-- EXTRA_ARGS...]
#   ./manage.sh <instance> exec    [--cli] [--sh] [COMMAND...]
#   ./manage.sh list
#
# Examples:
#   ./manage.sh prod start --gateway-port 18789 --bridge-port 18790
#   ./manage.sh dev  start --gateway-port 28789 --bridge-port 28790
#   ./manage.sh prod restart
#   ./manage.sh prod restart --rebuild
#   ./manage.sh prod stop
#   ./manage.sh prod logs -- -f --tail 100
#   ./manage.sh prod exec
#   ./manage.sh prod exec --cli
#   ./manage.sh prod exec node -e "console.log('hello')"
#   ./manage.sh list
#
# Each instance gets its own run directory under instances/<name>/ with
# symlinks to shared files and isolated generated files (.env, overlays).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTANCES_DIR="$SCRIPT_DIR/instances"
PRECHECK_SCRIPT="$SCRIPT_DIR/pre-check.sh"

# Ensure HOME is available — some environments (sudo without -H, cron,
# non-login shells) may leave it unset.
if [[ -z "${HOME:-}" ]]; then
  HOME="$(eval echo ~"$(whoami)" 2>/dev/null || getent passwd "$(id -un)" | cut -d: -f6 || echo "/root")"
  export HOME
fi

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  echo "Usage:"
  echo "  $0 <instance> start   [--gateway-port PORT] [--bridge-port PORT] [--allow-insecure-ws] [--image IMAGE] [--custom-bind-host IP]"
  echo "  $0 <instance> stop"
  echo "  $0 <instance> restart [--rebuild]"
  echo "  $0 <instance> status"
  echo "  $0 <instance> logs    [-- EXTRA_ARGS...]"
  echo "  $0 <instance> exec    [--cli] [--sh] [COMMAND...]"
  echo "  $0 <instance> delete  [--volumes]"
  echo "  $0 list"
  exit 1
}

# ── Instance config helpers ──────────────────────────────────────

instance_env_file() {
  echo "$INSTANCES_DIR/$1.env"
}

instance_run_dir() {
  echo "$INSTANCES_DIR/$1"
}

load_instance_env() {
  local name="$1"
  local env_file
  env_file="$(instance_env_file "$name")"
  if [[ ! -f "$env_file" ]]; then
    fail "Instance '$name' not found. Run '$0 $name start' first."
  fi
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
}

save_instance_env() {
  local name="$1"
  mkdir -p "$INSTANCES_DIR"
  local env_file
  env_file="$(instance_env_file "$name")"
  cat >"$env_file" <<EOF
# Auto-generated config for instance: $name
INSTANCE_NAME=$name
COMPOSE_PROJECT_NAME=openclaw-${name}
OPENCLAW_GATEWAY_PORT=$OPENCLAW_GATEWAY_PORT
OPENCLAW_BRIDGE_PORT=$OPENCLAW_BRIDGE_PORT
OPENCLAW_CONFIG_DIR=$OPENCLAW_CONFIG_DIR
OPENCLAW_WORKSPACE_DIR=$OPENCLAW_WORKSPACE_DIR
OPENCLAW_IMAGE=$OPENCLAW_IMAGE
OPENCLAW_GATEWAY_BIND=${OPENCLAW_GATEWAY_BIND:-lan}
OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=${OPENCLAW_ALLOW_INSECURE_PRIVATE_WS:-}
OPENCLAW_HOME_VOLUME=${OPENCLAW_HOME_VOLUME:-}
OPENCLAW_CUSTOM_BIND_HOST=${OPENCLAW_CUSTOM_BIND_HOST:-}
EOF
  echo "Instance config saved to $env_file"
}

# Create per-instance run directory with symlinks to shared read-only files.
# docker-setup.sh derives ROOT_DIR from its own path, so running from the
# symlink makes it write .env / overlay files into this isolated directory.
setup_instance_run_dir() {
  local name="$1"
  local run_dir
  run_dir="$(instance_run_dir "$name")"
  mkdir -p "$run_dir"

  local file
  for file in docker-setup.sh docker-compose.yml Dockerfile Dockerfile.sandbox; do
    if [[ -e "$REPO_ROOT/$file" ]]; then
      # Recreate symlink if missing or broken.
      if [[ -L "$run_dir/$file" && ! -e "$run_dir/$file" ]]; then
        rm -f "$run_dir/$file"
      fi
      if [[ ! -e "$run_dir/$file" ]]; then
        ln -s "$REPO_ROOT/$file" "$run_dir/$file"
      fi
    fi
  done
}

# Build compose args pointing to the instance's run directory.
# Automatically includes overlay files if they were generated during setup.
compose_cmd() {
  local run_dir
  run_dir="$(instance_run_dir "$INSTANCE_NAME")"
  local project_name="openclaw-${INSTANCE_NAME}"
  local -a compose_files=("-f" "$run_dir/docker-compose.yml")
  local extra="$run_dir/docker-compose.extra.yml"
  local sandbox="$run_dir/docker-compose.sandbox.yml"
  if [[ -f "$extra" ]]; then compose_files+=("-f" "$extra"); fi
  if [[ -f "$sandbox" ]]; then compose_files+=("-f" "$sandbox"); fi
  docker compose -p "$project_name" "${compose_files[@]}" "$@"
}

# ── Commands ─────────────────────────────────────────────────────

cmd_start() {
  local instance="$1"
  shift

  local gateway_port=""
  local bridge_port=""
  local allow_insecure_ws=""
  local image=""
  local custom_bind_host=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --gateway-port)      gateway_port="$2"; shift 2 ;;
      --bridge-port)       bridge_port="$2";  shift 2 ;;
      --allow-insecure-ws) allow_insecure_ws="1"; shift ;;
      --image)             image="$2"; shift 2 ;;
      --custom-bind-host)  custom_bind_host="$2"; shift 2 ;;
      *) fail "Unknown option: $1" ;;
    esac
  done

  local env_file
  env_file="$(instance_env_file "$instance")"

  if [[ -f "$env_file" ]]; then
    echo "Instance '$instance' already has a config. Loading existing settings."
    load_instance_env "$instance"
    if [[ -n "$gateway_port" ]]; then OPENCLAW_GATEWAY_PORT="$gateway_port"; fi
    if [[ -n "$bridge_port" ]]; then OPENCLAW_BRIDGE_PORT="$bridge_port"; fi
    if [[ -n "$allow_insecure_ws" ]]; then OPENCLAW_ALLOW_INSECURE_PRIVATE_WS="1"; fi
    if [[ -n "$image" ]]; then OPENCLAW_IMAGE="$image"; fi
    if [[ -n "$custom_bind_host" ]]; then OPENCLAW_CUSTOM_BIND_HOST="$custom_bind_host"; fi
  else
    export OPENCLAW_GATEWAY_PORT="${gateway_port:-18789}"
    export OPENCLAW_BRIDGE_PORT="${bridge_port:-18790}"
    export OPENCLAW_ALLOW_INSECURE_PRIVATE_WS="${allow_insecure_ws}"
    export OPENCLAW_IMAGE="${image:-openclaw:local}"
    export OPENCLAW_CUSTOM_BIND_HOST="${custom_bind_host}"
  fi

  # Per-instance isolated directories and volumes.
  export OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw-${instance}}"
  export OPENCLAW_WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-$HOME/.openclaw-${instance}/workspace}"

  if [[ -z "$OPENCLAW_CONFIG_DIR" || -z "$OPENCLAW_WORKSPACE_DIR" ]]; then
    fail "OPENCLAW_CONFIG_DIR or OPENCLAW_WORKSPACE_DIR resolved to empty. Check that \$HOME is set (current HOME='${HOME:-}')."
  fi
  export OPENCLAW_ALLOW_INSECURE_PRIVATE_WS="${OPENCLAW_ALLOW_INSECURE_PRIVATE_WS:-}"
  export INSTANCE_NAME="$instance"
  export COMPOSE_PROJECT_NAME="openclaw-${instance}"

  # Append instance name to named volume to prevent cross-instance sharing.
  if [[ -n "${OPENCLAW_HOME_VOLUME:-}" && "${OPENCLAW_HOME_VOLUME}" != *"/"* ]]; then
    if [[ "$OPENCLAW_HOME_VOLUME" != *"-${instance}" ]]; then
      export OPENCLAW_HOME_VOLUME="${OPENCLAW_HOME_VOLUME}-${instance}"
    fi
  fi

  # Build the shared image from repo root (correct Dockerfile + context).
  # docker-setup.sh runs from the instance dir where symlinks break Docker
  # BuildKit, so we pre-build here and let docker-setup.sh skip via the
  # "existing local image" branch.
  if [[ "$OPENCLAW_IMAGE" == "openclaw:local" ]]; then
    if ! docker image inspect "openclaw:local" >/dev/null 2>&1; then
      echo "==> Building shared Docker image: openclaw:local (IO priority: idle)"
      ionice -c3 nice -n 19 docker build \
        --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=${OPENCLAW_DOCKER_APT_PACKAGES:-}" \
        --build-arg "OPENCLAW_EXTENSIONS=${OPENCLAW_EXTENSIONS:-}" \
        --build-arg "OPENCLAW_INSTALL_DOCKER_CLI=${OPENCLAW_INSTALL_DOCKER_CLI:-}" \
        -t "openclaw:local" \
        -f "$REPO_ROOT/Dockerfile" \
        "$REPO_ROOT"
    else
      echo "==> Reusing existing shared image: openclaw:local"
    fi
  fi

  echo "============================================"
  echo "  Instance:       $instance"
  echo "  Gateway port:   $OPENCLAW_GATEWAY_PORT"
  echo "  Bridge port:    $OPENCLAW_BRIDGE_PORT"
  echo "  Config dir:     $OPENCLAW_CONFIG_DIR"
  echo "  Workspace dir:  $OPENCLAW_WORKSPACE_DIR"
  echo "  Project name:   $COMPOSE_PROJECT_NAME"
  echo "  Image:          $OPENCLAW_IMAGE"
  echo "  Insecure WS:    ${OPENCLAW_ALLOW_INSECURE_PRIVATE_WS:-off}"
  echo "============================================"
  echo ""

  # Run pre-checks.
  echo "==> Running pre-checks"
  bash "$PRECHECK_SCRIPT"
  echo ""

  # Set up per-instance run directory with symlinks.
  setup_instance_run_dir "$instance"

  # Save config so stop/restart can reuse it.
  save_instance_env "$instance"

  # Run docker-setup.sh from the instance run directory.
  # Because docker-setup.sh derives ROOT_DIR from BASH_SOURCE[0], running
  # the symlink makes it write .env and overlay files into the instance dir.
  local run_dir
  run_dir="$(instance_run_dir "$instance")"
  echo "==> Starting instance '$instance' (run dir: $run_dir)"
  bash "$run_dir/docker-setup.sh"

  # Fix controlUi.allowedOrigins to use the external (host) port.
  # onboard seeds origins with the container-internal port (18789), but
  # browsers reach the gateway through the host-mapped port which may differ.
  if [[ "${OPENCLAW_GATEWAY_BIND}" != "loopback" ]]; then
    local origin_json
    origin_json="[\"http://localhost:${OPENCLAW_GATEWAY_PORT}\",\"http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}\"]"

    local custom_host="${OPENCLAW_CUSTOM_BIND_HOST:-}"
    if [[ -n "$custom_host" ]]; then
      origin_json="[\"http://localhost:${OPENCLAW_GATEWAY_PORT}\",\"http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}\",\"http://${custom_host}:${OPENCLAW_GATEWAY_PORT}\"]"
    fi

    echo ""
    echo "==> Fixing controlUi.allowedOrigins to external port $OPENCLAW_GATEWAY_PORT"
    compose_cmd run --rm openclaw-cli \
      config set gateway.controlUi.allowedOrigins "$origin_json" --strict-json >/dev/null
    echo "  Set gateway.controlUi.allowedOrigins to $origin_json"
  fi
}

cmd_stop() {
  local instance="$1"
  load_instance_env "$instance"
  export INSTANCE_NAME="$instance"

  echo "==> Stopping instance '$instance' (project: openclaw-${instance})"
  compose_cmd down
  echo "Instance '$instance' stopped."
}

cmd_restart() {
  local instance="$1"
  shift
  load_instance_env "$instance"
  export INSTANCE_NAME="$instance"

  local rebuild=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rebuild) rebuild=true; shift ;;
      *) fail "Unknown option: $1" ;;
    esac
  done

  if [[ "$rebuild" == true ]]; then
    echo "==> Rebuilding image before restart (IO priority: idle)"
    ionice -c3 nice -n 19 docker build \
      --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=${OPENCLAW_DOCKER_APT_PACKAGES:-}" \
      --build-arg "OPENCLAW_EXTENSIONS=${OPENCLAW_EXTENSIONS:-}" \
      --build-arg "OPENCLAW_INSTALL_DOCKER_CLI=${OPENCLAW_INSTALL_DOCKER_CLI:-}" \
      -t "${OPENCLAW_IMAGE}" \
      -f "$REPO_ROOT/Dockerfile" \
      "$REPO_ROOT"
    echo "==> Recreating containers with new image"
    compose_cmd up -d --force-recreate openclaw-gateway
  else
    echo "==> Restarting instance '$instance' (project: openclaw-${instance})"
    compose_cmd restart
  fi
  echo "Instance '$instance' restarted."
}

cmd_status() {
  local instance="$1"
  load_instance_env "$instance"
  export INSTANCE_NAME="$instance"

  echo "==> Status for instance '$instance' (project: openclaw-${instance})"
  echo ""
  echo "  Gateway port:  $OPENCLAW_GATEWAY_PORT"
  echo "  Bridge port:   $OPENCLAW_BRIDGE_PORT"
  echo "  Config dir:    $OPENCLAW_CONFIG_DIR"
  echo "  Workspace dir: $OPENCLAW_WORKSPACE_DIR"
  echo "  Image:         $OPENCLAW_IMAGE"
  echo ""
  compose_cmd ps
}

cmd_logs() {
  local instance="$1"
  shift
  load_instance_env "$instance"
  export INSTANCE_NAME="$instance"

  compose_cmd logs "$@" openclaw-gateway
}

cmd_exec() {
  local instance="$1"
  shift
  load_instance_env "$instance"
  export INSTANCE_NAME="$instance"

  local service="openclaw-gateway"
  local shell="bash"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cli)   service="openclaw-cli"; shift ;;
      --sh)    shell="sh"; shift ;;
      *) break ;;
    esac
  done

  if [[ $# -gt 0 ]]; then
    echo "==> Executing in '$instance' ($service): $*"
    compose_cmd exec "$service" "$@"
  else
    echo "==> Opening $shell shell in '$instance' ($service)"
    compose_cmd exec "$service" "$shell"
  fi
}

cmd_delete() {
  local instance="$1"
  shift
  local remove_volumes=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --volumes) remove_volumes=true; shift ;;
      *) fail "Unknown option: $1" ;;
    esac
  done

  local env_file run_dir
  env_file="$(instance_env_file "$instance")"
  run_dir="$(instance_run_dir "$instance")"

  if [[ ! -f "$env_file" && ! -d "$run_dir" ]]; then
    fail "Instance '$instance' does not exist."
  fi

  # Stop containers if running.
  if [[ -f "$env_file" ]]; then
    load_instance_env "$instance"
    export INSTANCE_NAME="$instance"
    echo "==> Stopping containers for '$instance'"
    if [[ "$remove_volumes" == true ]]; then
      compose_cmd down --volumes 2>/dev/null || true
    else
      compose_cmd down 2>/dev/null || true
    fi
  fi

  # Remove run directory (symlinks + generated files).
  if [[ -d "$run_dir" ]]; then
    rm -rf "$run_dir"
    echo "Removed run directory: $run_dir"
  fi

  # Remove instance config.
  if [[ -f "$env_file" ]]; then
    rm -f "$env_file"
    echo "Removed instance config: $env_file"
  fi

  echo "Instance '$instance' deleted."
}

cmd_list() {
  if [[ ! -d "$INSTANCES_DIR" ]]; then
    echo "No instances found."
    return 0
  fi
  local -a env_files=()
  local f
  for f in "$INSTANCES_DIR"/*.env; do
    if [[ -f "$f" ]]; then env_files+=("$f"); fi
  done
  if [[ ${#env_files[@]} -eq 0 ]]; then
    echo "No instances found."
    return 0
  fi
  echo "Registered instances:"
  echo ""
  printf "  %-15s %-8s %-8s %-25s %s\n" "INSTANCE" "GATEWAY" "BRIDGE" "IMAGE" "CONFIG DIR"
  printf "  %-15s %-8s %-8s %-25s %s\n" "--------" "-------" "------" "-----" "----------"
  for f in "${env_files[@]}"; do
    local name port_gw port_br img config_dir
    name="$(basename "$f" .env)"
    port_gw="$(grep '^OPENCLAW_GATEWAY_PORT=' "$f" | cut -d= -f2)"
    port_br="$(grep '^OPENCLAW_BRIDGE_PORT=' "$f" | cut -d= -f2)"
    img="$(grep '^OPENCLAW_IMAGE=' "$f" | cut -d= -f2)"
    config_dir="$(grep '^OPENCLAW_CONFIG_DIR=' "$f" | cut -d= -f2)"
    printf "  %-15s %-8s %-8s %-25s %s\n" "$name" "$port_gw" "$port_br" "$img" "$config_dir"
  done
}

# ── Main ─────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  usage
fi

if [[ "$1" == "list" ]]; then
  cmd_list
  exit 0
fi

if [[ $# -lt 2 ]]; then
  usage
fi

INSTANCE="$1"
COMMAND="$2"
shift 2

if [[ ! "$INSTANCE" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
  fail "Instance name must be alphanumeric (hyphens/underscores allowed), got: '$INSTANCE'"
fi

case "$COMMAND" in
  start)   cmd_start   "$INSTANCE" "$@" ;;
  stop)    cmd_stop    "$INSTANCE" ;;
  restart) cmd_restart "$INSTANCE" "$@" ;;
  status)  cmd_status  "$INSTANCE" ;;
  logs)    cmd_logs    "$INSTANCE" "$@" ;;
  exec)    cmd_exec    "$INSTANCE" "$@" ;;
  delete)  cmd_delete  "$INSTANCE" "$@" ;;
  *)       fail "Unknown command: $COMMAND. Use start|stop|restart|status|logs|exec|delete." ;;
esac
