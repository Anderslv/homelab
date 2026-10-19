# shellcheck shell=bash
# Automatic values, placeholder and format checks, the timezone prompt and a
# non-executing .env reader. It exists so setup and fill share one set of rules.

# Prints N random characters from the set CLASS (a tr set). `|| true` because head
# closing the pipe can make tr exit with SIGPIPE under pipefail.
random_chars() {
  local out
  out=$(LC_ALL=C tr -dc "$1" </dev/urandom | head -c "$2" || true)
  printf '%s\n' "$out"
}

# VAR KIND SENSITIVITY: prints a generated value, or returns 1 when none applies.
auto_value() {
  local var=$1 kind=$2
  case "$var" in
    GLUETUN_HEALTHCHECK_DISABLED)
      if [ "${SELECTED_PROFILE:-}" = dev ]; then printf 'true\n'; return 0; fi
      return 1 ;;
    OPENVPN_*) return 1 ;;
    SPEEDTEST_APP_KEY) head -c 32 /dev/urandom | base64 | tr -d '\n'; printf '\n'; return 0 ;;
    DUMBASSETS_PIN) random_chars '0-9' 6; return 0 ;;
    RUSTFS_ACCESS_KEY) random_chars 'A-Za-z0-9' 20; return 0 ;;
    RUSTFS_SECRET_KEY) random_chars 'A-Za-z0-9' 40; return 0 ;;
  esac
  if [ "$kind" = required ] && [ "${3:-}" = secret ]; then
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    printf '\n'
    return 0
  fi
  return 1
}

# VALUE: returns 0 when it is a placeholder that must never be imported.
is_placeholder() {
  case "$1" in
    1234|local-openvpn-user|local-openvpn-password|rustadmin|ci-*|CHANGEME*) return 0 ;;
  esac
  return 1
}

# VAR VALUE: returns 0 when valid; otherwise says why on stderr and returns 1.
validate() {
  case "$1" in
    TZ)
      if [ "$2" = UTC ] || printf '%s' "$2" | grep -Eq '^[A-Za-z]+(/[A-Za-z0-9_+-]+)+$'; then return 0; fi
      fail 'TZ must be UTC or a name like Europe/Berlin.' ;;
    DOMAIN)
      if printf '%s' "$2" | grep -Eq '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'; then return 0; fi
      fail 'DOMAIN must look like example.com.' ;;
    ACME_EMAIL)
      if printf '%s' "$2" | grep -Eq '^[^@ ]+@[^@ ]+\.[^@ ]+$'; then return 0; fi
      fail 'ACME_EMAIL must look like name@example.com.' ;;
    age-key-label)
      if printf '%s' "$2" | grep -Eq '^[A-Za-z0-9_-]+$'; then return 0; fi
      fail 'The label may only use letters, digits, - and _.' ;;
    *)
      if [ -n "$2" ]; then return 0; fi
      fail "$1 must not be empty." ;;
  esac
  return 1
}

# Shows the quick picks on stderr and prints the chosen IANA name on stdout.
ask_timezone() {
  local pick zone=''
  {
    printf '  Timezone:\n'
    printf '  [1] Europe/Berlin\n  [2] America/Vancouver\n  [3] Asia/Kathmandu\n  [4] Asia/Taipei\n  [o] other\n'
  } >&2
  pick=$(menu '1 2 3 4 o')
  case "$pick" in
    1) zone=Europe/Berlin ;;
    2) zone=America/Vancouver ;;
    3) zone=Asia/Kathmandu ;;
    4) zone=Asia/Taipei ;;
    o)
      while :; do
        printf '  IANA name (e.g. Europe/Paris): ' >&2
        ui_read zone
        if validate TZ "$zone"; then break; fi
      done ;;
  esac
  printf '%s\n' "$zone"
}

# FILE VAR: prints VAR's value from a .env file without executing anything.
# Last occurrence wins; returns 1 when VAR is not set.
dotenv_value() {
  local line key value rest tail prefix found=1 result=''
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      export[[:space:]]*) line=${line#export}; line=${line#"${line%%[![:space:]]*}"} ;;
    esac
    key=${line%%=*}
    key=${key%"${key##*[![:space:]]}"}
    if [ "$key" != "$2" ] || [ "$key" = "$line" ]; then continue; fi
    value=${line#*=}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    rest='' tail=''
    case "$value" in
      \"*\"*) rest=${value#\"}; tail=${rest#*\"}; rest=${rest%%\"*} ;;
      \'*\'*) rest=${value#\'}; tail=${rest#*\'}; rest=${rest%%\'*} ;;
      *) tail=x ;;
    esac
    tail=${tail#"${tail%%[![:space:]]*}"}
    case "$tail" in
      ''|'#'*) value=$rest ;;
      *)
        prefix=${value//$'\t'/ }
        case "$prefix" in *' #'*) prefix=${prefix%% \#*}; value=${value:0:${#prefix}} ;; esac
        value=${value%"${value##*[![:space:]]}"} ;;
    esac
    result=$value found=0
  done <"$1"
  if [ "$found" = 0 ]; then printf '%s\n' "$result"; fi
  return "$found"
}

# FILE: dies when git tracks FILE. A file outside any repository is not tracked.
dotenv_refuse_tracked() {
  if git -C "$(dirname "$1")" ls-files --error-unmatch -- "$(basename "$1")" >/dev/null 2>&1; then
    die "$1 is tracked by git; refusing to read secrets from it."
  fi
  return 0
}
