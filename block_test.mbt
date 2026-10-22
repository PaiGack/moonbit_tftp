///|
test "next_block wraps at u16" {
  assert_eq(@tftp.next_block(0), 1)
  assert_eq(@tftp.next_block(65534), 65535)
  assert_eq(@tftp.next_block(65535), 0)
}

///|
test "block_follows sees the wrap" {
  assert_true(@tftp.block_follows(1, 0))
  assert_true(@tftp.block_follows(0, 65535))
  assert_false(@tftp.block_follows(0, 65534))
  assert_false(@tftp.block_follows(65535, 0))
}

///|
test "block_before is half-circle" {
  assert_true(@tftp.block_before(65535, 0))
  assert_true(@tftp.block_before(0, 1))
  assert_false(@tftp.block_before(0, 65535))
  assert_false(@tftp.block_before(1, 0))
  assert_true(@tftp.block_before(65534, 65535))
  // Equal is neither before nor after.
  assert_false(@tftp.block_before(7, 7))
  assert_false(@tftp.block_after(7, 7))
}

///|
test "block_after mirrors block_before" {
  assert_true(@tftp.block_after(0, 65535))
  assert_true(@tftp.block_after(1, 0))
  assert_false(@tftp.block_after(65535, 0))
  assert_false(@tftp.block_after(65534, 65535))
}

///|
test "half-circle boundary is not treated as newer" {
  // Exactly 32768 apart sits on the fence; the rule keeps it out of "before".
  assert_false(@tftp.block_before(0, 32768))
  assert_false(@tftp.block_before(32768, 0))
  // 32767 steps is the furthest a step can still be called "before".
  assert_true(@tftp.block_before(0, 32767))
  assert_true(@tftp.block_before(32769, 0))
}

///|
test "block_after is the upper half circle, not just one step" {
  // The wrap is the whole difference from `block_follows`: 0 directly follows
  // 65535, and every block the wrap puts within half a circle of it is newer
  // too, which is what the one-step rule cannot say.
  assert_true(@tftp.block_after(0, 65535))
  assert_true(@tftp.block_follows(0, 65535))
  assert_true(@tftp.block_after(1, 65535))
  assert_false(@tftp.block_follows(1, 65535))
  assert_true(@tftp.block_after(32767, 0))
  // A stale number is not newer, before or after the wrap.
  assert_false(@tftp.block_after(65535, 0))
  assert_false(@tftp.block_after(65534, 65535))
  // Neither before nor after: the half-circle fence and the equal case.
  assert_false(@tftp.block_after(0, 32768))
  assert_false(@tftp.block_after(9, 9))
}

///|
test "the circle reads every direction the same way" {
  // A pair of block numbers less than half a circle apart has one order, and
  // the three helpers have to agree on it: `before` one way, `after` the other,
  // `follows` only for the immediate neighbour. Walking this keeps the seam
  // from being a special case anyone has to remember.
  let pairs : Array[(UInt16, UInt16)] = [
    (0, 1),
    (1, 2),
    (65534, 65535),
    (65535, 0),
    (0, 2),
    (65535, 1),
  ]
  for pair in pairs {
    let (older, newer) = pair
    assert_true(@tftp.block_before(older, newer))
    assert_false(@tftp.block_before(newer, older))
    // `follows` is the one step, and it must never disagree with `before`
    // about the direction it does report.
    if @tftp.block_follows(older, newer) {
      assert_true(@tftp.block_before(older, newer))
    }
  }
  // A bare `+1` comparison is exactly what this pair separates: 65535 -> 0 is
  // one step forward, not 65536.
  assert_eq(@tftp.next_block(65535), 0)
  assert_true(@tftp.block_follows(0, 65535))
  assert_true(@tftp.block_before(65535, 0))
}
