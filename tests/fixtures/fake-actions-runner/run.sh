#!/usr/bin/env bash
set -Eeuo pipefail

: "${ACTIONS_RUNNER_INPUT_JITCONFIG:?missing JIT configuration}"
unset ACTIONS_RUNNER_INPUT_JITCONFIG

mkdir -p "$(dirname "$0")/_diag"
env | sort >"$(dirname "$0")/_diag/job-environment.log"
printf 'one-job-listener-exit\n' >"$(dirname "$0")/_diag/runner.log"

if env | grep -q '^ACTIONS_RUNNER_INPUT_JITCONFIG='; then
  printf 'JIT configuration leaked to the job environment.\n' >&2
  exit 70
fi

# A filesystem marker exercises listener failure without weakening env isolation.
if [[ -e "$(dirname "$0")/.fail" ]]; then
  exit 71
fi
