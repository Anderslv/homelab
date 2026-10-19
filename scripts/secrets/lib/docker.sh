# shellcheck shell=bash
# Detects how the Docker daemon runs (rootless, rootful, colima, down) and warns
# when it is rootful. It exists so setup and the macOS check share one answer.

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
