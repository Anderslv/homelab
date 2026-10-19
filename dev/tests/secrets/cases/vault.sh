# shellcheck shell=bash disable=SC2016,SC2034 # sandboxed bash -c scripts; OUT/STATUS feed expect_*
# Vault cases: lib/vault.sh unlocks a throwaway KeePassXC vault, picks the environment
# group, stores and verifies the JSON map, the age key and label, and keeps backups.

VAULT_LIBS="$CHECKOUT/scripts/secrets/lib"
REAL_KP=$(command -v keepassxc-cli || true)

# SCRIPT [ENV=VALUE…]: sources the libs and runs SCRIPT with the caller's stdin;
# KEEPASSXC_DATABASE is $VAULT unless an ENV argument sets it. Sets OUT and STATUS.
vault_exec() {
  local script=$1
  shift
  STATUS=0
  OUT=$(sandboxed KEEPASSXC_DATABASE="$VAULT" "$@" "$BASH" -c 'set -euo pipefail
    d=$1; . "$d/ui.sh"; . "$d/config.sh"; . "$d/vault.sh"; . "$d/vault-keys.sh"; secrets_paths
    '"$script" _ "$VAULT_LIBS" 2>&1) || STATUS=$?
  printf '%s\n' "$OUT" > "$CASE/last-output.txt"
}

# ANSWERS SCRIPT [ENV=VALUE…]: vault_exec with ANSWERS (printf %b) on stdin.
# Process substitution, not a pipe, so OUT and STATUS stay in this shell.
vault_run() { local answers=$1; shift; vault_exec "$@" < <(printf '%b' "$answers"); }

# CMD ARG…: runs keepassxc-cli CMD on $VAULT directly (test setup and checks).
kp_test() {
  local cmd=$1
  shift
  printf '%s\n' "$VAULT_PASSWORD" | sandboxed keepassxc-cli "$cmd" -q "$VAULT" "$@"
}

vault_env_groups() { kp_test mkdir homelab >/dev/null; kp_test mkdir "homelab/$1" >/dev/null; }

# Replaces keepassxc-cli with a wrapper that logs each subcommand name to $CASE/kp.log.
kp_logging_shim() {
  shim keepassxc-cli "printf '%s\\n' \"\$1\" >> '$CASE/kp.log'; exec '$REAL_KP' \"\$@\""
}

case_vault_wrong_password_retries() {
  new_case vault_wrong_password_retries
  new_vault
  vault_run 'wrong\nwrong\ntest-pw\n' 'vault_open; echo unlocked' HOMELAB_ASSUME_TTY=1
  expect_status 0
  expect_out 'Wrong password or key file.'
  expect_out 'unlocked'
  vault_run 'wrong\nwrong\nwrong\n' 'vault_open; echo unlocked' HOMELAB_ASSUME_TTY=1
  expect_status 1
  expect_no_out 'unlocked'
  expect_out 'giving up'
}

case_vault_non_tty_one_try() {
  new_case vault_non_tty_one_try
  new_vault
  vault_run 'wrong\ntest-pw\n' 'vault_open; echo unlocked'
  expect_status 1
  expect_no_out 'unlocked'
  vault_run 'test-pw\n' 'vault_open; echo unlocked; sh -c "echo kp=\${KP_PASSWORD:-unset}"' KP_PASSWORD=inherited
  expect_status 0
  expect_out 'unlocked'
  expect_out 'kp=unset'
}

case_vault_create_new() {
  new_case vault_create_new
  vault_run 'y\nnew-pw\nnew-pw\n' 'vault_open; kp ls >/dev/null; echo "db=$VAULT_DB"' \
    KEEPASSXC_DATABASE='~/vaults/new.kdbx'
  expect_status 0
  expect_out "db=$CASE/home/vaults/new.kdbx"
  VAULT="$CASE/home/vaults/new.kdbx" VAULT_PASSWORD=new-pw
  expect_true 'the new vault opens with the typed password' kp_test ls
  vault_run '' 'vault_open' KEEPASSXC_DATABASE="$CASE/other.kdbx" HOMELAB_NONINTERACTIVE=1
  expect_status 1
  expect_missing "$CASE/other.kdbx"
}

case_vault_env_menu_lists_groups() {
  new_case vault_env_menu_lists_groups
  new_vault
  vault_env_groups prod
  kp_test mkdir homelab/dev >/dev/null
  vault_run 'test-pw\n2\n' 'vault_open; vault_choose_env; echo "env=$ENV_NAME group=$VAULT_GROUP"'
  expect_status 0
  expect_out '[1] prod'
  expect_out '[2] dev'
  expect_out '[n] new environment'
  expect_out 'env=dev group=homelab/dev'
  expect_missing "$CASE/home/.local/state/homelab-secrets/backups"
  vault_run 'test-pw\nn\nstaging\n' 'vault_open; vault_choose_env; echo "env=$ENV_NAME"'
  expect_out '[dev]'
  expect_out 'env=staging'
  expect_true 'the new group homelab/staging exists' kp_test ls homelab/staging
  expect_true 'creating a group backed the vault up first' \
    [ -n "$(find "$CASE/home/.local/state/homelab-secrets/backups" -type f -name 'vault.*.kdbx')" ]
  vault_run 'test-pw\nn\n\n' 'SELECTED_PROFILE=prod; vault_open; vault_choose_env; echo "env=$ENV_NAME"'
  expect_out '[prod]'
  expect_out 'env=prod'
  vault_run 'test-pw\n' 'vault_open; vault_choose_env; echo "env=$ENV_NAME"' \
    HOMELAB_SECRETS_ENV=qa HOMELAB_NONINTERACTIVE=1
  expect_status 0
  expect_no_out '[n] new environment'
  expect_true 'HOMELAB_SECRETS_ENV created homelab/qa' kp_test ls homelab/qa
}

case_vault_json_roundtrip_metachars() {
  local json
  new_case vault_json_roundtrip_metachars
  new_vault
  json=$(jq -nc --arg canary "\$(touch \"$SCRATCH/canary\")" \
    '{A_PASS:"pa$$word \"quoted\" #hash", B_MULTI:"line1\nline2", C_SLASH:"back\\slash", D_CANARY:$canary}')
  vault_exec 'vault_open; vault_choose_env dev
    IFS= read -r j; vault_store_vars "$j"
    [ "$(vault_vars_json | jq -S .)" = "$(printf "%s\n" "$j" | jq -S .)" ] && echo same' \
    < <(printf 'test-pw\n%s\n' "$json")
  expect_status 0
  expect_out '✓ 4 values stored and verified'
  expect_out 'same'
  expect_vault_json '.A_PASS' 'pa$$word "quoted" #hash'
  expect_vault_json '.B_MULTI' 'line1
line2'
  expect_vault_json '.C_SLASH' 'back\slash'
  expect_vault_json '.D_CANARY' "\$(touch \"$SCRATCH/canary\")"
  expect_missing "$SCRATCH/canary"
  vault_run 'test-pw\n' 'vault_open; vault_choose_env fresh; vault_vars_json'
  expect_out '{}'
}

case_vault_invalid_json_dies_untouched() {
  new_case vault_invalid_json_dies_untouched
  new_vault
  vault_env_groups dev
  printf '%s\n%s\n' "$VAULT_PASSWORD" 'not json {' |
    sandboxed keepassxc-cli add -q -p "$VAULT" homelab/dev/vars >/dev/null
  cp -p "$VAULT" "$CASE/before.kdbx"
  vault_run 'test-pw\n' 'vault_open; vault_choose_env dev; vault_vars_json; echo after'
  expect_status 1
  expect_out 'KeePassXC entry homelab/dev/vars does not hold valid JSON; fix or delete it in KeePassXC.'
  expect_no_out 'after'
  expect_true 'the vault is byte-identical' cmp -s "$VAULT" "$CASE/before.kdbx"
  kp_test edit -p homelab/dev/vars >/dev/null < <(printf '%s\n%s\n' "$VAULT_PASSWORD" '{} {}')
  vault_run 'test-pw\n' 'vault_open; vault_choose_env dev; vault_vars_json; echo after'
  expect_status 1
  expect_out 'does not hold valid JSON'
}

case_vault_read_error_stops() {
  new_case vault_read_error_stops
  new_vault
  vault_env_groups dev
  shim keepassxc-cli "if [ \"\$1\" = show ]; then echo 'Error while reading the database: simulated' >&2; exit 1; fi
exec '$REAL_KP' \"\$@\""
  vault_run 'test-pw\n' 'vault_open; vault_choose_env dev; vault_vars_json; echo after'
  expect_status 1
  expect_out 'Could not read from KeePassXC (Error while reading the database: simulated). Stopping without changing anything.'
  expect_no_out 'after'
}

case_vault_keeps_other_fields() {
  local name
  new_case vault_keeps_other_fields
  new_vault
  vault_env_groups dev
  vault_run 'test-pw\n' 'vault_open; vault_choose_env dev; vault_store_vars "{\"A\":\"1\"}"'
  expect_status 0
  kp_test edit -u alice homelab/dev/vars >/dev/null
  kp_logging_shim
  vault_run 'test-pw\n' 'vault_open; vault_choose_env dev; vault_store_vars "{\"A\":\"2\",\"B\":\"3\"}"'
  expect_status 0
  expect_out '✓ 2 values stored and verified'
  expect_vault_json '.A' '2'
  name=$(kp_test show -a UserName homelab/dev/vars)
  expect_true 'the UserName set by hand is unchanged' [ "$name" = alice ]
  expect_true 'the second store used edit' grep -qx edit "$CASE/kp.log"
  expect_true 'the second store used neither add nor rm' [ -z "$(grep -xE 'add|rm' "$CASE/kp.log")" ]
}

case_vault_backups_keep_five() {
  local dir i newest
  new_case vault_backups_keep_five
  dir="$CASE/backups"
  new_vault
  vault_env_groups dev
  (umask 077 && mkdir "$dir" "$dir/vault.20190101-000000-1.kdbx")
  for i in 1 2 3 4 5 6; do (umask 077 && printf 'old %s\n' "$i" > "$dir/vault.20200101-00000$i-1.kdbx"); done
  printf 'other\n' > "$dir/other.20200101-000000-1.kdbx"
  chmod 755 "$dir"
  cp -p "$VAULT" "$CASE/before.kdbx"
  vault_run 'test-pw\n' 'vault_open; vault_choose_env dev
    vault_store_vars "{\"A\":\"1\"}"; vault_store_label "label-1"' HOMELAB_SECRETS_BACKUP_DIR="$dir"
  expect_status 0
  expect_true 'five backups of this vault are kept' \
    [ "$(find "$dir" -type f -name 'vault.*-*.kdbx' | wc -l | tr -d ' ')" = 5 ]
  newest=$(find "$dir" -type f -name 'vault.*' ! -name 'vault.2020*')
  expect_true 'exactly one new backup for the run' [ "$(printf '%s\n' "$newest" | grep -c .)" = 1 ]
  expect_true 'the new backup equals the vault before the write' cmp -s "$newest" "$CASE/before.kdbx"
  expect_mode "$newest" 600
  expect_mode "$dir" 700
  expect_missing "$dir/vault.20200101-000001-1.kdbx"
  expect_missing "$dir/vault.20200101-000002-1.kdbx"
  expect_true 'the newest old backup stays' [ -f "$dir/vault.20200101-000006-1.kdbx" ]
  expect_true 'a directory with a backup name is left alone' [ -d "$dir/vault.20190101-000000-1.kdbx" ]
  expect_true "another vault's backup is left alone" [ -f "$dir/other.20200101-000000-1.kdbx" ]
}

# Another vault's backups (vault.old.kdbx -> vault.old.<stamp>.kdbx) sit next to this one's.
case_vault_backups_spare_neighbours() {
  local dir i fresh
  new_case vault_backups_spare_neighbours
  new_vault
  vault_env_groups dev
  dir="$CASE/backups"
  (umask 077 && mkdir "$dir")
  for i in 1 2 3 4 5 6; do (umask 077 && printf 'old %s\n' "$i" > "$dir/vault.old.20200101-00000$i-1.kdbx"); done
  for i in 1 2 3 4 5; do (umask 077 && printf 'mine %s\n' "$i" > "$dir/vault.20200101-00000$i-1.kdbx"); done
  (umask 077 && printf 'odd\n' > "$dir/vault.20200101-000000-1x.kdbx")
  vault_run 'test-pw\n' 'vault_open; vault_choose_env dev; vault_store_vars "{}"' HOMELAB_SECRETS_BACKUP_DIR="$dir"
  expect_status 0
  fresh=$(find "$dir" -type f -name 'vault.2026*.kdbx' -o -type f -name 'vault.2[1-9]*.kdbx' -o -type f -name 'vault.20[3-9]*.kdbx')
  expect_true 'the fresh backup is kept' [ -n "$fresh" ]
  expect_true 'all six vault.old.* backups are kept' \
    [ "$(find "$dir" -type f -name 'vault.old.*' | wc -l | tr -d ' ')" = 6 ]
  expect_true 'a file that only looks like a backup is kept' [ -f "$dir/vault.20200101-000000-1x.kdbx" ]
  expect_missing "$dir/vault.20200101-000001-1.kdbx"
  expect_true 'the four newest own backups are kept' [ -f "$dir/vault.20200101-000002-1.kdbx" ]
}

case_vault_age_attachment_conflict() {
  local check='rc=0; vault_age_key >/dev/null || rc=$?; echo "rc=$rc"'
  new_case vault_age_attachment_conflict
  new_vault
  vault_env_groups dev
  vault_run 'test-pw\n' "vault_open; vault_choose_env dev; $check; rc=0; vault_label || rc=\$?; echo label-rc=\$rc"
  expect_out 'rc=3'
  expect_out 'label-rc=3'
  printf 'not an age key\n' > "$CASE/bad.txt"
  kp_test add homelab/dev/age-key >/dev/null
  kp_test attachment-import homelab/dev/age-key keys.txt "$CASE/bad.txt" >/dev/null
  vault_run 'test-pw\n' "vault_open; vault_choose_env dev; $check"
  expect_out 'rc=4'
  sandboxed age-keygen -o "$CASE/key.txt" >/dev/null 2>&1
  vault_run 'test-pw\n' "vault_open; vault_choose_env dev; vault_store_age_key '$CASE/key.txt'"
  expect_status 1
  vault_run 'test-pw\n' "vault_open; vault_choose_env qa; vault_store_age_key '$CASE/key.txt'
    vault_store_label 'test label'; vault_label; vault_age_key | age-keygen -y /dev/stdin" HOMELAB_NONINTERACTIVE=1
  expect_status 0
  expect_out 'test label'
  expect_out "$(sandboxed age-keygen -y "$CASE/key.txt")"
  vault_run 'test-pw\n' "vault_open; vault_choose_env dev; vault_store_age_key '$CASE/key.txt' force; $check"
  expect_status 0
  expect_out 'rc=0'
}

case_vault_app_running_warning() {
  new_case vault_app_running_warning
  shim pgrep 'echo 4242'
  vault_run '' 'vault_warn_if_app_running; echo continued' HOMELAB_NONINTERACTIVE=1
  expect_status 0
  expect_out '! KeePassXC is running.'
  expect_out 'continued'
  vault_run 'n\n' 'vault_warn_if_app_running; echo continued'
  expect_out 'Continue?'
  expect_no_out 'continued'
  vault_run 'y\n' 'vault_warn_if_app_running; echo continued'
  expect_out 'continued'
  shim pgrep 'exit 1'
  vault_run '' 'vault_warn_if_app_running; echo continued'
  expect_no_out 'KeePassXC is running'
  expect_out 'continued'
}
