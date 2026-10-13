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
