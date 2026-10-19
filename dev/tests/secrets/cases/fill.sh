# shellcheck shell=bash disable=SC2016,SC2034 # sandboxed bash -c scripts; OUT/STATUS feed expect_*
# Fill cases: setup.sh checks, fills, stores and writes end to end, and
# live_data_reason (lib/docker.sh) on its own. See harness.sh for conventions.

FILL_SECRETS="home/.config/homelab-secrets"
FILL_KEY="home/.config/sops/age/keys.txt"
FILL_ALL='{"TZ":"Europe/Berlin","DOMAIN":"example.com","ALPHA_DB_PASSWORD":"test-password-1","DUMBASSETS_PIN":"123456","SPEEDTEST_APP_KEY":"test-app-key","OPENVPN_USER":"test-user","OPENVPN_PASSWORD":"test-password-2","RUSTFS_ACCESS_KEY":"test-access","RUSTFS_SECRET_KEY":"test-secret-key"}'
SETUP_ENV=''

# ANSWERS ARG…: like run_setup, plus the VAR=VALUE words in SETUP_ENV.
setup_run() {
  local answers=$1
  shift
  STATUS=0
  # shellcheck disable=SC2086 # SETUP_ENV is a list of VAR=VALUE words
  OUT=$(cd "$REPO" && printf '%b' "$answers" |
    sandboxed $SETUP_ENV "$BASH" "$CHECKOUT/scripts/secrets/setup.sh" "$@" 2>&1) || STATUS=$?
  OUT=$(printf '%s\n' "$OUT" | strip_colour)
  printf '%s\n' "$OUT" > "$CASE/last-output.txt"
}

# CMD ARG…: keepassxc-cli CMD on $VAULT with the test password.
fill_kp() {
  local cmd=$1
  shift
  printf '%s\n' "$VAULT_PASSWORD" | sandboxed keepassxc-cli "$cmd" -q "$VAULT" "$@"
}

# [JSON]: a new vault with the homelab/dev group, holding JSON as its vars when given.
fill_vault() {
  new_vault
  fill_kp mkdir homelab >/dev/null
  fill_kp mkdir homelab/dev >/dev/null
  if [ -n "${1:-}" ]; then
    printf '%s\n%s\n' "$VAULT_PASSWORD" "$1" | sandboxed keepassxc-cli add -q -p "$VAULT" homelab/dev/vars >/dev/null
  fi
}

fill_backups() { find "$CASE/home/.local/state/homelab-secrets/backups" -name '*.kdbx' 2>/dev/null | wc -l | tr -d ' '; }
expect_vault_untouched() { expect_true 'vault is byte-identical' cmp -s "$CASE/vault.before" "$VAULT"; }

case_fill_auto_manual_skip() {
  new_case fill_auto_manual_skip
  docker_shim rootless
  new_vault
  # TZ and DOMAIN skipped; OPENVPN_PASSWORD mismatched once, then entered; OPENVPN_USER typed.
  SETUP_ENV=HOMELAB_ASSUME_TTY=1
  setup_run 'wrong\ntest-pw\na\ns\ns\nm\npw-one\npw-two\nm\ntest-password-2\ntest-password-2\nm\ntest-user\ny\n\n' \
    "$VAULT" --env-name dev --profile dev
  SETUP_ENV=''
  expect_status 0
  expect_out 'Wrong password or key file.'
  expect_out '13 variables missing. How do you want to set them?'
  expect_out '✗ ALPHA_MODE missing (optional)'
  expect_out 'Skipped optional: ACME_EMAIL CF_DNS_API_TOKEN ALPHA_API_TOKEN ALPHA_MODE'
  expect_no_out 'ALPHA_MODE (optional · setting)'
  expect_out '[a] automatically where possible, asking for the rest'
  expect_out 'The two entries differ.'
  expect_out '✗ OPENVPN_USER missing'
  expect_no_out 'test-password-2'
  expect_no_out 'pw-one'
  expect_vault_json '.OPENVPN_PASSWORD' test-password-2
  expect_vault_json '.OPENVPN_USER' test-user
  expect_vault_json '.ALPHA_DB_PASSWORD | test("^[0-9a-f]{64}$")' true
  expect_vault_json '.DUMBASSETS_PIN | test("^[0-9]{6}$")' true
  expect_vault_json 'has("TZ")' false
  expect_sops OPENVPN_USER test-user
  expect_sops OPENVPN_PASSWORD test-password-2
  expect_mode "$CASE/$FILL_KEY" 600
}

