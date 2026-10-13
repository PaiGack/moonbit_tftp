///|
/// Builds a request packet from raw option strings, so tests exercise the same
/// `Option\0Value\0` wire shape a real peer would send.
fn request(pairs : Array[(String, String)]) -> @tftp.Packet {
  let options = pairs.map(pair => @tftp.TftpOption::new(pair.0, pair.1))
  @tftp.Packet::Rrq("boot.img", @tftp.Mode::Octet, options)
}

///|
/// The option names an OACK carries, in order.
fn oack_names(options : @tftp.Options) -> Array[String] {
  options.oack_values().map(pair => pair.0)
}

///|
/// The option values an OACK carries, in order.
fn oack_values(options : @tftp.Options) -> Array[String] {
  options.oack_values().map(pair => pair.1)
}

///|
/// A server that accepts every option it can answer for: it never refuses, and
/// has no file, so `tsize` falls back to whatever the client stated.
fn accept_all(
  _option : @tftp.RequestedOption,
) -> Result[String?, @tftp.NegotiationError] {
  Ok(None)
}

// ---------------------------------------------------------------------------
// Accepting options (RFC 2347 section 2, RFC 2348, RFC 2349)
// ---------------------------------------------------------------------------

///|
test "blksize is accepted and echoed in the OACK (RFC 2348)" {
  let parsed = @tftp.parse_options(request([("blksize", "1428")])).unwrap()
  assert_eq(parsed.options().length(), 1)
  let options = @tftp.resolve_options(parsed, accept_all).unwrap()
  assert_eq(options.blksize(), 1428)
  assert_eq(options.timeout_seconds(), @tftp.default_timeout)
  assert_eq(options.tsize(), None)
  assert_eq(oack_names(options), ["blksize"])
  assert_eq(oack_values(options), ["1428"])
  assert_eq(
    options.oack_packet(),
    Some(@tftp.Packet::Oack([@tftp.TftpOption::new("blksize", "1428")])),
  )
}

///|
test "blksize accepts the whole legal range (RFC 2348 section 3)" {
  // 8 and 65464 are the inclusive bounds; the ceiling is not 65535 because a
  // u16 block number plus the 4-byte header has to fit in the same packet.
  for size in [@tftp.min_block_size, 512, 1428, @tftp.max_block_size] {
    let parsed = @tftp.parse_options(request([("blksize", size.to_string())])).unwrap()
    assert_eq(parsed.options().length(), 1)
    assert_eq(parsed.options()[0].request_value(), size)
  }
}

///|
test "a server that stays silent hands the client its own request back" {
  // RFC 2347 §2 lets the server answer with what was asked for. Silence is
  // that answer, so 256 stays 256 rather than being clamped to the default.
  let parsed = @tftp.parse_options(request([("blksize", "256")])).unwrap()
  assert_eq(@tftp.resolve_options(parsed, accept_all).unwrap().blksize(), 256)
}

///|
test "the server may shrink blksize but never grow it" {
  let parsed = @tftp.parse_options(request([("blksize", "1024")])).unwrap()
  let smaller = @tftp.resolve_options(parsed, _option => Ok(Some("512"))).unwrap()
  assert_eq(smaller.blksize(), 512)
  // Shrinking is always safe: the client sized its buffers for at least 1024.
  assert_eq(oack_values(smaller), ["512"])
  // A server that tries to answer with more than the client asked for is
  // clamped to the request: the client sized its buffers for 1024.
  let larger = @tftp.resolve_options(parsed, _option => Ok(Some("4096"))).unwrap()
  assert_eq(larger.blksize(), 1024)
  assert_eq(oack_values(larger), ["1024"])
}

///|
test "timeout is accepted and echoed in the OACK (RFC 2349 section 3)" {
  let parsed = @tftp.parse_options(request([("timeout", "3")])).unwrap()
  let options = @tftp.resolve_options(parsed, accept_all).unwrap()
  assert_eq(options.timeout_seconds(), 3)
  assert_eq(options.blksize(), @tftp.default_block_size)
  assert_eq(options.tsize(), None)
  assert_eq(oack_names(options), ["timeout"])
  assert_eq(oack_values(options), ["3"])
}

