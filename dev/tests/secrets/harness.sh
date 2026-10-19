# shellcheck shell=bash
# Test harness for the secrets scripts: scratch space, sandboxed runs, shims and
# ✓/✗ expectations. It exists so every case runs with a throwaway HOME inside an
# `env -i` child and never touches the real HOME, vault, keys or working tree.
#
# Conventions for case files (dev/tests/secrets/cases/*.sh):
# - Each case is a function named `case_<name>`, where <name> is the case name
#   from the plan, e.g. `case_config_roundtrip`. The runner finds them itself.
# - A function named `last_<name>` runs after every case (whole-run guards). It
#   runs on every invocation, with or without --only.
# - `--only NAME` runs the cases whose function name contains NAME, or that live
#   in a case file whose name contains NAME (`--only output` runs cases/output.sh).
# - Each case runs in its own subshell with `set -e`, so it starts fresh, its
#   variables never leak, and an unexpected error ends only that case (as a ✗).
# - A case calls `new_case NAME` first, then `sandboxed`/`run_*` and `expect_*`.
# - Never print a real secret; failing checks print labels only. The last
#   run_* output is saved in "$CASE/last-output.txt" for debugging.

# Forget every setting from the caller's shell that could point at real data,
# so nothing below can reach the user's vault, keys or secrets by accident.
for setting in $(env | sed -n 's/^\(HOMELAB_[A-Za-z0-9_]*\)=.*/\1/p;s/^\(KEEPASSXC_[A-Za-z0-9_]*\)=.*/\1/p'); do
  unset "$setting"
done
unset setting SOPS_AGE_KEY_FILE CASE REPO VAULT ANSWERS CASE_SECRETS_DIR CASE_AGE_KEY_FILE
CASE='' REPO='' VAULT='' ANSWERS=''
# A case that moves the sops file or age key elsewhere in $CASE sets these.
CASE_SECRETS_DIR='' CASE_AGE_KEY_FILE=''

CHECKOUT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
FIXTURE="$CHECKOUT/dev/tests/secrets/fixture"
BASE_PATH=$PATH
REAL_DOCKER=$(command -v docker || true)
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/secrets-setup-test.XXXXXX")
RESULTS="$SCRATCH/.results"
ENV_NAME=dev
VAULT_PASSWORD=test-pw
: > "$RESULTS"
touch "$SCRATCH/.started"

# --- Sandbox ----------------------------------------------------------------

new_case() {
  CASE="$SCRATCH/${1:?new_case needs a NAME}"
  REPO="$CASE/repo"
  (umask 077 && mkdir "$CASE" "$CASE/home" "$CASE/tmp" "$CASE/bin")
  cp -R "$FIXTURE" "$REPO"
  repo_git init -q
  repo_git add -A
  repo_git commit -q -m 'fixture'
}

# Runs git in $REPO inside the sandbox, with a fixed author and date.
repo_git() {
  sandboxed GIT_AUTHOR_NAME='Homelab Test' GIT_AUTHOR_EMAIL=test@example.invalid \
    GIT_COMMITTER_NAME='Homelab Test' GIT_COMMITTER_EMAIL=test@example.invalid \
    GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z \
    git -c init.defaultBranch=main -C "$REPO" "$@"
}

# Leading VAR=VALUE arguments add variables: `sandboxed X=1 cmd`.
sandboxed() {
  : "${CASE:?call new_case first}" "${REPO:?call new_case first}"
  env -i HOME="$CASE/home" TMPDIR="$CASE/tmp" PATH="$CASE/bin:$BASE_PATH" \
    LANG=C.UTF-8 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    HOMELAB_REPO="$REPO" HOMELAB_TEST_REAL_DOCKER="$REAL_DOCKER" "$@"
}

new_vault() {
  local password=${1:-test-pw}
  VAULT="${CASE:?call new_case first}/vault.kdbx"
  VAULT_PASSWORD=$password
  # -t 100 ms is the lowest decryption time keepassxc-cli accepts.
  if ! printf '%s\n%s\n' "$password" "$password" |
      sandboxed keepassxc-cli db-create -q -p -t 100 "$VAULT" >/dev/null 2>&1; then
    printf 'new_vault: keepassxc-cli db-create failed\n' >&2
    return 1
  fi
}

# --- Running the scripts under test -----------------------------------------

strip_colour() { sed "s/$(printf '\033')\[[0-9;]*[A-Za-z]//g"; }

# ANSWERS SCRIPT ARG…: runs SCRIPT from $REPO with ANSWERS on stdin; sets OUT, STATUS.
run_script() {
  local answers=$1 script=$2
  shift 2
  : "${CASE:?call new_case first}" "${REPO:?call new_case first}"
  STATUS=0
  OUT=$(cd "$REPO" && { printf '%b' "$answers" 2>/dev/null || true; } |
    sandboxed "$BASH" "$script" "$@" 2>&1) || STATUS=$?
  OUT=$(printf '%s\n' "$OUT" | strip_colour)
  printf '%s\n' "$OUT" > "$CASE/last-output.txt"
}

