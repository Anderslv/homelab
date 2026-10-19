# shellcheck shell=bash disable=SC2016,SC2034 # sandboxed bash -c scripts; OUT/STATUS feed expect_*
# Output cases: lib/output.sh writes the age key, .sops.yaml, secrets.yaml, the
# opt-out .env and the local compose.yml. See harness.sh for conventions.

# ANSWERS BODY [ARG…]: runs BODY with the secrets libs loaded and secrets_paths set.
# `sops_ready` installs an age key (reusing AGE_KEY_FILE) and writes .sops.yaml.
output_run() {
  local answers=$1 body=$2
  shift 2
  STATUS=0
  OUT=$(printf '%b' "$answers" | sandboxed ${OUTPUT_ENV:+"$OUTPUT_ENV"} "$BASH" -c 'set -euo pipefail
    d=$1; body=$2; shift 2
    for lib in ui config map example output output-compose; do . "$d/$lib.sh"; done
    secrets_paths
    sops_ready() {
      local key
      if [ -f "$AGE_KEY_FILE" ]; then key=$(cat "$AGE_KEY_FILE"); else key=$(age-keygen 2>/dev/null); fi
      install_age_key "$key"
      write_sops_config "$(printf "%s\n" "$key" | age-keygen -y /dev/stdin)" primary
    }
    eval "$body"' _ "$CHECKOUT/scripts/secrets/lib" "$body" "$@" 2>&1) || STATUS=$?
  OUT=$(printf '%s\n' "$OUT" | strip_colour)
  printf '%s\n' "$OUT" > "$CASE/last-output.txt"
}

SECRETS="home/.config/homelab-secrets"
WANT1='{"TZ":"UTC","ALPHA_DB_PASSWORD":"test-password-1","OPENVPN_USER":"vpn user # x"}'
WANT2='{"TZ":"UTC","ALPHA_DB_PASSWORD":"test-password-2","ALPHA_MODE":"fast"}'

case_sops_roundtrip_and_modes() {
  new_case sops_roundtrip_and_modes
  output_run '' 'sops_ready; write_sops "$1"' "$WANT1"
  expect_status 0
  expect_out '✓ Wrote secrets.yaml and verified it decrypts'
  expect_sops ALPHA_DB_PASSWORD test-password-1
  expect_sops OPENVPN_USER 'vpn user # x'
  expect_mode "$CASE/$SECRETS" 700
  expect_mode "$CASE/$SECRETS/secrets.yaml" 600
  expect_mode "$CASE/$SECRETS/.sops.yaml" 600
  expect_mode "$CASE/home/.config/sops/age/keys.txt" 600
  expect_mode "$CASE/home/.config/sops/age" 700
  expect_true '.sops.yaml has the &primary anchor' grep -q '&primary age1' "$CASE/$SECRETS/.sops.yaml"
  expect_true '.sops.yaml has the path_regex' grep -qF 'path_regex: \.ya?ml$' "$CASE/$SECRETS/.sops.yaml"
  output_run '' 'sops_ready; write_sops "$1"' "$WANT1"
  expect_status 0
  expect_out 'up to date'
  expect_missing "$CASE/$SECRETS/secrets.prev.yaml"
}

case_sops_change_listing_names_only() {
  new_case sops_change_listing_names_only
  output_run '' 'sops_ready; write_sops "$1"' "$WANT1"
  output_run 'y\n' 'sops_ready; write_sops "$1"' "$WANT2"
  expect_status 0
  expect_out 'ALPHA_DB_PASSWORD (changed)'
  expect_out 'OPENVPN_USER (removed)'
  expect_out 'ALPHA_MODE (added)'
  expect_no_out 'TZ ('
  expect_no_out 'test-password'
  expect_no_out 'vpn user'
  expect_sops ALPHA_DB_PASSWORD test-password-2
  expect_mode "$CASE/$SECRETS/secrets.prev.yaml" 600
  CASE_SECRETS_DIR="$CASE/prev" && mkdir "$CASE/prev" && cp "$CASE/$SECRETS/secrets.prev.yaml" "$CASE/prev/secrets.yaml"
  expect_sops ALPHA_DB_PASSWORD test-password-1
}

case_sops_noninteractive_refuses_change() {
  new_case sops_noninteractive_refuses_change
  output_run '' 'sops_ready; write_sops "$1"' "$WANT1"
  cp "$CASE/$SECRETS/secrets.yaml" "$CASE/before.yaml"
  output_run 'y\n' 'HOMELAB_NONINTERACTIVE=1; sops_ready; write_sops "$1"' "$WANT2"
  expect_status 1
  expect_out 'ALPHA_DB_PASSWORD (changed)'
  expect_true 'secrets.yaml unchanged' cmp -s "$CASE/before.yaml" "$CASE/$SECRETS/secrets.yaml"
  expect_missing "$CASE/$SECRETS/secrets.prev.yaml"
}

case_sops_refuses_in_git() {
  new_case sops_refuses_in_git
  OUTPUT_ENV="HOMELAB_SECRETS_DIR=$REPO/private/secrets"
  output_run '' 'write_sops "$1"' "$WANT1"
  OUTPUT_ENV=''
  expect_status 1
  expect_out "$REPO/private/secrets is inside a git work tree; refusing to write secrets there."
  expect_missing "$REPO/private"
  OUTPUT_ENV="HOMELAB_SECRETS_AGE_KEY_FILE=$REPO/keys.txt"
  output_run '' 'install_age_key "$(age-keygen 2>/dev/null)"'
  OUTPUT_ENV=''
  expect_status 1
  expect_missing "$REPO/keys.txt"
}

case_age_key_mismatch_untouched() {
  new_case age_key_mismatch_untouched
  output_run '' 'sops_ready'
  cp "$CASE/home/.config/sops/age/keys.txt" "$CASE/before.txt"
  output_run '' 'install_age_key "$(age-keygen 2>/dev/null)"'
  expect_status 1
  expect_out "$CASE/home/.config/sops/age/keys.txt holds a different key than KeePassXC; not touching it. Move it aside and rerun."
  expect_true 'keys.txt unchanged' cmp -s "$CASE/before.txt" "$CASE/home/.config/sops/age/keys.txt"
  chmod 644 "$CASE/home/.config/sops/age/keys.txt"
  output_run '' 'install_age_key "$(cat "$AGE_KEY_FILE")"'
  expect_status 0
  expect_mode "$CASE/home/.config/sops/age/keys.txt" 600
  # A dangling symlink is treated like a different key: left alone.
  ln -s "$CASE/nowhere.txt" "$CASE/dangling.txt"
  OUTPUT_ENV="HOMELAB_SECRETS_AGE_KEY_FILE=$CASE/dangling.txt"
  output_run '' 'install_age_key "$(age-keygen 2>/dev/null)"'
  OUTPUT_ENV=''
  expect_status 1
  expect_out "$CASE/dangling.txt holds a different key than KeePassXC; not touching it. Move it aside and rerun."
  expect_true 'dangling link still there' [ -L "$CASE/dangling.txt" ]
  expect_missing "$CASE/nowhere.txt"
}

case_env_output_600_and_order() {
  new_case env_output_600_and_order
  output_run '' 'write_env_file "$1"' '{"ZZ_EXTRA":"z","OPENVPN_USER":"u","TZ":"UTC","ALPHA_DB_PASSWORD":"test-password-1"}'
  expect_status 0
  expect_out '! .env holds your values in plain text. It is gitignored and blocked from commits.'
  expect_no_out 'test-password'
  expect_mode "$REPO/.env" 600
  expect_true 'names in .env.example order, extras last' [ "$(sed -n 's/^\([A-Z_]*\)=.*/\1/p' "$REPO/.env" | tr '\n' ' ')" = 'TZ ALPHA_DB_PASSWORD OPENVPN_USER ZZ_EXTRA ' ]
  output_run 'y\n' 'write_env_file "$1"' '{"TZ":"UTC","ALPHA_DB_PASSWORD":"test-password-2"}'
  expect_status 0
  expect_out 'ALPHA_DB_PASSWORD (changed)'
  expect_out 'OPENVPN_USER (removed)'
  expect_no_out 'test-password'
  expect_mode "$REPO/.env.prev" 600
  expect_true '.env.prev holds the old value' grep -q "^ALPHA_DB_PASSWORD='test-password-1'\$" "$REPO/.env.prev"
  output_run '' 'HOMELAB_NONINTERACTIVE=1; write_env_file "$1"' '{"TZ":"UTC","ALPHA_DB_PASSWORD":"test-password-2"}'
  expect_status 0
  expect_out 'up to date'
  output_run '' 'HOMELAB_NONINTERACTIVE=1; write_env_file "$1"' '{"TZ":"UTC"}'
  expect_status 1
  expect_missing "$REPO/.env.tmp"
}

case_env_bad_name_and_interrupt() {
  new_case env_bad_name_and_interrupt
  output_run '' 'write_env_file "$1"' '{"GOOD":"test-password-1","BAD-NAME":"test-password-2"}'
  expect_status 1
  expect_out 'Not a valid variable name for .env: BAD-NAME'
  expect_no_out 'test-password'
  expect_missing "$REPO/.env"
  output_run '' 'write_env_file "$1"' '{"TZ":"UTC"}'
  cp "$REPO/.env" "$CASE/before.env"
  # cmp runs while .env.tmp exists; this one sends TERM to the script that called it.
  shim cmp 'kill -TERM "$PPID"; exit 1'
  output_run '' 'trap "echo caller-trap-kept" USR1; write_env_file "$1"' '{"TZ":"Europe/Berlin"}'
  expect_status 130
  expect_missing "$REPO/.env.tmp"
  expect_true '.env unchanged after the interruption' cmp -s "$CASE/before.env" "$REPO/.env"
  rm -f "$CASE/bin/cmp"
  output_run 'y\n' 'trap "echo kept" USR1; write_env_file "$1"; trap -p USR1 EXIT' '{"TZ":"Europe/Berlin"}'
  expect_status 0
  expect_out "trap -- 'echo kept' SIGUSR1"
  expect_no_out 'EXIT'
}

case_compose_refuses_odd_repo_path() {
  new_case compose_refuses_odd_repo_path
  cp -R "$REPO" "$CASE/re\$po"
  OUTPUT_ENV="HOMELAB_REPO=$CASE/re\$po"
  output_run '' 'write_local_compose "$1"' '{}'
  OUTPUT_ENV=''
  expect_status 1
  expect_out 'contains a quote, backslash or $.'
  expect_missing "$CASE/$SECRETS/compose.yml"
}

# Compose itself must read every value back exactly. `config` prints a literal $ as $$.
case_env_quoting_compose_reads_back() {
  new_case env_quoting_compose_reads_back
  local nl='
' want name expected got
  want=$(jq -cn --arg nl "$nl" --arg canary "\$(touch $CASE/canary)" '{
    Q_DOLLAR: "$x and ${HOME} and $$", Q_DQUOTE: "say \"hi\"", Q_SQUOTE: "it'"'"'s",
    Q_HASH: "a # not a comment", Q_DASH: "-leading", Q_EQUALS: "k=v==", Q_SPACES: "  spaced  out  ",
    Q_UNICODE: "ünïcødé ✓ 日本", Q_NEWLINE: ("line1" + $nl + "line2"), Q_CANARY: $canary,
    Q_ALL: ("it'"'"'s $x \"q\" back\\slash # end" + $nl + "next =-")}')
  printf 'services:\n  q:\n    image: busybox:1.37.0\n    environment:\n' > "$REPO/quoting.yml"
  for name in $(printf '%s' "$want" | jq -r 'keys[]'); do printf '      %s: ${%s}\n' "$name" "$name" >> "$REPO/quoting.yml"; done
  output_run '' 'write_env_file "$1"' "$want"
  expect_status 0
  got=$(sandboxed docker compose --project-directory "$REPO" -f "$REPO/quoting.yml" config --format json 2>/dev/null |
    jq -c '.services.q.environment' || true)
  for name in $(printf '%s' "$want" | jq -r 'keys[]'); do
    expected=$(printf '%s' "$want" | jq -c --arg n "$name" '.[$n] | gsub("\\$"; "$$")')
    expect_true "compose reads $name back exactly" [ "$(printf '%s' "$got" | jq -c --arg n "$name" '.[$n]')" = "$expected" ]
  done
  expect_missing "$CASE/canary"
}

compose_line() { grep -F "\"$REPO/services/$1.yml\"" "$CASE/$SECRETS/compose.yml" || true; }
# STACK PROFILE: the commented "not set up" line for STACK.
todo_line() { printf '  # - "%s/services/%s.yml"  # not set up: scripts/secrets/setup.sh --profile %s %s' "$REPO" "$1" "$2" "$1"; }
# STACK: the active line for networking or alpha, with docker-compose.yml's comment.
active() {
  case "$1" in networking) set -- networking 'Traefik (dev and prod)' ;; alpha) set -- alpha 'a database and a web app' ;; esac
  printf '  - "%s/services/%s.yml"  # %s' "$REPO" "$1" "$2"
}

