# shellcheck shell=bash disable=SC2016,SC2034 # sandboxed bash -c scripts; OUT/STATUS feed expect_*
# Run cases: secrets.sh exports the values from the local output and runs the command.
# Uses setup_run, fill_vault and FILL_* from cases/fill.sh; see harness.sh for conventions.

RUN_ENV=''

# ARG…: secrets.sh with the VAR=VALUE words in RUN_ENV added to its environment.
run_with_env() {
  STATUS=0
  # shellcheck disable=SC2086 # RUN_ENV is a list of VAR=VALUE words
  OUT=$(cd "$REPO" && sandboxed $RUN_ENV "$BASH" "$CHECKOUT/secrets.sh" "$@" < /dev/null 2>&1) || STATUS=$?
  OUT=$(printf '%s\n' "$OUT" | strip_colour)
  printf '%s\n' "$OUT" > "$CASE/last-output.txt"
}

# JSON: a new age key and secrets.yaml holding JSON, made without setup.sh (as when
# both are copied from another machine; there is no config file).
run_sops_ready() {
  local key="$CASE/$FILL_KEY" recipient
  (umask 077 && mkdir -p "$(dirname "$key")" "$CASE/$FILL_SECRETS")
  (umask 077 && sandboxed age-keygen -o "$key" 2>/dev/null)
  recipient=$(sandboxed age-keygen -y "$key")
  printf '%s' "$1" | (umask 077 && sandboxed sops encrypt --age "$recipient" --input-type json \
    --output-type yaml --filename-override secrets.yaml /dev/stdin > "$CASE/$FILL_SECRETS/secrets.yaml")
}

# JSON ARG…: a vault holding JSON, then a non-interactive setup.sh run with ARG….
run_setup_ready() {
  local json=$1
  shift
  docker_shim rootless
  fill_vault "$json"
  setup_run 'test-pw\n' "$VAULT" --env-name dev --skip-missing "$@"
  expect_status 0
}

case_run_exports_and_skips_empty() {
  new_case run_exports_and_skips_empty
  run_sops_ready '{"TZ":"Europe/Berlin","ALPHA_DB_PASSWORD":"test-password-1","ALPHA_MODE":"","BAD-NAME":"x"}'
  run_secrets run env
  expect_status 0
  expect_out 'TZ=Europe/Berlin'
  expect_out 'ALPHA_DB_PASSWORD=test-password-1'
  expect_no_out 'ALPHA_MODE='
  expect_out '! skipped BAD?NAME: not a variable in .env.example'
  expect_no_out 'BAD?NAME='
  expect_no_out 'kept from your environment'
}

case_run_shell_wins_and_says_so() {
  new_case run_shell_wins_and_says_so
  run_sops_ready '{"DOMAIN":"example.com","TZ":"Europe/Berlin","ALPHA_DB_PASSWORD":"test-password-1"}'
  RUN_ENV='TZ=UTC DOMAIN='
  run_with_env run env
  RUN_ENV=''
  expect_status 0
  expect_out '− kept from your environment: DOMAIN TZ'
  expect_out 'TZ=UTC'
  expect_no_out 'TZ=Europe/Berlin'
  expect_no_out 'example.com'
  expect_out 'ALPHA_DB_PASSWORD=test-password-1'
}

case_run_missing_files() {
  new_case run_missing_files
  run_secrets run true
  expect_status 1
  expect_out "✗ missing $CASE/$FILL_SECRETS/secrets.yaml; run scripts/secrets/setup.sh first"
  run_sops_ready '{"TZ":"UTC"}'
  rm "$CASE/$FILL_KEY"
  run_secrets run true
  expect_status 1
  expect_out "✗ missing $CASE/$FILL_KEY; run scripts/secrets/setup.sh first"
  # With the .env output nothing is decrypted, so the missing key does not matter.
  printf 'OUTPUT=env\n' > "$CASE/$FILL_SECRETS/config"
  run_secrets run env
  expect_status 0
  expect_no_out 'TZ=UTC'
  expect_no_out 'run scripts/secrets/setup.sh first'
}

case_run_stray_env_warning() {
  new_case run_stray_env_warning
  run_sops_ready '{"TZ":"UTC"}'
  run_secrets run true
  expect_no_out '.env found'
  : > "$REPO/.env"
  run_secrets run true
  expect_status 0
  expect_out '! .env found next to a sops setup; Compose also reads it.'
  printf 'OUTPUT=env\n' > "$CASE/$FILL_SECRETS/config"
  run_secrets run true
  expect_no_out '.env found'
}

case_run_no_key_material_in_child() {
  new_case run_no_key_material_in_child
  run_sops_ready '{"TZ":"UTC","ALPHA_DB_PASSWORD":"test-password-1"}'
  run_secrets run env
  expect_status 0
  expect_out 'ALPHA_DB_PASSWORD=test-password-1'
  expect_no_out 'AGE-SECRET-KEY-'
  expect_no_out 'KP_PASSWORD'
}

