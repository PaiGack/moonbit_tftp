///|
/// Builds a packet from raw bytes, for tests that need exact wire input.
fn wire(bytes : Array[Byte]) -> Bytes {
  Bytes::from_array(bytes)
}

///|
test "default constants match RFC 1350" {
  assert_eq(@tftp.default_block_size, 512)
  assert_eq(@tftp.default_port, 69)
}

// ---------------------------------------------------------------------------
// RRQ / WRQ (RFC 1350, section 5)
// ---------------------------------------------------------------------------

///|
test "RRQ round-trip (RFC 1350 section 5)" {
  let packet = @tftp.Packet::Rrq("netascii", @tftp.Mode::Netascii, [])
  let bytes = @tftp.encode(packet)
  assert_eq(
    bytes,
    wire([
      0x00, 0x01, // opcode 1: RRQ
       b'n', b'e', b't', b'a', b's', b'c', b'i', b'i', 0x00, // filename
       b'n', b'e', b't', b'a', b's', b'c', b'i', b'i', 0x00, // mode
    ]),
  )
  assert_eq(@tftp.decode(bytes), Ok(packet))
}

///|
test "WRQ with octet mode round-trip" {
  let packet = @tftp.Packet::Wrq("firmware.bin", @tftp.Mode::Octet, [])
  let bytes = @tftp.encode(packet)
  assert_eq(
    bytes,
    wire([
      0x00, 0x02, b'f', b'i', b'r', b'm', b'w', b'a', b'r', b'e', b'.', b'b', b'i',
      b'n', 0x00, b'o', b'c', b't', b'e', b't', 0x00,
    ]),
  )
  assert_eq(@tftp.decode(bytes), Ok(packet))
}

///|
test "RRQ keeps options in order (RFC 2347 section 2)" {
  let options = [
    @tftp.TftpOption::new("blksize", "1428"),
    @tftp.TftpOption::new("tsize", "0"),
  ]
  let packet = @tftp.Packet::Rrq("boot.img", @tftp.Mode::Octet, options)
  let bytes = @tftp.encode(packet)
  assert_eq(
    bytes,
    wire([
      0x00, 0x01, b'b', b'o', b'o', b't', b'.', b'i', b'm', b'g', 0x00, b'o', b'c',
      b't', b'e', b't', 0x00, b'b', b'l', b'k', b's', b'i', b'z', b'e', 0x00, b'1',
      b'4', b'2', b'8', 0x00, b't', b's', b'i', b'z', b'e', 0x00, b'0', 0x00,
    ]),
  )
  assert_eq(@tftp.decode(bytes), Ok(packet))
}

// ---------------------------------------------------------------------------
// DATA / ACK (RFC 1350, section 5)
// ---------------------------------------------------------------------------

///|
test "DATA round-trip, including an empty final block" {
  let payload = wire([0xDE, 0xAD, 0xBE, 0xEF])
  let packet = @tftp.Packet::Data(1, payload)
  let bytes = @tftp.encode(packet)
  assert_eq(bytes, wire([0x00, 0x03, 0x00, 0x01, 0xDE, 0xAD, 0xBE, 0xEF]))
  assert_eq(@tftp.decode(bytes), Ok(packet))

  // A block shorter than blksize marks the end of the transfer (RFC 1350 §3).
  let last = @tftp.Packet::Data(9, Bytes::new(0))
  let last_bytes = @tftp.encode(last)
  assert_eq(last_bytes, wire([0x00, 0x03, 0x00, 0x09]))
  assert_eq(@tftp.decode(last_bytes), Ok(last))
}

///|
test "DATA block number wraps at 65535" {
  let packet = @tftp.Packet::Data(0xFFFF, wire([0x00]))
  let bytes = @tftp.encode(packet)
  assert_eq(bytes, wire([0x00, 0x03, 0xFF, 0xFF, 0x00]))
  assert_eq(@tftp.decode(bytes), Ok(packet))
}

