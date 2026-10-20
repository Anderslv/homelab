# shellcheck shell=bash disable=SC2034 # OUT/STATUS/SETUP_ENV feed expect_* and setup_run
# Rotation cases: setup.sh --rotate VAR, --rotate age-key and --finish-age-key-rotation.
# Several "machines" are separate throwaway HOMEs inside one case. Uses setup_run,
# fill_vault and fill_kp from cases/fill.sh; see harness.sh for conventions.

ROTATE_VARS='{"TZ":"UTC","DOMAIN":"example.com","ALPHA_DB_PASSWORD":"test-password-1"}'
ROTATE_STACKS='--profile dev networking alpha'

# A vault holding ROTATE_VARS, and a first --skip-missing run that writes the outputs.
rotate_ready() {
  new_case "$1"
  docker_shim rootless
  fill_vault "$ROTATE_VARS"
  # shellcheck disable=SC2086 # ROTATE_STACKS is a list of words
  setup_run 'test-pw\n' "$VAULT" --env-name dev --skip-missing $ROTATE_STACKS
  expect_status 0
}

# MACHINE ANSWERS ARG…: setup.sh with HOME=$CASE/MACHINE ("home" is the first machine).
machine_run() {
  local home="$CASE/$1" answers=$2
  shift 2
  (umask 077 && mkdir -p "$home")
  SETUP_ENV="HOME=$home"
  setup_run "$answers" "$VAULT" --env-name dev "$@"
  SETUP_ENV=''
}

# ENTRY: the keys.txt attachment of homelab/dev/ENTRY.
rotate_key_in_vault() { fill_kp attachment-export --stdout "homelab/dev/$1" keys.txt 2>/dev/null; }
machine_key() { printf '%s/%s/.config/sops/age/keys.txt' "$CASE" "$1"; }

# MACHINE VAR VALUE: decrypts VAR from MACHINE's secrets.yaml with MACHINE's key.
expect_machine_sops() {
  CASE_SECRETS_DIR="$CASE/$1/.config/homelab-secrets" CASE_AGE_KEY_FILE=$(machine_key "$1")
  expect_sops "$2" "$3"
  CASE_SECRETS_DIR='' CASE_AGE_KEY_FILE=''
}

case_rotate_var_cancel() {
  rotate_ready rotate_var_cancel
  cp "$VAULT" "$CASE/vault.before"
  cp "$CASE/$FILL_SECRETS/secrets.yaml" "$CASE/secrets.before"
  # shellcheck disable=SC2086
  setup_run 'test-pw\nc\n' "$VAULT" --env-name dev $ROTATE_STACKS --rotate ALPHA_DB_PASSWORD
  expect_status 0
  expect_out 'Rotating ALPHA_DB_PASSWORD (required · secret)'
  expect_out '[a] automatically  [e] from a .env file  [m] enter now  [c] cancel'
  expect_out '− Rotation cancelled; nothing changed.'
  expect_no_out 'AGE-SECRET-KEY'
  expect_vault_untouched
  expect_true 'secrets.yaml unchanged' cmp -s "$CASE/secrets.before" "$CASE/$FILL_SECRETS/secrets.yaml"
}

case_rotate_var_env() {
  local env
  rotate_ready rotate_var_env
  env="$CASE/rotate.env"
  printf '%s\n' 'ALPHA_DB_PASSWORD=test-password-9' 'DOMAIN=other.example' 'ALPHA_MODE=fast' > "$env"
  # shellcheck disable=SC2086
  setup_run 'test-pw\n' "$VAULT" --env-name dev --env "$env" $ROTATE_STACKS --rotate ALPHA_DB_PASSWORD
  expect_status 0
  expect_out 'ALPHA_DB_PASSWORD (changed)'
  expect_no_out 'test-password-9'
  expect_no_out 'A non-interactive run never changes existing values.'
  expect_vault_json '.ALPHA_DB_PASSWORD' test-password-9
  expect_vault_json '.DOMAIN' example.com
  expect_vault_json 'has("ALPHA_MODE")' false
  expect_sops ALPHA_DB_PASSWORD test-password-9
  # Any other change to secrets.yaml is still refused: DOMAIN changed in KeePassXC behind its back.
  printf '%s\n%s\n' "$VAULT_PASSWORD" '{"TZ":"UTC","DOMAIN":"changed.example","ALPHA_DB_PASSWORD":"test-password-9"}' |
    sandboxed keepassxc-cli edit -q -p "$VAULT" homelab/dev/vars >/dev/null
  printf 'ALPHA_DB_PASSWORD=test-password-8\n' > "$env"
  # shellcheck disable=SC2086
  setup_run 'test-pw\n' "$VAULT" --env-name dev --env "$env" $ROTATE_STACKS --rotate ALPHA_DB_PASSWORD
  expect_status 1
  expect_out 'DOMAIN (changed)'
  expect_out 'A non-interactive run never changes existing values.'
  expect_out 'KeePassXC already holds the new ALPHA_DB_PASSWORD. Run setup.sh again without --auto or --env to review and write secrets.yaml.'
  expect_sops ALPHA_DB_PASSWORD test-password-9
  expect_sops DOMAIN example.com
}

