# shellcheck shell=bash disable=SC2016 # the jq programs use jq $variables
# Writes the secret outputs: age key, .sops.yaml, secrets.yaml and the opt-out .env
# (compose.yml is in output-compose.sh). Values reach sops and jq only through pipes;
# every file is written to a tmp beside it, then moved into place.

# DIR: dies when DIR (or its nearest existing parent) is inside a git work tree.
refuse_inside_git() {
  local dir=$1
  while [ ! -d "$dir" ]; do dir=$(dirname "$dir"); done
  if [ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; then
    die "$1 is inside a git work tree; refusing to write secrets there."
  fi
}

# DIR: creates DIR at mode 700.
output_dir() { (umask 077 && mkdir -p "$1") && chmod 700 "$1"; }

# TMP FILE: moves TMP over FILE at mode 600.
output_commit() { chmod 600 "$1" && mv -f "$1" "$2"; }

# KEY: writes the age key when absent; accepts a file that already holds it.
install_age_key() {
  local secret line found='' tmp="$AGE_KEY_FILE.tmp"
  secret=$(printf '%s\n' "$1" | grep '^AGE-SECRET-KEY-' | head -n 1) || die 'The age key from KeePassXC is not an age key.'
  refuse_inside_git "$(dirname "$AGE_KEY_FILE")"
  if [ -L "$AGE_KEY_FILE" ] && [ ! -e "$AGE_KEY_FILE" ]; then
    die "$AGE_KEY_FILE holds a different key than KeePassXC; not touching it. Move it aside and rerun."
  fi
  if [ -e "$AGE_KEY_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$line" = "$secret" ]; then found=1; fi
    done < "$AGE_KEY_FILE"
    if [ "$found" = 1 ]; then chmod 600 "$AGE_KEY_FILE" || die "Could not chmod 600 $AGE_KEY_FILE."; return 0; fi
    die "$AGE_KEY_FILE holds a different key than KeePassXC; not touching it. Move it aside and rerun."
  fi
  output_dir "$(dirname "$AGE_KEY_FILE")" || die "Could not create $(dirname "$AGE_KEY_FILE")."
  rm -f "$tmp"
  { (umask 077 && printf '%s\n' "$1" > "$tmp") && output_commit "$tmp" "$AGE_KEY_FILE"; } ||
    { rm -f "$tmp"; die "Could not write $AGE_KEY_FILE."; }
  ok "Installed the age key in $AGE_KEY_FILE"
}

# PUBKEY LABEL: writes .sops.yaml so every *.yaml/*.yml here encrypts to PUBKEY.
write_sops_config() {
  case "$1" in age1*) ;; *) die "Not an age public key: $1" ;; esac
  case "$2" in ''|*[!A-Za-z0-9_-]*) die "Invalid age key label: $2" ;; esac
  refuse_inside_git "$SECRETS_DIR"
  output_dir "$SECRETS_DIR" || die "Could not create $SECRETS_DIR."
  rm -f "$SOPS_CONFIG.tmp"
  { (umask 077 && printf '%s\n' '# Written by scripts/secrets/setup.sh: the age key that encrypts secrets.yaml.' \
    'keys:' "  - &$2 $1" 'creation_rules:' '  - path_regex: \.ya?ml$' '    key_groups:' \
    '      - age:' "          - *$2" > "$SOPS_CONFIG.tmp") && output_commit "$SOPS_CONFIG.tmp" "$SOPS_CONFIG"; } ||
    die "Could not write $SOPS_CONFIG."
}

# OLD_JSON NEW_JSON: prints NAME (changed|removed|added), sorted by name. Never values.
changed_names() {
  printf '%s\n%s\n' "$1" "$2" | jq -rs '.[0] as $o | .[1] as $n | ($o + $n | keys[]) as $k
    | if ($o | has($k) | not) then "\($k) (added)" elif ($n | has($k) | not) then "\($k) (removed)"
      elif $o[$k] != $n[$k] then "\($k) (changed)" else empty end'
}

# FILE OLD_JSON NEW_JSON: lists the changed names and asks; returns 1 for no, and
# always in non-interactive runs.
output_confirm() {
  local name
  printf '  %s will change:\n' "$1" >&2
  changed_names "$2" "$3" | while IFS= read -r name; do note "$name"; done
  if [ "${HOMELAB_NONINTERACTIVE:-}" = 1 ]; then fail 'A non-interactive run never changes existing values.'; return 1; fi
  ask_yn "  Write $1?" y
}

