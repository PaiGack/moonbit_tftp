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
