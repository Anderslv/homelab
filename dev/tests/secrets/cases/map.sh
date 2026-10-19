# shellcheck shell=bash disable=SC2016,SC2034 # sandboxed bash -c scripts; OUT/STATUS feed expect_*
# Map cases: scripts/secrets/map.sh and lib/map.sh turn the compose files into
# the generated .env.example (variables, kinds, stacks, dependencies, volumes).
# Sourced by dev/tests/secrets-setup.test.sh; see harness.sh for the conventions.

MAP_LIB_DIR="$CHECKOUT/scripts/secrets/lib"

# FUNCTION ARG…: runs one lib/map.sh function against the case repo; sets OUT.
map_lib() {
  OUT=$(sandboxed "$BASH" -c '. "$1/ui.sh"; . "$1/config.sh"; . "$1/map.sh"; . "$1/example.sh"
    secrets_paths; shift; "$@"' _ "$MAP_LIB_DIR" "$@" 2>&1) || true
}

# VAR COLUMN: prints one column of VAR's row in the TSV held in OUT.
row_field() { printf '%s\n' "$OUT" | awk -F '\t' -v v="$1" -v c="$2" '$2 == v { print $c }'; }

# VAR N: prints the line N lines above VAR= in the case's .env.example (1 is the
# metadata line, 2 the last description line).
line_above() {
  awk -v v="$1=" -v n="$2" '$0 == v { print line[NR - n]; exit } { line[NR] = $0 }' "$REPO/.env.example"
}

# Rewrites the case's .env.example through an awk program.
edit_example() {
  awk "$1" "$REPO/.env.example" > "$CASE/example.tmp"
  mv "$CASE/example.tmp" "$REPO/.env.example"
}

case_map_finds_every_form() {
  new_case map_finds_every_form
  map_lib map_rows
  expect_true 'ALPHA_DB_PASSWORD is required' [ "$(row_field ALPHA_DB_PASSWORD 3)" = required ]
  expect_true 'TZ is a default' [ "$(row_field TZ 3)" = default ]
  expect_true 'TZ defaults to UTC' [ "$(row_field TZ 4)" = UTC ]
  expect_true 'ALPHA_MODE is optional' [ "$(row_field ALPHA_MODE 3)" = optional ]
  expect_true 'ALPHA_API_TOKEN is optional' [ "$(row_field ALPHA_API_TOKEN 3)" = optional ]
  expect_true 'ALPHA_API_TOKEN is a secret' [ "$(row_field ALPHA_API_TOKEN 5)" = secret ]
  expect_true 'ALPHA_MODE is a setting' [ "$(row_field ALPHA_MODE 5)" = setting ]
  expect_true 'the escaped $$ESCAPED is skipped' [ -z "$(row_field ESCAPED 2)" ]
}

case_map_core_section_first() {
  new_case map_core_section_first
  run_map
  expect_status 0
  OUT=$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$REPO/.env.example" | head -3 | tr '\n' ' ')
  expect_true "the first variables are TZ DOMAIN ACME_EMAIL (got $OUT)" [ "$OUT" = 'TZ DOMAIN ACME_EMAIL ' ]
}

case_map_keeps_descriptions() {
  new_case map_keeps_descriptions
  # Insert the description above the metadata line: hold it until VAR= shows up.
  edit_example '/^# \(/ { held = $0; next }
    /^ALPHA_DB_PASSWORD=/ { print "# Shared alpha password." }
    held != "" { print held; held = "" } { print }'
  run_map
  expect_status 0
  expect_true 'the description is still directly above ALPHA_DB_PASSWORD=' \
    [ "$(line_above ALPHA_DB_PASSWORD 2)" = '# Shared alpha password.' ]
}

case_map_new_var_gets_message() {
  new_case map_new_var_gets_message
  rm "$REPO/.env.example"
  run_map
  expect_status 0
  expect_out '.env.example updated (+'
  expect_true 'a new variable gets its :? message as the description' \
    [ "$(line_above ALPHA_DB_PASSWORD 2)" = '# Set ALPHA_DB_PASSWORD' ]
  expect_true 'the metadata line sits directly above ALPHA_DB_PASSWORD=' \
    [ "$(line_above ALPHA_DB_PASSWORD 1)" = '# (required · secret · alpha-db)' ]
  expect_true 'a new variable without a message gets TODO' \
    [ "$(line_above ALPHA_MODE 2)" = '# TODO: describe' ]
}

case_map_check_fails_when_stale() {
  new_case map_check_fails_when_stale
  run_map --check
  expect_status 0
  edit_example '!/^ALPHA_MODE=/'
  cp "$REPO/.env.example" "$CASE/before.txt"
  run_map --check
  expect_status 1
  expect_out 'ALPHA_MODE'
  expect_true '--check writes nothing' cmp -s "$CASE/before.txt" "$REPO/.env.example"
}

case_map_never_writes_values() {
  new_case map_never_writes_values
  edit_example '/^ALPHA_MODE=/ { print "ALPHA_MODE=canary-value"; next } { print }'
  run_map
  expect_status 0
  expect_true 'every variable line in the fixture .env.example is a bare VAR=' \
    bare_vars_only "$REPO/.env.example"
  expect_true 'every variable line in the real .env.example is a bare VAR=' \
    bare_vars_only "$CHECKOUT/.env.example"
}

# FILE: true when every line that starts with a variable name is exactly VAR=.
bare_vars_only() {
  grep -Eq '^[A-Za-z_][A-Za-z0-9_]*=' "$1" &&
    ! grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$1" | grep -Evxq '[A-Za-z_][A-Za-z0-9_]*='
}

# Compose reads the generated file as .env: every value must come out empty, never "#…".
case_map_copy_as_env_is_empty() {
  new_case map_copy_as_env_is_empty
  cp "$REPO/.env.example" "$REPO/.env"
  OUT=$(cd "$REPO" && sandboxed ALPHA_DB_PASSWORD=test-password-1 SPEEDTEST_APP_KEY=test-key-1 \
    DUMBASSETS_PIN=test-pin-1 OPENVPN_USER=test-user OPENVPN_PASSWORD=test-password-2 \
    RUSTFS_ACCESS_KEY=test-key-2 RUSTFS_SECRET_KEY=test-key-3 \
    docker compose -f "$REPO/docker-compose.yml" --profile dev --profile prod config --format json \
    | jq -r '[.services[].environment // {} | to_entries[] | select(.value // "" | startswith("#")) | .key] | join(" ")') || OUT='compose failed'
  expect_true "no variable reads as a comment (got: ${OUT:-none})" [ -z "$OUT" ]
}

case_map_stack_deps_network_mode() {
  new_case map_stack_deps_network_mode
  map_lib map_stack_deps beta
  expect_true "beta needs gamma (got: $OUT)" [ "$OUT" = gamma ]
}

case_map_stack_volumes() {
  new_case map_stack_volumes
  map_lib map_stack_volumes alpha
  expect_true "alpha owns homelab_alpha_db_data (got: $OUT)" [ "$OUT" = homelab_alpha_db_data ]
}

case_map_pods_stack_last() {
  new_case map_pods_stack_last
  map_lib map_stacks
  OUT=$(printf '%s\n' "$OUT" | tail -n 1 | cut -f 1,2)
  expect_true "the last stack is dockhand from docker-compose.pods.yml" \
    [ "$OUT" = "dockhand$(printf '\t')docker-compose.pods.yml" ]
}

case_map_stack_vars_include_core() {
  new_case map_stack_vars_include_core
  map_lib map_stack_vars alpha
  OUT=$(printf '%s\n' "$OUT" | LC_ALL=C sort | tr '\n' ' ')
  expect_true "alpha uses its own and core variables (got: $OUT)" \
    [ "$OUT" = 'ALPHA_API_TOKEN ALPHA_DB_PASSWORD ALPHA_MODE TZ ' ]
}

case_map_example_rows_parse_back() {
  new_case map_example_rows_parse_back
  map_lib example_rows "$REPO/.env.example"
  expect_true 'ALPHA_DB_PASSWORD row: alpha, required, secret, its description' \
    [ "$(printf '%s\n' "$OUT" | grep "$(printf '\tALPHA_DB_PASSWORD\t')")" = \
      "$(printf 'alpha\tALPHA_DB_PASSWORD\trequired\t\tsecret\tSet ALPHA_DB_PASSWORD')" ]
  expect_true 'TZ row: core, default UTC' [ "$(row_field TZ 1)$(row_field TZ 4)" = coreUTC ]
}
