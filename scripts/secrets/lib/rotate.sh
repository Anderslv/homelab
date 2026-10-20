# shellcheck shell=bash
# Rotation (spec §3.3): --rotate VAR replaces one value, or sets an unset default or optional
# one; --rotate age-key moves to a new age key; --finish-age-key-rotation drops the old one.
# Split from fill.sh, whose helpers it reuses; the normal Store and Write steps do the rest.

# VAR MODE: dies unless VAR is age-key or a variable of this run's stacks (naming the closest
# names for an unknown one), or when MODE cannot give it a new value. Runs before the unlock.
rotate_check() {
  local var=$1 section close
  if [ "$var" = age-key ]; then return 0; fi
  section=$(example_rows "$REPO/.env.example" | awk -F '\t' -v v="$var" '$2 == v { print $1; exit }')
  if [ -z "$section" ]; then
    # Names that contain the typed one (any case) first, then names sharing its first word.
    close=$(example_rows "$REPO/.env.example" | cut -f 2 | awk -v q="$(printf '%s' "$var" | tr '[:lower:]' '[:upper:]')" '
      index($0, q) || index(q, $0) { a = a " " $0; next }
      { p = q; sub(/_.*/, "", p) } p != "" && index($0, p "_") == 1 { b = b " " $0 }
      END { n = split(a b, w, " "); for (i = 1; i <= n && i <= 5; i++) printf "%s%s", (i > 1 ? " " : ""), w[i] }')
    if [ -n "$close" ]; then die "Unknown variable $var. Closest: $close"; fi
    die "Unknown variable $var; .env.example lists every variable."
  fi
  case " core $SELECTED_STACKS " in *" $section "*) ;;
    *) die "$var belongs to $section, which this run does not set up; add $section to the stacks." ;;
  esac
  if [ "$2" = skip ]; then die '--rotate needs a new value: use it alone, or with --auto or --env FILE.'; fi
}

# VAR MODE CURRENT_JSON: puts VAR's new value in PENDING_JSON and marks it as the one change
# the outputs may make without asking. [c] ends the run with nothing changed.
rotate_var() {
  local var=$1 mode=$2 kind sens current value='' keys='e m c' choice status
  kind=$(fill_field "$var" 3) sens=$(fill_field "$var" 5)
  current=$(printf '%s' "$3" | jq -r --arg k "$var" '.[$k] // ""')
  if [ -z "$current" ] && [ "$kind" = required ]; then
    die "$var has no value yet; run setup.sh without --rotate to set it."
  fi
  # shellcheck disable=SC2034 # output.sh reads it
  OUTPUT_EXPECTED=$var
  printf '\nRotating %s (%s · %s): %s\n' "$var" "$kind" "$sens" "$(fill_field "$var" 6)" >&2
  if [ -n "$current" ] && [ "$sens" != secret ]; then note "Current value: $current"; fi
  if [ -n "$current" ]; then note 'KeePassXC keeps the old value in the history of the vars entry.'; fi
  if value=$(auto_value "$var" "$kind" "$sens"); then keys="a $keys"; fi
  case "$mode" in
    auto)
      [ -n "$value" ] || die "No automatic value for $var; use --env FILE or run without --auto."
      if [ "$sens" = secret ] && ! fill_live_ok "$var"; then exit 1; fi
      fill_put "$var" "$value"; ok "$var set automatically" ;;
    env) fill_import "$var" || die "No new value for $var in $FILL_ENV_FILE; nothing changed." ;;
    *)
      printf '  ' >&2
      case "$keys" in a*) printf '[a] automatically  ' >&2 ;; esac
      printf '[e] from a .env file  [m] enter now  [c] cancel\n' >&2
      while :; do
        choice=$(menu "$keys") || exit 1
        case "$choice" in
          a) if [ "$sens" != secret ] || fill_live_ok "$var"; then fill_put "$var" "$value"; ok "$var set automatically"; break; fi ;;
          e) status=2
            while [ "$status" = 2 ]; do status=0; fill_import "$var" || status=$?; done
            if [ "$status" = 0 ]; then break; fi ;;
          m) if fill_enter "$var" "$kind" "$sens"; then break; fi ;;
          c) note 'Rotation cancelled; nothing changed.'; exit 0 ;;
        esac
        note 'Not rotated; choose again.'
      done ;;
  esac
  if printf '%s\n%s\n' "$3" "$PENDING_JSON" | jq -se --arg k "$var" '.[0][$k] == .[1][$k]' >/dev/null; then
    note "$var already has this value; nothing to change."
  fi
}

