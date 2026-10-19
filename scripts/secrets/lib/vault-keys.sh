# shellcheck shell=bash
# The age key and its label in KeePassXC, the vault backup and the running-app warning.
# Split from vault.sh to keep both short. Source vault.sh first: these use kp, kp_read, kp_set.
# vault_backup copies the vault before a run's first write (spec §2); vault.sh calls it too.

VAULT_BACKED_UP=''

# Prints the age key; returns 3 when it is missing, 4 when the attachment is not an age key.
vault_age_key() {
  local key status=0
  key=$(kp_read attachment-export --stdout "$VAULT_GROUP/age-key" keys.txt) || status=$?
  if [ "$status" = 3 ]; then return 3; elif [ "$status" != 0 ]; then exit 1; fi
  printf '%s\n' "$key" | age-keygen -y /dev/stdin >/dev/null 2>&1 || return 4
  printf '%s\n' "$key"
}

# FILE [force]: attaches FILE as keys.txt; `force` (rotation only) replaces an existing one.
vault_store_age_key() {
  local entry="$VAULT_GROUP/age-key" err
  vault_backup
  err=$(kp attachment-import ${2:+-f} "$entry" keys.txt "$1" 2>&1 >/dev/null) && return 0
  if kp_missing "$err" && kp add "$entry" >/dev/null; then
    err=$(kp attachment-import "$entry" keys.txt "$1" 2>&1 >/dev/null) && return 0
  fi
  die "Could not store the age key in KeePassXC ($err). Stopping."
}

# Prints the age key label; returns 3 when it is missing.
vault_label() { kp_read show -s -a Password "$VAULT_GROUP/age-key-label"; }
vault_store_label() { vault_backup; kp_set "$VAULT_GROUP/age-key-label" "$1"; }

# FILE: true for a regular file named <base>.YYYYmmdd-HHMMSS-PID.kdbx by vault_backup.
# The glob below already fixes the date and time digits; this checks the PID part.
vault_backup_ours() {
  local pid=${1##*-}
  pid=${pid%.kdbx}
  [ -f "$1" ] && [ ! -L "$1" ] && case "$pid" in ''|*[!0-9]*) false ;; esac
}

# Copies the vault to $BACKUP_DIR before the run's first write; keeps the newest 5.
vault_backup() {
  local base fresh file total=0
  if [ -n "$VAULT_BACKED_UP" ]; then return 0; fi
  base=$(basename "$VAULT_DB" .kdbx)
  fresh="$BACKUP_DIR/$base.$(date +%Y%m%d-%H%M%S)-$$.kdbx"
  if ! { (umask 077 && mkdir -p "$BACKUP_DIR") && chmod 700 "$BACKUP_DIR" &&
      (umask 077 && cp -p "$VAULT_DB" "$fresh") && chmod 600 "$fresh" && cmp -s "$VAULT_DB" "$fresh"; }; then
    die "Could not back up $VAULT_DB to $BACKUP_DIR. Stopping without changing anything."
  fi
  VAULT_BACKED_UP=1
  note "Vault backed up to $fresh"
  # Only this vault's backups: `vault.old.*` (from vault.old.kdbx) does not match.
  set -- "$BACKUP_DIR/$base".[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9]*.kdbx
  for file in "$@"; do
    if vault_backup_ours "$file"; then total=$((total + 1)); fi
  done
  for file in "$@"; do
    if [ "$total" -le 5 ]; then break; fi
    if [ "$file" != "$fresh" ] && vault_backup_ours "$file"; then rm -f -- "$file"; total=$((total - 1)); fi
  done
}

# Warns when the KeePassXC app runs (saving there could overwrite these writes).
vault_warn_if_app_running() {
  pgrep -xi keepassxc >/dev/null 2>&1 || return 0
  warn 'KeePassXC is running. If this vault is open there, saving it in the app can overwrite what this script writes.'
  if [ "${HOMELAB_NONINTERACTIVE:-}" = 1 ]; then return 0; fi
  ask_yn '  Continue?' y
}
