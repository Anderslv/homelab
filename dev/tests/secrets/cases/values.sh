# shellcheck shell=bash disable=SC2016,SC2034 # sandboxed bash -c scripts; OUT/STATUS feed expect_*
# Values cases: lib/values.sh makes automatic values, spots placeholders, asks for the
# timezone and reads .env files without executing them. See harness.sh for conventions.

# ANSWERS BODY [ARG…]: runs BODY (bash) with ui.sh, config.sh and values.sh loaded.
values_run() {
  local answers=$1 body=$2
  shift 2
  STATUS=0
  OUT=$(printf '%b' "$answers" | sandboxed "$BASH" -c 'set -euo pipefail
    d=$1; body=$2; shift 2; . "$d/ui.sh"; . "$d/config.sh"; . "$d/values.sh"
    eval "$body"' _ "$CHECKOUT/scripts/secrets/lib" "$body" "$@" 2>&1) || STATUS=$?
}

case_auto_formats() {
  new_case auto_formats
  values_run '' 'auto_value SPEEDTEST_APP_KEY required secret | base64 -d | wc -c | tr -d " "'
  expect_out '32'
  values_run '' 'auto_value DUMBASSETS_PIN required secret'
  expect_true 'PIN is 6 digits' sh -c "printf '%s' '$OUT' | grep -Eq '^[0-9]{6}\$'"
  values_run '' 'auto_value RUSTFS_ACCESS_KEY required secret | tr -d "\n" | wc -c | tr -d " "'
  expect_out '20'
  values_run '' 'auto_value RUSTFS_SECRET_KEY required secret | tr -d "\n" | wc -c | tr -d " "'
  expect_out '40'
  values_run '' 'auto_value RUSTFS_SECRET_KEY required secret'
  expect_true 'RustFS secret is alphanumeric' sh -c "printf '%s' '$OUT' | grep -Eq '^[A-Za-z0-9]{40}\$'"
  values_run '' 'auto_value SOME_TOKEN required secret'
  expect_true 'generic secret is 64 hex' sh -c "printf '%s' '$OUT' | grep -Eq '^[0-9a-f]{64}\$'"
  values_run '' 'auto_value OPENVPN_USER required secret'
  expect_status 1
  values_run '' 'auto_value SOME_TOKEN optional secret'
  expect_status 1
  values_run '' 'auto_value SOME_SETTING required setting'
  expect_status 1
}

case_auto_gluetun_dev_only() {
  new_case auto_gluetun_dev_only
  values_run '' 'SELECTED_PROFILE=dev; auto_value GLUETUN_HEALTHCHECK_DISABLED required setting'
  expect_status 0
  expect_out 'true'
  values_run '' 'SELECTED_PROFILE=prod; auto_value GLUETUN_HEALTHCHECK_DISABLED required setting'
  expect_status 1
  values_run '' 'SELECTED_PROFILE=; auto_value GLUETUN_HEALTHCHECK_DISABLED required setting'
  expect_status 1
}

case_placeholders_detected() {
  new_case placeholders_detected
  local v
  for v in 1234 local-openvpn-user local-openvpn-password rustadmin ci-abc CHANGEME CHANGEME-x; do
    values_run '' 'is_placeholder "$1"' "$v"
    expect_status 0
  done
  for v in real-value 12345 xci-1 ''; do
    values_run '' 'is_placeholder "$1"' "$v"
    expect_status 1
  done
}

case_timezone_quick_pick() {
  new_case timezone_quick_pick
  values_run '3\n' 'ask_timezone'
  expect_status 0
  expect_out 'Asia/Kathmandu'
  expect_out 'Europe/Berlin'
}

case_timezone_other_validated() {
  new_case timezone_other_validated
  values_run 'o\nnot a zone\nEurope/Paris\n' 'printf "result=%s\n" "$(ask_timezone 2>/dev/null)"'
  expect_status 0
  expect_out 'result=Europe/Paris'
  values_run 'o\nnot a zone\nEurope/Paris\n' 'ask_timezone >/dev/null'
  expect_out 'TZ'
}

case_validate_rules() {
  new_case validate_rules
  values_run '' 'validate TZ UTC && validate TZ America/Argentina/Buenos_Aires && validate DOMAIN a.example.com && validate ACME_EMAIL a@b.dk && validate age-key-label k_1-x && validate OTHER x'
  expect_status 0
  values_run '' '! validate TZ "not a zone" && ! validate DOMAIN localhost && ! validate ACME_EMAIL a@b && ! validate age-key-label "a b" && ! validate OTHER ""'
  expect_status 0
}

case_dotenv_rules() {
  new_case dotenv_rules
  {
    printf '# comment\n\nexport A="x # y"\n'
    printf "B='\$(touch %s/canary)'\n" "$CASE"
    printf 'C=plain # comment\nD=one\nD=two   \nE="unterminated\n'
  } > "$CASE/test.env"
  local var
  for var in A B C D; do
    values_run '' 'dotenv_value "$1" "$2"' "$CASE/test.env" "$var"
    expect_status 0
  done
  values_run '' 'dotenv_value "$1" A' "$CASE/test.env"
  expect_true 'A keeps # inside quotes' [ "$OUT" = 'x # y' ]
  values_run '' 'dotenv_value "$1" C' "$CASE/test.env"
  expect_true 'C loses the comment' [ "$OUT" = plain ]
  values_run '' 'dotenv_value "$1" D' "$CASE/test.env"
  expect_true 'last D wins' [ "$OUT" = two ]
  values_run '' 'dotenv_value "$1" B' "$CASE/test.env"
  expect_true 'B is literal' [ "$OUT" = "\$(touch $CASE/canary)" ]
  values_run '' 'dotenv_value "$1" MISSING' "$CASE/test.env"
  expect_status 1
  expect_missing "$CASE/canary"
}

case_dotenv_tracked_refused() {
  new_case dotenv_tracked_refused
  printf 'X=1\n' > "$REPO/tracked.env"
  repo_git add tracked.env
  values_run '' 'dotenv_refuse_tracked "$1"' "$REPO/tracked.env"
  expect_true 'tracked file refused' [ "$STATUS" != 0 ]
  expect_out 'is tracked by git; refusing to read secrets from it.'
  printf 'X=1\n' > "$REPO/untracked.env"
  values_run '' 'dotenv_refuse_tracked "$1"' "$REPO/untracked.env"
  expect_status 0
  printf 'X=1\n' > "$CASE/tmp/outside.env"
  values_run '' 'dotenv_refuse_tracked "$1"' "$CASE/tmp/outside.env"
  expect_status 0
}

# FILE_CONTENT(printf format) VAR EXPECTED LABEL
dotenv_expect() {
  printf '%b' "$1" > "$CASE/t.env"
  values_run '' 'dotenv_value "$1" "$2"' "$CASE/t.env" "$2"
  expect_true "$4" [ "$OUT" = "$3" ]
}

case_dotenv_empty_quoted() {
  new_case dotenv_empty_quoted
  dotenv_expect 'A=""\n' A '' 'A="" is empty'
  dotenv_expect "B=''\n" B '' "B='' is empty"
  dotenv_expect 'C="\n' C '"' 'a lone quote stays literal'
}

case_dotenv_crlf_and_trailing() {
  new_case dotenv_crlf_and_trailing
  dotenv_expect 'A="abc"\r\nB=plain\r\n' A abc 'CRLF quoted'
  dotenv_expect 'A="abc"\r\nB=plain\r\n' B plain 'CRLF unquoted'
  dotenv_expect 'A="abc"  \n' A abc 'trailing spaces after quotes'
  dotenv_expect 'A="abc" # c\n' A abc 'quoted value then comment'
  dotenv_expect 'A=plain\t# c\n' A plain 'tab before comment'
}

case_dotenv_export_whitespace() {
  new_case dotenv_export_whitespace
  dotenv_expect 'export   A=1\n' A 1 'export with spaces'
  dotenv_expect 'export\tA=2\n' A 2 'export with tab'
}

case_dotenv_lowercase_key() {
  new_case dotenv_lowercase_key
  dotenv_expect 'LISTMONK_db__password=pw\n' LISTMONK_db__password pw 'mixed-case key'
}
