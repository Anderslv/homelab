# shellcheck shell=bash disable=SC2016,SC2034 # sandboxed bash -c scripts; OUT/STATUS feed expect_*
# Guard cases: the rules the whole toolchain promises (no recursive deletes, no
# here-strings, the real HOME untouched) plus the ui.sh and config.sh basics.
# Sourced by dev/tests/secrets-setup.test.sh; see harness.sh for the conventions.

UI_LIB="$CHECKOUT/scripts/secrets/lib/ui.sh"
CONFIG_LIB="$CHECKOUT/scripts/secrets/lib/config.sh"

# Prints the given checkout paths that exist (Ruling 2: some appear in later tasks).
existing_paths() {
  local path
  for path in "$@"; do
    if [ -e "$CHECKOUT/$path" ]; then printf '%s\n' "$CHECKOUT/$path"; fi
  done
}

case_guard_no_recursive_delete() {
  local paths hits
  # The pattern is split so this file does not match itself.
  local pattern='rm +-[a-zA-Z]*r|fin''d .*-delete|git'' clean'
  paths=$(existing_paths scripts dev secrets.sh check_macos.sh setup-dev.sh)
  # shellcheck disable=SC2086 # one path per line, none contain spaces
  hits=$(grep -rnE "$pattern" $paths || true)
  expect_true 'no recursive delete in scripts/, dev/ or the top-level scripts' [ -z "$hits" ]
  if [ -n "$hits" ]; then printf '%s\n' "$hits"; fi
}

case_guard_no_herestrings() {
  local hits
  # Ruling 1: secrets.sh joins this scan when Task 11 rewrites it.
  hits=$( { grep -rn '<<<' "$CHECKOUT/scripts/secrets" || true
            grep -rn '<<' "$CHECKOUT/scripts/secrets" | grep -v "<<'USAGE'" || true; } )
  expect_true "no here-string or heredoc (except <<'USAGE') in scripts/secrets/" [ -z "$hits" ]
  if [ -n "$hits" ]; then printf '%s\n' "$hits"; fi
}

# Every helper that writes or runs something must refuse before new_case.
case_guard_helpers_need_new_case() {
  local helper status
  for helper in 'sandboxed true' 'shim fake true' 'run_secrets' 'new_vault'; do
    status=0
    # shellcheck disable=SC2086 # the helper and its arguments are words
    ( $helper ) >/dev/null 2>&1 || status=$?
    expect_true "$helper fails before new_case" [ "$status" -ne 0 ]
  done
  expect_true 'shim wrote nothing to a top-level bin folder' [ ! -e /bin/fake ]
  expect_true 'sandbox variables start empty' [ -z "$CASE$REPO$VAULT$ANSWERS" ]
}

last_guard_real_home_untouched() {
  local changed
  changed=$(find "$HOME/.config/homelab-secrets" "$HOME/.config/sops" \
    "$HOME/.local/state/homelab-secrets" -newer "$SCRATCH/.started" 2>/dev/null || true)
  expect_true 'nothing in the real HOME secrets folders changed during the run' [ -z "$changed" ]
}

case_ui_ok_has_no_colour_without_tty() {
  local dump escape=no
  new_case ui_ok_has_no_colour_without_tty
  dump=$(sandboxed "$BASH" -c '. "$1"; ok hi' _ "$UI_LIB" 2>&1 | od -c)
  case "$dump" in *033*) escape=yes ;; esac
  expect_true 'ok prints no escape code when stderr is not a terminal' [ "$escape" = no ]
  OUT=$(sandboxed "$BASH" -c '. "$1"; ok hi' _ "$UI_LIB" 2>&1)
  expect_out '  ✓ hi'
}

case_config_roundtrip() {
  new_case config_roundtrip
  OUT=$(sandboxed "$BASH" -c '. "$1"; . "$2"; secrets_paths
    config_set OUTPUT env; config_get OUTPUT' _ "$UI_LIB" "$CONFIG_LIB" 2>&1)
  expect_true 'config_get prints the value config_set stored' [ "$OUT" = env ]
  expect_mode "$CASE/home/.config/homelab-secrets/config" 600
  expect_mode "$CASE/home/.config/homelab-secrets" 700
}

case_config_refuses_symlink() {
  new_case config_refuses_symlink
  mkdir -p "$CASE/home/.config/homelab-secrets"
  printf 'untouched\n' > "$CASE/elsewhere"
  ln -s "$CASE/elsewhere" "$CASE/home/.config/homelab-secrets/config"
  STATUS=0
  OUT=$(sandboxed "$BASH" -c '. "$1"; . "$2"; secrets_paths
    config_set OUTPUT env' _ "$UI_LIB" "$CONFIG_LIB" 2>&1) || STATUS=$?
  expect_status 1
  expect_out 'symlink'
  expect_true 'the symlink target is unchanged' \
    [ "$(cat "$CASE/elsewhere")" = untouched ]
}
