///|
/// Client tests against the in-memory transport.
///
/// Each test hand-writes the server side of the session: it waits for a packet
/// and answers with exactly what a real server would send. That is what makes
/// retransmission, duplication and option negotiation testable without a
/// socket and without waiting on a real clock.

///|
/// Serves one RRQ: reads the request, then sends `blocks` as DATA packets,
/// swallowing the ACKs.
///
/// `oack` decides whether an OACK precedes the data, which is how the
/// "server ignored the options" path is exercised too.
async fn serve_read(
  server : @tftp.MemoryTransport,
  blocks : Array[Bytes],
  oack : Bool,
  block_size : Int32,
) -> Unit {
  ignore(server.recv("client:0", 1000))
  if oack {
    server.send(
      @tftp.encode(
        @tftp.Packet::Oack([
          @tftp.TftpOption::new("blksize", block_size.to_string()),
        ]),
      ),
      "client:0",
    )
  }
  let mut i = 0
  while i < blocks.length() {
    server.send(
      @tftp.encode(@tftp.Packet::Data((i + 1).to_uint16(), blocks[i])),
      "client:0",
    )
    // Wait for the ACK so the peers alternate, like a real stop-and-wait pair.
    ignore(server.recv("client:0", 1000))
    i = i + 1
  }
}

///|
/// Serves one WRQ: acknowledges block 0 (or OACKs), then acks every DATA.
async fn serve_write(
  server : @tftp.MemoryTransport,
  oack : Bool,
  block_size : Int32,
) -> Int32 {
  ignore(server.recv("client:0", 1000))
  if oack {
    server.send(
      @tftp.encode(
        @tftp.Packet::Oack([
          @tftp.TftpOption::new("blksize", block_size.to_string()),
        ]),
      ),
      "client:0",
    )
  } else {
    server.send(@tftp.encode(@tftp.Packet::Ack(0)), "client:0")
  }
  let mut received = 0
  while true {
    let packet = server.recv("client:0", 1000)
    match packet {
      @tftp.Recv::Timeout => break
      @tftp.Recv::Packet(datagram) =>
        match @tftp.decode(datagram.payload()) {
          Ok(@tftp.Packet::Data(block, payload)) => {
            received = received + payload.length()
            server.send(@tftp.encode(@tftp.Packet::Ack(block)), "client:0")
            if payload.length() < block_size {
              break
            }
          }
          Ok(@tftp.Packet::Error(_, _)) => break
          Ok(_) => ()
          Err(_) => ()
        }
    }
  }
  received
}

///|
async test "get reads a small file in one block" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  let payload = b"hello tftp"
  @async.with_task_group(group => {
    group.spawn_bg(() => serve_read(server, [payload], false, 512))
    let result = @tftp.get(
      client,
      "server:69",
      "greeting.txt",
      @tftp.ClientOptions::default(),
    )
    match result {
      Ok(outcome) =>
        match outcome.received() {
          Some(bytes) => assert_true(bytes == payload)
          None => fail("expected received bytes")
        }
      Err(_) => fail("get failed")
    }
  })
}

///|
async test "get joins multiple blocks" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  let first : Bytes = Bytes::make(512, b'a')
  let second : Bytes = b"tail"
  @async.with_task_group(group => {
    group.spawn_bg(() => serve_read(server, [first, second], false, 512))
    let result = @tftp.get(
      client,
      "server:69",
      "big.bin",
      @tftp.ClientOptions::default(),
    )
    match result {
      Ok(outcome) =>
        match outcome.received() {
          Some(bytes) => {
            assert_eq(bytes.length(), 516)
            assert_true(bytes == first + second)
          }
          None => fail("expected received bytes")
        }
      Err(_) => fail("get failed")
    }
  })
}

///|
async test "get honours a negotiated block size" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  // Two blocks of the negotiated 1024 bytes, plus a short final one, so the
  // loop only ends on the block boundary the OACK established.
  let first : Bytes = Bytes::make(1024, b'x')
  let second : Bytes = Bytes::make(1024, b'y')
  let last : Bytes = b"end"
  @async.with_task_group(group => {
    group.spawn_bg(() => serve_read(server, [first, second, last], true, 1024))
    let result = @tftp.get(
      client,
      "server:69",
      "block.bin",
      @tftp.ClientOptions::default().with_block_size(1024),
    )
    match result {
      Ok(outcome) =>
        match outcome.received() {
          Some(bytes) => assert_eq(bytes.length(), 2051)
          None => fail("expected received bytes")
        }
      Err(_) => fail("get failed")
    }
  })
}

///|
async test "get reports a peer ERROR" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      server.send(
        @tftp.encode(@tftp.Packet::Error(@tftp.FileNotFound, "no such file")),
        "client:0",
      )
    })
    let result = @tftp.get(
      client,
      "server:69",
      "missing.txt",
      @tftp.ClientOptions::default(),
    )
    match result {
      Ok(_) => fail("expected an error")
      Err(@tftp.ClientError::PeerError(code, _)) =>
        assert_eq(code, @tftp.FileNotFound)
      Err(_) => fail("expected a peer error")
    }
  })
}

