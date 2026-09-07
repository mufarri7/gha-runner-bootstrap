#!/usr/bin/env bash
set -Eeuo pipefail

: "${ACTIONS_RUNNER_INPUT_JITCONFIG:?missing JIT configuration}"
[[ "$("$(dirname "$0")/bin/Runner.Listener" --version)" == 2.337.0 ]] || exit 78
[[ "${ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER:-}" == true ]] || {
  printf 'The runner was not forced into job-container mode.\n' >&2
  exit 69
}
unset ACTIONS_RUNNER_INPUT_JITCONFIG
mkdir -p "$(dirname "$0")/_diag"
printf 'holding boundary probe\n' >"$(dirname "$0")/_diag/runner.log"
printf '%s\n' "$BASHPID" >"$(dirname "$0")/_diag/runner.pid"
exec sleep 300