///|
test "timeout keeps the boundary values (RFC 2349 section 3)" {
  let parsed = @tftp.parse_options(
    request([("timeout", @tftp.max_timeout.to_string())]),
  ).unwrap()
  assert_eq(
    @tftp.resolve_options(parsed, accept_all).unwrap().timeout_seconds(),
    @tftp.max_timeout,
  )
  let parsed_min = @tftp.parse_options(
    request([("timeout", @tftp.min_timeout.to_string())]),
  ).unwrap()
  assert_eq(
    @tftp.resolve_options(parsed_min, accept_all).unwrap().timeout_seconds(),
    @tftp.min_timeout,
  )
}

///|
test "a read request with tsize 0 is answered by the server (RFC 2349 section 4)" {
  let parsed = @tftp.parse_options(request([("tsize", "0")])).unwrap()
  // The placeholder 0 is the request, not an answer: the server fills it in.
  assert_eq(parsed.tsize_hint(), None)
  let options = @tftp.resolve_options(parsed, _option => Ok(Some("9412"))).unwrap()
  assert_eq(options.tsize(), Some(9412))
  assert_eq(options.blksize(), @tftp.default_block_size)
  assert_eq(oack_values(options), ["9412"])
}

///|
test "a write request keeps the size the client stated (RFC 2349 section 4)" {
  let packet = @tftp.Packet::Wrq("upload.bin", @tftp.Mode::Octet, [
    @tftp.TftpOption::new("tsize", "2048"),
    @tftp.TftpOption::new("blksize", "1024"),
  ])
  let parsed = @tftp.parse_options(packet).unwrap()
  assert_eq(parsed.tsize_hint(), Some(2048))
  let resolved = @tftp.resolve_options(parsed, accept_all).unwrap()
  assert_eq(resolved.tsize(), Some(2048))
  assert_eq(resolved.blksize(), 1024)
  assert_eq(oack_names(resolved), ["tsize", "blksize"])
}

///|
test "a read request tsize needs the server: silence cannot invent a size" {
  let parsed = @tftp.parse_options(request([("tsize", "0")])).unwrap()
  assert_eq(
    @tftp.resolve_options(parsed, accept_all),
    Err(@tftp.NegotiationError::BadTsize("0")),
  )
}

///|
test "OACK keeps the order the client asked in (RFC 2347 section 4)" {
  let parsed = @tftp.parse_options(
    request([("timeout", "2"), ("blksize", "1024"), ("tsize", "0")]),
  ).unwrap()
  let options = @tftp.resolve_options(parsed, option => {
    match option.kind() {
      Tsize => Ok(Some("4096"))
      _ => Ok(None)
    }
  }).unwrap()
  assert_eq(oack_names(options), ["timeout", "blksize", "tsize"])
  assert_eq(oack_values(options), ["2", "1024", "4096"])
  assert_eq(options.blksize(), 1024)
  assert_eq(options.timeout_seconds(), 2)
  assert_eq(options.tsize(), Some(4096))
}

// ---------------------------------------------------------------------------
// Refusing options
// ---------------------------------------------------------------------------

///|
test "an unknown option name is ignored, not fatal (RFC 2347 section 2)" {
  let parsed = @tftp.parse_options(
    request([("windowsize", "4"), ("blksize", "1024")]),
  ).unwrap()
  assert_eq(parsed.options().length(), 1)
  assert_eq(parsed.options()[0].kind(), @tftp.OptionKind::Blksize)
  let options = @tftp.resolve_options(parsed, accept_all).unwrap()
  assert_eq(oack_names(options), ["blksize"])
}

///|
test "a request with only unknown options negotiates nothing" {
  let parsed = @tftp.parse_options(request([("windowsize", "4")])).unwrap()
  assert_true(parsed.is_empty())
  let options = @tftp.resolve_options(parsed, accept_all).unwrap()
  // No OACK: the server answers with DATA / ACK instead (RFC 2347 §4).
  assert_true(options.is_empty())
  assert_eq(options.oack_packet(), None)
}

///|
test "a request without options stays on the defaults" {
  let parsed = @tftp.parse_options(request([])).unwrap()
  assert_true(parsed.is_empty())
  let options = @tftp.resolve_options(parsed, accept_all).unwrap()
  assert_eq(options, @tftp.Options::default())
  assert_eq(options.oack_packet(), None)
}