case_run_pods_file_passthrough() {
  new_case run_pods_file_passthrough
  run_sops_ready '{"TZ":"UTC"}'
  : > "$CASE/$FILL_SECRETS/compose.yml"
  # A fake docker that prints its arguments, one per line.
  shim docker 'printf "[%s]\n" "$PWD" "$@"'
  run_secrets compose logs -f alpha
  expect_true 'compose.yml added right after compose; logs -f is not a file' [ "$(printf '%s' "$OUT" | tr '\n' ' ')" = \
    "[$REPO] [compose] [-f] [$CASE/$FILL_SECRETS/compose.yml] [--project-directory] [$REPO] [logs] [-f] [alpha]" ]
  for args in '-f docker-compose.pods.yml config' '--file docker-compose.pods.yml config' \
      '--file=docker-compose.pods.yml config' '--profile dev -f docker-compose.pods.yml up'; do
    # shellcheck disable=SC2086 # the arguments are words
    run_secrets compose $args
    expect_true "no compose.yml added for: $args" [ "$(printf '%s\n' "$OUT" | grep -c 'compose.yml')" = 0 ]
    expect_out "[$REPO]"
  done
  # An exported COMPOSE_FILE names the files too.
  RUN_ENV='COMPOSE_FILE=docker-compose.pods.yml'
  run_with_env compose ps
  RUN_ENV=''
  expect_true 'no compose.yml added with COMPOSE_FILE set' [ "$(printf '%s' "$OUT" | tr '\n' ' ')" = "[$REPO] [compose] [ps]" ]
  # Without compose.yml, compose runs from the repository with its own files.
  rm "$CASE/$FILL_SECRETS/compose.yml"
  run_secrets compose ps
  expect_true 'plain compose from the repository' [ "$(printf '%s' "$OUT" | tr '\n' ' ')" = "[$REPO] [compose] [ps]" ]
  # The real Compose renders the pods file with the values in place.
  rm "$CASE/bin/docker"
  run_secrets compose -f docker-compose.pods.yml config --services
  expect_status 0
  expect_out 'dockhand'
  expect_no_out 'alpha'
}

# Ruling 30: a planted secrets.yaml cannot steer the shell, the loader, Docker or secrets.sh.
case_run_planted_names_refused() {
  local name planted='{"TZ":"UTC"}' denied='LD_PRELOAD BASH_ENV DOCKER_HOST UID __ss_x'
  new_case run_planted_names_refused
  for name in $denied REPO COMMAND decode NOT_IN_MAP; do
    planted=$(printf '%s' "$planted" | jq -c --arg n "$name" '. + {($n): "planted-value"}')
  done
  run_sops_ready "$planted"
  # The denied names are listed in .env.example too, so the denylist alone must stop them.
  # shellcheck disable=SC2086 # a list of names
  printf '%s=\n' $denied >> "$REPO/.env.example"
  run_secrets run env
  expect_status 0
  expect_no_out 'planted-value'
  expect_out 'TZ=UTC'
  for name in LD_PRELOAD BASH_ENV DOCKER_HOST UID __ss_x; do expect_out "! skipped $name: a reserved name"; done
  for name in REPO COMMAND decode NOT_IN_MAP; do expect_out "! skipped $name: not a variable in .env.example"; done
  expect_no_out 'SOPS_AGE_KEY_FILE'
  # Even when a compose file uses them, REPO, COMMAND and decode do not change what runs.
  printf '%s=\n' REPO COMMAND decode >> "$REPO/.env.example"
  : > "$CASE/$FILL_SECRETS/compose.yml"
  shim docker 'printf "[%s]\n" "$PWD" "$@"; printf "[%s]\n" "$REPO" "$COMMAND" "$decode"'
  run_secrets compose ps
  expect_status 0
  expect_true 'compose ran with the real paths; the values reached the child' [ "$(printf '%s' "$OUT" | grep -v '^  ' | tr '\n' ' ')" = \
    "[$REPO] [compose] [-f] [$CASE/$FILL_SECRETS/compose.yml] [--project-directory] [$REPO] [ps] [planted-value] [planted-value] [planted-value] " ]
}

case_run_malformed_secrets() {
  new_case run_malformed_secrets
  run_sops_ready '{"TZ":"UTC"}'
  shim sops 'printf "not json\n"'
  run_secrets run true
  expect_status 1
  expect_out "✗ $CASE/$FILL_SECRETS/secrets.yaml does not hold a map of values."
  expect_no_out 'not json'
}

# Values Compose and .env quoting can break; none must be executed or altered.
RUN_META='{"TZ":"UTC","DOMAIN":"example.com","ALPHA_DB_PASSWORD":"it'"'"'s $x \"q\" back\\slash # end",
  "DUMBASSETS_PIN":"line1\nline2","SPEEDTEST_APP_KEY":"trailing newline\n","OPENVPN_USER":"ünïcødé ✓ 日本",
  "OPENVPN_PASSWORD":"$(touch CANARY)","RUSTFS_ACCESS_KEY":"`touch CANARY` ${HOME} =-","RUSTFS_SECRET_KEY":"  spaced  "}'