case_fill_env_import_confirm_and_canary() {
  local env
  new_case fill_env_import_confirm_and_canary
  env="$CASE/import.env"
  docker_shim rootless
  fill_vault
  printf '%s\n' "OPENVPN_USER='\$(touch $CASE/canary)'" "OPENVPN_PASSWORD=\"\$(touch $CASE/canary)\"" \
    'ALPHA_DB_PASSWORD=test-password-1' 'TZ=Europe/Berlin # inline comment' > "$env"
  cp "$VAULT" "$CASE/vault.before"
  setup_run "test-pw\ne\n$env\nn\nS\n" "$VAULT" --env-name dev --profile dev networking alpha gamma
  expect_status 0
  expect_out 'Store these 4 values? [y/N]'
  expect_out 'Nothing imported.'
  expect_vault_untouched
  setup_run "test-pw\ne\n$env\ny\nS\n\ny\n" "$VAULT" --env-name dev --profile dev networking alpha gamma
  expect_status 0
  expect_out 'TZ=Europe/Berlin'
  expect_out "OPENVPN_USER=\$(touch $CASE/canary)"
  expect_out 'OPENVPN_PASSWORD=••••'
  expect_out 'ALPHA_DB_PASSWORD=••••'
  expect_no_out 'test-password-1'
  expect_missing "$CASE/canary"
  expect_vault_json '.OPENVPN_PASSWORD' "\$(touch $CASE/canary)"
  expect_vault_json '.TZ' Europe/Berlin
  expect_vault_json '.ALPHA_DB_PASSWORD' test-password-1
  expect_sops OPENVPN_USER "\$(touch $CASE/canary)"
}

case_fill_env_placeholders_ignored() {
  new_case fill_env_placeholders_ignored
  docker_shim rootless
  fill_vault
  printf '%s\n' OPENVPN_USER=local-openvpn-user OPENVPN_PASSWORD=local-openvpn-password DUMBASSETS_PIN=1234 \
    RUSTFS_ACCESS_KEY=rustadmin RUSTFS_SECRET_KEY=ci-secret ALPHA_DB_PASSWORD=CHANGEME-later \
    SPEEDTEST_APP_KEY=test-app-key > "$CASE/import.env"
  setup_run 'test-pw\n' "$VAULT" --env-name dev --env "$CASE/import.env" --profile dev
  expect_status 0
  expect_out 'DUMBASSETS_PIN: ignoring a placeholder value'
  expect_out 'ALPHA_DB_PASSWORD: ignoring a placeholder value'
  expect_no_out 'Store these'
  expect_vault_json 'keys | join(" ")' SPEEDTEST_APP_KEY
}

case_fill_skip_one_then_all() {
  new_case fill_skip_one_then_all
  docker_shim rootless
  fill_vault
  cp "$VAULT" "$CASE/vault.before"
  setup_run 'test-pw\ng\ns\nS\n' "$VAULT" --env-name dev --profile dev
  expect_status 0
  expect_out '− TZ skipped'
  expect_out 'Skipped the rest.'
  expect_no_out 'OPENVPN_USER (required'
  expect_vault_untouched
  expect_out 'No values yet'
  expect_missing "$CASE/$FILL_SECRETS/secrets.yaml"
}

case_fill_first_setup_tz_asked() {
  new_case fill_first_setup_tz_asked
  docker_shim rootless
  fill_vault
  setup_run 'test-pw\ng\nm\n2\nm\nexample.com\ny\nS\n\n' "$VAULT" --env-name dev --profile dev networking
  expect_status 0
  expect_out '✗ TZ missing'
  expect_out '✗ DOMAIN missing'
  expect_out '[1] Europe/Berlin'
  expect_out '[4] Asia/Taipei'
  expect_out '✗ ACME_EMAIL missing (optional)'
  expect_out 'ACME_EMAIL (optional · setting)'
  expect_out 'DOMAIN [localhost.me]'
  expect_vault_json '.TZ' America/Vancouver
  expect_vault_json '.DOMAIN' example.com
}