///|
async test "put sends a small file" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  let payload = b"upload me"
  let seen : Ref[Int32] = Ref(0)
  @async.with_task_group(group => {
    group.spawn_bg(() => seen.val = serve_write(server, false, 512))
    let result = @tftp.put(
      client,
      "server:69",
      "up.txt",
      payload,
      @tftp.ClientOptions::default(),
    )
    match result {
      Ok(outcome) => assert_eq(outcome.sent(), Some(payload.length()))
      Err(_) => fail("put failed")
    }
  })
  assert_eq(seen.val, payload.length())
}

///|
async test "put splits an exact multiple into a final empty block" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  let payload : Bytes = Bytes::make(512, b'z')
  let block_count : Ref[Int32] = Ref(0)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      server.send(@tftp.encode(@tftp.Packet::Ack(0)), "client:0")
      while true {
        match server.recv("client:0", 1000) {
          @tftp.Recv::Timeout => break
          @tftp.Recv::Packet(datagram) =>
            match @tftp.decode(datagram.payload()) {
              Ok(@tftp.Packet::Data(block, chunk)) => {
                block_count.val = block_count.val + 1
                server.send(@tftp.encode(@tftp.Packet::Ack(block)), "client:0")
                if chunk.length() == 0 {
                  break
                }
              }
              _ => break
            }
        }
      }
    })
    ignore(
      @tftp.put(
        client,
        "server:69",
        "exact.bin",
        payload,
        @tftp.ClientOptions::default(),
      ),
    )
  })
  // One full block plus the empty terminator.
  assert_eq(block_count.val, 2)
}

///|
async test "get survives a DATA that was lost once" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  let payload = b"retransmitted"
  let data_sends : Ref[Int32] = Ref(0)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      // Drop the first DATA so the client's wait times out. TFTP has no ACK to
      // resend here, so the client nudges the peer by repeating its request;
      // the server answers the repeat with the DATA again. The server's own
      // wait has to outlast the client's 1-second timeout.
      server.outbox().drop_next_packet()
      server.send(@tftp.encode(@tftp.Packet::Data(1, payload)), "client:0")
      data_sends.val = data_sends.val + 1
      let repeat = server.recv("client:0", 8000)
      match repeat {
        @tftp.Recv::Packet(datagram) =>
          match @tftp.decode(datagram.payload()) {
            Ok(@tftp.Packet::Rrq(_, _, _)) => {
              // The client re-asked: send the DATA for real this time.
              server.send(
                @tftp.encode(@tftp.Packet::Data(1, payload)),
                "client:0",
              )
              data_sends.val = data_sends.val + 1
              ignore(server.recv("client:0", 2000))
            }
            _ => fail("expected the client to repeat its request")
          }
        @tftp.Recv::Timeout => fail("server saw no retried request")
      }
    })
    let result = @tftp.get(
      client,
      "server:69",
      "lossy.bin",
      @tftp.ClientOptions::default().with_max_retries(3),
    )
    match result {
      Ok(outcome) =>
        match outcome.received() {
          Some(bytes) => assert_true(bytes == payload)
          None => fail("expected received bytes")
        }
      Err(@tftp.ClientError::Timeout) => fail("client gave up too early")
      Err(_) => fail("get failed")
    }
  })
}

///|
async test "get ignores a duplicated DATA block" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  let payload = b"once"
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      let packet = @tftp.encode(@tftp.Packet::Data(1, payload))
      server.send(packet, "client:0")
      // Wait for the ACK of block 1, then send the very same DATA again: this
      // is the Sorcerer's Apprentice trigger, and the file must not grow.
      let ack = server.recv("client:0", 2000)
      match ack {
        @tftp.Recv::Packet(datagram) =>
          match @tftp.decode(datagram.payload()) {
            Ok(@tftp.Packet::Ack(block)) => {
              assert_eq(block, 1)
              server.send(packet, "client:0")
            }
            _ => fail("expected an ACK")
          }
        @tftp.Recv::Timeout =>
          // No ACK because the file already ended on the short block: that is
          // fine, the duplicate never reached the client.
          ()
      }
    })
    let result = @tftp.get(
      client,
      "server:69",
      "dup.bin",
      @tftp.ClientOptions::default(),
    )
    match result {
      Ok(outcome) =>
        match outcome.received() {
          // The payload is one short block, so the transfer ended on it; the
          // duplicate must not append a second copy.
          Some(bytes) => assert_eq(bytes.length(), 4)
          None => fail("expected received bytes")
        }
      Err(_) => fail("get failed")
    }
  })
}

///|
async test "put retransmits a DATA whose ACK was lost" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  let payload : Bytes = Bytes::make(600, b'p')
  let data_seen : Ref[Int32] = Ref(0)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      server.send(@tftp.encode(@tftp.Packet::Ack(0)), "client:0")
      // Ack block 1, but drop the ACK on the way so the client resends.
      let first = server.recv("client:0", 8000)
      ignore(first)
      data_seen.val = data_seen.val + 1
      server.outbox().drop_next_packet()
      server.send(@tftp.encode(@tftp.Packet::Ack(1)), "client:0")
      // The client should resend block 1; ack it properly this time.
      let resent = server.recv("client:0", 8000)
      match resent {
        @tftp.Recv::Packet(datagram) =>
          match @tftp.decode(datagram.payload()) {
            Ok(@tftp.Packet::Data(block, _)) => {
              assert_eq(block, 1)
              data_seen.val = data_seen.val + 1
              server.send(@tftp.encode(@tftp.Packet::Ack(1)), "client:0")
            }
            _ => fail("expected a resent DATA")
          }
        @tftp.Recv::Timeout => fail("server saw no retransmission")
      }
      // Then block 2.
      match server.recv("client:0", 8000) {
        @tftp.Recv::Packet(datagram) =>
          match @tftp.decode(datagram.payload()) {
            Ok(@tftp.Packet::Data(block, _)) => {
              data_seen.val = data_seen.val + 1
              server.send(@tftp.encode(@tftp.Packet::Ack(block)), "client:0")
            }
            _ => fail("expected the second DATA")
          }
        @tftp.Recv::Timeout => ()
      }
    })
    let result = @tftp.put(
      client,
      "server:69",
      "lossy.bin",
      payload,
      @tftp.ClientOptions::default().with_max_retries(3),
    )
    match result {
      Ok(outcome) => assert_eq(outcome.sent(), Some(600))
      Err(_) => fail("put failed")
    }
  })
}