case_rotate_sets_unset_default() {
  local alpha env
  rotate_ready rotate_sets_unset_default
  alpha="$REPO/services/alpha.yml"
  awk '{ print } /MODE: \$\{ALPHA_MODE/ { print "      LOCALE: ${ALPHA_LOCALE:-en-US}" }' "$alpha" > "$alpha.new"
  mv "$alpha.new" "$alpha"
  # An unset default variable, set interactively; the change it asked for needs no second yes.
  # shellcheck disable=SC2086
  setup_run 'test-pw\nm\nde-DE\ny\n' "$VAULT" --env-name dev $ROTATE_STACKS --rotate ALPHA_LOCALE
  expect_status 0
  expect_out 'ALPHA_LOCALE [en-US]'
  expect_out 'ALPHA_LOCALE (added)'
  expect_no_out 'Write secrets.yaml?'
  expect_vault_json '.ALPHA_LOCALE' de-DE
  expect_sops ALPHA_LOCALE de-DE
  # An unset optional variable, from a .env file without asking.
  env="$CASE/rotate.env"
  printf 'ALPHA_MODE=fast\n' > "$env"
  # shellcheck disable=SC2086
  setup_run 'test-pw\n' "$VAULT" --env-name dev --env "$env" $ROTATE_STACKS --rotate ALPHA_MODE
  expect_status 0
  expect_vault_json '.ALPHA_MODE' fast
  expect_sops ALPHA_MODE fast
  # An unset required variable is not rotation: the normal run sets it.
  cp "$VAULT" "$CASE/vault.before"
  setup_run 'test-pw\n' "$VAULT" --env-name dev --auto --profile dev networking alpha beta --rotate DUMBASSETS_PIN
  expect_status 1
  expect_out 'DUMBASSETS_PIN has no value yet; run setup.sh without --rotate to set it.'
  expect_vault_untouched
}

case_rotate_unknown_var() {
  rotate_ready rotate_unknown_var
  cp "$VAULT" "$CASE/vault.before"
  # shellcheck disable=SC2086
  setup_run 'test-pw\n' "$VAULT" --env-name dev $ROTATE_STACKS --rotate ALPHA_DB_PASS
  expect_status 1
  expect_out '✗ Unknown variable ALPHA_DB_PASS. Closest: ALPHA_DB_PASSWORD'
  expect_no_out 'KeePassXC password'
  # shellcheck disable=SC2086
  setup_run 'test-pw\n' "$VAULT" --env-name dev $ROTATE_STACKS --rotate alpha_mode
  expect_out 'Unknown variable alpha_mode. Closest: ALPHA_MODE'
  # shellcheck disable=SC2086
  setup_run 'test-pw\n' "$VAULT" --env-name dev $ROTATE_STACKS --rotate NOTHING_LIKE_IT
  expect_status 1
  expect_out 'Unknown variable NOTHING_LIKE_IT; .env.example lists every variable.'
  # shellcheck disable=SC2086
  setup_run 'test-pw\n' "$VAULT" --env-name dev $ROTATE_STACKS --rotate DUMBASSETS_PIN
  expect_status 1
  expect_out 'DUMBASSETS_PIN belongs to beta, which this run does not set up; add beta to the stacks.'
  # shellcheck disable=SC2086
  setup_run 'test-pw\n' "$VAULT" --env-name dev --skip-missing $ROTATE_STACKS --rotate ALPHA_DB_PASSWORD
  expect_status 1
  expect_out '--rotate needs a new value: use it alone, or with --auto or --env FILE.'
  expect_vault_untouched
}

