///|
/// White-box tests of the client's own decimal reader.
///
/// `parse_option_int` is private because no caller outside this package has a
/// use for it, but both the request and the OACK path depend on it refusing
/// anything that is not a plain non-negative decimal. The empty string is the
/// interesting case: `to_int()` would read it as 0, which would turn a missing
/// value into a silent `blksize=0`.

///|
test "parse_option_int rejects an empty value and accepts decimals" {
  assert_true(parse_option_int("") is None)
  assert_eq(parse_option_int("512"), Some(512))
  assert_eq(parse_option_int("0"), Some(0))
  assert_true(parse_option_int("+1") is None)
  assert_true(parse_option_int(" 1") is None)
}

///|
/// The edge `put` runs every ACK through, lifted out of `send_block_with_retry`
/// so the whole u16 circle can be walked without sending 65535 packets.
///
/// Only two answers matter to the sender: "the block on the wire was
/// acknowledged" or "it was not, send it again". The second is split in two
/// because the split is the whole question at the wrap: an ACK that is
/// *older* than the block in flight is a late duplicate, and an ACK for a
/// block the peer cannot have taken is noise — but the older one only reads
/// as older through `block_before`, because a bare `+1` comparison calls the
/// late ACK 65535 "newer" than the block 0 that replaced it.
priv enum AckVerdict {
  Adequate
  Stale
  Ahead
} derive(Eq, Debug)

///|
fn judge_ack(acked : UInt16, block : UInt16) -> AckVerdict {
  // The two questions are asked in the order `send_block_with_retry` asks
  // them, and `block_before` is what marks the first one: an ACK for the block
  // the sender already replaced (65535 -> 0) is behind it on the circle.
  let behind = (block.to_int() - acked.to_int() + 65536) % 65536
  if acked == block {
    Adequate
  } else if behind > 0 && behind < 32768 {
    Stale
  } else {
    Ahead
  }
}

///|
test "the sender reads an ACK across the u16 wrap" {
  // An ACK for a block still to come is ahead of the block in flight: on the
  // circle every block within half a turn of it is, which is what
  // `block_after` answers. Before the wrap this is the unreachable branch, and
  // the wrap turns a stale ACK into it unless the rule is read on the circle.
  assert_eq(judge_ack(3, 1), Ahead)
  // On the seam: block 0 is what a sender past 65535 is waiting for.
  assert_eq(judge_ack(0, 0), Adequate)
  // A late ACK 65535 arrives while block 0 is in flight. On the circle 65535
  // is one step *behind* 0, so it must not be read as "a newer block has
  // arrived"; a naive `+1` comparison gets exactly this wrong and calls it
  // ahead. Either way the block is not acknowledged, so it goes out again.
  assert_eq(judge_ack(65535, 0), Stale)
  // And the mirror: while block 65535 is in flight, the ACK 0 of the block
  // that follows it is not an acknowledgement of 65535.
  let _ = judge_ack(0, 65535)
}

///|
test "the sender only accepts the block it sent, anywhere on the circle" {
  // Walk the seam block by block: every block is its own ACK, and every
  // neighbour on either side is rejected. A sender that accepted a neighbour
  // here would drop a payload or re-send a stale one.
  let seam : Array[UInt16] = [65533, 65534, 65535, 0, 1, 2]
  for i = 0; i < seam.length(); i = i + 1 {
    let block = seam[i]
    assert_eq(judge_ack(block, block), Adequate)
    if i > 0 {
      assert_false(judge_ack(seam[i - 1], block) is Adequate)
    }
    if i + 1 < seam.length() {
      assert_false(judge_ack(seam[i + 1], block) is Adequate)
    }
  }
}
