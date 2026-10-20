# shellcheck shell=bash disable=SC2034,SC2016 # OUT/STATUS feed expect_*
# setup-dev cases: setup-dev.sh keeps only the local TLS files and the env_file
# checks; it never creates or reads .env. It runs against an export of the real
# repo (it needs config/traefik), inside the sandbox, never in the working tree.

case_setup_dev_writes_no_env() {
  new_case setup_dev_writes_no_env
  local real="$CASE/realrepo"
  mkdir "$real"
  (cd "$CHECKOUT" && git ls-files -z | xargs -0 tar -c | tar -x -C "$real")
  rm -f "$real/.env"
  REPO=$real
  STATUS=0
  OUT=$(cd "$real" && sandboxed CI=true "$BASH" setup-dev.sh 2>&1 </dev/null) || STATUS=$?
  OUT=$(printf '%s\n' "$OUT" | strip_colour)
  printf '%s\n' "$OUT" > "$CASE/last-output.txt"
  expect_status 0
  expect_missing "$real/.env"
  expect_true 'cert file exists' [ -s "$real/config/traefik/certs/localhost.me.pem" ]
  expect_true 'key file exists' [ -s "$real/config/traefik/certs/localhost.me-key.pem" ]
  expect_true 'dyn file exists' [ -s "$real/config/traefik/dyn/local-certs.generated.yml" ]
  expect_true 'output ends with scripts/secrets/setup.sh' \
    sh -c 'printf "%s\n" "$1" | tail -n 1 | grep -q "scripts/secrets/setup.sh"' _ "$OUT"
}

case_setup_dev_bash32_safe() {
  new_case setup_dev_bash32_safe
  local hits
  hits=$(grep -nE ',,\}|\^\^\}|mapfile|readarray' "$CHECKOUT/setup-dev.sh" || true)
  expect_true 'setup-dev.sh has no ,,} ^^} mapfile readarray' [ -z "$hits" ]
}
