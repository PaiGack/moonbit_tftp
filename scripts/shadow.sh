#!/usr/bin/env bash
# Refresh `shadow/generated.mbt` from `moon.mod` and the local toolchain.
#
# The file is tracked, not generated at build time. `moon publish` re-checks
# the packaged zip in a scratch directory with no `.git`, and the generator
# walks up looking for one — there it does not answer, it spins, and the check
# never returns. The packager ships tracked files only, so a build-time
# artifact would have been missing from the zip anyway. Run this by hand when
# `moon.mod` changes, then commit the diff; `moon test` fails when the two
# disagree (see `the reported version comes from moon.mod` in
# `cmd/main/main_wbtest.mbt`).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

export PATH="$HOME/.moon/bin:$PATH"

OUT="shadow/generated.mbt"
GEN=".mooncakes/PaiGack/moon_shadow/gen"

if [ ! -d "$GEN" ]; then
  echo "no generator at $GEN — run \`moon check\` first" >&2
  exit 1
fi

# `--target native`: the generator shells out to `git` through libc. Its own
# build output gets its own target dir so it never lands in the main `_build`.
moon run --target native --target-dir _build/gen "$GEN" -- ./moon.mod "$OUT.tmp"

# The generator's output cannot be committed as-is: it bakes in the git state
# of the checkout it ran in, and its prose describes a build-time file this one
# is not. `scripts/shadow_rewrite.py` makes both edits, idempotently.
python3 "$SCRIPT_DIR/shadow_rewrite.py" "$OUT.tmp" "$OUT"

rm -f "$OUT.tmp"
# `moon fmt --check` runs over the whole module in CI, so a refresh must not
# arrive as a style diff mixed into a version bump. Formatting the module also
# normalizes whatever the generator emitted.
moon fmt >/dev/null
echo "refreshed $OUT; commit the diff"
