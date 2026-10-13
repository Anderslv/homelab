#!/usr/bin/env bash
set -euo pipefail

# Runs a command with the homelab secrets from your secrets backend in its environment.
# Docker Compose prefers shell variables over .env, so ${VAR} in services/*.yml resolve
# from the backend without any secret ever being written to disk.

# shellcheck source=lib/secrets-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/secrets-common.sh"

show_usage() {
    cat <<EOF
Usage: $0 compose ARGS...   Run 'docker compose ARGS...' with secrets loaded
       $0 run CMD [ARGS...] Run any command with secrets loaded

Uses the backend and database saved by ./setup_homelab.sh.

Examples:
    $0 compose --profile dev up --wait
    $0 run ./setup-dev.sh
EOF
}

# Exports every secret the compose project uses. Compose interpolates all included
# services, even those you do not start, so all of them must be present.
load_secrets() {
    load_config
    [[ -n "$SECRETS_BACKEND" ]] || die "No secrets backend configured. Run ./setup_homelab.sh first."
    load_backend "$SECRETS_BACKEND"
    backend_open "$SECRETS_DB" || die "Could not open the $SECRETS_BACKEND store"

    local services name value missing=()
    mapfile -t services < <(compose_services all)
    while read -r name; do
        if backend_has "$name" </dev/null; then
            value=$(backend_get "$name" </dev/null)
            export "$name=$value"
        else
            missing+=("$name")
        fi
    done < <(compose_secrets "${services[@]}" | cut -d' ' -f2 | sort -u)

    if ((${#missing[@]})); then
        log_warn "Not in your $SECRETS_BACKEND store: ${missing[*]} (run ./setup_homelab.sh)"
    fi
}

case "${1:-}" in
    compose)
        shift
        load_secrets
        cd "$ROOT_DIR"
        exec docker compose "$@"
        ;;
    run)
        shift
        (($#)) || die "run needs a command"
        load_secrets
        exec "$@"
        ;;
    -h | --help)
        show_usage
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
