///|
/// Generated from `moon.mod`. Keep in sync when `moon.mod` changes.
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
      { name: "PaiGack/moon_shadow", version: "0.2.0" },
      { name: "moonbitlang/async", version: "0.21.3" },
    ],
  }
}

///|
/// Generated from the git checkout this module was built in.
pub fn git_info() -> @PaiGack/moon_shadow/gitinfo.GitInfo {
  {
    available: true,
    branch: "main",
    tag: "",
    describe: "feabd72",
    commit: "feabd72120175a751ab20a2f5995a74bc2190283",
    short_commit: "feabd72",
    commit_date: "2026-10-22T22:55:35+08:00",
    author: "rzhangsan",
    email: "4iNtJYlBfhr1QT8bkeMawE+rzhangsan@noreply.cnb.cool",
    dirty: true,
    ahead: 0,
    behind: 0,
  }
}
