# shellcheck shell=bash
# The local age key file: installs the key from KeePassXC, and after a rotation swaps only
# the old identity for the new one, keeping any other identities the file holds (it is often
# shared with other projects). Split from output.sh; uses its refuse_inside_git helpers.

# SECRET: true when AGE_KEY_FILE has the line SECRET (an AGE-SECRET-KEY-… line).
age_key_file_holds() {
  local line
  [ -n "$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$1" ]; then return 0; fi
  done < "$AGE_KEY_FILE"
  return 1
}

# KEY: the AGE-SECRET-KEY-… line of KEY (empty when there is none).
age_key_secret() { printf '%s\n' "$1" | grep '^AGE-SECRET-KEY-' | head -n 1 || true; }

# OLD_SECRET NEW_KEY: prints AGE_KEY_FILE with the OLD_SECRET line (and the `# created:` and
# `# public key:` lines just above it) replaced by NEW_KEY; every other line stays.
age_key_swapped() {
  local line held=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '# created:'*|'# public key:'*) held="$held$line"$'\n'; continue ;; esac
    if [ "$line" = "$1" ]; then held=''; printf '%s\n' "$2"; continue; fi
    printf '%s%s\n' "$held" "$line"
    held=''
  done < "$AGE_KEY_FILE"
  printf '%s' "$held"
}

# KEY [PREVIOUS]: writes the age key when absent; accepts a file that already holds it.
# In a file holding PREVIOUS (age-key-previous of an unfinished rotation) that identity is
# replaced by KEY, and the whole old file is kept beside it; any other file is never touched.
install_age_key() {
  local secret previous rotated tmp="$AGE_KEY_FILE.tmp"
  secret=$(age_key_secret "$1")
  [ -n "$secret" ] || die 'The age key from KeePassXC is not an age key.'
  previous=$(age_key_secret "${2:-}")
  refuse_inside_git "$(dirname "$AGE_KEY_FILE")"
  if [ -L "$AGE_KEY_FILE" ] && [ ! -e "$AGE_KEY_FILE" ]; then
    die "$AGE_KEY_FILE holds a different key than KeePassXC; not touching it. Move it aside and rerun."
  fi
  rm -f "$tmp"
  if [ -e "$AGE_KEY_FILE" ]; then
    if age_key_file_holds "$secret"; then chmod 600 "$AGE_KEY_FILE" || die "Could not chmod 600 $AGE_KEY_FILE."; return 0; fi
    if ! age_key_file_holds "$previous"; then
      die "$AGE_KEY_FILE holds a different key than KeePassXC; not touching it. Move it aside and rerun."
    fi
    rotated="$AGE_KEY_FILE.rotated-$(date +%Y%m%d-%H%M%S)"
    { (umask 077 && age_key_swapped "$previous" "$1" > "$tmp") && mv "$AGE_KEY_FILE" "$rotated" &&
      chmod 600 "$rotated" && output_commit "$tmp" "$AGE_KEY_FILE"; } ||
      { rm -f "$tmp"; die "Could not replace the old age key in $AGE_KEY_FILE."; }
    note "The age key was rotated; kept the old file at $rotated"
    ok "Replaced the old age key in $AGE_KEY_FILE"
    return 0
  fi
  output_dir "$(dirname "$AGE_KEY_FILE")" || die "Could not create $(dirname "$AGE_KEY_FILE")."
  { (umask 077 && printf '%s\n' "$1" > "$tmp") && output_commit "$tmp" "$AGE_KEY_FILE"; } ||
    { rm -f "$tmp"; die "Could not write $AGE_KEY_FILE."; }
  ok "Installed the age key in $AGE_KEY_FILE"
}