# NAME: a case whose gamma stack also uses GLUETUN_HEALTHCHECK_DISABLED (default false).
gluetun_case() {
  local gamma
  new_case "$1"
  gamma="$REPO/services/gamma.yml"
  awk '{ print } /RUSTFS_SECRET_KEY:/ { print "      HEALTHCHECK_OFF: ${GLUETUN_HEALTHCHECK_DISABLED:-false}" }' "$gamma" > "$gamma.new"
  mv "$gamma.new" "$gamma"
  docker_shim rootless
  fill_vault
}

# Ruling 12: for dev, GLUETUN_HEALTHCHECK_DISABLED is asked with `true` suggested.
case_fill_gluetun_dev_default_true() {
  gluetun_case fill_gluetun_dev_default_true
  setup_run 'test-pw\ng\ns\ns\ns\ns\nm\n\ny\nS\n\n' "$VAULT" --env-name dev --profile dev networking gamma
  expect_status 0
  expect_out '✗ GLUETUN_HEALTHCHECK_DISABLED missing'
  expect_out 'GLUETUN_HEALTHCHECK_DISABLED [true]'
  expect_vault_json '.GLUETUN_HEALTHCHECK_DISABLED' true
  gluetun_case fill_gluetun_dev_auto_true
  setup_run 'test-pw\n' "$VAULT" --env-name dev --auto --profile dev networking gamma
  expect_out '✓ GLUETUN_HEALTHCHECK_DISABLED set automatically'
  expect_vault_json '.GLUETUN_HEALTHCHECK_DISABLED' true
}

case_fill_default_vars_untouched() {
  local alpha
  new_case fill_default_vars_untouched
  alpha="$REPO/services/alpha.yml"
  awk '{ print } /MODE: \$\{ALPHA_MODE/ { print "      LOCALE: ${ALPHA_LOCALE:-en-US}" }' "$alpha" > "$alpha.new"
  mv "$alpha.new" "$alpha"
  docker_shim rootless
  fill_vault '{"TZ":"UTC","DOMAIN":"example.com","ALPHA_DB_PASSWORD":"test-password-1"}'
  setup_run 'test-pw\n' "$VAULT" --env-name dev --skip-missing --profile dev networking alpha
  expect_status 0
  expect_out '− ALPHA_LOCALE uses default en-US'
  expect_out '✓ TZ in KeePassXC'
  expect_no_out 'ALPHA_LOCALE missing'
  expect_vault_json 'has("ALPHA_LOCALE")' false
  # The prod profile makes ACME_EMAIL and CF_DNS_API_TOKEN first-setup variables.
  setup_run 'test-pw\n' "$VAULT" --env-name dev --skip-missing --profile prod networking alpha
  expect_out '✗ ACME_EMAIL missing'
  expect_out '✗ CF_DNS_API_TOKEN missing'
  expect_out '− ALPHA_LOCALE uses default en-US'
}

case_fill_linked_sops_offered() {
  local pub
  new_case fill_linked_sops_offered
  docker_shim rootless
  fill_vault
  (umask 077 && mkdir -p "$CASE/home/.config/sops/age" "$CASE/$FILL_SECRETS")
  sandboxed age-keygen -o "$CASE/$FILL_KEY" 2>/dev/null
  pub=$(sandboxed age-keygen -y "$CASE/$FILL_KEY")
  printf '%s' '{"TZ":"UTC","DOMAIN":"example.com","ALPHA_DB_PASSWORD":"test-password-1"}' |
    sandboxed sops encrypt --age "$pub" --input-type json --output-type yaml /dev/stdin > "$CASE/$FILL_SECRETS/secrets.yaml"
  setup_run 'test-pw\ny\ny\n\ns\n\n' "$VAULT" --env-name dev --profile dev networking alpha
  expect_status 0
  expect_out '− TZ found in secrets.yaml'
  expect_out '− ALPHA_DB_PASSWORD found in secrets.yaml'
  expect_out 'Store it in KeePassXC? [Y/n]'
  expect_no_out 'test-password-1'
  expect_vault_json '.ALPHA_DB_PASSWORD' test-password-1
  expect_vault_json '.DOMAIN' example.com
  expect_out 'secrets.yaml is up to date'
  expect_true 'the local age key went into KeePassXC' \
    [ "$(fill_kp attachment-export --stdout homelab/dev/age-key keys.txt)" = "$(cat "$CASE/$FILL_KEY")" ]
}

