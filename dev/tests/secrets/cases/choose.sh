# shellcheck shell=bash disable=SC2016,SC2034 # sandboxed bash -c scripts; OUT/STATUS feed expect_*
# Choose cases: lib/choose.sh picks the profile and stacks, adds dependencies and
# warns when infra is left out. Sourced by dev/tests/secrets-setup.test.sh; see harness.sh.

# ANSWERS [ENV=VALUE…] -- ARG…: runs choose_stacks ARG… with ANSWERS on stdin and
# prints the result as `profile=… stacks=…`; sets OUT (messages and result), STATUS.
choose_run() {
  local answers=$1
  shift
  STATUS=0
  OUT=$(printf '%b' "$answers" | sandboxed "$@" 2>&1) || STATUS=$?
}

choose_call() {
  local answers=$1
  shift
  choose_run "$answers" "$BASH" -c 'set -euo pipefail
    d=$1; shift; . "$d/ui.sh"; . "$d/config.sh"; . "$d/map.sh"; . "$d/choose.sh"
    secrets_paths; choose_stacks "$@"
    printf "profile=%s stacks=%s\n" "$SELECTED_PROFILE" "$SELECTED_STACKS"' _ "$CHECKOUT/scripts/secrets/lib" "$@"
}

case_choose_profile_dev_selects_all() {
  new_case choose_profile_dev_selects_all
  choose_call '1\n'
  expect_status 0
  expect_out '[1] dev    everything, local HTTPS on localhost.me'
  expect_out '[4] apps   pick stacks'
  expect_out 'profile=dev stacks=networking alpha beta gamma'
  expect_no_out 'dockhand'
  expect_no_out 'infra is not selected'
}

case_choose_apps_pick_stack() {
  new_case choose_apps_pick_stack
  choose_call '4\n1\nn\n'
  expect_status 0
  expect_out 'profile=apps stacks=alpha'
  expect_out '! infra is not selected.'
}

case_choose_adds_dependency_and_says_so() {
  new_case choose_adds_dependency_and_says_so
  choose_call '4\n2\nn\n'
  expect_status 0
  expect_out '+ gamma (beta depends on it)'
  expect_out 'profile=apps stacks=beta gamma'
}

case_choose_infra_warning_accept() {
  new_case choose_infra_warning_accept
  choose_call '4\n1\n\n'
  expect_status 0
  expect_out '! infra is not selected. Traefik routes every app; without it nothing is reachable by name.'
  expect_out 'Set up infra too? [Y/n]'
  expect_out 'profile=apps stacks=networking alpha'
}

case_choose_infra_warning_decline() {
  new_case choose_infra_warning_decline
  choose_call '4\nall\nn\n'
  expect_status 0
  expect_out 'profile=apps stacks=alpha beta gamma'
}

case_choose_flags_noninteractive() {
  new_case choose_flags_noninteractive
  choose_run '' env HOMELAB_NONINTERACTIVE=1 "$BASH" -c 'set -euo pipefail
    d=$1; shift; . "$d/ui.sh"; . "$d/config.sh"; . "$d/map.sh"; . "$d/choose.sh"
    secrets_paths; choose_stacks "$@"
    printf "profile=%s stacks=%s\n" "$SELECTED_PROFILE" "$SELECTED_STACKS"' _ "$CHECKOUT/scripts/secrets/lib" apps beta
  expect_status 0
  expect_out '+ gamma (beta depends on it)'
  expect_out '! infra is not selected.'
  expect_out 'profile=apps stacks=beta gamma'
  choose_run '' env HOMELAB_NONINTERACTIVE=1 "$BASH" -c 'set -euo pipefail
    d=$1; shift; . "$d/ui.sh"; . "$d/config.sh"; . "$d/map.sh"; . "$d/choose.sh"
    secrets_paths; choose_stacks "$@"
    printf "profile=%s stacks=%s\n" "$SELECTED_PROFILE" "$SELECTED_STACKS"' _ "$CHECKOUT/scripts/secrets/lib" prod
  expect_out 'profile=prod stacks=networking alpha beta gamma'
  choose_run '' env HOMELAB_NONINTERACTIVE=1 "$BASH" -c 'set -euo pipefail
    d=$1; shift; . "$d/ui.sh"; . "$d/config.sh"; . "$d/map.sh"; . "$d/choose.sh"
    secrets_paths; choose_stacks "$@"
    printf "profile=%s stacks=%s\n" "$SELECTED_PROFILE" "$SELECTED_STACKS"' _ "$CHECKOUT/scripts/secrets/lib" apps dockhand
  expect_out 'profile=apps stacks=dockhand'
  choose_run '' env HOMELAB_NONINTERACTIVE=1 "$BASH" -c 'set -euo pipefail
    d=$1; shift; . "$d/ui.sh"; . "$d/config.sh"; . "$d/map.sh"; . "$d/choose.sh"
    secrets_paths; choose_stacks "$@"' _ "$CHECKOUT/scripts/secrets/lib" nonsense
  expect_true 'unknown profile fails' [ "$STATUS" != 0 ]
  expect_out 'Unknown profile: nonsense'
}

# PROFILE: prints first_setup_vars for SELECTED_PROFILE=PROFILE on one line.
first_vars() {
  choose_run '' "$BASH" -c 'set -euo pipefail
    d=$1; . "$d/ui.sh"; . "$d/config.sh"; . "$d/map.sh"; . "$d/choose.sh"
    SELECTED_PROFILE=$2; printf "vars=%s\n" "$(first_setup_vars | tr "\n" " ")"' _ "$CHECKOUT/scripts/secrets/lib" "$1"
}

case_first_setup_prod_adds_acme() {
  new_case first_setup_prod_adds_acme
  first_vars prod
  expect_out 'vars=TZ DOMAIN ACME_EMAIL CF_DNS_API_TOKEN '
  first_vars apps
  expect_out 'vars=TZ DOMAIN '
}

case_first_setup_dev_adds_gluetun() {
  new_case first_setup_dev_adds_gluetun
  first_vars dev
  expect_out 'vars=TZ DOMAIN GLUETUN_HEALTHCHECK_DISABLED '
}

# Non-interactive runs never read stdin: apps without stacks selects them all.
case_choose_noninteractive_apps_selects_all() {
  new_case choose_noninteractive_apps_selects_all
  choose_run '' env HOMELAB_NONINTERACTIVE=1 "$BASH" -c 'set -euo pipefail
    d=$1; shift; . "$d/ui.sh"; . "$d/config.sh"; . "$d/map.sh"; . "$d/choose.sh"
    secrets_paths; choose_stacks "$@"
    printf "profile=%s stacks=%s\n" "$SELECTED_PROFILE" "$SELECTED_STACKS"' _ "$CHECKOUT/scripts/secrets/lib" apps </dev/null
  expect_status 0
  expect_out 'profile=apps stacks=alpha beta gamma'
  expect_out '! infra is not selected.'
}

case_choose_noninteractive_needs_profile() {
  new_case choose_noninteractive_needs_profile
  choose_run '' env HOMELAB_NONINTERACTIVE=1 "$BASH" -c 'set -euo pipefail
    d=$1; shift; . "$d/ui.sh"; . "$d/config.sh"; . "$d/map.sh"; . "$d/choose.sh"
    secrets_paths; choose_stacks' _ "$CHECKOUT/scripts/secrets/lib" </dev/null
  expect_true 'fails without a profile' [ "$STATUS" != 0 ]
  expect_out '--profile is required with --auto, --env or --skip-missing'
}
