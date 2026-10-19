# shellcheck shell=bash
# Writes ~/.config/homelab-secrets/compose.yml: docker-compose.yml's include list with only
# the stacks you set up active, so a partial setup runs. Source ui.sh, map.sh and output.sh first.

# PROFILES: the profile for a "not set up" hint: SELECTED_PROFILE when the stack has
# it, else its first profile other than dev and prod.
output_hint_profile() {
  local p
  case " $1 " in *" ${SELECTED_PROFILE:-none} "*) printf '%s\n' "$SELECTED_PROFILE"; return ;; esac
  for p in $1; do case "$p" in dev|prod) ;; *) printf '%s\n' "$p"; return ;; esac; done
  printf '%s\n' "${1%% *}"
}

# LINE: "active", "commented out" or "absent" for an include line.
output_state() { case "$1" in '') echo absent ;; *'# - '*) echo 'commented out' ;; *) echo active ;; esac; }

# SERVICES SET_NAMES ROWS: true when every required variable SERVICES use is set
# (ROWS from map_rows, read once because it runs jq over the whole project).
output_stack_ready() {
  printf '%s\n' "$3" | awk -F '\t' -v list=" $1 " -v set=" $2 " '$3 == "required" && !index(set, " " $2 " ") {
    n = split($6, used, " "); for (i = 1; i <= n; i++) if (index(list, " " used[i] " ")) bad = 1 } END { exit bad }'
}

# WANT_JSON: rewrites compose.yml. A stack is active when it is in SELECTED_STACKS or
# already active there, and every required variable it uses is set. Lines commented
# by hand stay; other changes are listed and confirmed (non-interactive runs apply them).
write_local_compose() {
  local set rows hand='' old='' new was kind file comment info stack path line changes='' tab
  tab=$(printf '\t')
  case "$REPO" in *[\"\\\$]*) die "The repository path $REPO contains a quote, backslash or \$." ;; esac
  set=$(printf '%s' "$1" | jq -r 'to_entries[] | select((.value // "") | tostring != "") | .key' | tr '\n' ' ')
  rows=$(map_rows)
  if [ -f "$LOCAL_COMPOSE" ]; then
    old=$(cat "$LOCAL_COMPOSE")
    hand=$(printf '%s\n' "$old" | sed -n '/not set up:/d; s/^[[:space:]]*#[[:space:]]*-[[:space:]]*"\([^"]*\)".*/\1/p')
  fi
  new="# $LOCAL_COMPOSE. Written by scripts/secrets/setup.sh; edit freely.
# Stacks you have not set up are commented out. Run setup.sh again to add one.
# Commented include lines you add by hand are kept; other edits are replaced on the next run.
name: homelab
include:"
  while IFS=$tab read -r kind file comment; do
    if [ "$kind" = C ]; then new="$new
$file"; continue; fi
    info=$(map_stacks | awk -F '\t' -v f="$file" '$2 == f { print $1 "\t" $3 "\t" $4 }')
    stack=${info%%"$tab"*} path="$REPO/$file"
    was=$(printf '%s\n' "$old" | grep -F "\"$path\"" | head -n 1 || true)
    line=$was
    if printf '%s\n' "$hand" | grep -qxF "$path"; then :
    elif { case " ${SELECTED_STACKS:-} " in *" $stack "*) true ;; *) [ "$(output_state "$was")" = active ] ;; esac; } &&
        output_stack_ready "${info##*"$tab"}" "$set" "$rows"; then
      line="  - \"$path\"${comment:+  # $comment}"
    else line="  # - \"$path\"  # not set up: scripts/secrets/setup.sh --profile $(output_hint_profile "$(printf '%s\n' "$info" | cut -f 2)") $stack"
    fi
    if [ "$(output_state "$was")" != "$(output_state "$line")" ]; then changes="$changes$stack ($(output_state "$line"))
"; fi
    new="$new
$line"
  done < <(output_includes)
  if [ -n "$old" ]; then
    if [ "$old" = "$new" ]; then ok 'compose.yml is up to date'; return 0; fi
    printf '  compose.yml will change:\n' >&2
    printf '%s' "${changes:-comments and hints only
}" | while IFS= read -r line; do note "$line"; done
    if [ "${HOMELAB_NONINTERACTIVE:-}" != 1 ] && ! ask_yn '  Write compose.yml?' y; then
      note 'Left compose.yml unchanged.'; return 0
    fi
  fi
  output_dir "$SECRETS_DIR"
  rm -f "$LOCAL_COMPOSE.tmp"
  { (umask 077 && printf '%s\n' "$new" > "$LOCAL_COMPOSE.tmp") && output_commit "$LOCAL_COMPOSE.tmp" "$LOCAL_COMPOSE"; } ||
    die "Could not write $LOCAL_COMPOSE."
  ok "Wrote $LOCAL_COMPOSE"
}

# docker-compose.yml's include block as "I<TAB>file<TAB>comment" for each entry and
# "C<TAB>line" for each indented comment or blank line between entries.
output_includes() {
  awk '/^include:/ { inside = 1; next } /^[^ #]/ { inside = 0 } !inside { next }
    /^ *- / { file = $0; sub(/^ *- *(path: *)?/, "", file); comment = ""
      if (index(file, "#")) { comment = file; sub(/^[^#]*# */, "", comment); sub(/ *#.*/, "", file) }
      gsub(/^["'"'"']|["'"'"'] *$/, "", file); sub(/ +$/, "", file)
      printf "%s", blanks; blanks = ""; printf "I\t%s\t%s\n", file, comment; next }
    /^$/ { blanks = blanks "C\t\n"; next }
    /^ +#/ { printf "%s", blanks; blanks = ""; printf "C\t%s\n", $0 }' "$REPO/docker-compose.yml"
}