# MODE: the linked-sops setup of fill_linked_sops_offered, then a non-interactive MODE run.
linked_noninteractive() {
  local pub
  new_case "fill_linked_sops_noninteractive_$1"
  docker_shim rootless
  fill_vault
  (umask 077 && mkdir -p "$CASE/home/.config/sops/age" "$CASE/$FILL_SECRETS")
  sandboxed age-keygen -o "$CASE/$FILL_KEY" 2>/dev/null
  pub=$(sandboxed age-keygen -y "$CASE/$FILL_KEY")
  printf '%s' '{"ALPHA_DB_PASSWORD":"test-password-1"}' |
    sandboxed sops encrypt --age "$pub" --input-type json --output-type yaml /dev/stdin > "$CASE/$FILL_SECRETS/secrets.yaml"
  setup_run 'test-pw\n' "$VAULT" --env-name dev "--$1" --profile dev networking alpha
  expect_status 0
  expect_out '− ALPHA_DB_PASSWORD found in secrets.yaml'
  expect_no_out 'Store it in KeePassXC?'
  expect_no_out 'ALPHA_DB_PASSWORD set automatically'
  expect_vault_json '.ALPHA_DB_PASSWORD' test-password-1
  expect_out 'secrets.yaml is up to date'
}

# Ruling 25: a non-interactive flag takes a linked value instead of generating one.
case_fill_linked_sops_noninteractive_imported() {
  linked_noninteractive auto
  linked_noninteractive skip-missing
}

# Ruling 22: guided mode asks optional variables too.
case_fill_optional_guided_asked() {
  new_case fill_optional_guided_asked
  docker_shim rootless
  fill_vault '{"TZ":"UTC","DOMAIN":"example.com","ALPHA_DB_PASSWORD":"test-password-1"}'
  setup_run 'test-pw\ng\ns\ns\nm\ntest-token\ntest-token\nm\nfast\ny\n\n' "$VAULT" --env-name dev --profile dev networking alpha
  expect_status 0
  expect_out '4 variables missing.'
  expect_out '✗ CF_DNS_API_TOKEN missing (optional)'
  expect_out 'ALPHA_MODE (optional · setting)'
  expect_vault_json '.ALPHA_API_TOKEN' test-token
  expect_vault_json '.ALPHA_MODE' fast
  expect_no_out 'Skipped optional'
}

# Ruling 22: --auto fills only required and first-setup variables and names the optional ones.
case_fill_optional_auto_skipped() {
  new_case fill_optional_auto_skipped
  docker_shim rootless
  fill_vault
  setup_run 'test-pw\n' "$VAULT" --env-name dev --auto --profile dev networking alpha
  expect_status 0
  expect_out '− Skipped optional: ACME_EMAIL CF_DNS_API_TOKEN ALPHA_API_TOKEN ALPHA_MODE'
  expect_out '− Still missing: TZ DOMAIN.'
  expect_vault_json 'keys | join(" ")' ALPHA_DB_PASSWORD
}

# Ruling 26: an invalid age-key label is refused and asked again.
case_fill_invalid_label_reasked() {
  new_case fill_invalid_label_reasked
  docker_shim rootless
  fill_vault '{"TZ":"UTC","DOMAIN":"example.com","ALPHA_DB_PASSWORD":"test-password-1"}'
  setup_run 'test-pw\ns\nbad label!\nlaptop\n' "$VAULT" --env-name dev --profile dev networking alpha
  expect_status 0
  expect_out 'Label for the age key [primary]'
  expect_out 'The label may only use letters, digits, - and _.'
  expect_true 'KeePassXC holds the label laptop' [ "$(fill_kp show -s -a Password homelab/dev/age-key-label)" = laptop ]
  expect_true '.sops.yaml uses &laptop' grep -q '&laptop age1' "$CASE/$FILL_SECRETS/.sops.yaml"
}

