# shellcheck shell=bash
# Output helpers (✓ ✗ − !) and prompts shared by every secrets script.
# All messages and prompts go to stderr, so stdout carries only answers and values.

# Colour only for a terminal, and never when NO_COLOR is set.
ui_colour() { [ -t 2 ] && [ -z "${NO_COLOR+set}" ]; }

# SYMBOL COLOUR MESSAGE: one indented status line on stderr.
ui_line() {
  if ui_colour; then
    printf '  \033[%sm%s\033[0m %s\n' "$2" "$1" "$3" >&2
  else
    printf '  %s %s\n' "$1" "$3" >&2
  fi
}

ok() { ui_line '✓' 32 "$*"; }
fail() { ui_line '✗' 31 "$*"; }
note() { ui_line '−' 2 "$*"; }
warn() { ui_line '!' 33 "$*"; }
die() { fail "$*"; exit 1; }

# Reads one line from stdin into the named variable; dies when input has ended.
ui_read() {
  # A last line without a newline still counts as an answer.
  IFS= read -r "$1" || [ -n "${!1}" ] ||
    die 'No answer; stopping without changing anything.'
}

# QUESTION DEFAULT(y|n): returns 0 for yes. Non-interactive runs answer no.
ask_yn() {
  local question=$1 default=$2 hint='[y/N]' answer=''
  if [ "${HOMELAB_NONINTERACTIVE:-}" = 1 ]; then return 1; fi
  if [ "$default" = y ]; then hint='[Y/n]'; fi
  while :; do
    printf '%s %s ' "$question" "$hint" >&2
    ui_read answer
    case "${answer:-$default}" in
      y|Y|yes|Yes) return 0 ;;
      n|N|no|No) return 1 ;;
    esac
    note 'Please answer y or n.'
  done
}

# KEYS: space-separated keys, e.g. "1 2 n". Prints the key that was typed.
menu() {
  local keys=$1 answer='' key
  while :; do
    printf '  Choose [%s]: ' "$keys" >&2
    ui_read answer
    for key in $keys; do
      if [ "$answer" = "$key" ]; then printf '%s\n' "$key"; return 0; fi
    done
    note "Please type one of: $keys"
  done
}

# LABEL: asks twice without echo and prints the value; returns 1 on a mismatch.
read_hidden_twice() {
  local first='' second=''
  printf '  %s: ' "$1" >&2
  IFS= read -rs first || [ -n "$first" ] || die 'No answer; stopping without changing anything.'
  printf '\n  %s (again): ' "$1" >&2
  IFS= read -rs second || [ -n "$second" ] || die 'No answer; stopping without changing anything.'
  printf '\n' >&2
  if [ "$first" != "$second" ]; then fail 'The two entries differ.'; return 1; fi
  printf '%s\n' "$first"
}

# LABEL DEFAULT: asks with the default shown; Enter keeps it. Prints the value.
read_shown() {
  local answer=''
  printf '  %s [%s]: ' "$1" "$2" >&2
  ui_read answer
  printf '%s\n' "${answer:-$2}"
}

# TOOL…: dies naming every tool that is not on PATH.
require_tools() {
  local tool missing=''
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then die "Missing tools:$missing. Install them, then run this again."; fi
}