///|
test "a non-request packet is not a negotiation" {
  let parsed = @tftp.parse_options(@tftp.Packet::Data(1, Bytes::new(0))).unwrap()
  assert_true(parsed.is_empty())
  assert_eq(parsed.tsize_hint(), None)
  assert_eq(
    @tftp.resolve_options(parsed, accept_all).unwrap(),
    @tftp.Options::default(),
  )
}

///|
test "blksize 0 and anything past 65464 are dropped (RFC 2348 section 3)" {
  for text in ["0", "7", "65465", "99999"] {
    let parsed = @tftp.parse_options(request([("blksize", text)])).unwrap()
    assert_true(parsed.is_empty())
  }
}

///|
test "timeout 0 and anything past 255 are dropped (RFC 2349 section 3)" {
  for text in ["0", "256", "1000"] {
    let parsed = @tftp.parse_options(request([("timeout", text)])).unwrap()
    assert_true(parsed.is_empty())
  }
}

///|
test "non-numeric option values are dropped" {
  for text in ["abc", "-1", "+1", "1.5", " 1", "", "1x"] {
    let parsed = @tftp.parse_options(request([("blksize", text)])).unwrap()
    assert_true(parsed.is_empty())
  }
}

///|
test "one bad value does not take its peers down (RFC 2347 section 2)" {
  let parsed = @tftp.parse_options(
    request([("blksize", "0"), ("timeout", "2"), ("tsize", "junk")]),
  ).unwrap()
  assert_eq(parsed.options().length(), 1)
  assert_eq(parsed.options()[0].kind(), @tftp.OptionKind::Timeout)
  let options = @tftp.resolve_options(parsed, accept_all).unwrap()
  assert_eq(oack_names(options), ["timeout"])
  assert_eq(options.timeout_seconds(), 2)
  assert_eq(options.blksize(), @tftp.default_block_size)
}

///|
test "a read request may not name a tsize (RFC 2349 section 4)" {
  assert_eq(
    @tftp.parse_options(request([("tsize", "100")])),
    Err(@tftp.NegotiationError::BadTsize("100")),
  )
}

///|
test "a write request may not send a zero tsize (RFC 2349 section 4)" {
  let packet = @tftp.Packet::Wrq("upload.bin", @tftp.Mode::Octet, [
    @tftp.TftpOption::new("tsize", "0"),
  ])
  assert_eq(
    @tftp.parse_options(packet),
    Err(@tftp.NegotiationError::BadTsize("0")),
  )
}

///|
test "a server refusing an option rejects the whole negotiation" {
  let parsed = @tftp.parse_options(request([("blksize", "1024")])).unwrap()
  let refused = @tftp.resolve_options(parsed, _option => {
    Err(@tftp.NegotiationError::BadOption("blksize", "1024"))
  })
  assert_eq(refused, Err(@tftp.NegotiationError::BadOption("blksize", "1024")))
}

///|
test "a server answering with a non-numeric value is a rejection" {
  let parsed = @tftp.parse_options(request([("timeout", "3")])).unwrap()
  assert_eq(
    @tftp.resolve_options(parsed, _option => Ok(Some("soon"))),
    Err(@tftp.NegotiationError::BadOption("timeout", "soon")),
  )
}

///|
test "a server tsize past the blksize ceiling is still a file size" {
  // `tsize` is the whole file, not a packet: a value far past any single
  // packet is exactly what a big firmware image negotiates, so it must be
  // accepted rather than refused against the block-size ceiling.
  let parsed = @tftp.parse_options(request([("tsize", "0")])).unwrap()
  let options = @tftp.resolve_options(parsed, _option => Ok(Some("104857600"))).unwrap()
  assert_eq(options.tsize(), Some(104857600))
  assert_eq(oack_values(options), ["104857600"])
}

// ---------------------------------------------------------------------------
// OACK on the wire
// ---------------------------------------------------------------------------

