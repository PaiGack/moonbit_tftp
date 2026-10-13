///|
/// The netascii conversion, including the escapes that straddle a block
/// boundary (RFC 1350, section 2).

///|
fn bytes_from(text : String) -> Bytes {
  let out : Array[Byte] = []
  for char in text {
    out.push(char.to_int().to_byte())
  }
  Bytes::from_array(out)
}

///|
fn text_from(bytes : Bytes) -> String {
  let out = StringBuilder()
  for byte in bytes {
    out.write_char(byte.to_int().unsafe_to_char())
  }
  out.to_string()
}

///|
test "encode turns a newline into crlf" {
  let encoded = @tftp.netascii_encode_all(bytes_from("a\nb"))
  assert_eq(text_from(encoded), "a\r\nb")
}

///|
test "encode turns a lone carriage return into cr nul" {
  // The CR is not the last byte, so it is written with its NUL partner.
  let encoded = @tftp.netascii_encode_all(bytes_from("a\rb"))
  assert_eq(encoded.length(), 4)
  assert_eq(text_from(encoded.clamped_view(end=2).to_owned()), "a\r")
  assert_eq(encoded[2], b'\x00')
  assert_eq(text_from(encoded.clamped_view(start=3).to_owned()), "b")
}

///|
test "a carriage return at the very end gets its nul partner on finish" {
  let (state, body) = @tftp.netascii_encode(@tftp.Clean, bytes_from("a\r"))
  assert_eq(state, @tftp.LocalCr)
  assert_eq(text_from(body), "a")
  assert_eq(text_from(@tftp.netascii_encode_finish(state, body)), "a\r\u{00}")
}

///|
test "decode turns crlf back into a newline" {
  let decoded = @tftp.netascii_decode_all(bytes_from("a\r\nb"))
  assert_eq(text_from(decoded), "a\nb")
}

///|
test "decode turns cr nul back into a carriage return" {
  let decoded = @tftp.netascii_decode_all(
    Bytes::from_array([b'a', b'\r', b'\x00', b'b']),
  )
  assert_eq(text_from(decoded), "a\rb")
}

///|
test "round trip through both directions" {
  let text = "line one\nline two\rline three\n"
  let wire = @tftp.netascii_encode_all(bytes_from(text))
  assert_eq(text_from(@tftp.netascii_decode_all(wire)), text)
}

///|
test "a line ending split across blocks survives the encode" {
  // Block one ends on the `\r`, block two opens on the `\n`: the pair must be
  // emitted as one CRLF, not as a CR-NUL plus a bare LF.
  let first = bytes_from("tail\r")
  let second = bytes_from("\nhead")
  let (state, encoded_first) = @tftp.netascii_encode(@tftp.Clean, first)
  assert_eq(state, @tftp.LocalCr)
  // The CR is held back until the next block says what its partner is.
  assert_eq(text_from(encoded_first), "tail")
  let (state2, encoded_second) = @tftp.netascii_encode(state, second)
  assert_eq(state2, @tftp.Clean)
  // The held CR is emitted here, joined to the LF: one CRLF, as the peer expects.
  assert_eq(text_from(encoded_second), "\r\nhead")
}

///|
test "a line ending split across blocks survives the decode" {
  // The decoder works per chunk, so a CR at the end of block one and its LF at
  // the start of block two arrive as "tail\r" + "\nhead"; appending them in
  // order reproduces the CRLF as one newline.
  let first = bytes_from("tail\r")
  let second = bytes_from("\nhead")
  let (_, decoded_first) = @tftp.netascii_decode(@tftp.Clean, first)
  assert_eq(text_from(decoded_first), "tail\r")
  let (_, decoded_second) = @tftp.netascii_decode(@tftp.Clean, second)
  assert_eq(text_from(decoded_second), "\nhead")
  // Re-normalize the joined stream: the CRLF is now inside one buffer.
  assert_eq(
    text_from(@tftp.netascii_decode_all(decoded_first + decoded_second)),
    "tail\nhead",
  )
}

///|
test "a final carriage return is completed at the end of the stream" {
  // "done\r" with nothing after it is a lone CR, so the encoder owes a NUL.
  let (state, body) = @tftp.netascii_encode(@tftp.Clean, bytes_from("done\r"))
  assert_eq(state, @tftp.LocalCr)
  let finished = @tftp.netascii_encode_finish(state, body)
  assert_eq(finished.length(), 6)
  assert_eq(finished[4], b'\r')
  assert_eq(finished[5], b'\x00')
}

///|
test "a trailing carriage return on the wire decodes to a lone cr" {
  let (_, body) = @tftp.netascii_decode(@tftp.Clean, bytes_from("done\r"))
  assert_eq(text_from(body), "done\r")
}

///|
test "cr followed by something other than lf is a lone cr" {
  // RFC 1350 spells a lone CR as CR NUL, but a tolerant decoder also accepts
  // the bare CR: the CR must not swallow the following byte.
  let decoded = @tftp.netascii_decode_all(bytes_from("a\rb"))
  assert_eq(text_from(decoded), "a\rb")
}

///|
test "empty input stays empty" {
  assert_eq(@tftp.netascii_encode_all(Bytes::new(0)).length(), 0)
  assert_eq(@tftp.netascii_decode_all(Bytes::new(0)).length(), 0)
}

///|
test "every byte of a chunk that is not cr or lf passes through" {
  let text = "abcXYZ012\t "
  let encoded = @tftp.netascii_encode_all(bytes_from(text))
  assert_eq(text_from(encoded), text)
}
