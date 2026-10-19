#!/usr/bin/env bash
# Runs the sandboxed tests for the secrets scripts (scripts/secrets/, secrets.sh).
# Usage: bash dev/tests/secrets-setup.test.sh [--only NAME]
# Conventions for writing cases are at the top of dev/tests/secrets/harness.sh.
set -euo pipefail

TESTS_DIR=$(cd "$(dirname "$0")" && pwd -P)
ONLY=''

case "${1:-}" in
  '') ;;
  --only) ONLY=${2:?--only needs a NAME} ;;
  -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
  *) printf 'Unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
esac

# shellcheck source-path=SCRIPTDIR source=secrets/harness.sh
. "$TESTS_DIR/secrets/harness.sh"

defined_functions() { declare -F | sed 's/^declare -f //' | LC_ALL=C sort; }

# Sources every case file and lists "FILE FUNCTION" for each case_/last_ function.
CASES=''
for case_file in "$TESTS_DIR"/secrets/cases/*.sh; do
  before=$(defined_functions)
  # shellcheck source=/dev/null
  . "$case_file"
  added=$(LC_ALL=C comm -13 <(printf '%s\n' "$before") <(defined_functions))
  for fn in $added; do
    CASES="$CASES$(basename "$case_file" .sh) $fn
"
  done
done

# Prints the selected functions with the given prefix (by file, then by name).
selected() {
  local file fn
  printf '%s' "$CASES" | while read -r file fn; do
    case "$fn" in "$1"*) ;; *) continue ;; esac
    if [ "$1" = last_ ] || [ -z "$ONLY" ]; then printf '%s\n' "$fn"; continue; fi
    case "$fn $file" in *"$ONLY"*) printf '%s\n' "$fn" ;; esac
  done
}

run_case() {
  local status=0
  printf '\n%s\n' "$1"
  set +e
  (set -e; "$1")
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then record fail "$1 stopped early (status $status)"; fi
}

to_run=$(selected case_)
if [ -n "$ONLY" ] && [ -z "$to_run" ]; then
  printf 'No case matches %s\n' "$ONLY" >&2
  exit 1
fi
for fn in $to_run $(selected last_); do run_case "$fn"; done
summary
