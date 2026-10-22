#!/usr/bin/env bash
# The single CI entry point. Both pipelines call exactly this script:
#
#   .github/workflows/ci.yml   ->  - run: bash scripts/ci.sh
#   .cnb.yml                   ->  script: bash scripts/ci.sh
#
# so the step list, the tool flags, the FTP server lifecycle and the CLI demo
# live in one place instead of being duplicated per provider. Steps mirror the
# GitHub Actions job one-for-one; the demo server is always stopped and its log
# always printed, so a failed transfer can be diagnosed from what the server
# said rather than from the client's exit code alone.
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
unasserted_sections=""

# Scratch space for the run: the assertion counters below, and the stderr the
# demo's assertions capture so a failure can print what the CLI said.
LOG_DIR="$ROOT/_build/ci-logs"
SECTION_MARK="$LOG_DIR/open-section"
SECTION_COUNT="$LOG_DIR/section-assertions"
mkdir -p "$LOG_DIR"
: > "$SECTION_MARK"
printf '0\n' > "$SECTION_COUNT"

# Opening a section closes the one before it: a section with no assertion is
# either one that broke before it could assert, or one nobody ever asserted on,
# and both are the silent pass `set -uo pipefail` (deliberately without `-e`)
# leaves the door open to.
step() {
  close_section
  echo
  echo "===== $* ====="
  printf '%s\n' "$*" > "$SECTION_MARK"
  printf '0\n' > "$SECTION_COUNT"
}

# Records that the current section asserted something. Called by every helper,
# so the count cannot drift from the helpers that actually report. The two
# counters are files, not variables: a variable a function writes is a
# variable whose other readers can end up looking somewhere else — dash and
# bash disagree about when a function's assignment reaches the script's
# variable, and `f() { x=0; }` alone is enough to trigger it — while a file
# has exactly one meaning everywhere.
count_assertion() {
  local n
  n="$(cat "$SECTION_COUNT" 2>/dev/null || echo 0)"
  printf '%s\n' "$((n + 1))" > "$SECTION_COUNT"
}

# A heading for a block that only sets something up — the demo's fixtures and
# the background server. Deliberately not `step`: a `step` promises that an
# assertion follows, and a setup block cannot promise that.
section_marker() {
  echo
  echo "----- $* (setup) -----"
}

# Called by `step` before it starts the next one, and once more at the end of
# the script for the last section, which nothing follows.
close_section() {
  local name n
  name="$(cat "$SECTION_MARK" 2>/dev/null || true)"
  n="$(cat "$SECTION_COUNT" 2>/dev/null || echo 0)"
  if [ -n "$name" ] && [ "$n" = 0 ]; then
    unasserted_sections="$unasserted_sections
  - $name"
  fi
}

# Run a documented step, remembering failures instead of aborting: a broken
# demo must not hide the later steps, and the exit code still propagates. The
# call is the only check a `moon` step has, so it is the section's assertion.
run() {
  step "$*"
  count_assertion
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
# The README's fenced blocks are compiled too — the one block marked
# `moonbit check` is a doc test, but `moon test -p <pkg>` never runs it (a
# package-wide run does not pick up the module README). Naming the file makes
# it a target of its own, which is the only thing that keeps the snippet in
# README.mbt.md from drifting away from the API it documents: it did drift —
# a missing `await` and a package alias that exists only inside this repo —
# and nothing failed until it was pasted into a real package by hand.
run moon test --target native --deny-warn ./README.mbt.md
# The report above is a number, not a list: `analyze` names the lines nothing
# runs yet. `uncovered.log` is written inside the build directory so the
# accounting lives in one tracked place — this repo's most under-tested file
# (`server_fs.mbt`) was invisible in the summary until `analyze` printed zero
# for it.
# Two `run`s, not `a && b`: an arm of an `&&` list runs in a subshell, and an
# assertion counted there would land in a file the parent never reads back.
run bash -c 'moon coverage analyze > _build/uncovered.log'
run cat _build/uncovered.log

run moon build --target native
run moon build --target native --release

# ---------------------------------------------------------------------------
# The CLI, exercised as a real program against a real server.
#
# `moon test` covers the library and the CLI's argument parser, but neither
# runs the `main` that ships: the socket plumbing, the exit codes and the
# get/put/serve loop are only wired up in `cmd/main`. This section starts the
# built server, drives it with the built client, and compares bytes with
# `cmp`, which is the only check that catches a client and server that both
# think they finished a transfer that never happened.
#
# It lives here rather than in a second script on purpose: `ci.sh` is the one
# entry point both pipelines call, and a demo that can drift out of step with
# the checks around it is a demo that silently stops running.
#
# Everything happens on loopback, in one container: no network hop, no flake.
# ---------------------------------------------------------------------------
# A marker, not a section: what follows only sets the demo up. `step` is for
# sections an assertion is accountable for, and this one asserts nothing.
section_marker "CLI demo"
CLI="_build/native/release/build/cmd/main/main.exe"
# A port in the ephemeral range that is not 69 (unprivileged) and not 6969
# (what docs/interop.md uses), so a stray server cannot make this pass or fail.
PORT="${TFTP_DEMO_PORT:-17777}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/moon-tftp-cli-demo.XXXXXX")"
ROOT_DIR="$WORK/tftpboot"
SERVER_LOG="$WORK/server.log"
mkdir -p "$ROOT_DIR"

