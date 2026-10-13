#!/usr/bin/env bash
# The single CI entry point. Both pipelines call exactly this script:
#
#   .github/workflows/ci.yml   ->  - run: bash scripts/ci.sh
#   .cnb.yml                   ->  script: bash scripts/ci.sh
#
# so the step list, the tool flags and the FTP server lifecycle live in one
# place instead of being duplicated per provider. Steps mirror the GitHub
# Actions job one-for-one; the container start/stop is always attempted so a
# failed demo still prints the server logs.
set -uo pipefail

# Resolve the repo root from this script's own location, so it works no matter
# which directory the pipeline invokes it from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# MoonBit installs into ~/.moon/bin; the CNB image has it on PATH but the
# GitHub runner only adds it via GITHUB_PATH, so add it defensively for both.
export PATH="$HOME/.moon/bin:$PATH"

status=0

step() {
  echo
  echo "===== $* ====="
}

# Run a documented step, remembering failures instead of aborting: a broken
# demo must not hide the later steps, and the exit code still propagates.
run() {
  step "$*"
  if ! "$@"; then
    echo "FAILED: $*" >&2
    status=1
  fi
}

# ---------------------------------------------------------------------------
# Toolchain. `moon update` is required in a clean container: without the
# registry index `moon check` fails with "module was not found in the registry".
# ---------------------------------------------------------------------------
run moon version
run moon update

# ---------------------------------------------------------------------------
# check / test / build — the same commands as the GitHub Actions steps.
# ---------------------------------------------------------------------------
run moon fmt --check
run moon check --target native --deny-warn
run moon info
run git diff --exit-code
run git status

run moon test --target native --deny-warn --enable-coverage
run moon coverage report -f summary
# The report above is a number, not a list: `analyze` names the lines nothing
# runs yet. `uncovered.log` is written inside the build directory so the
# accounting lives in one tracked place — this repo's most under-tested file
# (`server_fs.mbt`) was invisible in the summary until `analyze` printed zero
# for it.
run bash -c 'moon coverage analyze > _build/uncovered.log' && cat _build/uncovered.log

run moon build --target native
run moon build --target native --release

# ---------------------------------------------------------------------------
# The CLI, exercised as a real program against a real server.
#
# `moon test` covers the library and the CLI's argument parser, but neither
# runs the `main` that ships: the socket plumbing, the exit codes and the
# get/put/serve loop are only wired up in `cmd/main`. This step starts the
# built server, drives it with the built client, and compares bytes with
# `cmp`, which is the only check that catches a client and server that both
# think they finished a transfer that never happened.
# ---------------------------------------------------------------------------
run bash scripts/cli_demo.sh

exit "$status"
