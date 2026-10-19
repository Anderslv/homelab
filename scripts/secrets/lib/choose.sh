# shellcheck shell=bash disable=SC2086,SC2046 # profile and stack lists are space-separated on purpose
# Chooses the profile and stacks to set up, adds what they depend on and warns
# when infra is left out. It exists so setup and output share one selection:
# SELECTED_PROFILE and SELECTED_STACKS (space-separated, in include order).

SELECTED_PROFILE='' SELECTED_STACKS=''

# PROFILE: prints the stacks (include order) whose services use that profile.
choose_profile_stacks() {
  map_stacks | awk -F '\t' -v p="$1" '{ n = split($3, a, " "); for (i = 1; i <= n; i++) if (a[i] == p) { print $1; break } }'
}

# Prints every profile in compose order, without duplicates.
choose_profiles() {
  map_stacks | awk -F '\t' '{ n = split($3, a, " "); for (i = 1; i <= n; i++) if (!(a[i] in seen)) { seen[a[i]] = 1; print a[i] } }'
}

# Prints the profile the user picked from the §3.1 menu.
choose_menu() {
  local others='' keys='1 2 3 4' n=4 profile
  for profile in $(choose_profiles); do
    case "$profile" in dev|prod|infra|apps) ;; *) others="$others $profile" ;; esac
  done
  printf '%s\n' 'Which part of the homelab do you want to set up?' \
    '  [1] dev    everything, local HTTPS on localhost.me' \
    '  [2] prod   everything, real domain and Let'\''s Encrypt' \
    '  [3] infra  Traefik, Sablier, AdGuard, RustFS, NetAlertX, whoami' \
    '  [4] apps   pick stacks: immich paperless media karakeep listmonk …' >&2
  for profile in $others; do
    n=$((n + 1)); keys="$keys $n"
    printf '  [%s] %s\n' "$n" "$profile" >&2
  done
  n=$(menu "$keys")
  case "$n" in 1) echo dev ;; 2) echo prod ;; 3) echo infra ;; 4) echo apps ;;
    *) set -- $others; shift $((n - 5)); echo "$1" ;; esac
}

# STACKS…: asks which of them to set up, by number or `all`; prints the choice.
choose_pick() {
  local answer='' stack n=0 picked='' word
  printf '%s\n' 'Which stacks?' >&2
  for stack in "$@"; do n=$((n + 1)); printf '  [%s] %s\n' "$n" "$stack" >&2; done
  while :; do
    printf '  Numbers separated by spaces, or all: ' >&2
    ui_read answer
    if [ "$answer" = all ]; then echo "$*"; return 0; fi
    picked='' n=0
    for word in $answer; do
      case "$word" in *[!0-9]*|'') picked=''; break ;; esac
      n=$((word)); if [ "$n" -lt 1 ] || [ "$n" -gt $# ]; then picked=''; break; fi
      eval "stack=\${$n}"; picked="$picked $stack"
    done
    if [ -n "$picked" ]; then echo "${picked# }"; return 0; fi
    note 'Please type stack numbers from the list, or all.'
  done
}

# Adds the stacks the selection needs, saying so once per stack that pulls them in.
choose_add_deps() {
  local stack dep list count verb
  for stack in $SELECTED_STACKS; do
    list='' count=0
    for dep in $(map_stack_deps "$stack"); do
      case " $SELECTED_STACKS " in *" $dep "*) continue ;; esac
      SELECTED_STACKS="$SELECTED_STACKS $dep" list="${list:+$list, }$dep" count=$((count + 1))
    done
    if [ "$count" -eq 0 ]; then continue; fi
    verb='depends on it'
    if [ "$count" -gt 1 ]; then verb='depends on them'; fi
    printf '  + %s (%s %s)\n' "$list" "$stack" "$verb" >&2
  done
}

# Keeps SELECTED_STACKS in include order, without duplicates.
choose_order() {
  local stack ordered=''
  for stack in $(map_stacks | cut -f1); do
    case " $SELECTED_STACKS " in *" $stack "*) ordered="$ordered $stack" ;; esac
  done
  SELECTED_STACKS=${ordered# }
}

# [PROFILE [STACK…]]: sets SELECTED_PROFILE and SELECTED_STACKS; asks when no PROFILE.
choose_stacks() {
  local profile=${1:-} stack infra
  map_ready
  if [ -z "$profile" ] && [ "${HOMELAB_NONINTERACTIVE:-}" = 1 ]; then
    die '--profile is required with --auto, --env or --skip-missing'
  fi
  [ -n "$profile" ] || profile=$(choose_menu)
  [ "$#" -eq 0 ] || shift
  if ! choose_profiles | grep -qx -- "$profile"; then die "Unknown profile: $profile"; fi
  SELECTED_PROFILE=$profile SELECTED_STACKS="$*"
  if [ "$#" -gt 0 ]; then
    for stack in "$@"; do
      map_stacks | cut -f1 | grep -qx -- "$stack" || die "Unknown stack: $stack"
    done
  else
    SELECTED_STACKS=$(choose_profile_stacks "$profile" | tr '\n' ' ')
    SELECTED_STACKS=${SELECTED_STACKS% }
    case "$profile" in dev|prod|infra) ;; *)
      set -- $(for stack in $SELECTED_STACKS; do
        case " $(choose_profile_stacks infra | tr '\n' ' ') " in *" $stack "*) ;; *) echo "$stack" ;; esac
      done)
      if [ "$#" -gt 1 ] && [ "${HOMELAB_NONINTERACTIVE:-}" != 1 ]; then
        SELECTED_STACKS=$(choose_pick "$@") || return 1
      fi ;;
    esac
  fi
  choose_add_deps
  infra=$(choose_profile_stacks infra | tr '\n' ' ')
  if [ -n "$infra" ]; then
    for stack in $SELECTED_STACKS; do
      case " $infra " in *" $stack "*) infra=''; break ;; esac
    done
  fi
  if [ -n "$infra" ]; then
    warn 'infra is not selected. Traefik routes every app; without it nothing is reachable by name.'
    if ask_yn '  Set up infra too?' y; then
      SELECTED_STACKS="$SELECTED_STACKS $infra"
      choose_add_deps
    fi
  fi
  choose_order
}

# Prints the variables first setup asks for, one per line.
first_setup_vars() {
  printf '%s\n' TZ DOMAIN
  case "$SELECTED_PROFILE" in
    prod) printf '%s\n' ACME_EMAIL CF_DNS_API_TOKEN ;;
    dev) printf '%s\n' GLUETUN_HEALTHCHECK_DISABLED ;;
  esac
}