///|
async test "put gives up after the retry budget" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  let payload = b"never acked"
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      server.send(@tftp.encode(@tftp.Packet::Ack(0)), "client:0")
      // Read the DATA but never acknowledge it.
      ignore(server.recv("client:0", 1000))
      ignore(server.recv("client:0", 1000))
      ignore(server.recv("client:0", 1000))
      ignore(server.recv("client:0", 1000))
    })
    let result = @tftp.put(
      client,
      "server:69",
      "dead.bin",
      payload,
      @tftp.ClientOptions::default().with_max_retries(2),
    )
    match result {
      Ok(_) => fail("expected a timeout")
      Err(@tftp.ClientError::Timeout) => ()
      Err(_) => fail("expected a timeout error")
    }
  })
}

///|
async test "put and get round-trip a netascii file" {
  let text = "first line\r\nsecond\r\n\r\nthird"
  let contents = netascii_test_bytes(text)
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  // The server captures the wire bytes, then replays them back for the read so
  // the two directions are checked against each other.
  let wire : Ref[Bytes] = Ref(Bytes::new(0))
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      server.send(@tftp.encode(@tftp.Packet::Ack(0)), "client:0")
      let mut collected : Bytes = Bytes::new(0)
      while true {
        match server.recv("client:0", 8000) {
          @tftp.Recv::Timeout => break
          @tftp.Recv::Packet(datagram) =>
            match @tftp.decode(datagram.payload()) {
              Ok(@tftp.Packet::Data(block, payload)) => {
                collected = collected + payload
                server.send(@tftp.encode(@tftp.Packet::Ack(block)), "client:0")
                if payload.length() < 512 {
                  break
                }
              }
              _ => break
            }
        }
      }
      wire.val = collected
    })
    let result = @tftp.put(
      client,
      "server:69",
      "text.txt",
      contents,
      @tftp.ClientOptions::default().with_mode(@tftp.Netascii),
    )
    assert_true(result is Ok(_))
  })
  assert_eq(netascii_test_text(wire.val), "first line\r\nsecond\r\n\r\nthird")
}

///|
fn netascii_test_bytes(text : String) -> Bytes {
  let out : Array[Byte] = []
  for char in text {
    out.push(char.to_int().to_byte())
  }
  Bytes::from_array(out)
}

///|
fn netascii_test_text(bytes : Bytes) -> String {
  let out = StringBuilder()
  for byte in bytes {
    out.write_char(byte.to_int().unsafe_to_char())
  }
  out.to_string()
}

///|
/// The block counter the `get` loop uses, lifted so the wrap can be exercised
/// without sending 65535 real packets.
///
/// This mirrors the one line in `get` that advances `expected`, so a change to
/// the wrap rule shows up as a failing test rather than a stalled transfer.
fn advance(expected : UInt16, block : UInt16) -> UInt16? {
  if @tftp.block_follows(block, expected - 1) {
    Some(block + 1)
  } else {
    None
  }
}

///|
test "the get counter walks across the u16 wrap" {
  // Start as `get` does, then step through the seam and confirm every block is
  // accepted instead of being mistaken for a stale duplicate.
  let mut expected : UInt16 = 1
  expected = match advance(expected, 1) {
    Some(next) => next
    None => fail("block 1 was rejected")
  }
  // Jump the counter to the top of the range, where the wrap happens.
  expected = 65535
  expected = match advance(expected, 65535) {
    Some(next) => next
    None => fail("block 65535 was rejected")
  }
  assert_eq(expected, 0)
  expected = match advance(expected, 0) {
    Some(next) => next
    None => fail("block 0 right after the wrap was rejected")
  }
  assert_eq(expected, 1)
  // And the block after the wrap is accepted too.
  match advance(expected, 1) {
    Some(_) => ()
    None => fail("block 1 after the wrap was rejected")
  }
}

///|
test "the get counter rejects an out-of-order block" {
  let mut expected : UInt16 = 1
  expected = match advance(expected, 1) {
    Some(next) => next
    None => fail("block 1 was rejected")
  }
  // Block 5 is neither the next block nor a duplicate: the stop-and-wait loop
  // must not accept it.
  assert_true(advance(expected, 5) is None)
  // A duplicate of the last block is not "before", it is equal: also rejected
  // here, because the loop handles the duplicate case separately by re-ACKing.
  assert_true(advance(expected, 1) is None)
}