case_local_compose_only_complete_stacks() {
  new_case local_compose_only_complete_stacks
  output_run '' 'SELECTED_STACKS="networking alpha beta gamma"; write_local_compose "$1"' \
    '{"ALPHA_DB_PASSWORD":"test-password-1","OPENVPN_USER":"u","OPENVPN_PASSWORD":""}'
  expect_status 0
  expect_mode "$CASE/$SECRETS/compose.yml" 600
  expect_true 'name: homelab' grep -qx 'name: homelab' "$CASE/$SECRETS/compose.yml"
  expect_true 'header names the hand-edit rule' grep -qx '# Commented include lines you add by hand are kept; other edits are replaced on the next run.' "$CASE/$SECRETS/compose.yml"
  expect_true 'networking active' [ "$(compose_line networking)" = "$(active networking)" ]
  expect_true 'alpha active' [ "$(compose_line alpha)" = "$(active alpha)" ]
  expect_true 'beta commented (selected, required value missing)' [ "$(compose_line beta)" = "$(todo_line beta apps)" ]
  expect_true 'gamma commented (empty required value)' [ "$(compose_line gamma)" = "$(todo_line gamma apps)" ]
  expect_true 'no dockhand line' sh -c "! grep -q pods '$CASE/$SECRETS/compose.yml'"
  expect_no_out 'test-password'
  expect_true 'compose renders it' sandboxed ALPHA_DB_PASSWORD=x docker compose -f "$CASE/$SECRETS/compose.yml" \
    --project-directory "$REPO" --profile dev config --services
  cp "$CASE/$SECRETS/compose.yml" "$CASE/before.yml"
  output_run '' 'write_local_compose "$1"' '{"ALPHA_DB_PASSWORD":"test-password-1"}'
  expect_out 'compose.yml is up to date'
  expect_true 'unchanged file not rewritten' cmp -s "$CASE/before.yml" "$CASE/$SECRETS/compose.yml"
  # Interactive: the change is listed and a "no" keeps the file.
  output_run 'n\n' 'SELECTED_PROFILE=dev; write_local_compose "$1"' '{}'
  expect_status 0
  expect_out 'alpha (commented out)'
  expect_out 'Left compose.yml unchanged.'
  expect_true 'declined change not written' cmp -s "$CASE/before.yml" "$CASE/$SECRETS/compose.yml"
  output_run 'y\n' 'SELECTED_PROFILE=dev; write_local_compose "$1"' '{}'
  expect_out 'Write compose.yml? [Y/n]'
  expect_true 'hint uses SELECTED_PROFILE' [ "$(compose_line alpha)" = "$(todo_line alpha dev)" ]
  expect_true 'networking stays active' [ "$(compose_line networking)" = "$(active networking)" ]
}

