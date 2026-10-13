#!/usr/bin/env bash
set -euo pipefail

# Interactive secrets setup: pick where secrets live (KeePassXC, GNOME/KDE keyring,
# or 1Password) and make sure that store opens.

# shellcheck source=lib/secrets-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/secrets-common.sh"

show_usage() {
    cat <<EOF
Usage: $0 [DATABASE] [--db DATABASE] [--backend NAME]

Options:
    DATABASE, --db DATABASE  KeePassXC .kdbx file or 1Password vault (default: remembered choice)
    --backend NAME           One of: $(list_backends | tr '\n' ' ')
    -h, --help               Show this help

Your choices are saved in .secrets.conf, so later runs and secrets.sh reuse them.
EOF
}

backend_arg=""
db_arg=""

while (($#)); do
    case "$1" in
        --backend) backend_arg="${2:?--backend needs a name}"; shift 2 ;;
        --db) db_arg="${2:?--db needs a value}"; shift 2 ;;
        -h | --help) show_usage; exit 0 ;;
        -*) show_usage; die "Unknown option: $1" ;;
        *) db_arg="$1"; shift ;;
    esac
done

# Step 1: choose the backend (flag, then saved choice, then ask)
choose_backend() {
    load_config
    if [[ -n "$backend_arg" && "$backend_arg" != "$SECRETS_BACKEND" ]]; then
        SECRETS_BACKEND="$backend_arg"
        SECRETS_DB="" # the saved database belongs to the old backend
    fi

    if [[ -z "$SECRETS_BACKEND" ]]; then
        echo "Where should homelab secrets be stored?" >&2
        select SECRETS_BACKEND in $(list_backends); do
            [[ -n "$SECRETS_BACKEND" ]] && break
        done
        [[ -n "$SECRETS_BACKEND" ]] || die "No backend chosen"
    fi

    load_backend "$SECRETS_BACKEND"
}

# Step 2: open the database, asking for another one until it works
open_store() {
    if [[ -z "$BACKEND_DB_LABEL" ]]; then
        backend_open "" || die "Could not open the $SECRETS_BACKEND store"
        SECRETS_DB=""
        return
    fi

    SECRETS_DB="${db_arg:-$SECRETS_DB}"
    until [[ -n "$SECRETS_DB" ]] && backend_open "$SECRETS_DB"; do
        local default="${SECRETS_DB:-$BACKEND_DB_DEFAULT}"
        read -rp "$BACKEND_DB_LABEL [$default]: " SECRETS_DB || die "No $BACKEND_DB_LABEL given"
        SECRETS_DB="${SECRETS_DB:-$default}"
        SECRETS_DB="${SECRETS_DB/#\~/$HOME}"
    done
}

choose_backend
open_store
save_config
log_info "Using $SECRETS_BACKEND${SECRETS_DB:+ ($SECRETS_DB)}"