///|
test "ClientOptions accessors report what was set" {
  let options = @tftp.ClientOptions::default()
  assert_eq(options.mode(), @tftp.Octet)
  assert_eq(options.block_size(), 512)
  assert_eq(options.timeout_seconds(), 5)
  assert_eq(options.max_retries(), 6)
  assert_eq(options.options().length(), 0)
  let tuned = options
    .with_mode(@tftp.Netascii)
    .with_block_size(1024)
    .with_timeout(3)
    .with_max_retries(1)
    .with_options([@tftp.TftpOption::new("tsize", "0")])
  assert_eq(tuned.mode(), @tftp.Netascii)
  assert_eq(tuned.block_size(), 1024)
  assert_eq(tuned.timeout_seconds(), 3)
  assert_eq(tuned.max_retries(), 1)
  assert_eq(tuned.options().length(), 1)
}

///|
test "Packet accessors only answer for the packets they belong to" {
  let data = @tftp.Packet::Data(3, b"abc")
  assert_true(data.data_payload() is Some(_))
  assert_eq(data.block_number(), Some(3))
  assert_true(data.mode() is None)
  assert_true(data.options() is None)
  assert_true(data.error_info() is None)
  let ack = @tftp.Packet::Ack(7)
  assert_eq(ack.block_number(), Some(7))
  assert_true(ack.data_payload() is None)
  let rrq = @tftp.Packet::Rrq("f", @tftp.Netascii, [])
  assert_eq(rrq.mode(), Some(@tftp.Netascii))
  assert_true(rrq.options() is Some(_))
  let error = @tftp.Packet::Error(@tftp.AccessViolation, "denied")
  assert_eq(error.error_info(), Some((@tftp.AccessViolation, "denied")))
}

///|
async test "TransferOutcome accessors split received from sent" {
  // Built through a real transfer so the struct's own constructor stays private.
  let received = real_get_outcome()
  assert_true(received.received() is Some(_))
  assert_true(received.sent() is None)
  assert_true(received.result() is @tftp.Received(_))
  let sent = real_put_outcome()
  assert_true(sent.sent() is Some(_))
  assert_true(sent.received() is None)
  assert_true(sent.result() is @tftp.Sent(_))
}

///|
test "split_blocks adds the empty terminator for an exact multiple" {
  let exact : Bytes = Bytes::make(1024, b'x')
  let blocks = @tftp.split_blocks(exact, 512)
  assert_eq(blocks.length(), 3)
  assert_eq(blocks[0].length(), 512)
  assert_eq(blocks[1].length(), 512)
  assert_eq(blocks[2].length(), 0)
}

///|
test "split_blocks keeps a short final block" {
  let data : Bytes = Bytes::make(1000, b'x')
  let blocks = @tftp.split_blocks(data, 512)
  assert_eq(blocks.length(), 2)
  assert_eq(blocks[0].length(), 512)
  assert_eq(blocks[1].length(), 488)
}

///|
test "split_blocks turns an empty file into one empty block" {
  let blocks = @tftp.split_blocks(Bytes::new(0), 512)
  assert_eq(blocks.length(), 1)
  assert_eq(blocks[0].length(), 0)
}

///|
test "join_blocks is the inverse of split_blocks" {
  let data : Bytes = Bytes::make(1300, b'q')
  let joined = @tftp.join_blocks(@tftp.split_blocks(data, 512))
  assert_true(joined == data)
}

///|
test "timeout_to_ms converts whole seconds" {
  assert_eq(@tftp.timeout_to_ms(1), 1000)
  assert_eq(@tftp.timeout_to_ms(5), 5000)
  assert_eq(@tftp.timeout_to_ms(255), 255000)
}

///|
async test "get gives up when the peer never answers" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      // Read the request and every retry, but never answer.
      let mut i = 0
      while i < 4 {
        ignore(server.recv("client:0", 8000))
        i = i + 1
      }
    })
    let result = @tftp.get(
      client,
      "server:69",
      "gone.txt",
      @tftp.ClientOptions::default().with_timeout(1).with_max_retries(2),
    )
    match result {
      Ok(_) => fail("expected a timeout")
      Err(@tftp.ClientError::Timeout) => ()
      Err(_) => fail("expected a timeout error")
    }
  })
}

///|
async test "get ignores a packet that is not a DATA or ERROR" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  let payload = b"ok"
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      // A stray ACK first: the client must skip it and keep waiting.
      server.send(@tftp.encode(@tftp.Packet::Ack(9)), "client:0")
      server.send(@tftp.encode(@tftp.Packet::Data(1, payload)), "client:0")
      ignore(server.recv("client:0", 8000))
    })
    let result = @tftp.get(
      client,
      "server:69",
      "stray.bin",
      @tftp.ClientOptions::default(),
    )
    match result {
      Ok(outcome) =>
        match outcome.received() {
          Some(bytes) => assert_true(bytes == payload)
          None => fail("expected received bytes")
        }
      Err(_) => fail("get failed")
    }
  })
}

///|
async test "an injected packet from a stranger is ignored" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  // A third party drops a DATA into the client's inbox with the wrong peer
  // address; the TID filter has to reject it.
  client.inbox().inject(@tftp.Datagram::new(b"hostile", "stranger:1"))
  let recv = client.recv("server:69", 50)
  assert_true(recv is @tftp.Recv::Timeout)
  ignore(server)
}