# Ruling 20: active needs (selected now or active before) and every required value.
case_local_compose_selection_rules() {
  new_case local_compose_selection_rules
  output_run '' 'SELECTED_STACKS=alpha; write_local_compose "$1"' '{"ALPHA_DB_PASSWORD":"p"}'
  expect_true 'unselected stack without required values stays commented' [ "$(compose_line networking)" = "$(todo_line networking infra)" ]
  expect_true 'alpha active' [ "$(compose_line alpha)" = "$(active alpha)" ]
  output_run '' 'HOMELAB_NONINTERACTIVE=1; SELECTED_STACKS=networking; write_local_compose "$1"' '{"ALPHA_DB_PASSWORD":"p"}'
  expect_status 0
  expect_out 'networking (active)'
  expect_no_out 'Write compose.yml?'
  expect_true 'networking active once selected' [ "$(compose_line networking)" = "$(active networking)" ]
  expect_true 'alpha stays active' [ "$(compose_line alpha)" = "$(active alpha)" ]
  output_run '' 'SELECTED_STACKS=beta; write_local_compose "$1"' '{"ALPHA_DB_PASSWORD":"p"}'
  expect_out 'compose.yml is up to date'
  expect_true 'networking stays active when beta is selected' [ "$(compose_line networking)" = "$(active networking)" ]
}

