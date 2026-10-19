# shellcheck shell=bash
# Paths with their override variables, and the small KEY=VALUE `config` file.
# One place decides where things live, so tests can point every path into a sandbox.

CONFIG_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CONFIG_KEYS='VAULT ENV_NAME OUTPUT'

# Sets every path the scripts use and exports SOPS_AGE_KEY_FILE.
# shellcheck disable=SC2034 # the scripts that source this file use them
secrets_paths() {
  # scripts/secrets/lib -> the checkout root, unless HOMELAB_REPO says otherwise.
  REPO=$(cd "${HOMELAB_REPO:-$CONFIG_LIB_DIR/../../..}" && pwd -P)
  SECRETS_DIR=${HOMELAB_SECRETS_DIR:-$HOME/.config/homelab-secrets}
  AGE_KEY_FILE=${HOMELAB_SECRETS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}
  BACKUP_DIR=${HOMELAB_SECRETS_BACKUP_DIR:-$HOME/.local/state/homelab-secrets/backups}
  CONFIG_FILE="$SECRETS_DIR/config"
  SOPS_FILE="$SECRETS_DIR/secrets.yaml"
  SOPS_CONFIG="$SECRETS_DIR/.sops.yaml"
  LOCAL_COMPOSE="$SECRETS_DIR/compose.yml"
  SOPS_AGE_KEY_FILE=$AGE_KEY_FILE
  export SOPS_AGE_KEY_FILE
}

config_key_known() {
  case " $CONFIG_KEYS " in *" $1 "*) return 0 ;; esac
  fail "Unknown config key: $1"
  return 1
}

# KEY: prints the stored value, or nothing. The file is read as data, never sourced.
config_get() {
  local line=''
  config_key_known "$1" || return 1
  if [ ! -f "$CONFIG_FILE" ]; then return 0; fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$1="*) printf '%s\n' "${line#*=}"; return 0 ;; esac
  done < "$CONFIG_FILE"
}

# KEY VALUE: rewrites the whole file at mode 600, keeping the other keys.
config_set() {
  local key value content='' tmp="$CONFIG_FILE.tmp"
  config_key_known "$1" || return 1
  case "$2" in *'
'*) die 'A config value must be a single line.' ;; esac
  if [ -L "$CONFIG_FILE" ] || [ -L "$tmp" ]; then
    die "$CONFIG_FILE is a symlink; refusing to write through it."
  fi
  for key in $CONFIG_KEYS; do
    if [ "$key" = "$1" ]; then value=$2; else value=$(config_get "$key"); fi
    if [ -n "$value" ]; then content="$content$key=$value
"; fi
  done
  (umask 077 && mkdir -p "$SECRETS_DIR")
  chmod 700 "$SECRETS_DIR"
  (umask 077 && printf '%s' "$content" > "$tmp")
  chmod 600 "$tmp"
  mv -f "$tmp" "$CONFIG_FILE"
}