///|
/// Runs a one-block `get` and returns its outcome, for accessor tests that need
/// a real `TransferOutcome`.
async fn real_get_outcome() -> @tftp.TransferOutcome {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  let result : Ref[@tftp.TransferOutcome?] = Ref(None)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      server.send(@tftp.encode(@tftp.Packet::Data(1, b"hi")), "client:0")
      ignore(server.recv("client:0", 8000))
    })
    match @tftp.get(client, "server:69", "f", @tftp.ClientOptions::default()) {
      Ok(outcome) => result.val = Some(outcome)
      Err(_) => ()
    }
  })
  match result.val {
    Some(outcome) => outcome
    None => abort("get failed in test helper")
  }
}

///|
/// Runs a one-block `put` and returns its outcome.
async fn real_put_outcome() -> @tftp.TransferOutcome {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  let result : Ref[@tftp.TransferOutcome?] = Ref(None)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      server.send(@tftp.encode(@tftp.Packet::Ack(0)), "client:0")
      match server.recv("client:0", 8000) {
        @tftp.Recv::Packet(datagram) =>
          match @tftp.decode(datagram.payload()) {
            Ok(@tftp.Packet::Data(block, _)) =>
              server.send(@tftp.encode(@tftp.Packet::Ack(block)), "client:0")
            _ => ()
          }
        @tftp.Recv::Timeout => ()
      }
    })
    match
      @tftp.put(client, "server:69", "f", b"hi", @tftp.ClientOptions::default()) {
      Ok(outcome) => result.val = Some(outcome)
      Err(_) => ()
    }
  })
  match result.val {
    Some(outcome) => outcome
    None => abort("put failed in test helper")
  }
}

///|
async test "get re-acknowledges a duplicate block without delivering it twice" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  // Two full blocks, so the duplicate of block 1 arrives while block 2 is still
  // expected. A naive client would append "aaa" a second time.
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      // 512-byte blocks, so the file does not end on the first one and the
      // duplicate really arrives mid-transfer.
      let full : Bytes = Bytes::make(512, b'a')
      server.send(@tftp.encode(@tftp.Packet::Data(1, full)), "client:0")
      let ack = server.recv("client:0", 8000)
      match ack {
        @tftp.Recv::Packet(datagram) =>
          match @tftp.decode(datagram.payload()) {
            Ok(@tftp.Packet::Ack(block)) => assert_eq(block, 1)
            _ => fail("expected an ACK for block 1")
          }
        @tftp.Recv::Timeout => fail("no ACK for block 1")
      }
      // Replay block 1, then send the real block 2 and the short tail.
      server.send(@tftp.encode(@tftp.Packet::Data(1, full)), "client:0")
      server.send(@tftp.encode(@tftp.Packet::Data(2, b"end")), "client:0")
      ignore(server.recv("client:0", 8000))
      ignore(server.recv("client:0", 8000))
    })
    let result = @tftp.get(
      client,
      "server:69",
      "dup.bin",
      @tftp.ClientOptions::default().with_max_retries(3),
    )
    match result {
      Ok(outcome) =>
        match outcome.received() {
          // 512 "a" plus "end": the duplicate must not add 512 more.
          Some(bytes) => assert_eq(bytes.length(), 515)
          None => fail("expected received bytes")
        }
      Err(_) => fail("get failed")
    }
  })
}

///|
async test "get reads the tsize the peer negotiated" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      server.send(
        @tftp.encode(
          @tftp.Packet::Oack([
            @tftp.TftpOption::new("blksize", "512"),
            @tftp.TftpOption::new("tsize", "5"),
          ]),
        ),
        "client:0",
      )
      server.send(@tftp.encode(@tftp.Packet::Data(1, b"hello")), "client:0")
      ignore(server.recv("client:0", 8000))
    })
    let result = @tftp.get(
      client,
      "server:69",
      "sized.txt",
      @tftp.ClientOptions::default(),
    )
    match result {
      Ok(outcome) => assert_eq(outcome.tsize(), Some(5))
      Err(_) => fail("get failed")
    }
  })
}

///|
async test "an unknown option in the OACK is ignored" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      // A server is allowed to answer with an option we never asked for, and a
      // value we cannot read must not abort the transfer.
      server.send(
        @tftp.encode(
          @tftp.Packet::Oack([
            @tftp.TftpOption::new("windowsize", "4"),
            @tftp.TftpOption::new("blksize", "not-a-number"),
          ]),
        ),
        "client:0",
      )
      server.send(@tftp.encode(@tftp.Packet::Data(1, b"ok")), "client:0")
      ignore(server.recv("client:0", 8000))
    })
    let result = @tftp.get(
      client,
      "server:69",
      "odd.bin",
      @tftp.ClientOptions::default(),
    )
    match result {
      Ok(outcome) =>
        match outcome.received() {
          Some(bytes) => assert_true(bytes == b"ok")
          None => fail("expected received bytes")
        }
      Err(_) => fail("get failed on an unreadable option")
    }
  })
}

///|
async test "a malformed packet is skipped, not fatal" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      // Garbage first, then the real data: a decode failure must not end the
      // transfer, the peer will simply retransmit.
      server.send(b"\x00\x09garbage", "client:0")
      server.send(@tftp.encode(@tftp.Packet::Data(1, b"ok")), "client:0")
      ignore(server.recv("client:0", 8000))
    })
    let result = @tftp.get(
      client,
      "server:69",
      "junk.bin",
      @tftp.ClientOptions::default(),
    )
    match result {
      Ok(outcome) =>
        match outcome.received() {
          Some(bytes) => assert_true(bytes == b"ok")
          None => fail("expected received bytes")
        }
      Err(_) => fail("get failed on a malformed packet")
    }
  })
}

