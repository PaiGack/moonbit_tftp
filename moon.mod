// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x

name = "PaiGack/tftp"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/PaiGack/moonbit_tftp"

license = "Apache-2.0"

// `moonbitlang/regexp` is not used directly anywhere in this repository: it is
// listed only to bump the transitive `moonbitlang/regexp@0.3.5` that
// `mizchi/x@0.6.1` declares. regexp only migrated to the new `moon.mod` format
// in 0.3.6, and the toolchain rejects the 0.3.5 `moon.mod.json`, so without
// this line `moon check` / `moon test` fail to even resolve the build plan.
// Drop it once `mizchi/x` depends on regexp 0.3.6 or newer.
import {
  "mizchi/x@0.6.1",
  "moonbitlang/async@0.21.3",
}

keywords = [ "tftp", "udp", "protocol", "netascii", "file-transfer" ]

description = "TFTP (RFC 1350/2347/2348/2349) client and server in pure MoonBit."

preferred_target = "native"