run_setup() { local answers=$1; shift; run_script "$answers" "$CHECKOUT/scripts/secrets/setup.sh" "$@"; }
# These two take their stdin from $ANSWERS (empty unless the case sets it).
run_secrets() { run_script "$ANSWERS" "$CHECKOUT/secrets.sh" "$@"; }
run_map() { run_script "$ANSWERS" "$CHECKOUT/scripts/secrets/map.sh" "$@"; }

# --- Shims ------------------------------------------------------------------

shim() {
  : "${CASE:?call new_case first}"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$CASE/bin/$1"
  chmod 755 "$CASE/bin/$1"
}

# MODE VOLUME…: a fake docker; `docker compose` runs the real one.
# shellcheck disable=SC2016 # the shim body expands at run time, not here
docker_shim() {
  local mode=$1 security='' context=default volumes='' volume
  shift
  case "$mode" in
    rootful|colima) security='["name=seccomp,profile=builtin","name=cgroupns"]' ;;
    rootless) security='["name=seccomp,profile=builtin","name=rootless","name=cgroupns"]' ;;
    down) ;;
    *) printf 'docker_shim: unknown mode %s\n' "$mode" >&2; return 1 ;;
  esac
  if [ "$mode" = colima ]; then context=colima; fi
  for volume in "$@"; do
    case "$volume" in *[!A-Za-z0-9_.-]*) printf 'docker_shim: bad volume %s\n' "$volume" >&2; return 1 ;; esac
    volumes="$volumes $volume"
  done
  shim docker "$(printf '%s\n' \
    "mode=$mode context=$context volumes='$volumes' security='$security'" \
    'case "${1:-} ${2:-}" in' \
    '  compose\ *) exec "$HOMELAB_TEST_REAL_DOCKER" "$@" ;;' \
    '  "context show") echo "$context"; exit 0 ;;' \
    'esac' \
    'if [ "$mode" = down ]; then' \
    '  echo "Cannot connect to the Docker daemon. Is the docker daemon running?" >&2; exit 1' \
    'fi' \
    'case "${1:-} ${2:-}" in' \
    '  info\ *) echo "$security"; exit 0 ;;' \
    '  "volume ls") for v in $volumes; do echo "$v"; done; exit 0 ;;' \
    'esac' \
    'echo "docker shim: unsupported: $*" >&2' \
    'exit 1')"
}

# --- Expectations -----------------------------------------------------------

record() {
  if [ "$1" = pass ]; then printf '  ✓ %s\n' "$2"; else printf '  ✗ %s\n' "$2"; fi
  printf '%s\n' "$1" >> "$RESULTS"
}

expect_true() {
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then record pass "$label"; else record fail "$label"; fi
}

expect_status() { expect_true "exit status $1 (got $STATUS)" [ "$STATUS" = "$1" ]; }

expect_out() {
  case "$OUT" in *"$1"*) record pass "output has: $1" ;; *) record fail "output has: $1" ;; esac
}

expect_no_out() {
  case "$OUT" in *"$1"*) record fail "output lacks: $1" ;; *) record pass "output lacks: $1" ;; esac
}

file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

expect_mode() {
  local mode
  mode=$(file_mode "$1" 2>/dev/null || true)
  expect_true "${1#"$CASE"/} has mode $2 (got ${mode:-none})" [ "$mode" = "$2" ]
}

expect_missing() {
  if [ -e "$1" ] || [ -L "$1" ]; then record fail "${1#"$CASE"/} does not exist"
  else record pass "${1#"$CASE"/} does not exist"; fi
}

# JQ_FILTER EXPECTED: checks the vars JSON in $VAULT, group homelab/$ENV_NAME.
expect_vault_json() {
  local got label="vault homelab/$ENV_NAME/vars: $1"
  if got=$(printf '%s\n' "$VAULT_PASSWORD" |
      sandboxed keepassxc-cli show -q -s -a Password "$VAULT" "homelab/$ENV_NAME/vars" |
      jq -r "$1") && [ "$got" = "$2" ]; then
    record pass "$label"
  else
    record fail "$label"
  fi
}

# VAR VALUE: decrypts VAR from the case's secrets.yaml (never the real one).
expect_sops() {
  local got dir key
  dir=${CASE_SECRETS_DIR:-${CASE:?call new_case first}/home/.config/homelab-secrets}
  key=${CASE_AGE_KEY_FILE:-$CASE/home/.config/sops/age/keys.txt}
  if got=$(sandboxed SOPS_AGE_KEY_FILE="$key" sops decrypt --extract "[\"$1\"]" \
      "$dir/secrets.yaml" 2>/dev/null) && [ "$got" = "$2" ]; then
    record pass "sops has $1"
  else
    record fail "sops has $1"
  fi
}

summary() {
  local passed failed
  passed=$(grep -c '^pass$' "$RESULTS" || true)
  failed=$(grep -c '^fail$' "$RESULTS" || true)
  printf '\n%s passed, %s failed\n' "$passed" "$failed"
  printf 'Test files kept in %s\n' "$SCRATCH"
  if [ "$failed" -gt 0 ]; then exit 1; fi
}