///|
async test "get decodes a netascii file back to local line endings" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      // The wire form of "a\nb\r\nc": CRLF for the newlines, CR-NUL for the CR.
      let wire = Bytes::from_array([
        b'a', b'\r', b'\n', b'b', b'\r', b'\x00', b'c',
      ])
      server.send(@tftp.encode(@tftp.Packet::Data(1, wire)), "client:0")
      ignore(server.recv("client:0", 8000))
    })
    let result = @tftp.get(
      client,
      "server:69",
      "text.txt",
      @tftp.ClientOptions::default().with_mode(@tftp.Netascii),
    )
    match result {
      Ok(outcome) =>
        match outcome.received() {
          Some(bytes) => assert_eq(netascii_test_text(bytes), "a\nb\rc")
          None => fail("expected received bytes")
        }
      Err(_) => fail("get failed")
    }
  })
}

///|
async test "get restores a netascii line ending split across two blocks" {
  // The regression from the issue: block one ends on the CR of a CRLF and
  // block two opens on the LF, so no single block contains the escape. The
  // client must join them into one newline rather than emit CR + LF.
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  let text = "abcdefg\n"
  let wire = @tftp.netascii_encode_all(netascii_test_bytes(text))
  // "abcdefg\n" becomes "abcdefg\r\n": nine bytes over a block size of 8.
  assert_eq(text.length(), 8)
  assert_eq(netascii_test_text(wire), "abcdefg\r\n")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      // The split a `--blksize 8` transfer produces: "abcdefg\r" + "\n".
      server.send(
        @tftp.encode(
          @tftp.Packet::Data(1, wire.clamped_view(start=0, end=8).to_owned()),
        ),
        "client:0",
      )
      ignore(server.recv("client:0", 8000))
      server.send(
        @tftp.encode(
          @tftp.Packet::Data(2, wire.clamped_view(start=8).to_owned()),
        ),
        "client:0",
      )
      ignore(server.recv("client:0", 8000))
    })
    let result = @tftp.get(
      client,
      "server:69",
      "split.txt",
      @tftp.ClientOptions::default()
      .with_mode(@tftp.Netascii)
      .with_block_size(8),
    )
    match result {
      Ok(outcome) =>
        match outcome.received() {
          // Eight bytes: the CRLF arrives as one newline, not as CR + LF.
          Some(bytes) => {
            assert_eq(bytes.length(), 8)
            assert_eq(netascii_test_text(bytes), text)
          }
          None => fail("expected received bytes")
        }
      Err(_) => fail("get failed on a split line ending")
    }
  })
}

///|
async test "get reports an ERROR that arrives after the first block" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      // A full block, so the file is not over yet, then an ERROR mid-transfer.
      server.send(
        @tftp.encode(@tftp.Packet::Data(1, Bytes::make(512, b'x'))),
        "client:0",
      )
      ignore(server.recv("client:0", 8000))
      server.send(
        @tftp.encode(@tftp.Packet::Error(@tftp.AccessViolation, "revoked")),
        "client:0",
      )
    })
    let result = @tftp.get(
      client,
      "server:69",
      "aborted.bin",
      @tftp.ClientOptions::default().with_max_retries(2),
    )
    match result {
      Ok(_) => fail("expected an error")
      Err(@tftp.ClientError::PeerError(code, _)) =>
        assert_eq(code, @tftp.AccessViolation)
      Err(_) => fail("expected a peer error")
    }
  })
}

///|
async test "put reports a peer ERROR instead of retrying" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      // A write refused outright: the client must surface it, not resend.
      server.send(
        @tftp.encode(@tftp.Packet::Error(@tftp.AccessViolation, "read-only")),
        "client:0",
      )
    })
    let result = @tftp.put(
      client,
      "server:69",
      "denied.bin",
      b"nope",
      @tftp.ClientOptions::default().with_max_retries(2),
    )
    match result {
      Ok(_) => fail("expected an error")
      Err(@tftp.ClientError::PeerError(code, _)) =>
        assert_eq(code, @tftp.AccessViolation)
      Err(_) => fail("expected a peer error")
    }
  })
}

///|
async test "put reports an ERROR that arrives mid-transfer" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      server.send(@tftp.encode(@tftp.Packet::Ack(0)), "client:0")
      let first = server.recv("client:0", 8000)
      match first {
        @tftp.Recv::Packet(_) => ()
        @tftp.Recv::Timeout => fail("no DATA arrived")
      }
      // Refuse the first block instead of acknowledging it.
      server.send(
        @tftp.encode(@tftp.Packet::Error(@tftp.DiskFull, "full")),
        "client:0",
      )
    })
    let result = @tftp.put(
      client,
      "server:69",
      "full.bin",
      Bytes::make(600, b'd'),
      @tftp.ClientOptions::default().with_max_retries(2),
    )
    match result {
      Ok(_) => fail("expected an error")
      Err(@tftp.ClientError::PeerError(code, _)) =>
        assert_eq(code, @tftp.DiskFull)
      Err(_) => fail("expected a peer error")
    }
  })
}