# A tracked .env chosen in the per-variable menu is refused, and another path is asked.
case_fill_tracked_env_reasked_per_variable() {
  new_case fill_tracked_env_reasked_per_variable
  docker_shim rootless
  fill_vault
  printf 'TZ=Asia/Taipei\n' > "$REPO/.env"
  repo_git add -f .env
  repo_git commit -q -m 'tracked .env'
  printf 'TZ=Europe/Berlin\n' > "$CASE/import.env"
  setup_run "test-pw\ng\ne\n$REPO/.env\n$CASE/import.env\ny\nS\n\n" "$VAULT" --env-name dev --profile dev networking
  expect_status 0
  expect_out "$REPO/.env is tracked by git; refusing to read secrets from it."
  expect_out 'Store this value? [y/N]'
  expect_vault_json '.TZ' Europe/Berlin
}

case_fill_live_data_refuses_auto() {
  new_case fill_live_data_refuses_auto
  docker_shim rootless homelab_alpha_db_data
  fill_vault
  setup_run 'test-pw\na\ns\ns\nm\ntest-password-1\ntest-password-1\nS\n\n' \
    "$VAULT" --env-name dev --profile dev networking alpha beta
  expect_status 0
  expect_out '! alpha already has data (volume homelab_alpha_db_data).'
  expect_out '    A new ALPHA_DB_PASSWORD would lock Alpha out of its database.'
  expect_out '    Import it from .env [e] or type the current value [m].'
  expect_out 'Set ALPHA_DB_PASSWORD'
  expect_vault_json '.ALPHA_DB_PASSWORD' test-password-1
  expect_vault_json '.DUMBASSETS_PIN | test("^[0-9]{6}$")' true
}

case_fill_docker_down_refuses_auto() {
  new_case fill_docker_down_refuses_auto
  docker_shim down
  fill_vault
  setup_run 'test-pw\na\ns\ns\nm\ntest-password-1\ntest-password-1\n\n' "$VAULT" --env-name dev --profile dev networking alpha
  expect_status 0
  expect_out '− Docker not running; skipping the rootless check'
  expect_out "✗ Docker is not running, so I can't check whether your stacks already hold data."
  expect_out '    A new password for a stack that has data would lock its apps out of their databases.'
  expect_out '    Start Docker and rerun, or import from .env [e] / type the current value [m].'
  expect_vault_json '.ALPHA_DB_PASSWORD' test-password-1
}

case_fill_noninteractive_live_data_exit_1() {
  new_case fill_noninteractive_live_data_exit_1
  docker_shim rootless homelab_alpha_db_data
  fill_vault
  setup_run 'test-pw\n' "$VAULT" --env-name dev --auto --profile dev networking alpha beta
  expect_status 1
  expect_out '! alpha already has data (volume homelab_alpha_db_data).'
  expect_out '✗ Resolve these, then rerun: ALPHA_DB_PASSWORD'
  expect_vault_json 'has("ALPHA_DB_PASSWORD")' false
  expect_vault_json '.RUSTFS_ACCESS_KEY | test("^[A-Za-z0-9]{20}$")' true
  expect_true 'compose.yml was still written' [ -f "$CASE/$FILL_SECRETS/compose.yml" ]
  docker_shim down
  setup_run 'test-pw\n' "$VAULT" --env-name dev --auto --profile dev networking alpha
  expect_status 1
  expect_out '✗ Resolve these, then rerun: ALPHA_DB_PASSWORD'
}

case_fill_skip_missing_no_age_key() {
  new_case fill_skip_missing_no_age_key
  docker_shim rootless
  fill_vault
  cp "$VAULT" "$CASE/vault.before"
  setup_run 'test-pw\n' "$VAULT" --env-name dev --skip-missing --profile dev
  expect_status 0
  expect_out 'No values yet'
  expect_vault_untouched
  expect_missing "$CASE/$FILL_KEY"
  expect_missing "$CASE/$FILL_SECRETS/secrets.yaml"
  expect_true 'compose.yml written' [ -f "$CASE/$FILL_SECRETS/compose.yml" ]
  expect_true 'config remembers the vault' grep -qxF "VAULT=$VAULT" "$CASE/$FILL_SECRETS/config"
}