case_rotate_age_key_three_machines() {
  local old new
  rotate_ready rotate_age_key_three_machines
  # Machine a set up before the rotation (the old key); machine b has an unrelated key.
  # shellcheck disable=SC2086
  machine_run a 'test-pw\n' --skip-missing $ROTATE_STACKS
  expect_status 0
  (umask 077 && mkdir -p "$CASE/b/.config/sops/age")
  sandboxed age-keygen -o "$(machine_key b)" 2>/dev/null
  cp "$(machine_key b)" "$CASE/b-key.before"
  old=$(rotate_key_in_vault age-key)
  expect_true 'machine a holds the old key' [ "$(cat "$(machine_key a)")" = "$old" ]

  # shellcheck disable=SC2086
  machine_run home 'test-pw\n' $ROTATE_STACKS --rotate age-key
  expect_status 0
  expect_out '✓ Kept the old age key in homelab/dev/age-key-previous'
  expect_out 'The age key was rotated; kept the old file at'
  expect_out '✓ Re-encrypted secrets.yaml to the new age key'
  expect_no_out 'Write secrets.yaml?'
  expect_no_out 'AGE-SECRET-KEY'
  new=$(rotate_key_in_vault age-key)
  expect_true 'KeePassXC holds an age key' [ -n "$new" ]
  expect_true 'KeePassXC holds a new age key' [ "$new" != "$old" ]
  expect_true 'age-key-previous holds the old key' [ "$(rotate_key_in_vault age-key-previous)" = "$old" ]
  expect_true 'this machine holds the new key' [ "$(cat "$(machine_key home)")" = "$new" ]
  expect_mode "$(ls "$(machine_key home)".rotated-*)" 600
  expect_machine_sops home ALPHA_DB_PASSWORD test-password-1
  expect_true '.sops.yaml names the new public key' \
    grep -q "$(printf '%s\n' "$new" | sandboxed age-keygen -y /dev/stdin)" "$CASE/$FILL_SECRETS/.sops.yaml"

  # shellcheck disable=SC2086
  machine_run a 'test-pw\n' --skip-missing $ROTATE_STACKS
  expect_status 0
  expect_out 'The age key was rotated; kept the old file at'
  expect_no_out 'AGE-SECRET-KEY'
  expect_true 'machine a now holds the new key' [ "$(cat "$(machine_key a)")" = "$new" ]
  expect_machine_sops a ALPHA_DB_PASSWORD test-password-1

  # shellcheck disable=SC2086
  machine_run b 'test-pw\n' --skip-missing $ROTATE_STACKS
  expect_status 1
  expect_out 'holds a different key than KeePassXC; not touching it.'
  expect_true "machine b's unrelated key is untouched" cmp -s "$CASE/b-key.before" "$(machine_key b)"

  machine_run home 'test-pw\nn\n' --finish-age-key-rotation
  expect_status 0
  expect_out "Move homelab/dev/age-key-previous to KeePassXC's recycle bin? [Y/n]"
  expect_out '− Kept homelab/dev/age-key-previous.'
  expect_true 'age-key-previous is kept' [ "$(rotate_key_in_vault age-key-previous)" = "$old" ]

  machine_run home 'test-pw\ny\n' --finish-age-key-rotation
  expect_status 0
  expect_out '✓ Moved homelab/dev/age-key-previous to the recycle bin'
  expect_out 'Old local key kept at'
  expect_no_out 'AGE-SECRET-KEY'
  expect_true 'age-key-previous is gone' [ -z "$(rotate_key_in_vault age-key-previous)" ]
  expect_true 'age-key still holds the new key' [ "$(rotate_key_in_vault age-key)" = "$new" ]
  machine_run home 'test-pw\n' --finish-age-key-rotation
  expect_out '− No previous age key in KeePassXC; nothing to finish.'
  # A secrets.yaml still encrypted to the old key, after finishing: the kept local key reads it.
  cp "$CASE/$FILL_SECRETS/secrets.prev.yaml" "$CASE/$FILL_SECRETS/secrets.yaml"
  # shellcheck disable=SC2086
  machine_run home 'test-pw\n' --skip-missing $ROTATE_STACKS
  expect_status 0
  expect_out '✓ Re-encrypted secrets.yaml to the new age key'
  expect_machine_sops home ALPHA_DB_PASSWORD test-password-1
}

