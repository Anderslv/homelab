# shellcheck shell=bash disable=SC2016 # the jq programs use jq $variables
# Writes the secret outputs: .sops.yaml, secrets.yaml and the opt-out .env (the age key
# is in age-key.sh, compose.yml in output-compose.sh). Values reach sops and jq only through pipes;
# every file is written to a tmp beside it, then moved into place.

OUTPUT_EXPECTED=''

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
# always in non-interactive runs. Changes to the names in OUTPUT_EXPECTED (what --rotate
# asked for) are listed, but alone they need no answer.
output_confirm() {
  local name unexpected=''
  printf '  %s will change:\n' "$1" >&2
  while IFS= read -r name; do
    if [ -z "$name" ]; then continue; fi
    case " $OUTPUT_EXPECTED " in
      *" ${name% (*} "*) note "$name, as --rotate asked" ;;
      *) note "$name"; unexpected=1 ;;
    esac
  done < <(changed_names "$2" "$3")
  if [ -z "$unexpected" ]; then return 0; fi
  if [ "${HOMELAB_NONINTERACTIVE:-}" = 1 ]; then fail 'A non-interactive run never changes existing values.'; return 1; fi
  ask_yn "  Write $1?" y
}

# FILE: dies saying FILE was left unchanged; after --rotate, also what KeePassXC already holds.
output_refused() {
  if [ -n "$OUTPUT_EXPECTED" ]; then
    note "KeePassXC already holds the new $OUTPUT_EXPECTED. Run setup.sh again without --auto or --env to review and write $1."
  fi
  die "Left $1 unchanged."
}

# JSON: encrypts JSON (sorted) to secrets.yaml through a tmp file, then checks it decrypts.
sops_write_verified() {
  local got tmp="$SECRETS_DIR/.secrets.yaml.tmp"
  output_dir "$SECRETS_DIR" || die "Could not create $SECRETS_DIR."
  rm -f "$tmp"
  (umask 077 && printf '%s' "$1" | sops --config "$SOPS_CONFIG" encrypt --input-type json \
    --output-type yaml --filename-override secrets.yaml /dev/stdin > "$tmp") || { rm -f "$tmp"; die 'sops could not encrypt the values.'; }
  output_commit "$tmp" "$SOPS_FILE" || die "Could not move the new secrets.yaml into place."
  got=$(sops decrypt --output-type json "$SOPS_FILE" | jq -S .) && [ "$got" = "$1" ] ||
    die 'secrets.yaml does not decrypt to the values just written. The previous file is secrets.prev.yaml.'
}

sops_keep_prev() {
  rm -f "$SECRETS_DIR/secrets.prev.yaml"
  { (umask 077 && cp "$SOPS_FILE" "$SECRETS_DIR/secrets.prev.yaml") && chmod 600 "$SECRETS_DIR/secrets.prev.yaml"; } ||
    die 'Could not keep the old file as secrets.prev.yaml. Nothing was changed.'
}

# WANT_JSON [OLD_KEY]: encrypts the map into secrets.yaml after listing what changes, then
# verifies. A file still encrypted to OLD_KEY (an age-key rotation) is first re-encrypted,
# values unchanged, to the current key without asking, so a declined change still leaves a
# file this machine can read.
write_sops() {
  local want old
  refuse_inside_git "$SECRETS_DIR"
  want=$(printf '%s' "$1" | jq -S .) || die 'The values are not a JSON object.'
  if [ -f "$SOPS_FILE" ]; then
    if old=$(sops decrypt --output-type json "$SOPS_FILE" 2>/dev/null | jq -S .); then :
    elif [ -n "${2:-}" ] && old=$(SOPS_AGE_KEY_FILE=<(printf '%s\n' "$2") \
        sops decrypt --output-type json "$SOPS_FILE" 2>/dev/null | jq -S .); then
      sops_keep_prev
      sops_write_verified "$old"
      ok 'Re-encrypted secrets.yaml to the new age key'
    else die "$SOPS_FILE does not decrypt with $AGE_KEY_FILE; not touching it."; fi
    if [ "$old" = "$want" ]; then ok 'secrets.yaml is up to date'; return 0; fi
    output_confirm secrets.yaml "$old" "$want" || output_refused secrets.yaml
    sops_keep_prev
  fi
  sops_write_verified "$want"
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
    if [ "$old" != "$want" ]; then output_confirm .env "$old" "$want" || { rm -f "$tmp"; output_refused .env; }; fi
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
