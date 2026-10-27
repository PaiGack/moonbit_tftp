///|
/// This module's own `moon.mod`, refreshed by `scripts/shadow.sh`.
///
/// Tracked rather than generated: `moon publish` re-checks the packaged zip in
/// a directory with no `.git`, where the generator does not answer. A hand copy
/// is the price of publishing at all — `moon test` pins the fields, so a stale
/// one fails instead of shipping a wrong version number.
pub fn module_info() -> @PaiGack/moon_shadow/mooninfo.ModuleInfo {
  {
    name: "PaiGack/tftp",
    version: "0.1.2",
    description: "TFTP (RFC 1350/2347/2348/2349) client and server in pure MoonBit.",
    license: "Apache-2.0",
    repository: "https://github.com/PaiGack/moonbit_tftp",
    readme: "README.mbt.md",
    keywords: ["tftp", "udp", "protocol", "netascii", "file-transfer"],
    preferred_target: "native",
    supported_targets: [],
    deps: [
      { name: "PaiGack/moon_shadow", version: "0.3.2", },
      { name: "moonbitlang/async", version: "0.21.3", },
    ],
  }
}

///|
/// No checkout is baked in.
///
/// This file is committed, so any git state written into it would be the state
/// of whoever last ran `scripts/shadow.sh`, printed by `--version` as if it
/// described the running binary. `available = false` is the true statement:
/// this module does not claim to know the commit it was built from.
pub fn git_info() -> @PaiGack/moon_shadow/gitinfo.GitInfo {
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
}

///|
/// The toolchain `scripts/shadow.sh` last ran under.
///
/// `from_toolchain` fills `profile` and `target` from the build compiling this
/// package, so those two stay true of whatever build is running; the two
/// versions can lag the machine that compiles it, and nothing branches on
/// them.
pub fn build_info() -> @PaiGack/moon_shadow/buildinfo.BuildInfo {
  @PaiGack/moon_shadow/buildinfo.BuildInfo::from_toolchain({
    moon_version: "0.1.20261023",
    moonc_version: "v0.10.17+d971670cd",
  })
}