///|
test "ACK round-trip" {
  let packet = @tftp.Packet::Ack(4)
  let bytes = @tftp.encode(packet)
  assert_eq(bytes, wire([0x00, 0x04, 0x00, 0x04]))
  assert_eq(@tftp.decode(bytes), Ok(packet))
}

///|
test "ACK of block 0 is legal (RFC 2347 option negotiation)" {
  let bytes = wire([0x00, 0x04, 0x00, 0x00])
  assert_eq(@tftp.decode(bytes), Ok(@tftp.Packet::Ack(0)))
}

// ---------------------------------------------------------------------------
// ERROR (RFC 1350, section 5)
// ---------------------------------------------------------------------------

///|
test "ERROR round-trip with each code" {
  // The variant order mirrors the error code numbers (RFC 1350 §5).
  let codes = [
    @tftp.ErrorCode::Undefined,
    @tftp.ErrorCode::FileNotFound,
    @tftp.ErrorCode::AccessViolation,
    @tftp.ErrorCode::DiskFull,
    @tftp.ErrorCode::IllegalOperation,
    @tftp.ErrorCode::UnknownTransferId,
    @tftp.ErrorCode::FileAlreadyExists,
    @tftp.ErrorCode::NoSuchUser,
    @tftp.ErrorCode::OptionNegotiationFailed,
  ]
  for i in 0..<codes.length() {
    let packet = @tftp.Packet::Error(codes[i], "boom")
    let bytes = @tftp.encode(packet)
    assert_eq(bytes.length(), 9)
    assert_eq(bytes[0], 0x00)
    assert_eq(bytes[1], 0x05)
    assert_eq(bytes[2], 0x00)
    assert_eq(bytes[3], i.to_byte())
    assert_eq(bytes[4], b'b')
    assert_eq(bytes[8], 0x00)
    assert_eq(@tftp.decode(bytes), Ok(packet))
  }
}

// ---------------------------------------------------------------------------
// OACK (RFC 2347 section 4)
// ---------------------------------------------------------------------------

///|
test "OACK round-trip" {
  let packet = @tftp.Packet::Oack([@tftp.TftpOption::new("blksize", "1024")])
  let bytes = @tftp.encode(packet)
  assert_eq(
    bytes,
    wire([
      0x00, 0x06, b'b', b'l', b'k', b's', b'i', b'z', b'e', 0x00, b'1', b'0', b'2',
      b'4', 0x00,
    ]),
  )
  assert_eq(@tftp.decode(bytes), Ok(packet))
}

// ---------------------------------------------------------------------------
// Malformed packets
// ---------------------------------------------------------------------------

///|
test "empty packet is truncated" {
  assert_eq(@tftp.decode(Bytes::new(0)), Err(@tftp.DecodeError::Truncated))
}

///|
test "half an opcode is truncated" {
  assert_eq(@tftp.decode(wire([0x00])), Err(@tftp.DecodeError::Truncated))
}

///|
test "unknown opcode is rejected" {
  // 0x0007 is not assigned in RFC 1350 or RFC 2347.
  assert_eq(
    @tftp.decode(wire([0x00, 0x07])),
    Err(@tftp.DecodeError::UnknownOpcode(7)),
  )
  assert_eq(
    @tftp.decode(wire([0x00, 0x00])),
    Err(@tftp.DecodeError::UnknownOpcode(0)),
  )
}

///|
test "opcode without a filename is truncated" {
  assert_eq(@tftp.decode(wire([0x00, 0x01])), Err(@tftp.DecodeError::Truncated))
}

///|
test "filename without a terminator is reported" {
  // "abc" runs to the end of the packet: no `\0` in sight.
  assert_eq(
    @tftp.decode(wire([0x00, 0x01, b'a', b'b', b'c'])),
    Err(@tftp.DecodeError::MissingTerminator),
  )
}