# Checks every service variable in `compose config --format json` (OUT) against JSON.
expect_compose_env() {
  local json=$1 got pairs var name expected
  got=$(printf '%s' "$OUT" | sed -n '/^{/,$p' | jq -c '[.services[].environment] | add' 2>/dev/null || true)
  pairs='ALPHA_DB_PASSWORD:POSTGRES_PASSWORD DUMBASSETS_PIN:PIN SPEEDTEST_APP_KEY:APP_KEY
    OPENVPN_USER:OPENVPN_USER OPENVPN_PASSWORD:OPENVPN_PASSWORD RUSTFS_ACCESS_KEY:RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY:RUSTFS_SECRET_KEY'
  for var in $pairs; do
    name=${var#*:} var=${var%%:*}
    expected=$(printf '%s' "$json" | jq -c --arg v "$var" '.[$v] | gsub("\\$"; "$$")')
    expect_true "$2: compose reads $var back exactly" \
      [ "$(printf '%s' "$got" | jq -c --arg n "$name" '.[$n]')" = "$expected" ]
  done
}

case_values_roundtrip_metacharacters() {
  local json
  new_case values_roundtrip_metacharacters
  json=$(printf '%s' "$RUN_META" | sed "s|CANARY|$CASE/canary|g" | jq -c .)
  run_setup_ready "$json" --profile dev
  run_secrets compose --profile dev config --format json
  expect_status 0
  expect_compose_env "$json" sops
  setup_run 'test-pw\n' "$VAULT" --env-name dev --skip-missing --profile dev --output env
  expect_status 0
  expect_mode "$REPO/.env" 600
  run_secrets compose --profile dev config --format json
  expect_status 0
  expect_compose_env "$json" .env
  expect_missing "$CASE/canary"
}

case_paths_with_spaces() {
  new_case 'paths with spaces'
  run_setup_ready "$FILL_ALL" --profile dev
  # Through a symlink in a folder with a space, from another working directory.
  mkdir "$CASE/my tools"
  ln -s "$CHECKOUT/secrets.sh" "$CASE/my tools/secrets.sh"
  STATUS=0
  OUT=$(cd "$CASE/home" && sandboxed "$BASH" "$CASE/my tools/secrets.sh" compose --profile dev config --services 2>&1) || STATUS=$?
  expect_status 0
  expect_out 'alpha-db'
  expect_out 'gamma-vpn'
  STATUS=0
  OUT=$(cd "$CASE/home" && sandboxed "$BASH" "$CASE/my tools/secrets.sh" run env 2>&1) || STATUS=$?
  expect_status 0
  expect_out 'OPENVPN_USER=test-user'
}

case_runs_from_other_cwd() {
  new_case runs_from_other_cwd
  run_sops_ready '{"TZ":"UTC"}'
  mkdir "$CASE/links"
  ln -s "$CHECKOUT/scripts/secrets/setup.sh" "$CASE/links/setup.sh"
  ln -s "$CHECKOUT/scripts/secrets/map.sh" "$CASE/links/map.sh"
  ln -s "$CHECKOUT/secrets.sh" "$CASE/links/secrets.sh"
  STATUS=0
  OUT=$(cd / && sandboxed "$BASH" "$CASE/links/setup.sh" --help 2>&1) || STATUS=$?
  expect_status 0
  STATUS=0
  OUT=$(cd / && sandboxed "$BASH" "$CASE/links/map.sh" --help 2>&1) || STATUS=$?
  expect_status 0
  STATUS=0
  OUT=$(cd / && sandboxed "$BASH" "$CASE/links/secrets.sh" run true 2>&1) || STATUS=$?
  expect_status 0
}

case_upstream_adds_stack() {
  new_case upstream_adds_stack
  run_setup_ready "$FILL_ALL" --profile dev
  printf 'services:\n  delta:\n    profiles: [apps, dev, prod]\n    image: busybox:1.37.0\n    environment:\n      T: ${DELTA_TOKEN:?}\n' \
    > "$REPO/services/delta.yml"
  printf '  - services/delta.yml  # a stack added upstream\n' >> "$REPO/docker-compose.yml"
  # Before setup runs again, delta is not in compose.yml at all.
  run_secrets compose --profile dev config --services
  expect_status 0
  expect_no_out 'delta'
  run_map --check
  expect_status 1
  expect_out '− new: DELTA_TOKEN'
  run_map
  expect_status 0
  expect_out '.env.example updated (+1 new'
  expect_true '.env.example lists DELTA_TOKEN' grep -qx 'DELTA_TOKEN=' "$REPO/.env.example"
  setup_run 'test-pw\n' "$VAULT" --env-name dev --skip-missing --profile dev
  expect_status 0
  expect_out '✗ DELTA_TOKEN missing'
  expect_true 'delta is commented in compose.yml' \
    grep -q "^  # - \"$REPO/services/delta.yml\"" "$CASE/$FILL_SECRETS/compose.yml"
  run_secrets compose --profile dev config --services
  expect_status 0
  expect_out 'alpha-db'
  expect_no_out 'delta'
}
