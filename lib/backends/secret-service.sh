# shellcheck shell=bash disable=SC2034 # BACKEND_* variables are read by the scripts that source this file
# Secret Service backend: GNOME Keyring or KDE Wallet (KWallet 5.97+) through secret-tool.
# Each secret is stored in your default keyring with the attributes service=homelab key=<NAME>.

BACKEND_DB_LABEL="" # no database to choose: the desktop's default keyring is used
BACKEND_DB_DEFAULT=""

backend_open() {
    require_command secret-tool
    # A lookup of a missing key prints nothing; any output means D-Bus or the keyring failed
    local error
    error=$(secret-tool lookup service homelab key __probe__ 2>&1)
    [[ -z "$error" ]] || { log_warn "Secret Service unavailable: $error"; return 1; }
}

backend_has() {
    secret-tool lookup service homelab key "$1" >/dev/null 2>&1
}

backend_get() {
    secret-tool lookup service homelab key "$1"
}

backend_set() {
    printf '%s' "$2" | secret-tool store --label="homelab $1" service homelab key "$1"
}
