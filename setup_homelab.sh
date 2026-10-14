#!/usr/bin/env bash
set -euo pipefail

# Interactive secrets setup: pick where secrets live (KeePassXC, GNOME/KDE keyring,
# or 1Password), then ask for every secret the enabled compose services still miss.
# The secrets come from secrets.inventory, which this script refreshes first.

# shellcheck source=lib/secrets-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/secrets-common.sh"

show_usage() {
    cat <<EOF
Usage: $0 [DATABASE] [--db DATABASE] [--backend NAME] [--profile PROFILE [SERVICE...]]

Options:
    DATABASE, --db DATABASE  KeePassXC .kdbx file or 1Password vault (default: remembered choice)
    --backend NAME           One of: $(list_backends | tr '\n' ' ')
    --profile PROFILE        Only check services in this compose profile ("all" = every
                             service, the default), optionally only the SERVICEs listed
    -h, --help               Show this help

Your choices are saved in .secrets.conf, so later runs and secrets.sh reuse them.

Examples:
    $0 ~/homelab.kdbx
    $0 --profile infra
    $0 --profile apps immich-server paperless-web
EOF
}

backend_arg=""
db_arg=""
profile="all"
services=()

while (($#)); do
    case "$1" in
        --backend) backend_arg="${2:?--backend needs a name}"; shift 2 ;;
        --db) db_arg="${2:?--db needs a value}"; shift 2 ;;
        --profile)
            profile="${2:?--profile needs a name}"
            shift 2
            # Every following word up to the next --flag is a service name
            while (($#)) && [[ "$1" != -* ]]; do
                services+=("$1")
                shift
            done
            ;;
        -h | --help) show_usage; exit 0 ;;
        -*) show_usage; die "Unknown option: $1" ;;
        *) db_arg="$1"; shift ;;
    esac
done

# Step 1: resolve --profile and the optional service list against the compose project
select_services() {
    if [[ "$profile" != all ]] && ! compose_profiles | grep -qx "$profile"; then
        die "Unknown profile '$profile'. Available: all $(compose_profiles | tr '\n' ' ')"
    fi

    local available service
    mapfile -t available < <(compose_services "$profile")
    if ((${#services[@]} == 0)); then
        services=("${available[@]}")
        return
    fi

    for service in "${services[@]}"; do
        printf '%s\n' "${available[@]}" | grep -qx "$service" ||
            die "Service '$service' is not in profile '$profile'. Available: ${available[*]}"
    done
}

# Step 2: choose the backend (flag, then saved choice, then ask)
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

# Step 3: open the database, asking for another one until it works
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

# Asks for one secret. Enter generates a random value for required secrets
# and stores an empty value for optional ones, so you are not asked again.
prompt_secret() {
    local name="$1" kind="$2" value hint="Enter = leave empty"
    [[ "$kind" == required ]] && hint="Enter = generate a random value"

    read -rsp "  $name ($kind, $hint): " value || die "No value given for $name"
    echo >&2
    if [[ -z "$value" && "$kind" == required ]]; then
        value=$(head -c 32 /dev/urandom | base64)
    fi
    backend_set "$name" "$value"
}

# Step 4: for each service with missing secrets, offer to add them
check_services() {
    local secrets service svc name kind missing entry
    secrets=$(inventory_secrets "${services[@]}")
    [[ -n "$secrets" ]] || { log_info "The selected services use no secrets"; return; }

    for service in $(cut -d' ' -f1 <<< "$secrets" | uniq); do
        missing=()
        while read -r svc name kind; do
            # </dev/null keeps backends from reading this loop's input
            if [[ "$svc" == "$service" ]] && ! backend_has "$name" </dev/null; then
                missing+=("$name $kind")
            fi
        done <<< "$secrets"

        if ((${#missing[@]} == 0)); then
            log_info "$service: all secrets set"
            continue
        fi

        log_warn "$service is missing: ${missing[*]%% *}"
        ask "Add secrets for $service now?" || continue
        for entry in "${missing[@]}"; do
            # shellcheck disable=SC2086 # split "NAME kind" into two arguments
            prompt_secret $entry
        done
    done
}

"$ROOT_DIR/update_secrets_inventory.sh" # pick up secrets from newly added services
select_services # before any password prompt, so a typo fails fast
choose_backend
open_store
save_config
log_info "Using $SECRETS_BACKEND${SECRETS_DB:+ ($SECRETS_DB)}"
check_services
log_info "Done. Rerun $0 at any time to add secrets you skipped."
