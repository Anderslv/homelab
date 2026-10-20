#!/usr/bin/env bash
# Sets up the homelab's variables: maps them, checks which have values, asks for the rest,
# stores them in KeePassXC and writes the local output (sops by default, or .env).
# Read top to bottom it is the eight steps of spec §3; the logic lives in lib/.
set -euo pipefail

# Follow a symlinked script (no readlink -f on macOS) to find lib/.
SELF=${BASH_SOURCE[0]}
while [ -L "$SELF" ]; do
  LINK=$(readlink "$SELF")
  case "$LINK" in /*) SELF=$LINK ;; *) SELF=$(dirname "$SELF")/$LINK ;; esac
done
LIB_DIR=$(cd "$(dirname "$SELF")/lib" && pwd -P)
# shellcheck source-path=SCRIPTDIR source=lib/ui.sh
. "$LIB_DIR/ui.sh"
# shellcheck source-path=SCRIPTDIR source=lib/config.sh
. "$LIB_DIR/config.sh"
# shellcheck source-path=SCRIPTDIR source=lib/map.sh
. "$LIB_DIR/map.sh"
# shellcheck source-path=SCRIPTDIR source=lib/example.sh
. "$LIB_DIR/example.sh"
# shellcheck source-path=SCRIPTDIR source=lib/choose.sh
. "$LIB_DIR/choose.sh"
# shellcheck source-path=SCRIPTDIR source=lib/values.sh
. "$LIB_DIR/values.sh"
# shellcheck source-path=SCRIPTDIR source=lib/vault.sh
. "$LIB_DIR/vault.sh"
# shellcheck source-path=SCRIPTDIR source=lib/vault-keys.sh
. "$LIB_DIR/vault-keys.sh"
# shellcheck source-path=SCRIPTDIR source=lib/docker.sh
. "$LIB_DIR/docker.sh"
# shellcheck source-path=SCRIPTDIR source=lib/output.sh
. "$LIB_DIR/output.sh"
# shellcheck source-path=SCRIPTDIR source=lib/age-key.sh
. "$LIB_DIR/age-key.sh"
# shellcheck source-path=SCRIPTDIR source=lib/output-compose.sh
. "$LIB_DIR/output-compose.sh"
# shellcheck source-path=SCRIPTDIR source=lib/fill.sh
. "$LIB_DIR/fill.sh"
# shellcheck source-path=SCRIPTDIR source=lib/fill-live.sh
. "$LIB_DIR/fill-live.sh"
# shellcheck source-path=SCRIPTDIR source=lib/rotate.sh
. "$LIB_DIR/rotate.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/secrets/setup.sh [DATABASE] [option…]
  DATABASE                   the KeePassXC vault (.kdbx); remembered after the first run
  --profile NAME [STACK…]    set up this profile (or only these stacks) without asking
  --auto                     generate what can be generated, skip the rest
  --env FILE                 import values from a .env file, skip the rest
  --skip-missing             add nothing; write the outputs from what KeePassXC holds
  --env-name NAME            the KeePassXC environment group homelab/NAME
  --output sops|env          an encrypted sops file (default) or a plain .env; remembered
  --rotate VAR               replace one value, or set an unset default or optional one;
                             --rotate age-key moves every machine to a new age key
  --finish-age-key-rotation  remove the previous age key once every machine has the new one
  -h, --help                 show this help
--auto, --env and --skip-missing ask nothing: they need --profile, and stdin
carries only the vault password.
USAGE
}

# Only the flags make a run non-interactive, never an inherited variable.
DATABASE='' PROFILE='' STACKS='' MODE=ask ENV_NAME_ARG='' OUTPUT='' HOMELAB_NONINTERACTIVE=''
ROTATE='' FINISH=''
# FLAG [VALUE…]: dies unless the flag has a value.
need_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (try --help)"; }
set_mode() {
  [ "$MODE" = ask ] || die 'Use only one of --auto, --env and --skip-missing.'
  MODE=$1 HOMELAB_NONINTERACTIVE=1
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --auto) set_mode auto ;;
    --skip-missing) set_mode skip ;;
    --env) need_value "$@"; set_mode env; FILL_ENV_FILE=$2; shift ;;
    --env-name) need_value "$@"; ENV_NAME_ARG=$2; shift ;;
    --output) need_value "$@"; OUTPUT=$2; shift
      case "$OUTPUT" in sops|env) ;; *) die "--output takes sops or env, not $OUTPUT" ;; esac ;;
    --profile) need_value "$@"; PROFILE=$2; shift 2
      while [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; do STACKS="$STACKS $1"; shift; done
      continue ;;
    --rotate) need_value "$@"; ROTATE=$2; shift ;;
    --finish-age-key-rotation) FINISH=1 ;;
    -*) die "Unknown option: $1 (try --help)" ;;
    *) [ -z "$DATABASE" ] || die "Unexpected argument: $1 (try --help)"; DATABASE=$1 ;;
  esac
  shift
done
if [ -n "$ROTATE" ] && [ -n "$FINISH" ]; then die 'Use --rotate or --finish-age-key-rotation, not both.'; fi

# The output step: sops (age key and label from KeePassXC, made on first use) or .env,
# then the local compose.yml.
write_outputs() {
  local want=$1 key label status=0
  if [ "$OUTPUT" = env ]; then write_env_file "$want"
  elif [ "$want" = '{}' ]; then note 'No values yet, so there is no secrets.yaml to write.'
  else
    label=$(vault_label) || status=$?
    if [ "$status" = 3 ]; then
      label=primary
      while fill_interactive; do
        label=$(read_shown 'Label for the age key' primary) || exit 1
        if validate age-key-label "$label"; then break; fi
      done
      vault_store_label "$label"
    elif [ "$status" != 0 ]; then exit 1; fi
    status=0
    key=$(vault_age_key) || status=$?
    if [ "$status" = 4 ]; then die "$VAULT_GROUP/age-key does not hold an age key; fix it in KeePassXC."; fi
    if [ "$status" = 3 ]; then
      if [ ! -f "$AGE_KEY_FILE" ]; then install_age_key "$(age-keygen 2>/dev/null)"; fi
      age-keygen -y "$AGE_KEY_FILE" >/dev/null 2>&1 || die "$AGE_KEY_FILE is not an age key; move it aside and rerun."
      vault_store_age_key "$AGE_KEY_FILE"
      key=$(cat "$AGE_KEY_FILE")
    elif [ "$status" != 0 ]; then exit 1; fi
    rotate_previous_for "$key"
    install_age_key "$key" "$ROTATE_PREVIOUS"
    write_sops_config "$(printf '%s\n' "$key" | age-keygen -y /dev/stdin)" "$label"
    rotate_old_key_for_sops
    write_sops "$want" "$ROTATE_OLD_KEY"
  fi
  write_local_compose "$want"
}

secrets_paths
require_tools keepassxc-cli jq sops age-keygen docker git

# 1 Preflight
warn_if_rootful
# 2 Map and 3 Choose; finishing an age-key rotation needs neither
if [ -z "$FINISH" ]; then
  "$LIB_DIR/../map.sh"
  # shellcheck disable=SC2086 # STACKS is a space-separated list
  choose_stacks ${PROFILE:+"$PROFILE"} $STACKS
  if [ -n "$ROTATE" ]; then rotate_check "$ROTATE" "$MODE"; fi
fi
# 4 Unlock, and remember the vault, environment and output only once it opened
vault_open "$DATABASE" || exit 1
vault_warn_if_app_running || die 'Stopped; nothing changed.'
vault_choose_env "$ENV_NAME_ARG"
OUTPUT=${OUTPUT:-$(config_get OUTPUT)}
OUTPUT=${OUTPUT:-sops}
config_set VAULT "$(cd "$(dirname "$VAULT_DB")" && pwd -P)/$(basename "$VAULT_DB")"
config_set ENV_NAME "$ENV_NAME"
config_set OUTPUT "$OUTPUT"
if [ -n "$FINISH" ]; then finish_age_key_rotation; exit 0; fi
# 5 Check
CURRENT=$(vault_vars_json) || exit 1
check_values "$(fill_rows)" "$CURRENT"
# 6 Fill, or with --rotate change only that one value (or the age key)
case "$ROTATE" in
  '') fill_missing "$MODE" ;;
  age-key) rotate_age_key ;;
  *) rotate_var "$ROTATE" "$MODE" "$CURRENT" ;;
esac
# 7 Store, only when Fill added or changed something
WANT=$(printf '%s\n%s\n' "$CURRENT" "$PENDING_JSON" | jq -cs '.[0] + .[1]')
if ! printf '%s\n%s\n' "$CURRENT" "$WANT" | jq -se '.[0] == .[1]' >/dev/null; then vault_store_vars "$WANT"; fi
# 8 Write
write_outputs "$WANT"

STILL=$(fill_still_missing)
if [ -n "$STILL" ]; then note "Still missing: ${STILL% }. Run setup.sh again to set them."; fi
if [ -n "$SKIPPED_OPTIONAL" ]; then note "Skipped optional: $SKIPPED_OPTIONAL"; fi
if [ -n "$REFUSED" ]; then fail "Resolve these, then rerun: $REFUSED"; exit 1; fi
ok 'Setup finished.'
