# shellcheck shell=bash disable=SC2016 # the jq programs use jq $variables
# Reads the compose files into stacks, variables, dependencies and volumes.
# It exists so one place knows what the project needs; setup, choose, docker,
# output and lib/example.sh (the .env.example renderer) all ask this file.

MAP_MAIN='' MAP_PODS='' MAP_STACKS=''
MAP_CORE='TZ DOMAIN ACME_EMAIL'
MAP_SENSITIVE='PASS|SECRET|TOKEN|KEY|PIN'
# ${V}, ${V:-x}, ${V-x}, ${V:?m}, ${V?m} or $V, never $$V. Captures: name, operator,
# argument, bare name. The argument sits in a lookahead so a ${…} inside it is found too.
MAP_SCAN='(?<!\$)\$(?:\{([A-Za-z_][A-Za-z0-9_]*)(?:(:?[-?+])(?=((?:\$\{[^}]*\}|[^}])*)\}))?|([A-Za-z_][A-Za-z0-9_]*))'
# jq helpers; the input is [main project, pods project] and $stacks is MAP_STACKS.
MAP_JQ_DEFS='def services: .[0].services + .[1].services;
def stackof: [$stacks | split("\n")[] | split("\t") | select(length == 4)
  | {key: (.[3] | split(" ")[]), value: .[0]}] | from_entries;'

# FILE: renders one compose project as JSON, without a daemon or interpolation.
map_compose() {
  docker compose -f "$REPO/$1" config --no-interpolate --format json || die "docker compose could not read $REPO/$1"
}

# Caches both compose projects and the stack list; exits when compose fails (like die).
map_load() {
  require_tools docker jq
  MAP_MAIN=$(map_compose docker-compose.yml) || exit 1
  MAP_PODS=$(map_compose docker-compose.pods.yml) || exit 1
  MAP_STACKS=$(map_build_stacks) || exit 1
}

map_ready() { if [ -z "$MAP_MAIN" ]; then map_load; fi; }

# PROGRAM [JQ OPTION…]: runs PROGRAM (after the helpers) over both projects.
map_jq() {
  local program=$1
  shift
  printf '%s\n%s\n' "$MAP_MAIN" "$MAP_PODS" |
    jq -rs --arg stacks "$MAP_STACKS" "$@" "$MAP_JQ_DEFS $program"
}