///|
test "filename without a mode is truncated" {
  assert_eq(
    @tftp.decode(wire([0x00, 0x01, b'a', b'b', b'c', 0x00])),
    Err(@tftp.DecodeError::Truncated),
  )
}

///|
test "mode without a terminator is reported" {
  assert_eq(
    @tftp.decode(wire([0x00, 0x01, b'a', 0x00, b'o', b'c', b't', b'e', b't'])),
    Err(@tftp.DecodeError::MissingTerminator),
  )
}

///|
test "unknown mode is unsupported" {
  assert_eq(
    @tftp.decode(wire([0x00, 0x01, b'a', 0x00, b'b', b'i', b'n', 0x00])),
    Err(@tftp.DecodeError::Unsupported("bin")),
  )
}

///|
test "mail mode is accepted but not implemented" {
  assert_eq(
    @tftp.decode(wire([0x00, 0x01, b'a', 0x00, b'm', b'a', b'i', b'l', 0x00])),
    Err(@tftp.DecodeError::Unsupported("mail")),
  )
}

///|
test "RRQ with a dangling option name is reported" {
  assert_eq(
    @tftp.decode(
      wire([
        0x00, 0x01, b'a', 0x00, b'o', b'c', b't', b'e', b't', 0x00, b'b', b'l', b'k',
      ]),
    ),
    Err(@tftp.DecodeError::MissingTerminator),
  )
}

///|
test "DATA shorter than its header is truncated" {
  assert_eq(
    @tftp.decode(wire([0x00, 0x03, 0x00])),
    Err(@tftp.DecodeError::Truncated),
  )
}

///|
test "ACK shorter than its header is truncated" {
  assert_eq(
    @tftp.decode(wire([0x00, 0x04, 0x00])),
    Err(@tftp.DecodeError::Truncated),
  )
}

///|
test "ERROR without a code is truncated" {
  assert_eq(@tftp.decode(wire([0x00, 0x05])), Err(@tftp.DecodeError::Truncated))
}

///|
test "ERROR with an unknown code is rejected" {
  assert_eq(
    @tftp.decode(wire([0x00, 0x05, 0x00, 0x09, b'x', 0x00])),
    Err(@tftp.DecodeError::UnknownOpcode(9)),
  )
}

///|
test "ERROR message without a terminator is reported" {
  assert_eq(
    @tftp.decode(wire([0x00, 0x05, 0x00, 0x01, b'o', b'o', b'p', b's'])),
    Err(@tftp.DecodeError::MissingTerminator),
  )
}

///|
test "oversized filename is rejected instead of allocated" {
  let bytes : Array[Byte] = [0x00, 0x01]
  for _ in 0..<(@tftp.max_filename_length + 1) {
    bytes.push(b'a')
  }
  bytes.push(0x00)
  bytes.push(b'o')
  bytes.push(b'c')
  bytes.push(b't')
  bytes.push(b'e')
  bytes.push(b't')
  bytes.push(0x00)
  assert_eq(
    @tftp.decode(wire(bytes)),
    Err(@tftp.DecodeError::MissingTerminator),
  )
}

///|
test "OACK with a dangling option name is reported" {
  assert_eq(
    @tftp.decode(wire([0x00, 0x06, b'b', b'l', b'k'])),
    Err(@tftp.DecodeError::MissingTerminator),
  )
}

///|
test "encode grows past its initial buffer" {
  // A long filename forces `Writer` to reallocate mid-encode.
  let mut filename = ""
  for _ in 0..<200 {
    filename += "abcdefgh"
  }
  // 1600 chars is past `max_filename_length`, so decode rejects it: assert the
  // encoded length only, and round-trip a shorter name instead.
  let packet = @tftp.Packet::Wrq(filename, @tftp.Mode::Octet, [
    @tftp.TftpOption::new("blksize", "65464"),
  ])
  let bytes = @tftp.encode(packet)
  assert_eq(bytes.length(), 2 + 1601 + 8 + 7 + 5)
  // The name is longer than `max_filename_length`, so decode refuses it.
  assert_eq(@tftp.decode(bytes), Err(@tftp.DecodeError::MissingTerminator))
}