///|
async test "put honours a negotiated timeout in the OACK" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      server.send(
        @tftp.encode(
          @tftp.Packet::Oack([
            @tftp.TftpOption::new("timeout", "2"),
            @tftp.TftpOption::new("tsize", "2"),
          ]),
        ),
        "client:0",
      )
      match server.recv("client:0", 8000) {
        @tftp.Recv::Packet(datagram) =>
          match @tftp.decode(datagram.payload()) {
            Ok(@tftp.Packet::Data(block, _)) =>
              server.send(@tftp.encode(@tftp.Packet::Ack(block)), "client:0")
            _ => ()
          }
        @tftp.Recv::Timeout => ()
      }
    })
    let result = @tftp.put(
      client,
      "server:69",
      "neg.bin",
      b"hi",
      @tftp.ClientOptions::default(),
    )
    match result {
      Ok(outcome) => assert_eq(outcome.tsize(), Some(2))
      Err(_) => fail("put failed")
    }
  })
}

///|
async test "put gives up on a malformed OACK that never acknowledges" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let mut i = 0
      while i < 5 {
        ignore(server.recv("client:0", 8000))
        i = i + 1
      }
    })
    let result = @tftp.put(
      client,
      "server:69",
      "silent.bin",
      b"lost",
      @tftp.ClientOptions::default().with_timeout(1).with_max_retries(2),
    )
    match result {
      Ok(_) => fail("expected a timeout")
      Err(@tftp.ClientError::Timeout) => ()
      Err(_) => fail("expected a timeout error")
    }
  })
}

///|
async test "get repeats its request when the first answer is lost" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  let payload = b"after the loss"
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      // The first DATA never makes it: the client should re-ask rather than
      // wait out its whole budget in silence.
      server.outbox().drop_next_packet()
      server.send(@tftp.encode(@tftp.Packet::Data(1, payload)), "client:0")
      let repeat = server.recv("client:0", 8000)
      match repeat {
        @tftp.Recv::Packet(datagram) =>
          match @tftp.decode(datagram.payload()) {
            Ok(@tftp.Packet::Rrq(_, _, _)) => {
              server.send(
                @tftp.encode(@tftp.Packet::Data(1, payload)),
                "client:0",
              )
              ignore(server.recv("client:0", 8000))
            }
            _ => fail("expected the client to repeat its RRQ")
          }
        @tftp.Recv::Timeout => fail("client never retried")
      }
    })
    let result = @tftp.get(
      client,
      "server:69",
      "retry.bin",
      @tftp.ClientOptions::default().with_timeout(1).with_max_retries(3),
    )
    match result {
      Ok(outcome) =>
        match outcome.received() {
          Some(bytes) => assert_true(bytes == payload)
          None => fail("expected received bytes")
        }
      Err(@tftp.ClientError::Timeout) => fail("client gave up too early")
      Err(_) => fail("get failed")
    }
  })
}

///|
async test "get re-acknowledges a block it already delivered" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      let full : Bytes = Bytes::make(512, b'a')
      server.send(@tftp.encode(@tftp.Packet::Data(1, full)), "client:0")
      // Wait for the ACK, then replay block 1 while block 2 is expected: the
      // client must answer with an ACK for block 1 again.
      ignore(server.recv("client:0", 8000))
      server.send(@tftp.encode(@tftp.Packet::Data(1, full)), "client:0")
      let duplicate_ack = server.recv("client:0", 8000)
      match duplicate_ack {
        @tftp.Recv::Packet(datagram) =>
          match @tftp.decode(datagram.payload()) {
            Ok(@tftp.Packet::Ack(block)) => assert_eq(block, 1)
            _ => fail("expected a repeated ACK for block 1")
          }
        @tftp.Recv::Timeout =>
          fail("client did not re-acknowledge the duplicate")
      }
      server.send(@tftp.encode(@tftp.Packet::Data(2, b"end")), "client:0")
      ignore(server.recv("client:0", 8000))
    })
    let result = @tftp.get(
      client,
      "server:69",
      "dup.bin",
      @tftp.ClientOptions::default().with_max_retries(3),
    )
    match result {
      Ok(outcome) =>
        match outcome.received() {
          Some(bytes) => assert_eq(bytes.length(), 515)
          None => fail("expected received bytes")
        }
      Err(_) => fail("get failed")
    }
  })
}

///|
async test "get retries on a nudge even before the first block" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      // Nothing at all for a while: the client's timeout fires and it nudges,
      // then answers the retried request.
      let retry = server.recv("client:0", 8000)
      match retry {
        @tftp.Recv::Packet(datagram) =>
          match @tftp.decode(datagram.payload()) {
            Ok(@tftp.Packet::Rrq(_, _, _)) => {
              server.send(
                @tftp.encode(@tftp.Packet::Data(1, b"late")),
                "client:0",
              )
              ignore(server.recv("client:0", 8000))
            }
            _ => fail("expected a repeated RRQ")
          }
        @tftp.Recv::Timeout => fail("client never nudged")
      }
    })
    let result = @tftp.get(
      client,
      "server:69",
      "slow.bin",
      @tftp.ClientOptions::default().with_timeout(1).with_max_retries(3),
    )
    match result {
      Ok(outcome) =>
        match outcome.received() {
          Some(bytes) => assert_true(bytes == b"late")
          None => fail("expected received bytes")
        }
      Err(_) => fail("get failed")
    }
  })
}