SERVER_PID=""

# Always stop the server and always print its log: a failed transfer is
# diagnosed from what the server said, not from the client's exit code.
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  echo "----- server log -----"
  cat "$SERVER_LOG" 2>/dev/null || true
  echo "----------------------"
  rm -rf "$WORK"
}
trap cleanup EXIT

# Report a failure and remember it, so the demo runs to the end and reports
# everything that broke instead of stopping at the first bad case.
check() {
  local name="$1"
  shift
  count_assertion
  if "$@"; then
    echo "ok: $name"
  else
    echo "FAILED: $name" >&2
    status=1
  fi
}

# The three exit codes README.mbt.md promises — 0 success, 1 a transfer that
# failed, 2 a command line that did not parse — named once, because they are a
# contract: a bare `2` in the middle of a check reads like a typo, not a
# promise.
EXIT_OK=0
EXIT_TRANSFER_FAILED=1
EXIT_USAGE=2

# Fails `$@` unless it exits exactly `expected`, and always says what it got:
# "exits 2" is the claim, the real code is the diagnosis. `expect_failure`
# below only asks for "non-zero", which is how a usage error can stand in for
# a transfer error without anything failing.
expect_exit() {
  local expected="$1"
  local name="$2"
  shift 2
  local code
  count_assertion
  "$@"
  code=$?
  if [ "$code" = "$expected" ]; then
    echo "ok: $name (exit $code)"
  else
    echo "FAILED: $name (expected exit $expected, got $code)" >&2
    status=1
  fi
}

expect_success() {
  expect_exit "$EXIT_OK" "$@"
}

# `$@` must fail — any non-zero code. Kept for the checks where the exit code
# is not the contract (a killed transport says nothing about which error the
# CLI picked); anything whose code README.mbt.md actually pins uses
# `expect_exit` instead.
expect_failure() {
  local name="$1"
  shift
  local code
  count_assertion
  "$@"
  code=$?
  if [ "$code" = "$EXIT_OK" ]; then
    echo "FAILED: $name (expected failure, got success)" >&2
    status=1
  else
    echo "ok: $name (rejected with $code)"
  fi
}

# `$@` must fail *and* say why: a usage error prints `error: ...` before the
# synopsis, which the bare exit code cannot tell apart from a transfer that
# died for an unrelated reason. stderr goes to a file rather than a pipeline so
# `$?` is the command's own code.
expect_usage_error() {
  local name="$1"
  shift
  local code
  count_assertion
  "$@" 2>"$LOG_DIR/usage.err" >/dev/null
  code=$?
  if [ "$code" != "$EXIT_USAGE" ]; then
    echo "FAILED: $name (expected exit $EXIT_USAGE, got $code)" >&2
    status=1
  elif ! grep -q '^error: ' "$LOG_DIR/usage.err"; then
    echo "FAILED: $name (exit $EXIT_USAGE but no \`error:\` line on stderr)" >&2
    echo "  stderr said:" >&2
    sed 's/^/    /' "$LOG_DIR/usage.err" >&2
    status=1
  else
    echo "ok: $name (exit $code, with an explanation)"
  fi
}

