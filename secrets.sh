#!/usr/bin/env bash
# Runs a command with the homelab's values in its environment, read from the local output
# scripts/secrets/setup.sh wrote (secrets.yaml, decrypted in memory, or Compose's own .env).
# It never opens KeePassXC, so it works on any machine that has the secrets folder and age key.
set -euo pipefail

# Every variable of this script starts with __ss_, a prefix no exported value may use.
# __ss_names_of: names from `export -p` / `readonly -p` output (no compgen: needs readline).
__ss_names_of() {
  sed -n -e 's/^declare -[A-Za-z-]* \([A-Za-z_][A-Za-z0-9_]*\).*/\1/p' \
    -e 's/^export \([A-Za-z_][A-Za-z0-9_]*\).*/\1/p' | tr '\n' ' '
}
# Names exported by the caller's shell, before this script sets anything: these win.
__ss_shell=" $(export -p | __ss_names_of) "
# Follow a symlinked secrets.sh (no readlink -f on macOS) to find the checkout.
__ss_self=${BASH_SOURCE[0]}
while [ -L "$__ss_self" ]; do
  __ss_link=$(readlink "$__ss_self")
  case "$__ss_link" in /*) __ss_self=$__ss_link ;; *) __ss_self=$(dirname "$__ss_self")/$__ss_link ;; esac
done
__ss_lib=$(cd "$(dirname "$__ss_self")/scripts/secrets/lib" && pwd -P)
# shellcheck source=scripts/secrets/lib/ui.sh
. "$__ss_lib/ui.sh"
# shellcheck source=scripts/secrets/lib/config.sh
. "$__ss_lib/config.sh"

usage() {
  cat <<'USAGE'
Usage: ./secrets.sh compose ARG…   docker compose ARG… with the homelab's values
       ./secrets.sh run CMD [ARG…]  any command with the homelab's values
Values come from what scripts/secrets/setup.sh wrote, for the variables in .env.example;
a variable already set in your shell wins. Without your own -f (or COMPOSE_FILE), compose
uses the local compose.yml (only the stacks you set up).
Example: ./secrets.sh compose --profile dev up --wait
USAGE
}

# ARG…: true unless COMPOSE_FILE or the compose arguments before the subcommand name a file.
__ss_wants_local() {
  local __ss_skip='' __ss_arg
  if [ -n "${COMPOSE_FILE+set}" ]; then return 1; fi
  for __ss_arg in "$@"; do
    if [ -n "$__ss_skip" ]; then __ss_skip=''; continue; fi
    case "$__ss_arg" in
      -f|--file|-f?*|--file=*) return 1 ;;
      -p|--project-name|--profile|--env-file|--project-directory|--ansi|--progress|--parallel) __ss_skip=1 ;;
      -*) ;;
      *) return 0 ;;
    esac
  done
  return 0
}

# NAME: why NAME must not be exported, or nothing. Only .env.example's variables qualify,
# never ones that steer the shell, the loader, Docker, Compose or sops, nor readonly ones.
__ss_refuse() {
  case " $__ss_allowed " in *" $1 "*) ;; *) echo 'not a variable in .env.example'; return ;; esac
  case "$1" in
    PATH|HOME|IFS|ENV|BASHOPTS|SHELLOPTS|PS4|PROMPT_COMMAND|BASH_*|LD_*|DYLD_*|DOCKER_*|COMPOSE_*|SOPS_*|__ss_*)
      echo 'a reserved name' ;;
    *) case " $(readonly -p | __ss_names_of) " in *" $1 "*) echo 'a reserved name' ;; esac ;;
  esac
}

# Decrypts secrets.yaml once and exports each allowed non-empty value the shell has not set.
__ss_export_sops() {
  local __ss_json __ss_name __ss_b64 __ss_value __ss_why __ss_kept='' __ss_tab __ss_file __ss_decode=-d
  __ss_tab=$(printf '\t')
  for __ss_file in "$SOPS_FILE" "$AGE_KEY_FILE"; do
    [ -f "$__ss_file" ] || die "missing $__ss_file; run scripts/secrets/setup.sh first"
  done
  [ -f "$__ss_repo/.env.example" ] || die "missing $__ss_repo/.env.example, which lists the variables to export."
  require_tools sops jq base64
  if [ -f "$__ss_repo/.env" ]; then warn '.env found next to a sops setup; Compose also reads it.'; fi
  __ss_allowed=$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=$/\1/p' "$__ss_repo/.env.example" | tr '\n' ' ')
  # Older macOS base64 only knows -D.
  if ! printf 'eA==' | base64 -d >/dev/null 2>&1; then __ss_decode=-D; fi
  __ss_json=$(sops decrypt --output-type json "$SOPS_FILE") || die "Could not decrypt $SOPS_FILE with $AGE_KEY_FILE."
  printf '%s' "$__ss_json" | jq -e 'type == "object"' >/dev/null 2>&1 || die "$SOPS_FILE does not hold a map of values."
  while IFS=$__ss_tab read -r __ss_name __ss_b64; do
    __ss_why=$(__ss_refuse "$__ss_name")
    if [ -n "$__ss_why" ]; then warn "skipped $__ss_name: $__ss_why"; continue; fi
    case "$__ss_shell" in *" $__ss_name "*) __ss_kept="$__ss_kept $__ss_name"; continue ;; esac
    # The x keeps a trailing newline that $(…) would strip.
    __ss_value=$(printf '%s' "$__ss_b64" | base64 "$__ss_decode"; printf x)
    export "$__ss_name=${__ss_value%x}"
  done < <(printf '%s' "$__ss_json" | jq -r 'to_entries[] | select((.value // "") | tostring != "")
    | "\(.key | gsub("[^A-Za-z0-9_]"; "?"))\t\(.value | tostring | @base64)"' 2>/dev/null)
  unset __ss_json __ss_name __ss_b64 __ss_value __ss_allowed
  if [ -n "$__ss_kept" ]; then note "kept from your environment:$__ss_kept"; fi
}

__ss_command=${1:-}
case "$__ss_command" in
  compose|run) shift ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 1 ;;
esac
if [ "$__ss_command" = run ] && [ "$#" = 0 ]; then die 'run needs a command (try --help)'; fi

secrets_paths
__ss_repo=$REPO __ss_compose=$LOCAL_COMPOSE __ss_output=$(config_get OUTPUT)
case "${__ss_output:-sops}" in
  sops) __ss_export_sops ;;
  env) ;; # Compose reads $REPO/.env itself.
  *) die "Unknown OUTPUT=$__ss_output in $CONFIG_FILE; run scripts/secrets/setup.sh again." ;;
esac
unset SOPS_AGE_KEY_FILE __ss_shell __ss_self __ss_link __ss_lib

if [ "$__ss_command" = run ]; then exec "$@"; fi
cd "$__ss_repo"
if [ -f "$__ss_compose" ] && __ss_wants_local "$@"; then
  exec docker compose -f "$__ss_compose" --project-directory "$__ss_repo" "$@"
fi
exec docker compose "$@"
