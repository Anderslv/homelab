# shellcheck shell=bash disable=SC2034 # BACKEND_* variables are read by the scripts that source this file
# KeePassXC backend: each secret is an entry in the database's root group.
# The entry title is the variable name and its Password field holds the value.

BACKEND_DB_LABEL="KeePassXC database file"
BACKEND_DB_DEFAULT="$HOME/homelab.kdbx"

KP_CLI=$(command -v keepassxc-cli || echo /Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli)
KP_DB=""
KP_PASSWORD=""
KP_XML=""

# Every keepassxc-cli call reads the database password from stdin
kp() {
    local command="$1"
    shift
    printf '%s\n' "$KP_PASSWORD" | "$KP_CLI" "$command" -q "$@"
}

# Each keepassxc-cli call re-derives the key (about 1 second with KeePassXC's default
# settings), so the database is exported once and queried in memory with xmllint
kp_refresh() {
    KP_XML=$(kp export "$KP_DB")
}

kp_query() {
    printf '%s' "$KP_XML" | xmllint --xpath "$1" -
}

# XPath for a root-group entry; skips history versions and the Recycle Bin
kp_entry() {
    echo "/KeePassFile/Root/Group/Entry[String[Key='Title']/Value='$1']"
}

backend_open() {
    KP_DB="$1"
    [[ -x "$KP_CLI" ]] || die "keepassxc-cli not found. Install KeePassXC."
    require_command xmllint

    if [[ ! -f "$KP_DB" ]]; then
        ask "No database at $KP_DB. Create it?" || return 1
        local repeat
        read -rsp "New password for $KP_DB: " KP_PASSWORD && echo >&2
        read -rsp "Repeat password: " repeat && echo >&2
        [[ "$KP_PASSWORD" == "$repeat" ]] || { log_warn "Passwords do not match"; return 1; }
        printf '%s\n%s\n' "$KP_PASSWORD" "$KP_PASSWORD" | "$KP_CLI" db-create -q -p "$KP_DB" >/dev/null 2>&1
        log_info "Created $KP_DB"
    else
        read -rsp "Password for $KP_DB: " KP_PASSWORD && echo >&2
    fi

    kp_refresh || { log_warn "Could not unlock $KP_DB"; return 1; }
}

backend_has() {
    [[ $(kp_query "boolean($(kp_entry "$1"))") == true ]]
}

backend_get() {
    kp_query "string($(kp_entry "$1")/String[Key='Password']/Value)"
}

backend_set() {
    # keepassxc-cli add -p reads the database password, then the entry password
    printf '%s\n%s\n' "$KP_PASSWORD" "$2" | "$KP_CLI" add -q -p "$KP_DB" "$1" >/dev/null
    kp_refresh
}