case_local_compose_keeps_hand_comment() {
  new_case local_compose_keeps_hand_comment
  output_run '' 'SELECTED_STACKS="networking alpha"; write_local_compose "$1"' '{"ALPHA_DB_PASSWORD":"p"}'
  sed "s|^  - \"$REPO/services/alpha.yml\".*|  # - \"$REPO/services/alpha.yml\"  # off for now|" "$CASE/$SECRETS/compose.yml" > "$CASE/edited.yml"
  cp "$CASE/edited.yml" "$CASE/$SECRETS/compose.yml"
  output_run '' 'SELECTED_STACKS="networking alpha"; write_local_compose "$1"' '{"ALPHA_DB_PASSWORD":"p"}'
  expect_status 0
  expect_out 'compose.yml is up to date'
  expect_true 'hand comment kept' [ "$(compose_line alpha)" = "  # - \"$REPO/services/alpha.yml\"  # off for now" ]
  expect_true 'networking still active' [ "$(compose_line networking)" = "$(active networking)" ]
}

case_local_compose_new_stack_commented() {
  new_case local_compose_new_stack_commented
  output_run '' 'SELECTED_STACKS="networking alpha"; write_local_compose "$1"' '{"ALPHA_DB_PASSWORD":"p"}'
  # delta has no required variables, and nobody chose it.
  printf 'services:\n  delta:\n    profiles: [apps]\n    image: busybox:1.37.0\n    environment:\n      T: ${DELTA_MODE:-x}\n' > "$REPO/services/delta.yml"
  printf '  - services/delta.yml  # a stack added upstream\n' >> "$REPO/docker-compose.yml"
  output_run 'y\n' 'write_local_compose "$1"' '{"ALPHA_DB_PASSWORD":"p"}'
  expect_status 0
  expect_out 'delta (commented out)'
  expect_true 'delta commented' [ "$(compose_line delta)" = "$(todo_line delta apps)" ]
  expect_true 'alpha still active' [ "$(compose_line alpha)" = "$(active alpha)" ]
}

case_no_tmp_files_left() {
  new_case no_tmp_files_left
  # A leftover tmp from an interrupted run is replaced, never written through.
  (umask 077 && mkdir -p "$CASE/$SECRETS") && : > "$CASE/decoy" && ln -s "$CASE/decoy" "$CASE/$SECRETS/.secrets.yaml.tmp"
  output_run '' 'sops_ready; write_sops "$1"; write_env_file "$1"; write_local_compose "$1"' "$WANT1"
  output_run 'y\ny\ny\n' 'sops_ready; write_sops "$1"; write_env_file "$1"; write_local_compose "$1"' "$WANT2"
  expect_status 0
  expect_true '$CASE/tmp is empty' [ -z "$(ls -A "$CASE/tmp")" ]
  expect_missing "$CASE/$SECRETS/.secrets.yaml.tmp"
  expect_missing "$REPO/.env.tmp"
  expect_missing "$CASE/$SECRETS/compose.yml.tmp"
  expect_true 'the leftover tmp link target stayed empty' [ ! -s "$CASE/decoy" ]
  expect_true 'secrets.yaml is not a link' [ ! -L "$CASE/$SECRETS/secrets.yaml" ]
}
