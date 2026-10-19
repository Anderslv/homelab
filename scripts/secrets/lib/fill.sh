# shellcheck shell=bash disable=SC2086 # MISSING is a space-separated list of names
# Check and Fill (spec §3.2, §3.3): which selected variables have a value, then asking for
# the missing ones, most important first. It exists so setup.sh only tells the story: every
# accepted value lands in PENDING_JSON in memory, and setup writes it to KeePassXC once.

MISSING='' REFUSED='' PENDING_JSON='{}' FILL_ROWS='' FILL_ENV_FILE='' FILL_LINKED='' FILL_LIVE='' FILL_DOWN_SAID=''
FILL_TAB=$(printf '\t') FILL_US=$(printf '\037')

# JSON VAR VALUE: prints JSON with VAR set to VALUE. The value never becomes an argument:
# it reaches `jq -Rs .` on stdin, and the second jq reads the map and that string as two inputs.
json_put() { { printf '%s\n' "$1"; printf '%s' "$3" | jq -Rs .; } | jq -cs --arg k "$2" '.[0] + {($k): .[1]}'; }
fill_put() { PENDING_JSON=$(json_put "$PENDING_JSON" "$1" "$2"); }
fill_pending() { printf '%s' "$PENDING_JSON" | jq -e --arg k "$1" 'has($k)' >/dev/null; }
fill_interactive() { [ "${HOMELAB_NONINTERACTIVE:-}" != 1 ]; }
fill_env_path() { [ -n "$FILL_ENV_FILE" ] || FILL_ENV_FILE=$(read_shown '.env file to import from' "$REPO/.env") || exit 1; }

# Prints example_rows for the core section and SELECTED_STACKS, in map order.
fill_rows() { example_rows "$REPO/.env.example" | awk -F '\t' -v s=" core $SELECTED_STACKS " 'index(s, " " $1 " ")'; }

# VAR COLUMN: one field of VAR's row: 1 section, 3 kind, 4 default, 5 sensitivity, 6 description.
fill_field() { printf '%s\n' "$FILL_ROWS" | awk -F '\t' -v v="$1" -v c="$2" '$2 == v { print $c; exit }'; }

# VAR: offers VAR from a linked secrets.yaml (decrypted once per run); 0 when taken.
fill_linked() {
  if [ -z "$FILL_LINKED" ]; then
    FILL_LINKED='{}'
    if [ -f "$SOPS_FILE" ] && ! FILL_LINKED=$(sops decrypt --output-type json "$SOPS_FILE" 2>/dev/null); then
      FILL_LINKED='{}'
      note "secrets.yaml does not decrypt with $AGE_KEY_FILE; not using it."
    fi
  fi
  printf '%s' "$FILL_LINKED" | jq -e --arg k "$1" '(.[$k] // "") != ""' >/dev/null || return 1
  note "$1 found in secrets.yaml"
  ask_yn '  Store it in KeePassXC?' y || return 1
  PENDING_JSON=$(printf '%s\n%s\n' "$PENDING_JSON" "$FILL_LINKED" | jq -cs --arg k "$1" '.[0] + {($k): .[1][$k]}')
}

# ROWS CURRENT_JSON: prints ✓/✗/− per variable and sets MISSING, in map order.
check_values() {
  local first have var kind default
  FILL_ROWS=$1 MISSING=''
  first=" $(first_setup_vars | tr '\n' ' ') "
  have=" $(printf '%s' "$2" | jq -r 'to_entries[] | select(.value != null and .value != "") | .key' | tr '\n' ' ') "
  # Fields split on a unit separator, not a tab, so `read` keeps empty ones; fd 3 leaves
  # stdin to the questions.
  while IFS=$FILL_US read -r _ var kind default _ <&3; do
    if [ -z "$var" ]; then continue; fi
    case "$have" in *" $var "*) ok "$var in KeePassXC"; continue ;; esac
    if fill_linked "$var"; then continue; fi
    case "$kind$first" in required*|*" $var "*) fail "$var missing"; MISSING="${MISSING:+$MISSING }$var" ;;
      default*) note "$var uses default $default" ;;
      *) note "$var is optional and not set" ;;
    esac
  done 3< <(printf '%s\n' "$1" | tr '\t' "$FILL_US")
}

