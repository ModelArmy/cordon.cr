#!/usr/bin/env bash
# Reports how a program built by the installed Crystal behaves on macOS under
# Cordon's profile with BASELINE's semaphore rule removed, to track
# crystal-lang/crystal#17685 and Crystal's use of named semaphores.
#
# Usage: scripts/probe-crystal-semaphores.sh CORDON_BINARY
#
# Verdicts, and exit codes:
#   stalls  0  Unchanged: #17685 is open and the rule is needed.
#   errors  1  #17685 looks fixed; the rule is still needed.
#   runs    1  Crystal no longer needs the rule; plan its removal.
#   (none)  2  The probe itself failed, e.g. the control run did not succeed.
#
# Steps: build a hello program, generate its profile with `cordon inspect`,
# run it once under the full profile as a control, then again with the rule
# removed, each under a time limit, and classify the second run.

set -euo pipefail

cordon=${1:?usage: $0 CORDON_BINARY}
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

summary() {
  echo "$1"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$1" >> "$GITHUB_STEP_SUMMARY"; fi
}

run_limited() {
  set +e
  perl -e 'alarm shift; exec @ARGV' 10 sandbox-exec -f "$1" -- "$dir/hello" > "$dir/out" 2> "$dir/err"
  status=$?
  set -e
}

crystal --version | head -1
echo 'puts "hello"' > "$dir/hello.cr"
crystal build "$dir/hello.cr" -o "$dir/hello"

printf '{"read_only_paths":["%s"]}' "$dir" > "$dir/policy.json"
"$cordon" inspect --policy "$dir/policy.json" --add brew --platform macos > "$dir/full.sb"
sed '/ipc-posix-sem-create/,/ipc-posix-name-prefix/d' "$dir/full.sb" > "$dir/probe.sb"

if ! grep -q 'ipc-posix-sem-create' "$dir/full.sb" || grep -q 'ipc-posix-sem' "$dir/probe.sb"; then
  summary "Probe failed: could not find and remove the semaphore rule in the profile."
  exit 2
fi

run_limited "$dir/full.sb"
if [ "$status" -ne 0 ]; then
  summary "Probe failed: the control run under the full profile exited $status."
  cat "$dir/err" >&2
  exit 2
fi

run_limited "$dir/probe.sb"
case $status in
  142)
    summary "stalls: without the semaphore rule the program hangs; crystal-lang/crystal#17685 is unfixed in this Crystal."
    exit 0
    ;;
  0)
    summary "runs: this Crystal no longer needs the semaphore rule. Plan its removal for programs built with it."
    exit 1
    ;;
  *)
    summary "errors (exit $status): crystal-lang/crystal#17685 looks fixed; the semaphore rule is still needed. stderr: $(head -c 300 "$dir/err")"
    exit 1
    ;;
esac