///|
test "the OACK packet survives encode / decode" {
  let parsed = @tftp.parse_options(
    request([("blksize", "1024"), ("timeout", "2")]),
  ).unwrap()
  let options = @tftp.resolve_options(parsed, accept_all).unwrap()
  let packet = options.oack_packet().unwrap()
  assert_eq(
    @tftp.encode(packet),
    wire([
      0x00, 0x06, b'b', b'l', b'k', b's', b'i', b'z', b'e', 0x00, b'1', b'0', b'2',
      b'4', 0x00, b't', b'i', b'm', b'e', b'o', b'u', b't', 0x00, b'2', 0x00,
    ]),
  )
  assert_eq(@tftp.decode(@tftp.encode(packet)), Ok(packet))
}

///|
test "a rejected negotiation becomes ERROR 8 (RFC 2347 section 3)" {
  let packet = @tftp.negotiation_error_packet(
    @tftp.NegotiationError::BadOption("blksize", "65535"),
  )
  assert_eq(
    packet,
    @tftp.Packet::Error(
      @tftp.ErrorCode::OptionNegotiationFailed,
      "blksize=65535",
    ),
  )
  assert_eq(@tftp.decode(@tftp.encode(packet)), Ok(packet))
}

///|
test "the error text names the option and the value" {
  assert_eq(
    @tftp.negotiation_error_packet(@tftp.NegotiationError::BadTsize("0")),
    @tftp.Packet::Error(@tftp.ErrorCode::OptionNegotiationFailed, "tsize=0"),
  )
}

// ---------------------------------------------------------------------------
// After the OACK: the data phase
// ---------------------------------------------------------------------------

///|
test "after an OACK the transfer starts at block 1 on the new blksize" {
  let parsed = @tftp.parse_options(request([("blksize", "1428")])).unwrap()
  let options = @tftp.resolve_options(parsed, accept_all).unwrap()
  assert_eq(options.blksize(), 1428)

  // RFC 2347 §4: the OACK replaces the ACK of block 0, so the first DATA of a
  // read transfer is block 1 and carries a full new-size payload.
  let payload = Bytes::make(1428, b'x')
  let first = @tftp.Packet::Data(1, payload)
  assert_eq(@tftp.decode(@tftp.encode(first)), Ok(first))

  // A client acknowledges the OACK itself with ACK block 0, and from then on
  // uses the negotiated block numbers.
  let oack_ack = @tftp.Packet::Ack(0)
  assert_eq(@tftp.decode(@tftp.encode(oack_ack)), Ok(oack_ack))
  assert_eq(
    options.oack_packet(),
    Some(@tftp.Packet::Oack([@tftp.TftpOption::new("blksize", "1428")])),
  )
}

///|
test "a repeated option keeps its first occurrence (RFC 2347 says nothing)" {
  let parsed = @tftp.parse_options(
    request([("blksize", "1000"), ("blksize", "2000")]),
  ).unwrap()
  assert_eq(parsed.options().length(), 1)
  assert_eq(parsed.options()[0].request_value(), 1000)
  let options = @tftp.resolve_options(parsed, accept_all).unwrap()
  assert_eq(options.blksize(), 1000)
  assert_eq(oack_values(options), ["1000"])
}

///|
test "a tsize past the packet ceiling is kept (RFC 2349 section 4)" {
  // The value is a file size, so the block-size ceiling has no say here.
  let parsed = @tftp.parse_options(
    request([("tsize", "65465"), ("timeout", "3")]),
  ).unwrap()
  assert_eq(parsed.tsize_hint(), Some(65465))
  assert_eq(parsed.options().length(), 2)
}

///|
test "a write request tsize at the ceiling survives" {
  let packet = @tftp.Packet::Wrq("upload.bin", @tftp.Mode::Octet, [
    @tftp.TftpOption::new("tsize", "65464"),
  ])
  let parsed = @tftp.parse_options(packet).unwrap()
  assert_eq(parsed.tsize_hint(), Some(65464))
}

///|
test "a write request tsize for a large file is accepted" {
  // 100 MB firmware: larger than any packet, still a legal file size.
  let packet = @tftp.Packet::Wrq("firmware.bin", @tftp.Mode::Octet, [
    @tftp.TftpOption::new("tsize", "104857600"),
  ])
  let parsed = @tftp.parse_options(packet).unwrap()
  assert_eq(parsed.tsize_hint(), Some(104857600))
  let options = @tftp.resolve_options(parsed, option => {
    Ok(Some(option.request_value().to_string()))
  }).unwrap()
  assert_eq(options.tsize(), Some(104857600))
}
