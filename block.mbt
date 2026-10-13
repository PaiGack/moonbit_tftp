///|
/// Block number arithmetic for the 16-bit wrap-around of RFC 1350 section 2.
///
/// A DATA/ACK block number is a u16, so a transfer longer than 65536 blocks
/// (32 MiB at the default 512-byte block size) runs past 65535 and starts over
/// at 0. The one rule that matters is comparison: on the wire the number is
/// unsigned, but a receiver must interpret it relative to the block it expects.
///
/// These helpers use the RFC 1982 serial-number rule: two block numbers are
/// compared on the half-circle they share, so 65535 is one step before 0 and
/// one step after 65534.

///|
/// Whether `value` is the block number that directly follows `reference`.
///
/// A naive `value == reference + 1` is wrong at the wrap: after 65535 comes 0.
pub fn block_follows(value : UInt16, reference : UInt16) -> Bool {
  value == next_block(reference)
}

///|
/// The block number after `block`, with the u16 wrap-around.
pub fn next_block(block : UInt16) -> UInt16 {
  block + 1
}

///|
/// Whether `value` is strictly older than `reference`, on the u16 circle.
///
/// `value` is older when stepping forward from `value` reaches `reference`
/// within half the circle. A duplicate of the current block is not older, it is
/// equal; that case is `value == reference` and is reported as `false` here.
pub fn block_before(value : UInt16, reference : UInt16) -> Bool {
  // How far `reference` is ahead of `value`, counted on the u16 circle, so
  // 65535 -> 0 comes out as one step (1) rather than a wrap to 65536.
  let forward = (reference.to_int() - value.to_int() + 65536) % 65536
  forward > 0 && forward < 32768
}

///|
/// Whether `value` is strictly newer than `reference`, on the u16 circle.
pub fn block_after(value : UInt16, reference : UInt16) -> Bool {
  block_before(reference, value)
}