case_fill_tracked_env_refused() {
  new_case fill_tracked_env_refused
  docker_shim rootless
  fill_vault
  printf 'ALPHA_DB_PASSWORD=test-password-1\n' > "$REPO/.env"
  repo_git add -f .env
  repo_git commit -q -m 'tracked .env'
  cp "$VAULT" "$CASE/vault.before"
  setup_run 'test-pw\n' "$VAULT" --env-name dev --env "$REPO/.env" --profile dev
  expect_status 1
  expect_out "$REPO/.env is tracked by git; refusing to read secrets from it."
  expect_vault_untouched
  expect_missing "$CASE/$FILL_SECRETS/compose.yml"
  setup_run 'test-pw\n' "$VAULT" --env-name dev --env "$CASE/absent.env" --profile dev
  expect_status 1
  expect_out "No file at $CASE/absent.env."
  expect_vault_untouched
}

case_fill_output_env_mode() {
  new_case fill_output_env_mode
  docker_shim rootless
  fill_vault "$FILL_ALL"
  setup_run 'test-pw\n' "$VAULT" --env-name dev --skip-missing --output env --profile dev
  expect_status 0
  expect_mode "$REPO/.env" 600
  expect_true '.env holds ALPHA_DB_PASSWORD' grep -qxF "ALPHA_DB_PASSWORD='test-password-1'" "$REPO/.env"
  expect_missing "$CASE/$FILL_SECRETS/secrets.yaml"
  expect_true 'config remembers OUTPUT=env' grep -qxF OUTPUT=env "$CASE/$FILL_SECRETS/config"
  setup_run 'test-pw\n' --skip-missing --profile dev
  expect_status 0
  expect_out '.env is up to date'
}

case_eof_mid_guided_leaves_vault_untouched() {
  new_case eof_mid_guided_leaves_vault_untouched
  docker_shim rootless
  fill_vault '{"OPENVPN_USER":"test-user"}'
  cp "$VAULT" "$CASE/vault.before"
  # TZ picked (pending in memory), then input ends at the DOMAIN prompt.
  setup_run 'test-pw\ng\nm\n1\nm\n' "$VAULT" --env-name dev --profile dev
  expect_status 1
  expect_out 'No answer; stopping without changing anything.'
  expect_true 'the message appears once' [ "$(printf '%s\n' "$OUT" | grep -c 'No answer')" = 1 ]
  expect_vault_untouched
  expect_missing "$CASE/home/.local/state/homelab-secrets/backups"
  expect_missing "$CASE/$FILL_SECRETS/secrets.yaml"
  expect_missing "$CASE/$FILL_SECRETS/compose.yml"
  # Input ends between the two hidden entries of a secret.
  setup_run 'test-pw\ng\ns\ns\nm\ntest-password-1\n' "$VAULT" --env-name dev --profile dev networking alpha
  expect_status 1
  expect_true 'the message appears once' [ "$(printf '%s\n' "$OUT" | grep -c 'No answer')" = 1 ]
  expect_vault_untouched
}

case_setup_idempotent_rerun() {
  new_case setup_idempotent_rerun
  docker_shim rootless
  fill_vault
  setup_run 'test-pw\n' "$VAULT" --env-name dev --auto --profile dev networking alpha
  expect_status 0
  expect_out 'values stored and verified'
  expect_true 'one backup after the first run' [ "$(fill_backups)" = 1 ]
  cp "$VAULT" "$CASE/vault.before"
  setup_run 'test-pw\n' "$VAULT" --env-name dev --auto --profile dev networking alpha
  expect_status 0
  expect_out 'secrets.yaml is up to date'
  expect_out 'compose.yml is up to date'
  expect_no_out 'values stored'
  expect_true 'still one backup after the rerun' [ "$(fill_backups)" = 1 ]
  expect_vault_untouched
}

case_setup_help_lists_flags() {
  local flag
  new_case setup_help_lists_flags
  setup_run '' -h
  expect_status 0
  for flag in DATABASE --auto '--env FILE' --skip-missing '--profile NAME [STACK…]' '--env-name NAME' \
      '--output sops|env' '--rotate VAR' --finish-age-key-rotation; do
    expect_out "$flag"
  done
}

