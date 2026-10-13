///|
/// TFTP protocol primitives (RFC 1350 with options from RFC 2347/2348/2349).
///
/// This package currently publishes the packet layer: opcodes, encode/decode,
/// and the canonical 512-byte default block size constant. Client and server
/// state machines are built on top of it in follow-up changes.

///|
/// Default TFTP data block size, in bytes (RFC 1350).
pub let default_block_size : Int = 512

///|
/// The UDP port a TFTP server listens on for the initial request (RFC 1350).
pub let default_port : Int = 69

///|
/// TFTP opcodes as they appear on the wire (RFC 1350, section 5).
pub(all) enum Opcode {
  Rrq // 1: read request
  Wrq // 2: write request
  Data // 3: data
  Ack // 4: acknowledgment
  Error // 5: error
} derive(Eq, Debug)

///|
pub extend Opcode with Eq::{not_equal, equal}

///|
pub extend Opcode with @moonbitlang/core/debug.Debug::{to_repr}
