#!/usr/bin/env bash
# Drives the built CLI: one real server, real get/put against it, and the exit
# codes the failure paths promise. Called by `scripts/ci.sh` after
# `moon build --release`, so both pipelines run exactly the same demo.
#
# Everything happens on loopback, in one container: no network hop, no flake.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

CLI="_build/native/release/build/cmd/main/main.exe"
# A port in the ephemeral range that is not 69 (unprivileged) and not 6969
# (what docs/interop.md uses), so a stray server cannot make this pass or fail.
PORT="${TFTP_DEMO_PORT:-17777}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/moon-tftp-cli-demo.XXXXXX")"
ROOT_DIR="$WORK/tftpboot"
SERVER_LOG="$WORK/server.log"
mkdir -p "$ROOT_DIR"

status=0
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

step() {
  echo
  echo "===== $* ====="
}

# Report a failure and remember it, so the demo runs to the end and reports
# everything that broke instead of stopping at the first bad case.
check() {
  local name="$1"
  shift
  if "$@"; then
    echo "ok: $name"
  else
    echo "FAILED: $name" >&2
    status=1
  fi
}

expect_success() {
  local name="$1"
  shift
  if "$@"; then
    echo "ok: $name"
  else
    echo "FAILED: $name (expected success, got $?)" >&2
    status=1
  fi
}

expect_failure() {
  local name="$1"
  shift
  if "$@"; then
    echo "FAILED: $name (expected failure, got success)" >&2
    status=1
  else
    echo "ok: $name (rejected with $?)"
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

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
step "fixtures"
printf 'hello moon-tftp\n' > "$ROOT_DIR/hello.txt"
head -c 4096 /dev/urandom > "$ROOT_DIR/blob.bin"
head -c 5000 /dev/urandom > "$WORK/upload.bin"
printf 'line one\nline two\n' > "$WORK/na.txt"
echo "served from $ROOT_DIR on port $PORT"

# ---------------------------------------------------------------------------
# serve
# ---------------------------------------------------------------------------
step "serve"
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
# netascii is not octet: the line feeds travel as CRLF on the wire and are
# stored that way, so the check is "the CRLF form arrived", not a plain copy.
printf 'line one\r\nline two\r\n' > "$WORK/na.crlf"
check "the netascii upload is stored in its CRLF form" \
  cmp "$WORK/na.crlf" "$ROOT_DIR/na.txt"

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
# ---------------------------------------------------------------------------
step "exit codes"
expect_success "--help exits 0" "$CLI" --help
expect_success "--version exits 0" "$CLI" --version
expect_failure "an unknown subcommand exits non-zero" "$CLI" frobnicate
expect_failure "a flag without a value exits non-zero" \
  "$CLI" get "$REMOTE" f --blksize

exit "$status"