# STACK: runs live_data_reason STACK in the sandbox; sets OUT and STATUS.
live_run() {
  STATUS=0
  OUT=$(sandboxed "$BASH" -c 'set -euo pipefail
    d=$1; for lib in ui config map values docker; do . "$d/$lib.sh"; done
    secrets_paths; live_data_reason "$2"' _ "$CHECKOUT/scripts/secrets/lib" "$1" 2>&1) || STATUS=$?
}

case_live_data_volume() {
  new_case live_data_volume
  docker_shim rootless homelab_other homelab_alpha_db_data
  live_run alpha
  expect_status 0
  expect_true 'reason is the volume' [ "$OUT" = 'volume homelab_alpha_db_data' ]
}

case_live_data_env_file() {
  new_case live_data_env_file
  docker_shim rootless
  printf 'TZ=UTC\n' > "$REPO/.env"
  live_run alpha
  expect_status 1
  printf 'TZ=UTC\nALPHA_DB_PASSWORD="test-password-1"\n' > "$REPO/.env"
  live_run alpha
  expect_status 0
  expect_true 'reason names the variable' [ "$OUT" = '.env sets ALPHA_DB_PASSWORD' ]
  live_run beta
  expect_status 1
}

case_live_data_clean() {
  new_case live_data_clean
  docker_shim rootless homelab_beta_cache
  live_run alpha
  expect_status 1
  expect_true 'no reason printed' [ -z "$OUT" ]
}

case_live_data_docker_down() {
  new_case live_data_docker_down
  docker_shim down
  live_run alpha
  expect_status 0
  expect_true 'reason is docker-down' [ "$OUT" = docker-down ]
}

case_setup_speed_60_vars() {
  local json start elapsed
  new_case setup_speed_60_vars
  docker_shim rootless
  VAULT="$CASE/vault.kdbx" VAULT_PASSWORD=test-pw
  printf 'test-pw\ntest-pw\n' | sandboxed keepassxc-cli db-create -q -p -t 1000 "$VAULT" >/dev/null 2>&1
  fill_kp mkdir homelab >/dev/null
  fill_kp mkdir homelab/dev >/dev/null
  json=$(printf '%s' "$FILL_ALL" | jq -c 'reduce range(1; 52) as $i (.; .["FILLER_\($i)"] = "test-value-\($i)")')
  printf '%s\n%s\n' "$VAULT_PASSWORD" "$json" | sandboxed keepassxc-cli add -q -p "$VAULT" homelab/dev/vars >/dev/null
  expect_vault_json 'length' 60
  setup_run 'test-pw\n' "$VAULT" --env-name dev --skip-missing --profile dev
  expect_status 0
  start=$(date +%s)
  setup_run 'test-pw\n' "$VAULT" --env-name dev --skip-missing --profile dev
  elapsed=$(( $(date +%s) - start ))
  expect_status 0
  expect_out 'secrets.yaml is up to date'
  expect_true "a no-change run of 60 values took ${elapsed}s (under 10)" [ "$elapsed" -lt 10 ]
}

case_setup_profile_partial_compose_renders() {
  new_case setup_profile_partial_compose_renders
  docker_shim rootless
  fill_vault
  setup_run 'test-pw\n' "$VAULT" --env-name dev --auto --profile dev networking alpha
  expect_status 0
  expect_true 'alpha is active' grep -q '^  - ".*/services/alpha.yml"' "$CASE/$FILL_SECRETS/compose.yml"
  expect_true 'networking is active' grep -q '^  - ".*/services/networking.yml"' "$CASE/$FILL_SECRETS/compose.yml"
  expect_true 'gamma is commented' grep -q '^  # - ".*/services/gamma.yml"' "$CASE/$FILL_SECRETS/compose.yml"
  STATUS=0
  OUT=$(sandboxed SOPS_AGE_KEY_FILE="$CASE/$FILL_KEY" "$BASH" -c 'set -euo pipefail
    eval "$(sops decrypt --output-type json "$1" | jq -r "to_entries[] | \"export \(.key)=\(.value | @sh)\"")"
    docker compose -f "$2" --project-directory "$3" config >/dev/null' _ \
    "$CASE/$FILL_SECRETS/secrets.yaml" "$CASE/$FILL_SECRETS/compose.yml" "$REPO" 2>&1) || STATUS=$?
  expect_status 0
}
