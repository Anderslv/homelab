#!/usr/bin/env bash
set -euo pipefail

# Setup script for homelab development environment
# Creates the local TLS certificate and checks env_file references; values are handled by scripts/secrets/setup.sh

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

collect_required_env_refs() {
    local file="$1"
    local in_env_block=0
    local env_indent=0
    local current_path=""
    local current_required=1
    local line trimmed_line indent

    while IFS= read -r line || [[ -n "$line" ]]; do
        trimmed_line=${line#"${line%%[![:space:]]*}"}
        indent=$(( ${#line} - ${#trimmed_line} ))

        if (( in_env_block )) && [[ -n "$trimmed_line" ]] && (( indent <= env_indent )); then
            if [[ -n "$current_path" && $current_required -eq 1 ]]; then
                printf '%s\n' "$current_path"
            fi
            in_env_block=0
            current_path=""
            current_required=1
        fi

        if [[ $trimmed_line =~ ^env_file:[[:space:]]*\[(.*)\][[:space:]]*$ ]]; then
            while IFS= read -r inline_ref; do
                [[ -n "$inline_ref" ]] && printf '%s\n' "$inline_ref"
            done < <(grep -oE '\.?/\.env-[A-Za-z0-9_-]+' <<< "$trimmed_line" || true)
            continue
        fi

        if [[ $trimmed_line =~ ^env_file:[[:space:]]*$ ]]; then
            in_env_block=1
            env_indent=$indent
            current_path=""
            current_required=1
            continue
        fi

        if (( in_env_block )); then
            if [[ $trimmed_line =~ ^-[[:space:]]+path:[[:space:]]*(\.?/\.env-[A-Za-z0-9_-]+)[[:space:]]*$ ]]; then
                if [[ -n "$current_path" && $current_required -eq 1 ]]; then
                    printf '%s\n' "$current_path"
                fi
                current_path="${BASH_REMATCH[1]}"
                current_required=1
                continue
            fi

            if [[ $trimmed_line =~ ^required:[[:space:]]*false[[:space:]]*$ ]]; then
                current_required=0
            fi
        fi
    done < "$file"

    if (( in_env_block )) && [[ -n "$current_path" && $current_required -eq 1 ]]; then
        printf '%s\n' "$current_path"
    fi
}

is_ci() {
    case "${CI-}" in
        1|true|TRUE|True|yes|YES|Yes|on|ON|On) return 0 ;;
        *) return 1 ;;
    esac
}

ensure_local_tls_artifacts() {
    local cert_dir="config/traefik/certs"
    local dyn_file="config/traefik/dyn/local-certs.generated.yml"
    local cert_file="$cert_dir/localhost.me.pem"
    local key_file="$cert_dir/localhost.me-key.pem"

    mkdir -p "$cert_dir" "config/traefik/dyn"

    if [[ ! -s "$cert_file" || ! -s "$key_file" ]]; then
        if command -v mkcert >/dev/null 2>&1; then
            log_info "Generating local TLS certificate with mkcert for localhost.me"
            mkcert -cert-file "$cert_file" -key-file "$key_file" localhost.me "*.localhost.me"
        elif is_ci && command -v openssl >/dev/null 2>&1; then
            log_warn "mkcert is unavailable in CI; generating a temporary self-signed certificate for compose validation"
            openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
                -keyout "$key_file" \
                -out "$cert_file" \
                -subj "/CN=localhost.me" \
                -addext "subjectAltName=DNS:localhost.me,DNS:*.localhost.me"
        else
            log_error "Local HTTPS requires mkcert. Install it, run 'mkcert -install', then rerun setup-dev.sh"
            return 1
        fi
    fi

    chmod 600 "$key_file"

    cat > "$dyn_file" <<EOF
---
tls:
  certificates:
    - certFile: /etc/traefik/certs/localhost.me.pem
      keyFile: /etc/traefik/certs/localhost.me-key.pem
EOF

    log_info "Local Traefik TLS certificate configured: $cert_file"
}

show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Prepare the homelab development environment.

Options:
    --help, -h    Show this help message

This script:
- Creates mkcert-backed local TLS files for https://*.localhost.me
- Verifies required env_file references from included compose files
- Never creates, writes or reads .env; store values with scripts/secrets/setup.sh

Run this script before starting the homelab and pods stacks with docker compose.
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            log_error "Unknown argument: $1"
            show_usage
            exit 1
            ;;
    esac
done

log_info "Setting up the homelab development environment..."
log_info "setup-dev.sh generates local TLS files and checks env_file references; it does not touch .env"

ENV_FILES_DIR="services"

# Verify that all env_file references used by the root compose include set exist.
missing_env_files=()
while IFS= read -r included_file; do
    while IFS= read -r env_ref; do
        env_name=${env_ref#./}
        env_path="$ENV_FILES_DIR/$env_name"
        if [[ ! -f "$env_path" ]]; then
            missing_env_files+=("$env_path")
        fi
    done < <(collect_required_env_refs "$included_file")
done < <(sed -n 's/^  - \(services\/[^ ]*\.yml\).*/\1/p' docker-compose.yml)

if (( ${#missing_env_files[@]} > 0 )); then
    log_warn "Some env_file references from docker-compose.yml are still missing:"
    printf ' - %s\n' "${missing_env_files[@]}"
fi

if ! ensure_local_tls_artifacts; then
    log_error "Failed to set up the local TLS certificate"
    exit 1
fi

log_info "Setup complete!"
log_info ""
log_info "Start the pods stack: docker compose -f docker-compose.pods.yml up -d"
log_info "Stop the main stack: ./secrets.sh compose down"
log_info "Next: store your values with scripts/secrets/setup.sh, then run ./secrets.sh compose --profile dev up --wait"
