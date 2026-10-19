#!/usr/bin/env bash
# Refreshes .env.example from the compose files, or checks that it is current.
# The file lists every variable with its kind and stacks, and never any value.
set -euo pipefail

LIB_DIR=$(cd "$(dirname "$0")/lib" && pwd -P)
# shellcheck source-path=SCRIPTDIR source=lib/ui.sh
. "$LIB_DIR/ui.sh"
# shellcheck source-path=SCRIPTDIR source=lib/config.sh
. "$LIB_DIR/config.sh"
# shellcheck source-path=SCRIPTDIR source=lib/map.sh
. "$LIB_DIR/map.sh"
# shellcheck source-path=SCRIPTDIR source=lib/example.sh
. "$LIB_DIR/example.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/secrets/map.sh [--check]
  (no option)  rewrite .env.example from the compose files
  --check      write nothing; exit 1 when .env.example is stale
USAGE
}

CHECK=no
case "${1:-}" in
  '') ;;
  --check) CHECK=yes ;;
  -h|--help) usage; exit 0 ;;
  *) die "Unknown option: $1 (try --help)" ;;
esac

# Prints the VAR names in a .env.example, sorted.
names() { sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' | LC_ALL=C sort; }

# LIST_A LIST_B: prints the lines of A that are not in B.
minus() {
  awk 'FNR == NR { seen[$0] = 1; next } $0 != "" && !($0 in seen)' \
    <(printf '%s\n' "$2") <(printf '%s\n' "$1")
}

count() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }

secrets_paths
EXAMPLE="$REPO/.env.example"
OLD=/dev/null
if [ -f "$EXAMPLE" ]; then OLD=$EXAMPLE; fi

NEW=$(render_env_example "$OLD")
CURRENT=$(cat "$OLD")
ADDED=$(minus "$(printf '%s\n' "$NEW" | names)" "$(names < "$OLD")")
REMOVED=$(minus "$(names < "$OLD")" "$(printf '%s\n' "$NEW" | names)")

if [ "$CURRENT" = "$NEW" ]; then ok '.env.example is up to date'; exit 0; fi

if [ "$CHECK" = yes ]; then
  fail '.env.example is stale. Run scripts/secrets/map.sh and commit the result.'
  for name in $ADDED; do note "new: $name"; done
  for name in $REMOVED; do note "removed: $name"; done
  if [ -z "$ADDED$REMOVED" ]; then note 'A header, description or kind changed.'; fi
  exit 1
fi

printf '%s\n' "$NEW" > "$EXAMPLE.tmp"
mv -f "$EXAMPLE.tmp" "$EXAMPLE"
ok ".env.example updated (+$(count "$ADDED") new, −$(count "$REMOVED") removed)"
