///|
test "default constants match RFC 1350" {
  assert_eq(@tftp.default_block_size, 512)
  assert_eq(@tftp.default_port, 69)
}