# VAR: 0 when VAR's stack (every selected stack for core) holds no data; otherwise
# prints the spec §3.6 reason and returns 1. Each stack is checked once per run.
fill_live_ok() {
  local var=$1 stacks stack line reason=''
  stacks=$(fill_field "$var" 1)
  if [ "$stacks" = core ]; then stacks=$SELECTED_STACKS; fi
  for stack in $stacks; do
    line=$(printf '%s\n' "$FILL_LIVE" | grep "^$stack$FILL_TAB" || true)
    if [ -z "$line" ]; then line="$stack$FILL_TAB$(live_data_reason "$stack" || true)" FILL_LIVE="$FILL_LIVE$line"$'\n'; fi
    reason=${line#*"$FILL_TAB"}
    if [ -n "$reason" ]; then break; fi
  done
  if [ -z "$reason" ]; then return 0; fi
  if [ "$reason" != docker-down ]; then
    warn "$stack already has data ($reason)."
    printf '    A new %s would lock %s out of its database.\n    Import it from .env [e] or type the current value [m].\n' \
      "$var" "$(printf '%s\n' "$stack" | awk '{ print toupper(substr($0, 1, 1)) substr($0, 2) }')" >&2
  elif [ -z "$FILL_DOWN_SAID" ]; then
    FILL_DOWN_SAID=1
    fail "Docker is not running, so I can't check whether your stacks already hold data."
    printf '%s\n' '    A new password for a stack that has data would lock its apps out of their databases.' \
      '    Start Docker and rerun, or import from .env [e] / type the current value [m].' >&2
  fi
  return 1
}

# VAR…: imports these from FILL_ENV_FILE (parsed, never sourced) after listing them;
# placeholders are ignored. Non-interactive runs (--env) take them without asking.
fill_import() {
  local var value found='{}' n=0
  fill_env_path
  dotenv_refuse_tracked "$FILL_ENV_FILE"
  if [ ! -f "$FILL_ENV_FILE" ]; then
    fill_interactive || die "No file at $FILL_ENV_FILE."
    fail "No file at $FILL_ENV_FILE."; FILL_ENV_FILE=''; return 1
  fi
  for var in "$@"; do
    if ! value=$(dotenv_value "$FILL_ENV_FILE" "$var") || [ -z "$value" ]; then continue; fi
    if is_placeholder "$value"; then note "$var: ignoring a placeholder value"; continue; fi
    found=$(json_put "$found" "$var" "$value") n=$((n + 1))
    if [ "$(fill_field "$var" 5)" = secret ]; then value='••••'; fi
    printf '    %s=%s\n' "$var" "$value" >&2
  done
  if [ "$n" = 0 ]; then note "No values for these in $FILL_ENV_FILE."; return 1; fi
  if fill_interactive && ! ask_yn "  Store these $n values?" n; then note 'Nothing imported.'; return 1; fi
  PENDING_JSON=$(printf '%s\n%s\n' "$PENDING_JSON" "$found" | jq -cs '.[0] + .[1]')
  ok "Took $n values from $FILL_ENV_FILE"
}

# VAR KIND SENSITIVITY: asks for the value; returns 1 to show the menu again.
fill_enter() {
  local value out
  if [ "$1" = TZ ]; then value=$(ask_timezone) || exit 1
  elif [ "$3" = secret ]; then
    # Exit status 1 means input ended (ui.sh already said so); empty output means the two
    # entries differed; otherwise the value comes with a trailing "|" that keeps its newlines.
    out=$(if read_hidden_twice "$1"; then printf '|'; fi) || exit 1
    if [ -z "$out" ]; then return 1; fi
    value=${out%$'\n|'}
  else
    value=$(auto_value "$1" "$2" "$3" || fill_field "$1" 4)
    value=$(read_shown "$1" "$value") || exit 1
  fi
  validate "$1" "$value" || return 1
  if [ "$3" != secret ] && [ "$1" != TZ ] && ! ask_yn "  Use $value for $1?" y; then return 1; fi
  fill_put "$1" "$value"
  ok "$1 set"
}

# VAR AUTO(yes|no): fills one variable, generating it without asking when AUTO=yes.
# Returns 2 for "skip all remaining", 3 when live data refused it in a non-interactive run.
fill_one() {
  local var=$1 kind sens value keys='e m s S' choice
  if ! fill_interactive && [ "$2" != yes ]; then return 0; fi
  kind=$(fill_field "$var" 3) sens=$(fill_field "$var" 5)
  if value=$(auto_value "$var" "$kind" "$sens"); then
    if [ "$sens" = secret ] && ! fill_live_ok "$var"; then
      fill_interactive || return 3
    elif [ "$2" = yes ]; then fill_put "$var" "$value"; ok "$var set automatically"; return 0
    else keys="a $keys"; fi
  fi
  fill_interactive || return 0
  printf '\n  %s (%s · %s): %s\n' "$var" "$kind" "$sens" "$(fill_field "$var" 6)" >&2
  case "$keys" in a*) printf '  [a] automatically' >&2 ;; esac
  printf '  [e] from a .env file  [m] enter now  [s] skip  [S] skip all remaining\n' >&2
  while :; do
    choice=$(menu "$keys") || exit 1
    case "$choice" in
      a) fill_put "$var" "$value"; ok "$var set automatically"; return 0 ;;
      e) if fill_import "$var"; then return 0; fi ;;
      m) if fill_enter "$var" "$kind" "$sens"; then return 0; fi ;;
      s) note "$var skipped"; return 0 ;;
      S) return 2 ;;
    esac
  done
}

# MODE (ask|auto|env|skip): fills MISSING into PENDING_JSON and sets REFUSED.
fill_missing() {
  local mode=$1 var status
  REFUSED=''
  set -- $MISSING
  if [ "$#" = 0 ] || [ "$mode" = skip ]; then return 0; fi
  if [ "$mode" = ask ]; then
    printf '\n%s variables missing. How do you want to set them?\n' "$#" >&2
    printf '%s\n' '  [a] automatically where possible, asking for the rest' '  [e] from a .env file, asking for the rest' \
      '  [g] guided, choosing for each variable' '  [s] skip all for now' >&2
    mode=$(menu 'a e g s') || exit 1
    case "$mode" in a) mode=auto ;; e) mode='env' ;; g) mode=guided ;; s) return 0 ;; esac
  fi
  if [ "$mode" = env ]; then fill_import $MISSING || true; fi
  for var in $MISSING; do
    if fill_pending "$var"; then continue; fi
    status=0
    if [ "$mode" = auto ]; then fill_one "$var" yes || status=$?; else fill_one "$var" no || status=$?; fi
    case "$status" in 2) note 'Skipped the rest.'; break ;; 3) REFUSED="${REFUSED:+$REFUSED }$var" ;; esac
  done
}

# Prints the MISSING names that Fill left without a value.
fill_still_missing() { local var; for var in $MISSING; do fill_pending "$var" || printf '%s ' "$var"; done; }
