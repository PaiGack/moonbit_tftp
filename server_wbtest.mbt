///|
/// White-box tests of the server's option-negotiation glue.
///
/// `accepted_read` and `accepted_write` are the two halves of `accept_options`:
/// the RRQ side knows the file size by the time it runs, the WRQ side answers
/// from the request alone, and a value neither can answer has to become ERROR 8
/// rather than a silently dropped option.

///|
test "accepted_read answers tsize with the file size and blksize with the request" {
  let negotiated = accepted_read(
    Packet::Rrq("a.txt", Octet, [
      TftpOption::new("blksize", "1024"),
      TftpOption::new("tsize", "0"),
    ]),
    5,
  )
  match negotiated {
    Ok(accepted) => {
      assert_eq(accepted.block_size(), 1024)
      match accepted.options() {
        Some(options) => {
          assert_eq(options.blksize(), 1024)
          assert_eq(options.tsize(), Some(5))
        }
        None => fail("expected negotiated options")
      }
    }
    Err(_) => fail("the negotiation should have succeeded")
  }
}

///|
test "accepted_write refuses a tsize the RFC does not allow" {
  // A write request has to state the size the file will have, so `tsize=0` is
  // refused by the parser and surfaces as ERROR 8 with the value spelled out.
  assert_eq(
    accepted_write(
      Packet::Wrq("new.bin", Octet, [TftpOption::new("tsize", "0")]),
    ),
    Err(ServerError::OptionNegotiationFailed("tsize=0")),
  )
  // A blksize the negotiator cannot use is dropped by the parser, not carried
  // into the session (RFC 2347, section 2): the request still succeeds.
  match
    accepted_write(
      Packet::Wrq("new.bin", Octet, [TftpOption::new("blksize", "0")]),
    ) {
    Ok(accepted) => assert_eq(accepted.block_size(), 512)
    Err(_) => fail("an unanswerable option is dropped, not fatal")
  }
  // A request with no options negotiates nothing: `None` is the "no options"
  // answer, not a failure.
  match accepted_write(Packet::Wrq("new.bin", Octet, [])) {
    Ok(accepted) => assert_eq(accepted.options(), None)
    Err(_) => fail("an option-less request always succeeds")
  }
  match accepted_read(Packet::Rrq("a.txt", Octet, []), 5) {
    Ok(accepted) => assert_eq(accepted.options(), None)
    Err(_) => fail("an option-less request always succeeds")
  }
}

///|
/// The `BadOption` arm of the ERROR 8 text: a `blksize` the negotiator cannot
/// bound-check is spelled out as `name=value`, which is what a client needs to
/// see to know which of its options was refused.
test "a refused option is described as name=value in ERROR 8" {
  let requested = match
    parse_options(
      Packet::Rrq("a.txt", Octet, [TftpOption::new("blksize", "1024")]),
    ) {
    Ok(requested) => requested
    Err(_) => fail("the request should parse")
  }
  // The callback answers with something that is not a number: `resolve_options`
  // turns that into `BadOption`, and the server has to render it.
  match
    accept_options(
      Packet::Rrq("a.txt", Octet, [TftpOption::new("blksize", "1024")]),
      fn(_option) { Ok(Some("not-a-number")) },
    ) {
    Err(ServerError::OptionNegotiationFailed(text)) =>
      assert_eq(text, "blksize=not-a-number")
    _ => fail("expected ERROR 8")
  }
  ignore(requested)
}
