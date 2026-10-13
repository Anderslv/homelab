# shellcheck shell=bash
# Shared helpers for setup_homelab.sh and secrets.sh. Source this file; do not run it.

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# A variable counts as a secret when compose marks it required (${VAR:?...})
# or when its name matches this pattern. Edit the pattern to tune detection.
SECRET_NAME_PATTERN='PASS|SECRET|TOKEN|KEY|PIN'

log_info() { echo -e "\033[0;32m[INFO]\033[0m $*" >&2; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
die() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; exit 1; }

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"
}

# Prints the whole compose project as JSON, with ${VAR} references left as-is.
# Only files included from docker-compose.yml (and not commented out) appear here.
compose_json() {
    require_command docker
    require_command jq
    docker compose -f "$ROOT_DIR/docker-compose.yml" config --no-interpolate --format json
}

# Prints every profile defined in the project, one per line
compose_profiles() {
    compose_json | jq -r '[.services[].profiles // [] | .[]] | unique[]'
}

# Prints the services enabled by a profile ("all" = every service), one per line.
# Services without a profiles list are always enabled, so they match every profile.
compose_services() {
    compose_json | jq -r --arg profile "$1" '
        .services | to_entries[]
        | select($profile == "all" or ((.value.profiles // [$profile]) | index($profile)))
        | .key'
}

# Prints "<service> <VAR> <required|optional>" for each secret the given services use
compose_secrets() {
    compose_json | jq -r --arg pattern "$SECRET_NAME_PATTERN" --args '
        .services | to_entries[]
        | select(.key as $service | $ARGS.positional | index($service))
        | .key as $service
        # Find ${VAR}, ${VAR:-x}, ${VAR:?x} in any string; skip escaped $${VAR}
        | [.value | .. | strings | scan("(?<!\\$)\\$\\{([A-Za-z_][A-Za-z0-9_]*)(:?\\?)?")]
        | group_by(.[0])[]
        | {name: .[0][0], required: any(.[1] != null)}
        | select(.required or (.name | test($pattern)))
        | "\($service) \(.name) \(if .required then "required" else "optional" end)"
    ' "$@"
}

# Asks a yes/no question; returns 0 for yes
ask() {
    local answer
    read -rp "$1 [y/N] " answer
    [[ "$answer" =~ ^[Yy] ]]
}

# Loads lib/backends/<name>.sh. Every backend defines the same interface:
#   BACKEND_DB_LABEL     what the "database" is (empty when the backend has none)
#   BACKEND_DB_DEFAULT   default database, shown when prompting
#   backend_open DB      check tools, unlock DB, return non-zero if unusable
#   backend_has NAME     return 0 if secret NAME exists
#   backend_get NAME     print the value of secret NAME
#   backend_set NAME V   store secret NAME with value V
load_backend() {
    local file="$ROOT_DIR/lib/backends/$1.sh"
    [[ -f "$file" ]] || die "Unknown backend '$1'. Available: $(list_backends | tr '\n' ' ')"
    # shellcheck source=/dev/null
    source "$file"
}

list_backends() {
    local file
    for file in "$ROOT_DIR"/lib/backends/*.sh; do
        basename "$file" .sh
    done
}

# The chosen backend and database are remembered here (gitignored)
CONFIG_FILE="$ROOT_DIR/.secrets.conf"

# Sets SECRETS_BACKEND and SECRETS_DB from the config file, if it exists
load_config() {
    SECRETS_BACKEND=""
    SECRETS_DB=""
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
}

save_config() {
    printf 'SECRETS_BACKEND=%q\nSECRETS_DB=%q\n' "$SECRETS_BACKEND" "$SECRETS_DB" > "$CONFIG_FILE"
}