# WANT_JSON: encrypts the map into secrets.yaml after listing what changes, then verifies.
write_sops() {
  local want old got tmp="$SECRETS_DIR/.secrets.yaml.tmp"
  refuse_inside_git "$SECRETS_DIR"
  want=$(printf '%s' "$1" | jq -S .) || die 'The values are not a JSON object.'
  if [ -f "$SOPS_FILE" ]; then
    old=$(sops decrypt --output-type json "$SOPS_FILE" | jq -S .) ||
      die "$SOPS_FILE does not decrypt with $AGE_KEY_FILE; not touching it."
    if [ "$old" = "$want" ]; then ok 'secrets.yaml is up to date'; return 0; fi
    output_confirm secrets.yaml "$old" "$want" || die 'Left secrets.yaml unchanged.'
    rm -f "$SECRETS_DIR/secrets.prev.yaml"
    { (umask 077 && cp "$SOPS_FILE" "$SECRETS_DIR/secrets.prev.yaml") && chmod 600 "$SECRETS_DIR/secrets.prev.yaml"; } ||
      die 'Could not keep the old file as secrets.prev.yaml. Nothing was changed.'
  fi
  output_dir "$SECRETS_DIR" || die "Could not create $SECRETS_DIR."
  rm -f "$tmp"
  (umask 077 && printf '%s' "$want" | sops --config "$SOPS_CONFIG" encrypt --input-type json \
    --output-type yaml --filename-override secrets.yaml /dev/stdin > "$tmp") || { rm -f "$tmp"; die 'sops could not encrypt the values.'; }
  output_commit "$tmp" "$SOPS_FILE" || die "Could not move the new secrets.yaml into place."
  got=$(sops decrypt --output-type json "$SOPS_FILE" | jq -S .) && [ "$got" = "$want" ] ||
    die 'secrets.yaml does not decrypt to the values just written. The previous file is secrets.prev.yaml.'
  ok 'Wrote secrets.yaml and verified it decrypts'
}

# FILE: parses a .env this file writes (and plain VAR=value lines) into a JSON map.
output_env_json() {
  jq -Rs '[scan("(?:^|\n)(?:export +)?([A-Za-z_][A-Za-z0-9_]*)=('"'"'[^'"'"']*'"'"'|\"(?:[^\"\\\\]|\\\\.)*\"|[^\n]*)")
    | {(.[0]): (.[1] | if startswith("'"'"'") then .[1:-1]
        elif startswith("\"") then .[1:-1] | gsub("\\\\(?<c>.)"; if .c == "n" then "\n" else .c end)
        else sub(" +#.*$"; "") end)}] | add // {} | .' "$1"
}

# WANT_JSON: writes $REPO/.env in .env.example order (unknown names last), mode 600.
write_env_file() {
  local env="$REPO/.env" tmp="$REPO/.env.tmp" order='' want old='{}' bad saved
  if git -C "$REPO" ls-files --error-unmatch -- .env >/dev/null 2>&1; then die "$env is tracked by git; refusing to write secrets there."; fi
  want=$(printf '%s' "$1" | jq -S 'map_values(select(. != null) | tostring)') || die 'The values are not a JSON object.'
  bad=$(printf '%s' "$want" | jq -r 'keys[] | select(test("^[A-Za-z_][A-Za-z0-9_]*$") | not)' | head -n 1)
  if [ -n "$bad" ]; then die "Not a valid variable name for .env: $bad"; fi
  if [ -f "$REPO/.env.example" ]; then order=$(example_rows "$REPO/.env.example" | cut -f 2); fi
  # The tmp file holds plain values: remove it if the run stops before the mv.
  saved=$(trap -p EXIT INT TERM HUP)
  trap 'rm -f -- "$REPO/.env.tmp"' EXIT
  trap 'exit 130' INT TERM HUP
  rm -f "$tmp"
  (umask 077 && printf '%s' "$want" | jq -r --arg order "$order" '. as $m
    | ($order | split("\n") | map(. as $k | select($k != "" and ($m | has($k))))) as $o
    | "# Written by scripts/secrets/setup.sh from KeePassXC. Plain text: never commit it.",
      (($o + (($m | keys) - $o))[] | . as $k | $m[$k] | select(. != null) | tostring
      | if test("'"'"'") then "\"" + (gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\\$"; "\\$")
          | gsub("\n"; "\\n")) + "\"" else "'"'"'" + . + "'"'"'" end | "\($k)=\(.)")' > "$tmp") ||
    { rm -f "$tmp"; die 'Could not render .env.'; }
  if [ -f "$env" ]; then
    if cmp -s "$tmp" "$env"; then rm -f "$tmp"; trap - EXIT INT TERM HUP; eval "$saved"; ok '.env is up to date'; return 0; fi
    old=$(output_env_json "$env" | jq -S .) || old='{}'
    if [ "$old" != "$want" ]; then output_confirm .env "$old" "$want" || { rm -f "$tmp"; die 'Left .env unchanged.'; }; fi
    rm -f "$env.prev"
    { (umask 077 && cp "$env" "$env.prev") && chmod 600 "$env.prev"; } ||
      die 'Could not keep the old file as .env.prev. Nothing was changed.'
  fi
  output_commit "$tmp" "$env" || die "Could not move the new .env into place."
  trap - EXIT INT TERM HUP
  eval "$saved"
  [ "$(output_env_json "$env" | jq -S .)" = "$want" ] || die '.env does not read back to the values just written.'
  ok 'Wrote .env'
  warn '.env holds your values in plain text. It is gitignored and blocked from commits.'
}