///|
test "a filename at the length limit still round-trips" {
  let mut filename = ""
  for _ in 0..<(@tftp.max_filename_length / 8) {
    filename += "abcdefgh"
  }
  let packet = @tftp.Packet::Rrq(filename, @tftp.Mode::Netascii, [])
  let bytes = @tftp.encode(packet)
  assert_eq(@tftp.decode(bytes), Ok(packet))
}

///|
test "OACK with a dangling option value is reported" {
  assert_eq(
    @tftp.decode(wire([0x00, 0x06, b'b', b'l', b'k', 0x00, b'1'])),
    Err(@tftp.DecodeError::MissingTerminator),
  )
}

///|
test "every accessor answers None for the packet shapes it does not name" {
  // `block_number` is the accessor the state machines use to move a transfer
  // along, so it must not invent a number for a packet that carries none: a
  // request or an ERROR has no block to act on.
  assert_eq(@tftp.Packet::Rrq("f", @tftp.Octet, []).block_number(), None)
  assert_eq(@tftp.Packet::Wrq("f", @tftp.Octet, []).block_number(), None)
  assert_eq(@tftp.Packet::Oack([]).block_number(), None)
  assert_eq(
    @tftp.Packet::Error(@tftp.FileNotFound, "gone").block_number(),
    None,
  )
  assert_eq(@tftp.Packet::Data(7, b"x").block_number(), Some(7))
  assert_eq(@tftp.Packet::Ack(7).block_number(), Some(7))
}

///|
test "a `mail` mode never reaches the wire" {
  // RFC 1350 keeps `mail` in the enum, but nothing a peer can send should
  // reach it: `mode_of` is the only door into `Mode` on the wire, and `mail`
  // is refused there. Asserting the refusal is what keeps `Mode::name`'s
  // fourth arm unreachable in practice rather than merely untested.
  assert_eq(
    @tftp.decode(wire([0x00, 0x01, b'f', 0x00, b'm', b'a', b'i', b'l', 0x00])),
    Err(@tftp.DecodeError::Unsupported("mail")),
  )
  // A misspelt mode is refused the same way, so `mail` is not special-cased
  // into acceptance by a typo.
  assert_eq(
    @tftp.decode(
      wire([
        0x00, 0x01, b'f', 0x00, b'N', b'e', b't', b'a', b's', b'c', b'i', b'i', 0x00,
      ]),
    ),
    Err(@tftp.DecodeError::Unsupported("Netascii")),
  )
}

///|
test "an encode that needs more than one doubling still fits" {
  // `Writer::reserve` grows in doublings, so a write that needs more than
  // twice the current buffer has to loop. A filename long enough to do that
  // still has to come back out of `decode` byte for byte.
  let mut filename = ""
  for _ in 0..<20 {
    filename += "abcdefgh"
  }
  let packet = @tftp.Packet::Rrq(filename, @tftp.Mode::Octet, [
    @tftp.TftpOption::new("blksize", "1024"),
  ])
  assert_eq(@tftp.decode(@tftp.encode(packet)), Ok(packet))
}

///|
test "an accessor that names no packet returns None for every shape" {
  // `data_payload`, `mode`, `options` and `first_packet` are the other half of
  // the accessor surface: each has to answer `None` rather than guess when the
  // packet it was handed is not one it describes.
  assert_eq(@tftp.Packet::Ack(1).data_payload(), None)
  assert_eq(@tftp.Packet::Data(1, b"x").mode(), None)
  assert_eq(@tftp.Packet::Ack(1).options(), None)
  assert_eq(@tftp.Packet::Rrq("f", @tftp.Octet, []).data_payload(), None)
}