# BLOCK FILE: prints the two-space-indented keys of a top-level block (services:).
map_file_keys() {
  awk -v block="$1:" '
    $0 == block || index($0, block " ") == 1 { inside = 1; next }
    /^[^ #]/ { inside = 0 }
    inside && /^  [A-Za-z0-9_.-]+:/ { key = substr($0, 3); sub(/:.*/, "", key); print key }' "$2"
}

# Prints the files docker-compose.yml includes, in order.
map_includes() {
  awk '/^include:/ { inside = 1; next } /^[^ #]/ { inside = 0 }
    inside && /^ *- / { sub(/^ *- *(path: *)?/, ""); sub(/ *#.*/, ""); print }' "$REPO/docker-compose.yml"
}

# Stack, file and services per included file, then profiles from the project.
map_build_stacks() {
  local file stack rows
  rows=$(map_includes | while IFS= read -r file; do
    stack=$(basename "$file" .yml)
    if [ "$stack" = docker-compose ]; then stack=$(basename "$(dirname "$file")"); fi
    printf '%s\t%s\t%s\n' "$stack" "$file" "$(map_file_keys services "$REPO/$file" | tr '\n' ' ')"
  done)
  map_jq 'services as $all
    | ($rows | split("\n")[] | split("\t")), ["dockhand", "docker-compose.pods.yml", (.[1].services | keys | join(" "))]
    | (.[2] | split(" ") | map(select(. != ""))) as $names
    | [.[0], .[1], ([$all[$names[]].profiles // [] | .[]] | unique | join(" ")), ($names | join(" "))] | @tsv' \
    --arg rows "$rows"
}

# TSV stack, file, profiles, services: in include order, the pods project last.
map_stacks() { map_ready; printf '%s\n' "$MAP_STACKS"; }

# TSV section, var, kind, default, sensitivity, services, message.
map_rows() {
  map_ready
  map_jq '
    stackof as $stackof | ($core | split(" ")) as $core
    # Sections: core, then infra stacks, then the rest in include order (dockhand
    # last). sort_by is stable, so false (infra) sorts first and keeps the order.
    | (["core"] + ([$stacks | split("\n")[] | split("\t")]
        | sort_by(.[0] == "dockhand" or (.[2] | split(" ") | index("infra") | not)) | map(.[0]))) as $order
    # One entry per use: variable, operator, argument, service.
    | [services | to_entries[] | .key as $svc | .value | .. | strings | scan($re)
        | {var: (.[0] // .[3]), op: (.[1] // ""), arg: (.[2] // ""), svc: $svc}
        | .kind = if (.op | contains("?")) then "required"
            elif (.op | contains("-")) and .arg != "" then "default" else "optional" end]
    # Per variable: required beats default beats optional.
    | group_by(.var) | map({var: .[0].var,
        kind: (map(.kind) | if index("required") then "required"
          elif index("default") then "default" else "optional" end),
        default: (map(select(.kind == "default") | .arg) | first // ""),
        message: (map(select(.kind == "required") | .arg | select(. != "")) | first // ""),
        services: (map(.svc) | unique),
        stacks: (map($stackof[.svc] // .svc) | unique)}
      | .var as $v | .core = ($core | index($v))
      | .section = if .core or (.stacks | length > 1) then "core" else .stacks[0] end)
    | sort_by((.section as $s | $order | index($s)), .core // 99, .var)[]
    | [.section, .var, .kind, .default,
       (if .var | test($sensitive; "i") then "secret" else "setting" end),
       (.services | join(" ")), .message] | @tsv' \
    --arg re "$MAP_SCAN" --arg core "$MAP_CORE" --arg sensitive "$MAP_SENSITIVE"
}

# STACK: prints every stack it needs, transitively, from depends_on and
# network_mode: service:X.
map_stack_deps() {
  map_ready
  map_jq 'stackof as $of
    | [services | to_entries[] | {stack: $of[.key], needs: [(.value.depends_on // {} | keys[]),
        (.value.network_mode // "" | select(startswith("service:")) | ltrimstr("service:"))
        | $of[.] // empty]}] as $edges
    # Adds the direct needs of every stack in the set until nothing new appears.
    | def close: . as $set | ($set + [$edges[] | select(.stack as $s | $set | index($s)) | .needs[]]
        | unique) as $next | if $next == $set then $set else $next | close end;
    [$stack] | close | .[] | select(. != $stack)' --arg stack "$1"
}

# STACK: prints the Docker volume names (<project>_<volume>) its file declares.
map_stack_volumes() {
  local file keys=''
  map_ready
  file=$(printf '%s\n' "$MAP_STACKS" | awk -F '\t' -v s="$1" '$1 == s { print $2 }')
  if [ -z "$file" ]; then return 0; fi
  if [ "$1" = dockhand ]; then map_jq '.[1].volumes // {} | .[].name'; return; fi
  keys=$(map_file_keys volumes "$REPO/$file")
  map_jq '.[0] as $p | $keys | split("\n")[] | select(. != "")
    | $p.volumes[.].name // "\($p.name)_\(.)"' --arg keys "$keys"
}

# STACK: prints the variables its services use, core ones included.
map_stack_vars() {
  local services
  map_ready
  services=$(printf '%s\n' "$MAP_STACKS" | awk -F '\t' -v s="$1" '$1 == s { print $4 }')
  map_rows | awk -F '\t' -v list=" $services " '
    { n = split($6, used, " "); for (i = 1; i <= n; i++) if (index(list, " " used[i] " ")) { print $2; next } }'
}
