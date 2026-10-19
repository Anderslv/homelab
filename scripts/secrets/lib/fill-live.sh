# shellcheck shell=bash
# Fill's live-data guardrail (spec §3.6): no automatic secrets for a stack that holds data.
# Split from fill.sh to keep both short (Ruling 21). Source ui.sh, map.sh, values.sh,
# docker.sh (live_data_reason) and fill.sh (fill_field) first.

FILL_LIVE='' FILL_DOWN_SAID='' FILL_TAB=$(printf '\t')

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