# Keeps the current age key in age-key-previous (so other machines recognise it), then
# stores a new one; refused while an earlier rotation is unfinished.
rotate_age_key() {
  local old new status=0 previous="$VAULT_GROUP/age-key-previous"
  if vault_previous_age_key >/dev/null; then
    fail "$previous still holds the key from an earlier rotation."
    die 'Finish that one first: run setup.sh on every machine, then setup.sh --finish-age-key-rotation.'
  fi
  old=$(vault_age_key) || status=$?
  case "$status" in
    0) ;;
    3) die "$VAULT_GROUP/age-key holds no age key yet; run setup.sh without --rotate to make one." ;;
    4) die "$VAULT_GROUP/age-key does not hold an age key; fix it in KeePassXC." ;;
    *) exit 1 ;;
  esac
  vault_put_age_key "$previous" "$old"
  [ "$(vault_previous_age_key)" = "$old" ] || die "Could not keep the old age key in $previous; stopping."
  ok "Kept the old age key in $previous"
  new=$(age-keygen 2>/dev/null) || die 'age-keygen could not make a new key.'
  vault_put_age_key "$VAULT_GROUP/age-key" "$new" force
  [ "$(vault_age_key)" = "$new" ] || die "$VAULT_GROUP/age-key did not read back the new key; the old one is in $previous."
  ok "Stored a new age key in $VAULT_GROUP/age-key"
  note 'Run setup.sh on every other machine to install it, then setup.sh --finish-age-key-rotation.'
}

ROTATE_PREVIOUS='' ROTATE_PREVIOUS_READ='' ROTATE_OLD_KEY=''

# Sets ROTATE_PREVIOUS to age-key-previous (empty when there is none); reads it once per run.
rotate_read_previous() {
  local status=0
  if [ -n "$ROTATE_PREVIOUS_READ" ]; then return 0; fi
  ROTATE_PREVIOUS=$(vault_previous_age_key) || status=$?
  if [ "$status" = 3 ]; then ROTATE_PREVIOUS=''; elif [ "$status" != 0 ]; then exit 1; fi
  ROTATE_PREVIOUS_READ=1
}

# KEY: reads age-key-previous when the local key file holds a key other than KEY, so
# install_age_key can tell a key a rotation replaced from an unrelated one.
rotate_previous_for() {
  if [ -f "$AGE_KEY_FILE" ] && ! age_key_file_holds "$(age_key_secret "$1")"; then rotate_read_previous; fi
}

# Sets ROTATE_OLD_KEY when secrets.yaml does not decrypt with the installed key: from
# age-key-previous, or else the newest keys.txt.rotated-* this machine kept.
rotate_old_key_for_sops() {
  local file
  ROTATE_OLD_KEY=''
  if [ ! -f "$SOPS_FILE" ] || sops decrypt "$SOPS_FILE" >/dev/null 2>&1; then return 0; fi
  rotate_read_previous
  ROTATE_OLD_KEY=$ROTATE_PREVIOUS
  if [ -n "$ROTATE_OLD_KEY" ]; then return 0; fi
  for file in "$AGE_KEY_FILE".rotated-*; do
    if [ -f "$file" ]; then ROTATE_OLD_KEY=$(cat "$file"); fi
  done
}

# Moves age-key-previous to KeePassXC's recycle bin once every machine has the new key.
finish_age_key_rotation() {
  local previous="$VAULT_GROUP/age-key-previous" status=0 rotated
  vault_previous_age_key >/dev/null || status=$?
  if [ "$status" = 3 ]; then note 'No previous age key in KeePassXC; nothing to finish.'; return 0; fi
  printf '\nEvery machine should have run setup.sh since the rotation, so it holds the new age key.\n' >&2
  if fill_interactive && ! ask_yn "  Move $previous to KeePassXC's recycle bin?" y; then note "Kept $previous."; return 0; fi
  vault_backup
  kp rm "$previous" >/dev/null || die "Could not remove $previous."
  status=0
  vault_previous_age_key >/dev/null || status=$?
  [ "$status" = 3 ] || die "$previous is still there after removing it."
  ok "Moved $previous to the recycle bin"
  for rotated in "$AGE_KEY_FILE".rotated-*; do
    if [ -e "$rotated" ]; then note "Old local key kept at $rotated; delete it once you're sure."; fi
  done
}
