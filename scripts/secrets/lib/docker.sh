# shellcheck shell=bash
# Detects how the Docker daemon runs (rootless, rootful, colima, down), warns when it
# is rootful and spots stacks that already hold data. It exists so setup and the
# macOS check share one answer.

# Runs `docker info` for the security options, giving up after
# ${HOMELAB_DOCKER_TIMEOUT:-5} seconds so a hung daemon cannot block the caller.
# Uses timeout/gtimeout when present; stock macOS has neither, so it falls back
# to a background run that is killed when the limit passes.
docker_info() {
  local limit=${HOMELAB_DOCKER_TIMEOUT:-5} tool='' pid tmp ticks=0 status=0
  for tool in timeout gtimeout; do
    if command -v "$tool" >/dev/null 2>&1; then
      "$tool" "$limit" docker info --format '{{json .SecurityOptions}}' 2>/dev/null
      return
    fi
  done
  tmp=$(mktemp "${TMPDIR:-/tmp}/docker-info.XXXXXX") || return 1
  docker info --format '{{json .SecurityOptions}}' >"$tmp" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge $((limit * 10)) ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$tmp"
      return 1
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid" || status=$?
  if [ "$status" -eq 0 ]; then cat "$tmp"; fi
  rm -f "$tmp"
  return "$status"
}

# Prints rootless|rootful|colima|down. Never fails the caller.
docker_mode() {
  local security context
  if ! security=$(docker_info); then
    echo down
    return 0
  fi
  case "$security" in
    *name=rootless*) echo rootless; return 0 ;;
  esac
  context=$(docker context show 2>/dev/null || true)
  if [ "$context" = colima ]; then echo colima; else echo rootful; fi
}

# Warns when Docker runs as root; never blocks and always returns 0.
warn_if_rootful() {
  local mode
  mode=$(docker_mode)
  case "$mode" in
    rootless) ;;
    down) note 'Docker not running; skipping the rootless check' ;;
    *)
      warn 'Docker runs as root. A container escape or anyone in the docker group gets root on this machine.'
      printf '    Rootless Docker: https://docs.docker.com/engine/security/rootless/\n' >&2
      if [ "$mode" = colima ]; then
        printf '    (inside the Colima VM, so it is isolated from macOS)\n' >&2
      fi
      ;;
  esac
  return 0
}

# STACK: prints why the stack may already hold data and returns 0, or returns 1 when
# it is clean. Reasons: "volume NAME", ".env sets VAR" (one of the stack's secrets),
# or "docker-down" (live data can't be ruled out). Needs map.sh, values.sh, $REPO.
live_data_reason() {
  local volumes volume var value
  if [ "$(docker_mode)" = down ] || ! volumes=$(docker volume ls -q 2>/dev/null); then
    echo docker-down
    return 0
  fi
  for volume in $(map_stack_volumes "$1"); do
    if printf '%s\n' "$volumes" | grep -qxF -- "$volume"; then echo "volume $volume"; return 0; fi
  done
  if [ ! -f "$REPO/.env" ]; then return 1; fi
  for var in $(map_stack_vars "$1"); do
    if ! printf '%s\n' "$var" | grep -Eiq "$MAP_SENSITIVE"; then continue; fi
    if value=$(dotenv_value "$REPO/.env" "$var") && [ -n "$value" ]; then echo ".env sets $var"; return 0; fi
  done
  return 1
}
