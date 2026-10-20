# shellcheck shell=bash disable=SC2016,SC2034 # shim bodies expand at run time; OUT/STATUS feed expect_*
# check_macos.sh cases: the read-only Mac/Colima readiness report. Every tool it calls
# is a shim, so the cases run on any host. Sourced by dev/tests/secrets-setup.test.sh.

# CONTEXT CPUS MEMORY_GIB: fake docker, colima, uname and curl; sops, age and keepassxc-cli
# are shimmed too, so the case does not depend on the host having them.
macos_shims() {
  local context=$1 cpus=$2 gib=$3 tool
  shim docker 'echo "$*" >> "$(dirname "$0")/../docker.log"
case "${1:-} ${2:-}" in
  "context show") echo "'"$context"'"; exit 0 ;;
  "compose version") echo "Docker Compose version v5.0.0"; exit 0 ;;
  "info --format") echo "[\"name=seccomp,profile=builtin\"]"; exit 0 ;;
  "ps --format") echo "traefik-dev"; exit 0 ;;
  "buildx imagetools") echo "Platform: linux/arm64"; exit 0 ;;
esac
exit 1'
  shim colima 'echo "{\"name\":\"default\",\"status\":\"Running\",\"cpus\":'"$cpus"',\"memory\":'"$((gib * 1073741824))"'}"'
  shim uname 'case "${1:-}" in -m) echo arm64 ;; *) echo Darwin ;; esac'
  shim curl 'echo "Hostname: whoami"'
  for tool in sops age keepassxc-cli; do shim "$tool" 'exit 0'; done
}

# [ARG…]: runs check_macos.sh in the sandbox; sets OUT, STATUS.
run_check_macos() { run_script '' "$CHECKOUT/check_macos.sh" "$@"; }

case_macos_ok() {
  new_case macos_ok
  macos_shims colima 6 16
  run_check_macos
  expect_status 0
  expect_out '✓ docker and docker compose found'
  expect_out '✓ docker context is colima'
  expect_out '✓ Colima has 6 CPUs and 16 GiB'
  expect_out '✓ https://whoami.localhost.me answers'
  expect_no_out '✗'
}

case_macos_wrong_context_problem() {
  new_case macos_wrong_context_problem
  macos_shims default 6 16
  run_check_macos
  expect_status 1
  expect_out '✗ docker context is default, not colima'
  expect_out 'docker context use colima'
}

case_macos_missing_tool_problem() {
  new_case macos_missing_tool_problem
  macos_shims colima 6 16
  # PATH holds only the shims and the system tools; sops is removed.
  rm -f "$CASE/bin/sops"
  STATUS=0
  OUT=$(cd "$REPO" && env -i HOME="$CASE/home" TMPDIR="$CASE/tmp" PATH="$CASE/bin:/usr/bin:/bin" \
    "$BASH" "$CHECKOUT/check_macos.sh" 2>&1) || STATUS=$?
  OUT=$(printf '%s\n' "$OUT" | strip_colour)
  expect_status 1
  expect_out '✗ sops not found'
  expect_out 'brew install sops'
}

case_macos_low_memory_warns_exit0() {
  new_case macos_low_memory_warns_exit0
  macos_shims colima 6 8
  run_check_macos
  expect_status 0
  expect_out '! Colima has 6 CPUs and 8 GiB'
  expect_out 'colima start --cpu 6 --memory 16'
  expect_no_out '✗'
}

case_macos_ci_skips_images() {
  new_case macos_ci_skips_images
  macos_shims colima 2 2
  run_check_macos --ci
  expect_status 0
  expect_no_out 'Colima has'
  expect_no_out 'images'
  touch "$CASE/docker.log"
  expect_true 'no buildx call' [ -z "$(grep buildx "$CASE/docker.log")" ]
}

case_macos_whoami_failure_problem() {
  new_case macos_whoami_failure_problem
  macos_shims colima 6 16
  shim curl 'exit 22'
  run_check_macos
  expect_status 1
  expect_out '✗ https://whoami.localhost.me does not answer'
}

case_macos_images_unlisted_warns() {
  new_case macos_images_unlisted_warns
  macos_shims colima 6 16
  run_check_macos
  expect_out '! Could not list the images'
  expect_status 0
}