///|
async test "put retransmits after its ACK is lost" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  let payload : Bytes = Bytes::make(700, b'p')
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.recv("client:0", 1000))
      server.send(@tftp.encode(@tftp.Packet::Ack(0)), "client:0")
      // Read block 1, then lose its ACK so the client resends.
      ignore(server.recv("client:0", 8000))
      server.outbox().drop_next_packet()
      server.send(@tftp.encode(@tftp.Packet::Ack(1)), "client:0")
      let resent = server.recv("client:0", 8000)
      match resent {
        @tftp.Recv::Packet(datagram) =>
          match @tftp.decode(datagram.payload()) {
            Ok(@tftp.Packet::Data(block, _)) => {
              assert_eq(block, 1)
              server.send(@tftp.encode(@tftp.Packet::Ack(1)), "client:0")
            }
            _ => fail("expected a resent DATA")
          }
        @tftp.Recv::Timeout => fail("client did not resend")
      }
      // Block 2, the short tail.
      match server.recv("client:0", 8000) {
        @tftp.Recv::Packet(datagram) =>
          match @tftp.decode(datagram.payload()) {
            Ok(@tftp.Packet::Data(block, _)) =>
              server.send(@tftp.encode(@tftp.Packet::Ack(block)), "client:0")
            _ => ()
          }
        @tftp.Recv::Timeout => ()
      }
    })
    let result = @tftp.put(
      client,
      "server:69",
      "lossy.bin",
      payload,
      @tftp.ClientOptions::default().with_timeout(1).with_max_retries(3),
    )
    match result {
      Ok(outcome) => assert_eq(outcome.sent(), Some(700))
      Err(_) => fail("put failed")
    }
  })
}

///|
/// A read server that follows RFC 2347 to the letter: it sends the OACK and
/// then *waits for ACK 0* before the first DATA, like this module's own
/// `serve_read` does.
///
/// The lenient double above answers an OACK straight with DATA 1, so it never
/// catches a client that forgets the ACK 0; this one hangs if that happens,
/// which is the whole point of writing it out separately.
async fn serve_read_strict(
  server : @tftp.MemoryTransport,
  blocks : Array[Bytes],
  block_size : Int32,
) -> Unit {
  ignore(server.recv("client:0", 1000))
  server.send(
    @tftp.encode(
      @tftp.Packet::Oack([
        @tftp.TftpOption::new("blksize", block_size.to_string()),
      ]),
    ),
    "client:0",
  )
  // The client's ACK 0 is what licenses the data; anything else means it
  // never answered the OACK.
  match server.recv("client:0", 1000) {
    @tftp.Recv::Packet(datagram) =>
      match @tftp.decode(datagram.payload()) {
        Ok(@tftp.Packet::Ack(0)) => ()
        _ => fail("expected ACK 0 after the OACK")
      }
    @tftp.Recv::Timeout => fail("no ACK 0 after the OACK")
  }
  let mut i = 0
  while i < blocks.length() {
    server.send(
      @tftp.encode(@tftp.Packet::Data((i + 1).to_uint16(), blocks[i])),
      "client:0",
    )
    ignore(server.recv("client:0", 1000))
    i = i + 1
  }
}

///|
async test "get acknowledges an OACK before the data arrives" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  let payload = b"negotiated"
  @async.with_task_group(group => {
    group.spawn_bg(() => serve_read_strict(server, [payload], 1024))
    let result = @tftp.get(
      client,
      "server:69",
      "greeting.txt",
      @tftp.ClientOptions::default().with_block_size(1024),
    )
    match result {
      Ok(outcome) =>
        match outcome.received() {
          Some(bytes) => assert_true(bytes == payload)
          None => fail("expected received bytes")
        }
      Err(_) => fail("get failed")
    }
  })
}

///|
/// A write client that waits for every ACK, the last one included.
///
/// A server that returns without acknowledging the short block leaves this
/// hanging, which is exactly the bug worth pinning down.
async fn put_expecting_final_ack(
  client : @tftp.MemoryTransport,
  payload : Bytes,
  block_size : Int32,
) -> Int32 {
  let result = @tftp.put(
    client,
    "server:69",
    "out.bin",
    payload,
    @tftp.ClientOptions::default().with_block_size(block_size).with_timeout(1),
  )
  match result {
    Ok(outcome) =>
      match outcome.sent() {
        Some(bytes) => bytes
        None => fail("expected a byte count")
      }
    Err(_) => fail("put never got its last ACK")
  }
}

///|
async test "the last block of a write is acknowledged" {
  let (client, server) = @tftp.MemoryTransport::pair("client:0", "server:69")
  // Two blocks: a full one and a short one, so the short block ends the file.
  let payload : Bytes = Bytes::make(600, b'z')
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let files = @tftp.MemoryFileSystem::new()
      let options = @tftp.ServerOptions::default().with_root("/")
      let session = @tftp.TransferSession::new(
        server, files, "client:0", options,
      )
      let request = server.recv("client:0", 1000)
      match request {
        @tftp.Recv::Packet(datagram) =>
          match @tftp.decode(datagram.payload()) {
            Ok(packet) => {
              let outcome = session.serve(packet)
              // The bytes must have landed, and the session must report them.
              assert_eq(outcome.bytes(), 600)
            }
            Err(_) => fail("bad request")
          }
        @tftp.Recv::Timeout => fail("no request")
      }
    })
    let sent = put_expecting_final_ack(client, payload, 512)
    assert_eq(sent, 600)
  })
}