case_rotate_age_key_refused_while_previous() {
  local new
  rotate_ready rotate_age_key_refused_while_previous
  # shellcheck disable=SC2086
  setup_run 'test-pw\n' "$VAULT" --env-name dev $ROTATE_STACKS --rotate age-key
  expect_status 0
  new=$(rotate_key_in_vault age-key)
  cp "$VAULT" "$CASE/vault.before"
  # shellcheck disable=SC2086
  setup_run 'test-pw\n' "$VAULT" --env-name dev --auto $ROTATE_STACKS --rotate age-key
  expect_status 1
  expect_out 'homelab/dev/age-key-previous still holds the key from an earlier rotation.'
  expect_out 'Finish that one first: run setup.sh on every machine, then setup.sh --finish-age-key-rotation.'
  expect_vault_untouched
  expect_true 'age-key unchanged' [ "$(rotate_key_in_vault age-key)" = "$new" ]
}

# Values changed in KeePassXC behind secrets.yaml's back, then the age key is rotated: the
# refused (and later the declined) change still leaves a file the new key reads; a rerun works.
case_rotate_age_key_refused_then_rerun() {
  rotate_ready rotate_age_key_refused_then_rerun
  printf '%s\n%s\n' "$VAULT_PASSWORD" '{"TZ":"UTC","DOMAIN":"changed.example","ALPHA_DB_PASSWORD":"test-password-1"}' |
    sandboxed keepassxc-cli edit -q -p "$VAULT" homelab/dev/vars >/dev/null
  # shellcheck disable=SC2086
  setup_run 'test-pw\n' "$VAULT" --env-name dev --auto $ROTATE_STACKS --rotate age-key
  expect_status 1
  expect_out '✓ Re-encrypted secrets.yaml to the new age key'
  expect_out 'A non-interactive run never changes existing values.'
  expect_no_out 'AGE-SECRET-KEY'
  expect_sops DOMAIN example.com
  # Declined interactively: still unchanged, still readable, no "does not decrypt".
  # shellcheck disable=SC2086
  setup_run 'test-pw\ns\nn\n' "$VAULT" --env-name dev $ROTATE_STACKS
  expect_status 1
  expect_out 'Write secrets.yaml? [Y/n]'
  expect_out 'Left secrets.yaml unchanged.'
  expect_no_out 'does not decrypt'
  expect_sops DOMAIN example.com
  # shellcheck disable=SC2086
  setup_run 'test-pw\ns\ny\n' "$VAULT" --env-name dev $ROTATE_STACKS
  expect_status 0
  expect_sops DOMAIN changed.example
}

# A keys.txt shared with another project: only the old homelab identity is swapped.
case_rotate_age_key_shared_keys_file() {
  local other old new
  rotate_ready rotate_age_key_shared_keys_file
  old=$(rotate_key_in_vault age-key)
  other=$(sandboxed age-keygen 2>/dev/null)
  (umask 077 && mkdir -p "$CASE/a/.config/sops/age" && printf '%s\n%s\n' "$other" "$old" > "$(machine_key a)")
  # shellcheck disable=SC2086
  machine_run home 'test-pw\n' --skip-missing $ROTATE_STACKS --rotate age-key
  expect_status 0
  new=$(rotate_key_in_vault age-key)
  # shellcheck disable=SC2086
  machine_run a 'test-pw\n' --skip-missing $ROTATE_STACKS
  expect_status 0
  expect_out '✓ Replaced the old age key in'
  expect_no_out 'AGE-SECRET-KEY'
  expect_true 'machine a keeps the other identity' grep -qxF "$(printf '%s\n' "$other" | grep '^AGE-SECRET-KEY-')" "$(machine_key a)"
  expect_true 'machine a holds the new key' grep -qxF "$(printf '%s\n' "$new" | grep '^AGE-SECRET-KEY-')" "$(machine_key a)"
  expect_true 'machine a no longer holds the old key' [ "$(grep -cxF "$(printf '%s\n' "$old" | grep '^AGE-SECRET-KEY-')" "$(machine_key a)")" = 0 ]
  expect_true 'machine a has 2 identities' [ "$(grep -c '^AGE-SECRET-KEY-' "$(machine_key a)")" = 2 ]
  expect_true 'machine a has 2 public key comments' [ "$(grep -c '^# public key:' "$(machine_key a)")" = 2 ]
  expect_mode "$(machine_key a)" 600
  expect_machine_sops a ALPHA_DB_PASSWORD test-password-1
}
