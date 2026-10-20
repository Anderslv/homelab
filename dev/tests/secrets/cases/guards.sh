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
  # Ruling 1: secrets.sh joined this scan when Task 11 rewrote it.
  hits=$( { grep -rn '<<<' "$CHECKOUT/scripts/secrets" "$CHECKOUT/secrets.sh" || true
            grep -rn '<<' "$CHECKOUT/scripts/secrets" "$CHECKOUT/secrets.sh" | grep -v "<<'USAGE'" || true; } )
  expect_true "no here-string or heredoc (except <<'USAGE') in scripts/secrets/ or secrets.sh" [ -z "$hits" ]
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

case_guard_no_personal_defaults() {
  local hits
  # Ruling 12: committed defaults must not reveal the owner's location.
  hits=$(cd "$CHECKOUT" && grep -rnE 'Copenhagen|DKK|da-DK' services home-assistant docker-compose*.yml .env.example docs || true)
  expect_true 'no personal timezone or currency defaults in compose files, .env.example or docs' [ -z "$hits" ]
  if [ -n "$hits" ]; then printf '%s\n' "$hits"; fi
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

# Paths that must never be committed, and the one .env file that must be.
GUARD_SECRET_PATHS='.env .env.prev x.agekey keys.txt secrets/a'

case_guard_gitignore_blocks() {
  local path
  new_case guard_gitignore_blocks
  cp "$CHECKOUT/.gitignore" "$REPO/.gitignore"
  # --no-index tests the patterns alone, whether or not a path is tracked.
  for path in $GUARD_SECRET_PATHS; do
    expect_true ".gitignore ignores $path" repo_git check-ignore -q --no-index "$path"
  done
  expect_true '.gitignore keeps .env.example' \
    eval '! repo_git check-ignore -q --no-index .env.example'
}

# Prints the value of KEY (files or exclude) in the forbid-secret-files hook.
hook_pattern() {
  awk -v key="$1" '
    /- id:/ { inhook = ($3 == "forbid-secret-files") }
    inhook && $1 == key":" { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
  ' "$CHECKOUT/.pre-commit-config.yaml"
}

# PATH: true when the hook would refuse PATH (files matches, exclude does not).
hook_refuses() {
  printf '%s\n' "$1" | grep -E -- "$GUARD_FILES" | grep -vqE -- "$GUARD_EXCLUDE"
}

case_guard_hook_regex() {
  local path
  GUARD_FILES=$(hook_pattern files)
  GUARD_EXCLUDE=$(hook_pattern exclude)
  expect_true 'forbid-secret-files has a files pattern' [ -n "$GUARD_FILES" ]
  expect_true 'forbid-secret-files has an exclude pattern' [ -n "$GUARD_EXCLUDE" ]
  for path in $GUARD_SECRET_PATHS sub/.env sub/x.agekey vault.kdbx a.sops.yaml .sops.yaml age-key.txt; do
    expect_true "forbid-secret-files refuses $path" hook_refuses "$path"
  done
  for path in .env.example README.md services/x.yml docs/keys.txt.md; do
    expect_true "forbid-secret-files allows $path" eval "! hook_refuses $path"
  done
}

# Scripts that docs and CI run directly must be executable in git itself: the suite runs
# them through "$BASH", so a lost mode bit would otherwise go unnoticed.
case_guard_executables_are_executable() {
  local path mode
  for path in secrets.sh setup-dev.sh scripts/secrets/setup.sh scripts/secrets/map.sh; do
    mode=$(git -C "$CHECKOUT" ls-files -s -- "$path" | cut -d ' ' -f 1)
    expect_true "$path is 100755 in git (got ${mode:-untracked})" [ "$mode" = 100755 ]
  done
}

# Every scripts/secrets/… and ./secrets.sh command that docs/secrets.md quotes names a file
# that exists, and every --flag on a setup.sh or map.sh line is one that script's --help lists.
case_docs_commands_exist() {
  local doc="$CHECKOUT/docs/secrets.md" paths path script help flag flags count=0
  new_case docs_commands_exist
  paths=$(grep -oE '(scripts/secrets/[A-Za-z0-9_./-]*[A-Za-z0-9_]|\./secrets\.sh)' "$doc" | LC_ALL=C sort -u)
  expect_true 'docs/secrets.md quotes scripts/secrets/setup.sh' eval 'printf "%s\n" "$paths" | grep -qx scripts/secrets/setup.sh'
  for path in $paths; do
    expect_true "docs/secrets.md: $path exists" [ -e "$CHECKOUT/${path#./}" ]
  done
  for script in setup map; do
    help=$(sandboxed "$BASH" "$CHECKOUT/scripts/secrets/$script.sh" --help 2>&1)
    # The text after each "$script.sh" up to the next backtick is that command's arguments.
    flags=$(awk -v name="$script.sh" '{ line = $0
        while ((i = index(line, name)) > 0) { line = substr(line, i + length(name)); arg = line
          sub(/`.*/, "", arg); print arg } }' "$doc" | grep -oE -- '(^| )--[a-z][a-z-]*' | tr -d ' ' | LC_ALL=C sort -u)
    for flag in $flags; do
      count=$((count + 1))
      case "$help" in *"$flag"*) record pass "docs/secrets.md: $script.sh $flag is in --help" ;;
        *) record fail "docs/secrets.md: $script.sh $flag is in --help" ;; esac
    done
  done
  expect_true 'docs/secrets.md quotes setup.sh flags' [ "$count" -gt 0 ]
}
