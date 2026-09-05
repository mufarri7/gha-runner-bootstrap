#!/usr/bin/env bash
set -Eeuo pipefail

: "${ACTIONS_RUNNER_INPUT_JITCONFIG:?missing JIT configuration}"
unset ACTIONS_RUNNER_INPUT_JITCONFIG
mkdir -p "$(dirname "$0")/_diag"
printf 'holding boundary probe\n' >"$(dirname "$0")/_diag/runner.log"
exec sleep 300
