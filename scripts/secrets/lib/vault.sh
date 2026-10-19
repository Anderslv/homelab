# shellcheck shell=bash
# KeePassXC access: unlock, environment groups, the vars JSON map, the age key and label.
# Secrets reach keepassxc-cli only on stdin (never argv, never a file); writes are backed up and verified.
# Test hook: HOMELAB_ASSUME_TTY=1 makes vault_open treat stdin as a terminal (3 tries).

# keepassxc-cli 2.7.10 says "Could not find entry with path …" or "… attachment with name …".
VAULT_MISSING_MSG='Could not find '

# PATH: prints PATH with a leading ~ expanded to $HOME.
vault_expand() { case "$1" in \~|\~/*) printf '%s\n' "$HOME${1#\~}" ;; *) printf '%s\n' "$1" ;; esac; }

# CMD ARG…: keepassxc-cli CMD on $VAULT_DB, with the key file when one is set.
kp_raw() {
  local cmd=$1
  shift
  keepassxc-cli "$cmd" -q ${KEEPASSXC_KEYFILE:+-k "$(vault_expand "$KEEPASSXC_KEYFILE")"} "$VAULT_DB" "$@"
}
kp() { printf '%s\n' "$KP_PASSWORD" | kp_raw "$@"; }
# VALUE CMD ARG…: like kp, then VALUE as the second stdin line (the entry password).
kp_put() { local value=$1; shift; printf '%s\n%s\n' "$KP_PASSWORD" "$value" | kp_raw "$@"; }
kp_missing() { case "$1" in *"$VAULT_MISSING_MSG"*) return 0 ;; esac; return 1; }

# CMD ARG…: prints what a read prints; returns 3 when the entry or attachment is
# missing, dies on any other error. Only a failed read is repeated to get its message,
# so a value never mixes with error text.
kp_read() {
  local out err
  if out=$(kp "$@" 2>/dev/null); then printf '%s\n' "$out"; return 0; fi
  err=$(kp "$@" 2>&1 >/dev/null || true)
  if kp_missing "$err"; then return 3; fi
  err=${err:-keepassxc-cli failed once, then gave no error on a second try}
  die "Could not read from KeePassXC ($err). Stopping without changing anything."
}

# ENTRY VALUE: sets the entry's Password with `edit -p` (other fields and history stay),
# or adds the entry when it does not exist yet.
kp_set() {
  local err
  err=$(kp_put "$2" edit -p "$1" 2>&1 >/dev/null) && return 0
  if kp_missing "$err"; then err=$(kp_put "$2" add -p "$1" 2>&1 >/dev/null) && return 0; fi
  die "Could not write $1 to KeePassXC ($err). Stopping."
}

# [DB]: sets VAULT_DB and KP_PASSWORD (never exported); returns 1 when it gives up.
vault_open() {
  local db=${1:-${KEEPASSXC_DATABASE:-}} tries=1 try=1
  unset KP_PASSWORD # an inherited, exported KP_PASSWORD would reach every child process
  if [ -z "$db" ]; then db=$(config_get VAULT); fi
  if [ -z "$db" ]; then
    if [ "${HOMELAB_NONINTERACTIVE:-}" = 1 ]; then fail 'No KeePassXC vault given; set KEEPASSXC_DATABASE.'; return 1; fi
    printf '  Path to your KeePassXC vault (.kdbx): ' >&2
    ui_read db
  fi
  VAULT_DB=$(vault_expand "$db")
  if [ ! -f "$VAULT_DB" ]; then vault_create; return; fi
  if [ -t 0 ] || [ "${HOMELAB_ASSUME_TTY:-}" = 1 ]; then tries=3; fi
  while [ "$try" -le "$tries" ]; do
    KP_PASSWORD=''
    printf '  KeePassXC password for %s: ' "$VAULT_DB" >&2
    IFS= read -rs KP_PASSWORD || [ -n "$KP_PASSWORD" ] || die 'No answer; stopping without changing anything.'
    printf '\n' >&2
    if kp ls >/dev/null 2>&1; then ok "Unlocked $VAULT_DB"; return 0; fi
    fail 'Wrong password or key file.'
    try=$((try + 1))
  done
  unset KP_PASSWORD
  fail "Could not unlock $VAULT_DB; giving up."
  return 1
}

vault_create() {
  local pw
  if ! ask_yn "  No vault at $VAULT_DB. Create a new one?" y; then fail "No KeePassXC vault at $VAULT_DB."; return 1; fi
  pw=$(read_hidden_twice 'Password for the new vault') || return 1
  if [ -z "$pw" ]; then fail 'The vault needs a password.'; return 1; fi
  (umask 077 && mkdir -p "$(dirname "$VAULT_DB")")
  if ! printf '%s\n%s\n' "$pw" "$pw" | keepassxc-cli db-create -q -p \
      ${KEEPASSXC_KEYFILE:+--set-key-file "$(vault_expand "$KEEPASSXC_KEYFILE")"} "$VAULT_DB" >/dev/null 2>&1; then
    fail "Could not create $VAULT_DB."
    return 1
  fi
  KP_PASSWORD=$pw
  ok "Created $VAULT_DB"
}

# [NAME]: sets ENV_NAME and VAULT_GROUP, creating missing groups (after vault_backup,
# from vault-keys.sh, because mkdir rewrites the vault).
# shellcheck disable=SC2034 # ENV_NAME is read by the scripts that source this file
vault_choose_env() {
  local root=${HOMELAB_SECRETS_GROUP:-homelab} name=${1:-${HOMELAB_SECRETS_ENV:-}}
  local listing groups count i keys='' choice default=dev
  if [ -z "$name" ]; then name=$(config_get ENV_NAME); fi
  if ! listing=$(kp ls -f "$root" 2>&1); then
    case "$listing" in *'Cannot find group'*) listing='' ;;
      *) die "Could not read from KeePassXC ($listing). Stopping without changing anything." ;; esac
    vault_backup
    kp mkdir "$root" >/dev/null || die "Could not create the KeePassXC group $root."
  fi
  groups=$(printf '%s\n' "$listing" | sed -n 's|/$||p')
  if [ -z "$name" ]; then
    if [ "${HOMELAB_NONINTERACTIVE:-}" = 1 ]; then die 'No environment chosen; pass --env-name NAME or set HOMELAB_SECRETS_ENV.'; fi
    if [ "${SELECTED_PROFILE:-}" = prod ]; then default=prod; fi
    count=$(printf '%s\n' "$groups" | grep -c . || true)
    printf 'Which environment does this machine use?\n' >&2
    printf '%s\n' "$groups" | awk 'NF { printf "  [%d] %s\n", ++i, $0 } END { print "  [n] new environment" }' >&2
    for i in $(seq 1 "$count"); do keys="$keys$i "; done
    choice=$(menu "${keys}n") || return 1
    if [ "$choice" = n ]; then name=$(read_shown 'Name of the new environment' "$default") || return 1
    else name=$(printf '%s\n' "$groups" | grep . | sed -n "${choice}p"); fi
  fi
  case "$name" in ''|.*|*[!A-Za-z0-9_.-]*) die "Environment names use letters, digits, '.', '_' and '-': $name" ;; esac
  if ! printf '%s\n' "$groups" | grep -qxF -- "$name"; then
    vault_backup
    kp mkdir "$root/$name" >/dev/null || die "Could not create the KeePassXC group $root/$name."
    note "Created the KeePassXC group $root/$name"
  fi
  ENV_NAME=$name
  VAULT_GROUP="$root/$name"
}

# Prints the compact JSON map from $VAULT_GROUP/vars, or {} when the entry is missing.
vault_vars_json() {
  local json status=0
  json=$(kp_read show -s -a Password "$VAULT_GROUP/vars") || status=$?
  if [ "$status" = 3 ]; then printf '{}\n'; return 0; fi
  if [ "$status" != 0 ]; then exit 1; fi
  # Exactly one JSON value, and an object (so `{} {}` and an empty field are refused).
  printf '%s\n' "$json" | jq -se 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 ||
    die "KeePassXC entry $VAULT_GROUP/vars does not hold valid JSON; fix or delete it in KeePassXC."
  printf '%s\n' "$json" | jq -c .
}

# JSON: stores the whole map in one write, reads it back and compares.
vault_store_vars() {
  local json back
  json=$(printf '%s\n' "$1" | jq -c 'if type=="object" then . else error end' 2>/dev/null) ||
    die 'Refusing to store values that are not a JSON object.'
  vault_backup
  kp_set "$VAULT_GROUP/vars" "$json"
  back=$(vault_vars_json) || exit 1
  if [ "$(printf '%s\n' "$back" | jq -S .)" != "$(printf '%s\n' "$json" | jq -S .)" ]; then
    die "KeePassXC returned different values from $VAULT_GROUP/vars after the write; check the entry's history in KeePassXC."
  fi
  ok "$(printf '%s\n' "$json" | jq length) values stored and verified"
}
