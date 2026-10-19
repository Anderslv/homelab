# shellcheck shell=bash disable=SC2016,SC2034 # sandboxed bash -c scripts; OUT/STATUS feed expect_*
# Docker cases: lib/docker.sh detects rootless/rootful/colima/down and warns about
# a rootful daemon. Sourced by dev/tests/secrets-setup.test.sh; see harness.sh.

# MODE: runs warn_if_rootful and docker_mode under `set -euo pipefail` with the
# docker shim for MODE; sets OUT (messages and mode), STATUS.
docker_lib() {
  new_case "docker_$1"
  docker_shim "$1"
  STATUS=0
  OUT=$(sandboxed "$BASH" -c 'set -euo pipefail
    . "$1/ui.sh"; . "$1/docker.sh"
    warn_if_rootful; printf "mode=%s\n" "$(docker_mode)"' _ "$CHECKOUT/scripts/secrets/lib" 2>&1) || STATUS=$?
}

case_docker_rootful_warns() {
  docker_lib rootful
  expect_status 0
  expect_out 'mode=rootful'
  expect_out '! Docker runs as root. A container escape or anyone in the docker group gets root on this machine.'
  expect_out 'Rootless Docker: https://docs.docker.com/engine/security/rootless/'
  expect_no_out 'Colima'
}

case_docker_rootless_quiet() {
  docker_lib rootless
  expect_status 0
  expect_out 'mode=rootless'
  expect_no_out 'Docker runs as root'
  expect_no_out 'Docker not running'
}

case_docker_colima_note() {
  docker_lib colima
  expect_status 0
  expect_out 'mode=colima'
  expect_out 'Docker runs as root'
  expect_out '(inside the Colima VM, so it is isolated from macOS)'
}

case_docker_down_note() {
  docker_lib down
  expect_status 0
  expect_out 'mode=down'
  expect_out '− Docker not running; skipping the rootless check'
  expect_no_out 'Docker runs as root'
}

# A daemon that never answers must count as down, within the time limit.
case_docker_hung_daemon_is_down() {
  new_case docker_hung_daemon_is_down
  shim docker 'case "${1:-}" in context) echo default; exit 0 ;; esac
exec sleep 30'
  STATUS=0
  local start=$SECONDS
  OUT=$(sandboxed HOMELAB_DOCKER_TIMEOUT=1 "$BASH" -c 'set -euo pipefail
    . "$1/ui.sh"; . "$1/docker.sh"
    warn_if_rootful; printf "mode=%s\n" "$(docker_mode)"' _ "$CHECKOUT/scripts/secrets/lib" 2>&1) || STATUS=$?
  expect_status 0
  expect_out 'mode=down'
  expect_out '− Docker not running; skipping the rootless check'
  expect_true "gave up within 8 seconds (took $((SECONDS - start)))" [ $((SECONDS - start)) -lt 8 ]
}

# With docker missing from PATH the mode is down and nothing fails.
case_docker_missing_is_down() {
  new_case docker_missing_is_down
  STATUS=0
  OUT=$(sandboxed "$BASH" -c 'set -euo pipefail
    . "$1/ui.sh"; . "$1/docker.sh"
    PATH=/nonexistent; warn_if_rootful; printf "mode=%s\n" "$(docker_mode)"' _ "$CHECKOUT/scripts/secrets/lib" 2>&1) || STATUS=$?
  expect_status 0
  expect_out 'mode=down'
  expect_out '− Docker not running; skipping the rootless check'
}
