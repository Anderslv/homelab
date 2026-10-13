# shellcheck shell=bash disable=SC2034 # BACKEND_* variables are read by the scripts that source this file
# 1Password backend: each secret is a Password item in a vault, read as op://<vault>/<NAME>/password.

BACKEND_DB_LABEL="1Password vault"
BACKEND_DB_DEFAULT="homelab"

OP_VAULT=""

backend_open() {
    OP_VAULT="$1"
    require_command op
    # With the desktop app integration, op unlocks itself; otherwise sign in for this shell
    op whoami >/dev/null 2>&1 || eval "$(op signin)" || return 1

    if ! op vault get "$OP_VAULT" >/dev/null 2>&1; then
        ask "No 1Password vault named '$OP_VAULT'. Create it?" || return 1
        op vault create "$OP_VAULT" >/dev/null
    fi
}

backend_has() {
    op item get "$1" --vault "$OP_VAULT" >/dev/null 2>&1
}

backend_get() {
    op read "op://$OP_VAULT/$1/password"
}

backend_set() {
    # The template comes from a file descriptor, so the value never shows up in `ps`
    op item create --vault "$OP_VAULT" --template <(
        NAME="$1" VALUE="$2" jq -n '{
            title: env.NAME,
            category: "PASSWORD",
            fields: [{id: "password", type: "CONCEALED", purpose: "PASSWORD", label: "password", value: env.VALUE}]
        }'
    ) >/dev/null
}
