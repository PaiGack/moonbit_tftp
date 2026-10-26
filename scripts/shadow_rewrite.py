"""Rewrite the generator's output into a file that can be committed.

`gen` bakes in the git state of the checkout it ran in. Committed, that is one
machine's commit id printed by `--version` as if it described every build, and
every other checkout sees a diff. So `git_info()` reports the truth instead:
nothing is known about the commit. The doc comments go with it, since they
describe a build-time file this one is not.
"""

import re
import sys

DOCS = {
    "module_info": """///|
/// This module's own `moon.mod`, refreshed by `scripts/shadow.sh`.
///
/// Tracked rather than generated: `moon publish` re-checks the packaged zip in
/// a directory with no `.git`, where the generator does not answer. A hand copy
/// is the price of publishing at all — `moon test` pins the fields, so a stale
/// one fails instead of shipping a wrong version number.""",
    "git_info": """///|
/// No checkout is baked in.
///
/// This file is committed, so any git state written into it would be the state
/// of whoever last ran `scripts/shadow.sh`, printed by `--version` as if it
/// described the running binary. `available = false` is the true statement:
/// this module does not claim to know the commit it was built from.""",
    "build_info": """///|
/// The toolchain `scripts/shadow.sh` last ran under.
///
/// `from_toolchain` fills `profile` and `target` from the build compiling this
/// package, so those two stay true of whatever build is running; the two
/// versions can lag the machine that compiles it, and nothing branches on
/// them.""",
}

GIT_BODY = '''pub fn git_info() -> @PaiGack/moon_shadow/gitinfo.GitInfo {
  {
    available: false,
    branch: "",
    tag: "",
    describe: "",
    commit: "",
    short_commit: "",
    commit_date: "",
    author: "",
    email: "",
    dirty: false,
    ahead: 0,
    behind: 0,
  }
}'''


def main(src, dst):
    text = open(src, encoding="utf-8").read()
    # Each block starts at a `///|` line and holds at most one definition.
    blocks = re.split(r"(?m)^(?=///\|\n)", text)
    out = []
    for block in blocks:
        if not block.strip():
            continue
        match = re.search(r"pub fn (\w+)\(\)", block)
        if not match:
            out.append(block.strip("\n"))
            continue
        name = match.group(1)
        body = block[block.index(match.group(0)):].strip("\n")
        if name == "git_info":
            body = GIT_BODY
        out.append(DOCS[name] + "\n" + body)
    with open(dst, "w", encoding="utf-8") as handle:
        handle.write("\n\n".join(out) + "\n")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
