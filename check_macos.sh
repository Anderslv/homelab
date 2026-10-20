#!/usr/bin/env bash
# Read-only readiness report for running the stack on a Mac with Colima. It changes
# nothing: each check prints ✓, ! (warning) or ✗ (problem) with a one-line fix.
# Usage: ./check_macos.sh [--ci]   (--ci skips the VM size and image checks)
# Exits 1 only when a problem was found.
set -euo pipefail

self=${BASH_SOURCE[0]}
while [ -L "$self" ]; do
  link=$(readlink "$self")
  case "$link" in /*) self=$link ;; *) self=$(dirname "$self")/$link ;; esac
done
repo=$(cd "$(dirname "$self")" && pwd -P)
# shellcheck source=scripts/secrets/lib/ui.sh
. "$repo/scripts/secrets/lib/ui.sh"
# shellcheck source=scripts/secrets/lib/docker.sh
. "$repo/scripts/secrets/lib/docker.sh"

ci=''
case "${1:-}" in
  '') ;;
  --ci) ci=1 ;;
  -h|--help) sed -n '2,4p' "$self" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'Unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
esac

problems=0
# MESSAGE FIX: a problem with its one-line fix.
problem() { fail "$1"; printf '    Fix: %s\n' "$2" >&2; problems=$((problems + 1)); }
# MESSAGE FIX: a warning with its one-line fix.
caution() { warn "$1"; printf '    Fix: %s\n' "$2" >&2; }

has_tool() { command -v "$1" >/dev/null 2>&1; }

check_docker() {
  if ! has_tool docker; then
    problem 'docker not found' 'brew install colima docker docker-compose'
  elif ! docker compose version >/dev/null 2>&1; then
    problem 'docker compose not found' 'brew install docker-compose, then add cliPluginsExtraDirs to ~/.docker/config.json (docs/macos.md)'
  else
    ok 'docker and docker compose found'
  fi
}

check_secret_tools() {
  local tool fix path=/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli
  for tool in sops age keepassxc-cli; do
    fix="brew install $tool"
    if [ "$tool" = keepassxc-cli ]; then fix='brew install --cask keepassxc'; fi
    if has_tool "$tool" || { [ "$tool" = keepassxc-cli ] && [ -x "$path" ]; }; then
      ok "$tool found"
    else
      problem "$tool not found" "$fix"
    fi
  done
}

check_context() {
  local context
  has_tool docker || return 0
  context=$(docker context show 2>/dev/null || true)
  if [ "$context" = colima ]; then
    ok 'docker context is colima'
    if ! has_tool colima; then problem 'colima not found' 'brew install colima'; fi
  else
    problem "docker context is ${context:-unknown}, not colima" 'colima start, then docker context use colima'
  fi
}

check_resources() {
  local line cpus mem gib
  if ! has_tool colima || ! has_tool jq; then
    caution 'Cannot read the Colima VM size (colima or jq missing)' 'brew install colima jq'
    return 0
  fi
  line=$(colima list --json 2>/dev/null | head -n 1 || true)
  cpus=$(printf '%s' "$line" | jq -r '.cpus // empty' 2>/dev/null || true)
  mem=$(printf '%s' "$line" | jq -r '.memory // empty' 2>/dev/null || true)
  case "$cpus$mem" in
    ''|*[!0-9]*) caution 'Cannot read the Colima VM size (is the VM started?)' 'colima start --cpu 6 --memory 16'; return 0 ;;
  esac
  gib=$((mem / 1073741824))
  if [ "$cpus" -lt 4 ] || [ "$gib" -lt 16 ]; then
    caution "Colima has $cpus CPUs and $gib GiB; the dev profile wants 4 and 16" 'colima stop && colima start --cpu 6 --memory 16'
  else
    ok "Colima has $cpus CPUs and $gib GiB"
  fi
}

check_images() {
  local images image missing=''
  [ "$(uname -m)" = arm64 ] || return 0
  if ! has_tool docker || ! images=$(bash "$repo/secrets.sh" compose --profile dev config --images 2>/dev/null); then
    caution 'Could not list the images (secrets not set up yet?)' 'scripts/secrets/setup.sh ~/homelab.kdbx --profile dev, then run this again'
    return 0
  fi
  for image in $(printf '%s\n' "$images" | sort -u); do
    if ! docker buildx imagetools inspect "$image" 2>/dev/null | grep -q 'linux/arm64'; then
      missing="$missing $image"
    fi
  done
  if [ -z "$missing" ]; then
    ok 'every image publishes linux/arm64'
  else
    for image in $missing; do
      caution "$image has no linux/arm64 build" 'it runs through Rosetta (colima start --vz-rosetta), or skip it'
    done
  fi
}

check_whoami() {
  has_tool docker || return 0
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q traefik || return 0
  if curl -fsk --max-time 5 https://whoami.localhost.me >/dev/null 2>&1; then
    ok 'https://whoami.localhost.me answers'
  else
    problem 'https://whoami.localhost.me does not answer' 'mkcert -install; colima restart; see docs/macos.md'
  fi
}

check_docker
check_secret_tools
check_context
if [ -z "$ci" ]; then check_resources; fi
has_tool docker && warn_if_rootful
if [ -z "$ci" ]; then check_images; fi
check_whoami

if [ "$problems" -gt 0 ]; then
  printf '\n  %s problem(s) found.\n' "$problems" >&2
  exit 1
fi