# Runs `$@` until it succeeds, or gives up after a few seconds: the server is
# started as a background process, so the first request can beat its bind.
retry_until_served() {
  local i
  for i in $(seq 1 50); do
    if "$@"; then
      return 0
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "the server exited before it could be reached" >&2
      return 1
    fi
    sleep 0.1
  done
  return 1
}

# Polls until `file` is exactly `size` bytes: the server lands a received file
# when its session ends, which is a beat after the client saw its last ACK.
wait_for_size() {
  local file="$1"
  local size="$2"
  local i
  for i in $(seq 1 50); do
    if [ "$(stat -c %s "$file" 2>/dev/null || echo -1)" = "$size" ]; then
      return 0
    fi
    sleep 0.1
  done
  echo "$file is $(stat -c %s "$file" 2>/dev/null || echo missing) bytes, expected $size" >&2
  return 1
}

# A UDP port with nothing on the other end, discovered rather than guessed:
# bind one, read its number, drop it. Ports 1 and 69 are not that — this kernel
# answers a send to them with ECONNREFUSED on the same call, and the CLI would
# die of a panic that says nothing about the timeout being tested. Silence is
# the point: the request is sent, nothing ever comes back.
free_udp_port() {
  local py
  py="$(command -v python3 || true)"
  if [ -z "$py" ]; then
    echo "no python3 to pick a free UDP port with" >&2
    return 1
  fi
  "$py" -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
section_marker "fixtures"
printf 'hello moon-tftp\n' > "$ROOT_DIR/hello.txt"
head -c 4096 /dev/urandom > "$ROOT_DIR/blob.bin"
head -c 5000 /dev/urandom > "$WORK/upload.bin"
printf 'line one\nline two\n' > "$WORK/na.txt"
echo "served from $ROOT_DIR on port $PORT"

# ---------------------------------------------------------------------------
# serve
# ---------------------------------------------------------------------------
section_marker "serve"
# The CLI's stdout is block-buffered when it is redirected, so its banner is
# only flushed at exit: polling the log for "serving" would wait forever. The
# honest readiness signal is a request that succeeds, and the first `get` below
# doubles as one.
"$CLI" serve --root "$ROOT_DIR" --port "$PORT" --allow-overwrite \
  >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
REMOTE="127.0.0.1:$PORT"

step "get"
expect_success "get a one-block file (also proves the server is listening)" \
  retry_until_served "$CLI" get "$REMOTE" hello.txt "$WORK/hello.out"
check "the one-block file matches byte for byte" \
  cmp "$ROOT_DIR/hello.txt" "$WORK/hello.out"

expect_success "get a multi-block file" \
  "$CLI" get "$REMOTE" blob.bin "$WORK/blob.out"
check "the multi-block file matches byte for byte" \
  cmp "$ROOT_DIR/blob.bin" "$WORK/blob.out"

# A negotiated block size means the transfer runs on more, shorter packets than
# the default, which is where an off-by-one in the block loop would show up.
expect_success "get with --blksize 1024" \
  "$CLI" get "$REMOTE" blob.bin "$WORK/blob1024.out" --blksize 1024
check "the negotiated download matches byte for byte" \
  cmp "$ROOT_DIR/blob.bin" "$WORK/blob1024.out"

expect_failure "get a file the server does not have" \
  "$CLI" get "$REMOTE" nope.txt "$WORK/nope.out"

# ---------------------------------------------------------------------------
# put
# ---------------------------------------------------------------------------
step "put"
expect_success "put a multi-block file" \
  "$CLI" put "$REMOTE" "$WORK/upload.bin" uploaded.bin --blksize 1024
check "the uploaded file matches byte for byte" \
  cmp "$WORK/upload.bin" "$ROOT_DIR/uploaded.bin"

expect_success "put with --netascii" \
  "$CLI" put "$REMOTE" "$WORK/na.txt" na.txt --netascii
# netascii is not octet: the line feeds travel as CRLF on the wire, and the
# server decodes them back, so the stored file is the LF form the client read
# off disk. Checking "the CRLF form arrived" here would only prove the server
# passed the bytes through — which is what it used to do, and what the
# round trip below now catches.
check "the netascii upload is decoded before it is stored" \
  cmp "$WORK/na.txt" "$ROOT_DIR/na.txt"

# The direction that used to be missing. The upload above proves the client
# encodes and the server decodes; this one proves the server *encodes*: the
# served file is now CRLF, so a server that passed the bytes through would hand
# it back verbatim and the client would store CRLF instead of the LF it started
# with. A round trip that does not come back to the original bytes is the bug.
expect_success "get with --netascii" \
  "$CLI" get "$REMOTE" na.txt "$WORK/na.lf.txt" --netascii
printf 'line one\nline two\n' > "$WORK/na.lf"
check "the netascii download is decoded to local line endings" \
  cmp "$WORK/na.lf" "$WORK/na.lf.txt"

# And the octet control: the same file, fetched without the flag, is the bytes
# as stored — the conversion is a property of the mode, not of the server.
expect_success "get the same file as octet" \
  "$CLI" get "$REMOTE" na.txt "$WORK/na.octet.txt"
check "the octet download is the file as stored" \
  cmp "$ROOT_DIR/na.txt" "$WORK/na.octet.txt"

# `--allow-overwrite` is on, so this is a round trip rather than an ERROR 6:
# the second put must replace the first one, not append to it.
expect_success "put over an existing name" \
  "$CLI" put "$REMOTE" "$ROOT_DIR/hello.txt" uploaded.bin
# The server writes the file when the session ends, which can be a beat after
# the client's last ACK, so the size is polled rather than read once.
check "the overwrite is a replace, not an append" \
  wait_for_size "$ROOT_DIR/uploaded.bin" "$(stat -c %s "$ROOT_DIR/hello.txt")"

# ---------------------------------------------------------------------------
# Exit codes
#
# README.mbt.md pins three of them: 0 success, 1 a transfer that failed, 2 a
# command line that did not parse. Every check below names the number it wants,
# because "non-zero" is what makes a usage error and a dead peer look alike.
# ---------------------------------------------------------------------------
step "exit codes"
expect_exit "$EXIT_OK" "--help exits 0" "$CLI" --help
expect_exit "$EXIT_OK" "--version exits 0" "$CLI" --version
expect_usage_error "an unknown subcommand is a usage error" "$CLI" frobnicate
expect_usage_error "a flag without a value is a usage error" \
  "$CLI" get "$REMOTE" f --blksize
# An out-of-range flag is rejected before it reaches the wire, per README,
# rather than sent and waited on.
expect_usage_error "an out-of-range --timeout is a usage error" \
  "$CLI" get "$REMOTE" f --timeout 0
expect_usage_error "a missing position argument is a usage error" "$CLI" get

# The failures that are not about parsing. A peer that never answers runs out
# of retries; a local file that cannot be read never gets as far as the wire;
# a server refusing with ERROR 1 is the same number as both. Seconds rather
# than the default 6 x 5s, thanks to --timeout / --retries.
DEAD_REMOTE="127.0.0.1:$(free_udp_port)"
expect_exit "$EXIT_TRANSFER_FAILED" "get from a peer that never answers exits 1" \
  "$CLI" get "$DEAD_REMOTE" nope.txt "$WORK/dead.out" --timeout 1 --retries 1
expect_exit "$EXIT_TRANSFER_FAILED" "put from a missing local file exits 1" \
  "$CLI" put "$REMOTE" "$WORK/no-such-local-file" absent.bin
expect_exit "$EXIT_TRANSFER_FAILED" "a file the server does not have exits 1" \
  "$CLI" get "$REMOTE" nope.txt "$WORK/nope2.out"

# The last section has no `step` after it to close it.
close_section
if [ -n "$unasserted_sections" ]; then
  echo "FAILED: these sections made no assertion at all:$unasserted_sections" >&2
  status=1
fi

# The demo shares the script's `status`, so a failure in any check above is
# already remembered and reported by the final `exit`.
exit "$status"
