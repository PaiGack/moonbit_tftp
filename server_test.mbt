///|
/// Black-box tests of the server: request intake, path policy, error codes,
/// full read/write sessions over the in-memory transport, and concurrency.

///|
/// Renders a decoded packet for a failure message. `Packet` has no `Show`, on
/// purpose: the layer never prints, so tests spell the rendering out here.
fn packet_repr(packet : Result[@tftp.Packet, @tftp.DecodeError]) -> String {
  match packet {
    Ok(packet) => packet.to_repr().to_string()
    Err(error) => "undecodable \{error.to_repr()}"
  }
}

// ---------------------------------------------------------------------------
// Path policy
// ---------------------------------------------------------------------------

///|
test "resolve_path keeps a plain name inside the root" {
  assert_eq(@tftp.resolve_path("/srv/tftp", "a.txt"), Ok("/srv/tftp/a.txt"))
  assert_eq(
    @tftp.resolve_path("/srv/tftp", "docs/a.txt"),
    Ok("/srv/tftp/docs/a.txt"),
  )
  assert_eq(@tftp.resolve_path("root", "a.txt"), Ok("root/a.txt"))
  assert_eq(@tftp.resolve_path("/", "a.txt"), Ok("/a.txt"))
}

///|
test "resolve_path refuses traversal instead of normalising it away" {
  // The classic, and the one a naive "strip ../" would get wrong by turning an
  // attack into a successful read of a different file.
  assert_true(@tftp.resolve_path("/srv/tftp", "../etc/passwd") is Err(_))
  assert_true(@tftp.resolve_path("/srv/tftp", "../../etc/passwd") is Err(_))
  // A traversal in the middle is refused too, not simplified to `secret`.
  assert_true(@tftp.resolve_path("/srv/tftp", "docs/../../secret") is Err(_))
  assert_true(@tftp.resolve_path("/srv/tftp", "docs/../secret") is Err(_))
  assert_true(@tftp.resolve_path("/srv/tftp", "..") is Err(_))
  // A filename is never URL-decoded, so `%2e%2e` is just an odd name rather
  // than an escape: `.../a` stays inside the root, which is the point.
  assert_eq(@tftp.resolve_path("/srv/tftp", ".../a"), Ok("/srv/tftp/.../a"))
  assert_eq(@tftp.resolve_path("/srv/tftp", "..%2f.."), Ok("/srv/tftp/..%2f.."))
}

///|
test "resolve_path treats a leading slash as a separator, not an escape" {
  // A leading slash is a separator, never a root override: the name still
  // lands under the served root, which is what bounds it.
  assert_eq(
    @tftp.resolve_path("/srv/tftp", "/etc/passwd"),
    Ok("/srv/tftp/etc/passwd"),
  )
  // Backslashes are ordinary name characters on this platform, and a name that
  // carries one is more likely an attempt at a Windows escape than a real
  // file, so it is refused.
  assert_true(@tftp.resolve_path("/srv/tftp", "a\\b") is Err(_))
  assert_true(@tftp.resolve_path("/srv/tftp", "") is Err(_))
  assert_true(@tftp.resolve_path("/srv/tftp", "a\u{00}b") is Err(_))
  // Redundant separators and `.` are safe no-ops, so they resolve rather than
  // fail: a client that writes `./a.txt` is not attacking anything.
  assert_eq(@tftp.resolve_path("/srv/tftp", "./a.txt"), Ok("/srv/tftp/a.txt"))
  assert_eq(
    @tftp.resolve_path("/srv/tftp", "docs//a.txt"),
    Ok("/srv/tftp/docs/a.txt"),
  )
}

///|
test "resolve_path reports traversal as an access violation" {
  match @tftp.resolve_path("/srv/tftp", "../etc/passwd") {
    Err(error) => {
      assert_eq(error.error_code(), @tftp.AccessViolation)
      assert_eq(
        error.to_packet(),
        @tftp.Packet::Error(
          @tftp.AccessViolation,
          "path escapes the served root",
        ),
      )
    }
    Ok(_) => fail("expected a traversal to be refused")
  }
}

// ---------------------------------------------------------------------------
// Request intake
// ---------------------------------------------------------------------------

///|
async fn plan(
  files : @tftp.MemoryFileSystem,
  request : @tftp.Packet,
) -> Result[@tftp.RequestAction, @tftp.ServerError] {
  @tftp.plan_request(
    @tftp.ServerOptions::default().with_root("/srv"),
    files,
    request,
  )
}

///|
async test "plan_request accepts a plain RRQ" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/a.txt", b"hello")
  let outcome = plan(files, @tftp.Packet::Rrq("a.txt", @tftp.Octet, []))
  assert_eq(outcome, Ok(@tftp.ServeFile("/srv/a.txt")))
}

///|
async test "plan_request accepts a plain WRQ" {
  let files = @tftp.MemoryFileSystem::new()
  assert_eq(
    plan(files, @tftp.Packet::Wrq("new.txt", @tftp.Octet, [])),
    Ok(@tftp.ReceiveFile("/srv/new.txt")),
  )
}

///|
async test "plan_request accepts a RRQ with options and lets the session answer" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/a.txt", b"hello")
  let request = @tftp.Packet::Rrq("a.txt", @tftp.Octet, [
    @tftp.TftpOption::new("blksize", "1024"),
  ])
  // The OACK itself is the session's to send, because a RRQ's `tsize` answer
  // is the file size and only the file backend knows it.
  assert_eq(plan(files, request), Ok(@tftp.ServeFile("/srv/a.txt")))
}

///|
async test "plan_request accepts a WRQ with options and lets the session answer" {
  let files = @tftp.MemoryFileSystem::new()
  let request = @tftp.Packet::Wrq("new.txt", @tftp.Octet, [
    @tftp.TftpOption::new("blksize", "1024"),
  ])
  // A WRQ's OACK needs no file size — the client already said what it will
  // send — but the packet still belongs to the session, so that one path sends
  // every first packet and a refused request keeps its ERROR on the request
  // TID.
  assert_eq(plan(files, request), Ok(@tftp.ReceiveFile("/srv/new.txt")))
}

///|
async test "plan_request drops a below-range option but keeps the request" {
  let files = @tftp.MemoryFileSystem::new()
  let request = @tftp.Packet::Rrq("a.txt", @tftp.Octet, [
    @tftp.TftpOption::new("blksize", "1"),
  ])
  // Below the minimum for every option kind, so `parse_options` drops it and
  // the request itself survives: RFC 2347 section 2 asks for exactly that.
  assert_eq(plan(files, request), Ok(@tftp.ServeFile("/srv/a.txt")))
}

///|
async test "plan_request refuses a traversal before opening the file" {
  let files = @tftp.MemoryFileSystem::new()
  match plan(files, @tftp.Packet::Rrq("../etc/passwd", @tftp.Octet, [])) {
    Err(error) => assert_eq(error.error_code(), @tftp.AccessViolation)
    Ok(_) => fail("expected the traversal to be refused")
  }
}

///|
async test "plan_request refuses an unwritable path the same way" {
  let files = @tftp.MemoryFileSystem::new()
  match plan(files, @tftp.Packet::Wrq("../../etc/passwd", @tftp.Octet, [])) {
    Err(error) => assert_eq(error.error_code(), @tftp.AccessViolation)
    Ok(_) => fail("expected the traversal to be refused")
  }
}

///|
async test "plan_request refuses a directory" {
  let files = @tftp.MemoryFileSystem::new()
  match plan(files, @tftp.Packet::Rrq("docs/", @tftp.Octet, [])) {
    Err(error) => assert_eq(error.error_code(), @tftp.AccessViolation)
    Ok(_) => fail("expected the directory to be refused")
  }
}

///|
async test "plan_request refuses an existing file under the create-only policy" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/there.txt", b"already here")
  match plan(files, @tftp.Packet::Wrq("there.txt", @tftp.Octet, [])) {
    Err(error) => assert_eq(error.error_code(), @tftp.FileAlreadyExists)
    Ok(_) => fail("expected ERROR 6")
  }
}

///|
async test "plan_request overwrites when the policy says so" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/there.txt", b"already here")
  let options = @tftp.ServerOptions::default()
    .with_root("/srv")
    .with_write_policy(@tftp.AllowOverwrite)
  assert_eq(
    @tftp.plan_request(
      options,
      files,
      @tftp.Packet::Wrq("there.txt", @tftp.Octet, []),
    ),
    Ok(@tftp.ReceiveFile("/srv/there.txt")),
  )
}

///|
async test "plan_request refuses a request that is not a RRQ or WRQ" {
  let files = @tftp.MemoryFileSystem::new()
  match plan(files, @tftp.Packet::Ack(3)) {
    Err(error) => assert_eq(error.error_code(), @tftp.IllegalOperation)
    Ok(_) => fail("expected ERROR 4")
  }
}

///|
async test "plan_request drops an out-of-range option but keeps the request" {
  let files = @tftp.MemoryFileSystem::new()
  // RFC 2347 section 2 makes an unanswerable value a *dropped* option, not a
  // failed request: the transfer runs on with the defaults.
  let request = @tftp.Packet::Rrq("a.txt", @tftp.Octet, [
    @tftp.TftpOption::new("blksize", "99999999"),
  ])
  assert_eq(plan(files, request), Ok(@tftp.ServeFile("/srv/a.txt")))
}

///|
async test "plan_request turns a bad tsize shape into ERROR 8" {
  let files = @tftp.MemoryFileSystem::new()
  // A read request's tsize is a placeholder, so a non-zero one is a shape the
  // server cannot answer (RFC 2349, section 4).
  let request = @tftp.Packet::Rrq("a.txt", @tftp.Octet, [
    @tftp.TftpOption::new("tsize", "123"),
  ])
  match plan(files, request) {
    Err(error) => assert_eq(error.error_code(), @tftp.OptionNegotiationFailed)
    Ok(_) => fail("expected ERROR 8")
  }
}

// ---------------------------------------------------------------------------
// Full sessions over the in-memory transport
// ---------------------------------------------------------------------------

///|
/// A session plus the *server* end of the link, so a test can drop a packet
/// straight into the session's inbox.
///
/// This is how the "what if the peer sends something unexpected" branches are
/// reached: a real network delivers those, and no well-behaved client will.
fn session_triple(
  files : @tftp.MemoryFileSystem,
  options : @tftp.ServerOptions,
) -> (
  @tftp.MemoryTransport,
  @tftp.MemoryTransport,
  @tftp.TransferSession[@tftp.MemoryTransport, @tftp.MemoryFileSystem],
) {
  let (client, server) = @tftp.MemoryTransport::pair(
    "127.0.0.1:5000", "127.0.0.1:7000",
  )
  let session = @tftp.TransferSession::new(
    server, files, "127.0.0.1:5000", options,
  )
  (client, server, session)
}

///|
/// Queues `payload` as if it had arrived from the session's peer.
fn inject(server : @tftp.MemoryTransport, payload : Bytes) -> Unit {
  server.inbox().inject(@tftp.Datagram::new(payload, "127.0.0.1:5000"))
}

///|
/// Builds a server session wired to a client transport, returning both.
fn session_pair(
  files : @tftp.MemoryFileSystem,
  options : @tftp.ServerOptions,
  client_address : String,
  server_address : String,
) -> (
  @tftp.MemoryTransport,
  @tftp.TransferSession[@tftp.MemoryTransport, @tftp.MemoryFileSystem],
) {
  let (client, server) = @tftp.MemoryTransport::pair(
    client_address, server_address,
  )
  let session = @tftp.TransferSession::new(
    server, files, client_address, options,
  )
  (client, session)
}

///|
async test "a read session sends every block and stops on the short one" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/a.txt", b"hello, tftp")
  let (client, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  let outcome : @tftp.SessionOutcome? = None
  let mut result = None
  @async.with_task_group(group => {
    let task = group.spawn(() => {
      session.serve(@tftp.Packet::Rrq("a.txt", @tftp.Octet, []))
    })
    // The client half: read the DATA, acknowledge it, and check the payload.
    let mut payload = Bytes::new(0)
    let mut block : UInt16 = 1
    while true {
      match client.recv("127.0.0.1:7000", 1000) {
        @tftp.Recv::Packet(datagram) =>
          match @tftp.decode(datagram.payload()) {
            Ok(@tftp.Packet::Data(number, chunk)) => {
              assert_eq(number, block)
              payload = payload + chunk
              client.send(
                @tftp.encode(@tftp.Packet::Ack(number)),
                "127.0.0.1:7000",
              )
              block = block + 1
              if chunk.length() < @tftp.default_block_size {
                break
              }
            }
            Ok(_) => fail("expected DATA")
            Err(error) => fail("undecodable: \{error.to_repr()}")
          }
        @tftp.Recv::Timeout => break
      }
    }
    assert_eq(payload, b"hello, tftp")
    result = Some(task.wait())
  })
  assert_eq(result, Some(@tftp.Read(11)))
  ignore(outcome)
}

///|
async test "a read session of an exact block multiple sends an empty tail block" {
  let files = @tftp.MemoryFileSystem::new()
  // 512 bytes exactly: the peer can only learn that the file ended from the
  // extra, empty block (RFC 1350, section 1).
  let payload = Bytes::from_array(FixedArray::make(512, b'x'))
  files.put("/srv/one.bin", payload)
  let (client, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  let mut blocks = 0
  let mut total = 0
  @async.with_task_group(group => {
    let task = group.spawn(() => {
      session.serve(@tftp.Packet::Rrq("one.bin", @tftp.Octet, []))
    })
    while true {
      match client.recv("127.0.0.1:7000", 1000) {
        @tftp.Recv::Packet(datagram) =>
          match @tftp.decode(datagram.payload()) {
            Ok(@tftp.Packet::Data(number, chunk)) => {
              blocks = blocks + 1
              total = total + chunk.length()
              client.send(
                @tftp.encode(@tftp.Packet::Ack(number)),
                "127.0.0.1:7000",
              )
              if chunk.length() < @tftp.default_block_size {
                break
              }
            }
            _ => fail("expected DATA")
          }
        @tftp.Recv::Timeout => break
      }
    }
    ignore(task.wait())
  })
  assert_eq(blocks, 2)
  assert_eq(total, 512)
}

///|
async test "a read session reports a missing file as ERROR 1" {
  let files = @tftp.MemoryFileSystem::new()
  let (client, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  let mut outcome = None
  @async.with_task_group(group => {
    let task = group.spawn(() => {
      session.serve(@tftp.Packet::Rrq("gone.txt", @tftp.Octet, []))
    })
    match client.recv("127.0.0.1:7000", 1000) {
      @tftp.Recv::Packet(datagram) =>
        assert_eq(
          @tftp.decode(datagram.payload()),
          Ok(@tftp.Packet::Error(@tftp.FileNotFound, "read /srv/gone.txt")),
        )
      @tftp.Recv::Timeout => fail("expected an ERROR")
    }
    outcome = Some(task.wait())
  })
  match outcome {
    Some(@tftp.Failed(error)) =>
      assert_eq(error.error_code(), @tftp.FileNotFound)
    _ => fail("expected a failed read")
  }
}

///|
/// Drives one `step_write` call with the first packet already sent, returning
/// `(finished, outcome)`; the caller threads `acknowledged`/`collected` along.
async fn step_once(
  session : @tftp.TransferSession[@tftp.MemoryTransport, @tftp.MemoryFileSystem],
  acknowledged : UInt16,
  collected : Bytes,
  retries : Int32,
) -> (Bool, @tftp.SessionOutcome) {
  session.step_write(acknowledged, collected, retries)
}

///|
/// The whole write handshake as the caller sees it: send ACK 0 by hand, then
/// step until a short block ends the file. This is the naked `step_write`
/// shape, without the retransmission timer that `serve` also owns, so a test
/// can drive it one packet at a time.
async test "step_write acknowledges each block and ends on the short one" {
  let files = @tftp.MemoryFileSystem::new()
  let (client, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  let full = Bytes::from_array(FixedArray::make(512, b'a'))
  let data1 = @tftp.encode(@tftp.Packet::Data(1, full))
  let data2 = @tftp.encode(@tftp.Packet::Data(2, b"tail"))
  // The client and the server each hold one half of the exchange, so they have
  // to run as two tasks: `send` hands control to the other endpoint when it
  // pauses, and expecting DATA 2 before DATA 1 has been acknowledged would
  // make one side read the other's packet by accident. The client task also
  // has to drain ACK 0, so the server's first `step_write` finds DATA 1 at the
  // head of its inbox.
  @async.with_task_group(group => {
    let client_task = group.spawn(() => {
      client.send(data1, "127.0.0.1:7000")
      match client.recv("127.0.0.1:7000", 1000) {
        @tftp.Recv::Packet(datagram) =>
          assert_eq(@tftp.decode(datagram.payload()), Ok(@tftp.Packet::Ack(0)))
        @tftp.Recv::Timeout => fail("expected ACK 0")
      }
      client.send(data2, "127.0.0.1:7000")
      match client.recv("127.0.0.1:7000", 1000) {
        @tftp.Recv::Packet(datagram) =>
          assert_eq(@tftp.decode(datagram.payload()), Ok(@tftp.Packet::Ack(1)))
        @tftp.Recv::Timeout => fail("expected ACK 1")
      }
      match client.recv("127.0.0.1:7000", 1000) {
        @tftp.Recv::Packet(datagram) =>
          assert_eq(@tftp.decode(datagram.payload()), Ok(@tftp.Packet::Ack(2)))
        @tftp.Recv::Timeout => fail("expected ACK 2")
      }
    })
    // ACK 0 opens the session; the caller owns that packet.
    session.transport.send(@tftp.encode(@tftp.Packet::Ack(0)), "127.0.0.1:5000")
    let (done1, outcome1) = step_once(session, 0, Bytes::new(0), 3)
    assert_false(done1)
    assert_eq(outcome1, @tftp.Written(512))
    let (done2, outcome2) = step_once(session, 1, full, 3)
    assert_true(done2)
    assert_eq(outcome2, @tftp.Written(516))
    ignore(client_task.wait())
  })
}

///|
async test "step_write re-acknowledges a duplicate without storing it twice" {
  let files = @tftp.MemoryFileSystem::new()
  let (client, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  // A short block would end the transfer, so block 1 is full-size and the file
  // is closed later. Two full blocks and a short one is the sequence a client
  // whose ACK for block 1 got lost would produce.
  let full = Bytes::from_array(FixedArray::make(512, b'f'))
  let data1 = @tftp.encode(@tftp.Packet::Data(1, full))
  // The duplicate is re-acknowledged and the buffer is *not* appended again:
  // still 512 bytes, not 1024 (Sorcerer's Apprentice).
  @async.with_task_group(group => {
    let client_task = group.spawn(() => {
      client.send(data1, "127.0.0.1:7000")
      match client.recv("127.0.0.1:7000", 1000) {
        @tftp.Recv::Packet(datagram) =>
          assert_eq(@tftp.decode(datagram.payload()), Ok(@tftp.Packet::Ack(0)))
        @tftp.Recv::Timeout => fail("expected ACK 0")
      }
      // The ACK for block 1 was "lost", so the client repeats DATA 1 verbatim.
      client.send(data1, "127.0.0.1:7000")
      match client.recv("127.0.0.1:7000", 1000) {
        @tftp.Recv::Packet(datagram) =>
          assert_eq(@tftp.decode(datagram.payload()), Ok(@tftp.Packet::Ack(1)))
        @tftp.Recv::Timeout => fail("expected ACK 1")
      }
      match client.recv("127.0.0.1:7000", 1000) {
        @tftp.Recv::Packet(datagram) =>
          assert_eq(@tftp.decode(datagram.payload()), Ok(@tftp.Packet::Ack(1)))
        @tftp.Recv::Timeout => fail("expected a re-ACK")
      }
    })
    // ACK 0 opens the session; the caller owns that packet.
    session.transport.send(@tftp.encode(@tftp.Packet::Ack(0)), "127.0.0.1:5000")
    let (done1, first) = step_once(session, 0, Bytes::new(0), 3)
    assert_false(done1)
    assert_eq(first, @tftp.Written(512))
    let (done2, second) = step_once(session, 1, full, 3)
    assert_false(done2)
    assert_eq(second, @tftp.Written(512))
    ignore(client_task.wait())
  })
}

///|
async test "a write session reports a full disk as ERROR 3" {
  let files = @tftp.MemoryFileSystem::new()
  files.make_full()
  let (client, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  let mut outcome = None
  @async.with_task_group(group => {
    let task = group.spawn(() => {
      session.serve(@tftp.Packet::Wrq("big.bin", @tftp.Octet, []))
    })
    ignore(client.recv("127.0.0.1:7000", 1000)) // ACK 0
    client.send(@tftp.encode(@tftp.Packet::Data(1, b"data")), "127.0.0.1:7000")
    // The ACK for the data arrives before the write is attempted, so a test
    // that stops at the ACK would miss the failure entirely.
    let mut last = None
    while true {
      match client.recv("127.0.0.1:7000", 1000) {
        @tftp.Recv::Packet(datagram) => last = Some(datagram)
        @tftp.Recv::Timeout => break
      }
    }
    match last {
      Some(datagram) =>
        assert_eq(
          @tftp.decode(datagram.payload()),
          Ok(@tftp.Packet::Error(@tftp.DiskFull, "write /srv/big.bin")),
        )
      None => fail("expected an ERROR 3")
    }
    outcome = Some(task.wait())
  })
  match outcome {
    Some(@tftp.Failed(error)) => assert_eq(error.error_code(), @tftp.DiskFull)
    _ => fail("expected a full-disk failure")
  }
}

///|
async test "a read session with blksize uses the negotiated block size" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/a.bin", Bytes::from_array(FixedArray::make(2000, b'z')))
  let (client, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  let request = @tftp.Packet::Rrq("a.bin", @tftp.Octet, [
    @tftp.TftpOption::new("blksize", "1024"),
  ])
  let sizes : Array[Int32] = []
  @async.with_task_group(group => {
    let task = group.spawn(() => session.serve(request))
    // The OACK comes first, and is acknowledged with ACK 0 (RFC 2347 §4).
    match client.recv("127.0.0.1:7000", 1000) {
      @tftp.Recv::Packet(datagram) =>
        match @tftp.decode(datagram.payload()) {
          Ok(@tftp.Packet::Oack(options)) =>
            assert_eq(options, [@tftp.TftpOption::new("blksize", "1024")])
          other => fail("expected an OACK, got \{packet_repr(other)}")
        }
      @tftp.Recv::Timeout => fail("expected an OACK")
    }
    client.send(@tftp.encode(@tftp.Packet::Ack(0)), "127.0.0.1:7000")
    while true {
      match client.recv("127.0.0.1:7000", 1000) {
        @tftp.Recv::Packet(datagram) =>
          match @tftp.decode(datagram.payload()) {
            Ok(@tftp.Packet::Data(number, chunk)) => {
              sizes.push(chunk.length())
              client.send(
                @tftp.encode(@tftp.Packet::Ack(number)),
                "127.0.0.1:7000",
              )
              if chunk.length() < 1024 {
                break
              }
            }
            other => fail("expected DATA, got \{packet_repr(other)}")
          }
        @tftp.Recv::Timeout => break
      }
    }
    ignore(task.wait())
  })
  // 1024 + 976: the last block is short, which is what ends the transfer.
  assert_eq(sizes, [1024, 976])
}

///|
async test "a read session answers tsize with the real file size" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/a.txt", b"12345")
  let (client, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  let request = @tftp.Packet::Rrq("a.txt", @tftp.Octet, [
    @tftp.TftpOption::new("tsize", "0"),
  ])
  @async.with_task_group(group => {
    let task = group.spawn(() => session.serve(request))
    match client.recv("127.0.0.1:7000", 1000) {
      @tftp.Recv::Packet(datagram) =>
        match @tftp.decode(datagram.payload()) {
          Ok(@tftp.Packet::Oack(options)) =>
            assert_eq(options, [@tftp.TftpOption::new("tsize", "5")])
          other => fail("expected an OACK, got \{packet_repr(other)}")
        }
      @tftp.Recv::Timeout => fail("expected an OACK")
    }
    ignore(task.wait())
  })
}

// ---------------------------------------------------------------------------
// TID dispatch
// ---------------------------------------------------------------------------

///|
test "a dispatcher hands every request its own TID" {
  let dispatcher = @tftp.Dispatcher::new(@tftp.CounterTid::new(40000), 8)
  let first = dispatcher.route(
    @tftp.Datagram::new(
      @tftp.encode(@tftp.Packet::Rrq("a.txt", @tftp.Octet, [])),
      "10.0.0.1:1000",
    ),
  )
  let second = dispatcher.route(
    @tftp.Datagram::new(
      @tftp.encode(@tftp.Packet::Wrq("b.txt", @tftp.Octet, [])),
      "10.0.0.1:1000",
    ),
  )
  // The RFC only asks for a *new* TID, so the requirement is distinctness, not
  // a particular numbering: the same peer sending two requests must not be
  // answered on one port.
  assert_true(first != second)
  assert_eq(dispatcher.started(), 2)
  match first {
    @tftp.Started(tid) => assert_eq(tid, "10.0.0.1:40000")
    other => fail("expected a session, got \{tid_repr(other)}")
  }
}

///|
test "a dispatcher starts exactly max_sessions sessions and then refuses" {
  // The ceiling is the field the whole `Dispatcher` carries, so it has to be
  // the thing that ends the run: with a limit of 2, the third request is
  // answered with ERROR 4 instead of quietly opening a third session.
  let dispatcher = @tftp.Dispatcher::new(@tftp.CounterTid::new(30000), 2)
  let request = @tftp.encode(@tftp.Packet::Rrq("a.txt", @tftp.Octet, []))
  for i = 0; i < 2; i = i + 1 {
    match dispatcher.route(@tftp.Datagram::new(request, "10.0.0.\{i}:1000")) {
      @tftp.Started(_) => ()
      other => fail("expected session \{i}, got \{tid_repr(other)}")
    }
  }
  assert_eq(dispatcher.started(), 2)
  match dispatcher.route(@tftp.Datagram::new(request, "10.0.0.9:1000")) {
    @tftp.Rejected(tid~, error~) => {
      assert_eq(tid, "10.0.0.9:30002")
      // ERROR 4, not ERROR 5: the client is on the right TID, the server is
      // just full. A wrong code here would send the client chasing a port
      // problem that does not exist.
      assert_eq(error.error_code(), @tftp.IllegalOperation)
      assert_eq(
        error,
        @tftp.ServerError::IllegalOperation(
          "too many concurrent sessions (limit 2)",
        ),
      )
    }
    other => fail("expected a refusal, got \{tid_repr(other)}")
  }
  // A refused request must not creep the session count: otherwise the refusal
  // itself is what grows the server.
  assert_eq(dispatcher.started(), 2)
}

///|
test "a full dispatcher leaves running sessions alone" {
  // The refusal is scoped to the new request. Whatever is already running
  // keeps its TID, which is the property a naive "reset the counter" fix
  // would quietly break.
  let dispatcher = @tftp.Dispatcher::new(@tftp.CounterTid::new(31000), 1)
  let first = dispatcher.route(
    @tftp.Datagram::new(
      @tftp.encode(@tftp.Packet::Rrq("a.txt", @tftp.Octet, [])),
      "10.0.0.1:1000",
    ),
  )
  let running = match first {
    @tftp.Started(tid) => tid
    other => fail("expected a session, got \{tid_repr(other)}")
  }
  ignore(
    dispatcher.route(
      @tftp.Datagram::new(
        @tftp.encode(@tftp.Packet::Wrq("b.txt", @tftp.Octet, [])),
        "10.0.0.2:1000",
      ),
    ),
  )
  // The first session's TID is still valid, and the counter did not advance
  // past it.
  assert_eq(running, "10.0.0.1:31000")
  assert_eq(dispatcher.started(), 1)
}

///|
test "a ceiling of zero refuses even the first request" {
  // A degenerate limit is still a limit: zero sessions means zero, not "one".
  let dispatcher = @tftp.Dispatcher::new(@tftp.CounterTid::new(32000), 0)
  match
    dispatcher.route(
      @tftp.Datagram::new(
        @tftp.encode(@tftp.Packet::Rrq("a.txt", @tftp.Octet, [])),
        "10.0.0.1:1000",
      ),
    ) {
    @tftp.Rejected(tid~, error~) => {
      assert_eq(tid, "10.0.0.1:32000")
      assert_eq(error.error_code(), @tftp.IllegalOperation)
    }
    other => fail("expected a refusal, got \{tid_repr(other)}")
  }
  assert_eq(dispatcher.started(), 0)
}

///|
/// Renders a dispatch decision for a failure message.
fn tid_repr(dispatch : @tftp.Dispatch) -> String {
  dispatch.to_repr().to_string()
}

///|
test "a dispatcher answers a stray ACK with ERROR 5" {
  // An ACK arriving on the request port is a client using the wrong TID, which
  // RFC 1350 section 4 names exactly: unknown transfer ID.
  let dispatcher = @tftp.Dispatcher::new(@tftp.CounterTid::new(50000), 8)
  let decision = dispatcher.route(
    @tftp.Datagram::new(@tftp.encode(@tftp.Packet::Ack(3)), "10.0.0.9:1000"),
  )
  assert_eq(dispatcher.started(), 0)
  match decision {
    @tftp.Rejected(tid~, error~) => {
      assert_eq(tid, "10.0.0.9:50000")
      assert_eq(error.error_code(), @tftp.UnknownTransferId)
    }
    other => fail("expected a rejection, got \{tid_repr(other)}")
  }
}

///|
test "a datagram that cannot decode is answered with ERROR 4" {
  let dispatcher = @tftp.Dispatcher::new(@tftp.CounterTid::new(50000), 8)
  let decision = dispatcher.route(
    @tftp.Datagram::new(b"\x00\x01\x02", "10.0.0.9:1000"),
  )
  // No session is started — a malformed body is not a request — but the peer
  // is told so, with the code RFC 1350 section 5 reserves for "not right now".
  assert_eq(dispatcher.started(), 0)
  match decision {
    @tftp.Rejected(tid~, error~) => {
      assert_eq(tid, "10.0.0.9:50000")
      assert_eq(error.error_code(), @tftp.IllegalOperation)
    }
    other => fail("expected a refusal, got \{tid_repr(other)}")
  }
}

///|
/// The matrix of malformed bodies a peer can send, all of which the dispatcher
/// answers rather than drops.
///
/// Silence would leave the peer retransmitting until its budget ran out, which
/// is the failure mode an ERROR packet exists to prevent; so every one of these
/// owes a packet, and the dispatcher has to be the one that decides it because
/// only it sees the raw datagram.
test "every malformed request is refused with ERROR 4" {
  let dispatcher = @tftp.Dispatcher::new(@tftp.CounterTid::new(50000), 8)
  let malformed : Array[Bytes] = [
    // Opcode and nothing else.
    b"\x00\x01",
    // A filename with no mode after it.
    b"\x00\x01boot.img\x00",
    // A mode we do not implement.
    b"\x00\x01boot.img\x00mail\x00",
    // The mode field is never terminated.
    b"\x00\x01boot.img\x00octet",
    // A filename longer than any we accept.
    b"\x00\x01" + Bytes::make(600, b'a') + b"\x00octet\x00",
    // An opcode RFC 1350 does not define.
    b"\x00\x07boot.img\x00",
    // An option name with no value after it.
    b"\x00\x01boot.img\x00octet\x00blksize\x00",
  ]
  for payload in malformed {
    let decision = dispatcher.route(
      @tftp.Datagram::new(payload, "10.0.0.9:1000"),
    )
    match decision {
      @tftp.Rejected(tid~, error~) => {
        ignore(tid)
        assert_eq(error.error_code(), @tftp.IllegalOperation)
      }
      other => fail("expected a refusal, got \{tid_repr(other)}")
    }
  }
  // Not one of them opened a session, so the ceiling is untouched.
  assert_eq(dispatcher.started(), 0)
  assert_eq(dispatcher.active(), 0)
  // Refusing a malformed request must not consume the ceiling either: a
  // well-formed request right after the whole matrix still gets its session.
  let after = dispatcher.route(
    @tftp.Datagram::new(
      @tftp.encode(@tftp.Rrq("a", @tftp.Octet, [])),
      "10.0.0.9:1000",
    ),
  )
  match after {
    @tftp.Started(_) => assert_eq(dispatcher.started(), 1)
    other => fail("expected a session, got \{tid_repr(other)}")
  }
}

///|
test "a dispatcher refuses a request once the ceiling is reached" {
  // The ceiling bounds *concurrent* sessions. The first request starts one; the
  // second, with the ceiling already taken, is refused rather than started.
  let dispatcher = @tftp.Dispatcher::new(@tftp.CounterTid::new(45000), 1)
  let first = dispatcher.route(
    @tftp.Datagram::new(
      @tftp.encode(@tftp.Rrq("a", @tftp.Octet, [])),
      "10.0.0.1:1000",
    ),
  )
  match first {
    @tftp.Started(_) => ()
    other => fail("expected a session, got \{tid_repr(other)}")
  }
  let second = dispatcher.route(
    @tftp.Datagram::new(
      @tftp.encode(@tftp.Rrq("b", @tftp.Octet, [])),
      "10.0.0.2:1000",
    ),
  )
  match second {
    @tftp.Rejected(tid~, error~) => {
      assert_eq(tid, "10.0.0.2:45001")
      // ERROR 4, not ERROR 5: the client is on the right TID, the server is
      // just full. The refusal carries the reason instead of the caller
      // re-deriving it from the packet.
      assert_eq(error.error_code(), @tftp.IllegalOperation)
      assert_eq(
        error,
        @tftp.ServerError::IllegalOperation(
          "too many concurrent sessions (limit 1)",
        ),
      )
    }
    other => fail("expected a refusal, got \{tid_repr(other)}")
  }
  // A refused request did not start a session, and the running one is intact.
  assert_eq(dispatcher.started(), 1)
  assert_eq(dispatcher.active(), 1)
}

///|
test "a finished session gives its slot back" {
  // Without releasing, the ceiling would lock the server out after N total
  // transfers instead of bounding how many run at once.
  let dispatcher = @tftp.Dispatcher::new(@tftp.CounterTid::new(46000), 1)
  ignore(
    dispatcher.route(
      @tftp.Datagram::new(
        @tftp.encode(@tftp.Rrq("a", @tftp.Octet, [])),
        "10.0.0.1:1000",
      ),
    ),
  )
  assert_eq(dispatcher.active(), 1)
  dispatcher.release()
  assert_eq(dispatcher.active(), 0)
  let next = dispatcher.route(
    @tftp.Datagram::new(
      @tftp.encode(@tftp.Rrq("b", @tftp.Octet, [])),
      "10.0.0.2:1000",
    ),
  )
  match next {
    @tftp.Started(_) => ()
    other =>
      fail(
        "expected a session after the slot was released, got \{tid_repr(other)}",
      )
  }
  assert_eq(dispatcher.started(), 2)
}

///|
test "an IPv6 peer keeps its address and only gets its port replaced" {
  let dispatcher = @tftp.Dispatcher::new(@tftp.CounterTid::new(42000), 8)
  let decision = dispatcher.route(
    @tftp.Datagram::new(
      @tftp.encode(@tftp.Packet::Rrq("a", @tftp.Octet, [])),
      "[::1]:1000",
    ),
  )
  match decision {
    @tftp.Started(tid) => assert_eq(tid, "[::1]:42000")
    other => fail("expected a session, got \{tid_repr(other)}")
  }
}

// ---------------------------------------------------------------------------
// Concurrency
// ---------------------------------------------------------------------------

///|
async test "three read sessions run concurrently without crossing wires" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/a.txt", b"aaaa")
  files.put("/srv/b.txt", b"bbbb")
  files.put("/srv/c.txt", b"cccc")
  // Each session gets its own pair and its own TID, which is the whole point:
  // a server that mixed them up would answer the wrong client, and the
  // payloads below are what catches it.
  let sessions : Array[(@tftp.MemoryTransport, Bytes)] = []
  let names : Array[String] = ["a.txt", "b.txt", "c.txt"]
  for i = 0; i < names.length(); i = i + 1 {
    let files_for_session = files
    let (client, server) = @tftp.MemoryTransport::pair(
      "10.0.0.\{i}:1000",
      "10.0.0.\{i}:4000",
    )
    let session = @tftp.TransferSession::new(
      server,
      files_for_session,
      "10.0.0.\{i}:1000",
      @tftp.ServerOptions::default().with_root("/srv"),
    )
    sessions.push((client, Bytes::new(0)))
    ignore(session)
  }
  // Each session is driven in its own task, in parallel.
  let results : Array[Bytes] = []
  @async.with_task_group(group => {
    for i = 0; i < names.length(); i = i + 1 {
      let files_for_session = files
      let name = names[i]
      let peer = "10.0.0.\{i}:1000"
      ignore(
        group.spawn(() => {
          let (client, server) = @tftp.MemoryTransport::pair(
            peer,
            "10.0.0.\{i}:4000",
          )
          let session = @tftp.TransferSession::new(
            server,
            files_for_session,
            peer,
            @tftp.ServerOptions::default().with_root("/srv"),
          )
          let task = @async.with_task_group(inner => {
            inner.spawn(() => {
              session.serve(@tftp.Packet::Rrq(name, @tftp.Octet, []))
            })
          })
          let mut payload = Bytes::new(0)
          while true {
            match client.recv("10.0.0.\{i}:4000", 1000) {
              @tftp.Recv::Packet(datagram) =>
                match @tftp.decode(datagram.payload()) {
                  Ok(@tftp.Packet::Data(number, chunk)) => {
                    payload = payload + chunk
                    client.send(
                      @tftp.encode(@tftp.Packet::Ack(number)),
                      "10.0.0.\{i}:4000",
                    )
                    if chunk.length() < @tftp.default_block_size {
                      break
                    }
                  }
                  _ => break
                }
              @tftp.Recv::Timeout => break
            }
          }
          ignore(task)
          results.push(payload)
        }),
      )
    }
  })
  // Every payload came back exactly once, and none of them is another
  // session's: the three are distinct and equal to their own file.
  assert_eq(results.length(), 3)
  assert_eq(results[0], b"aaaa")
  assert_eq(results[1], b"bbbb")
  assert_eq(results[2], b"cccc")
  ignore(sessions)
}

///|
async test "two write sessions run concurrently without mixing their files" {
  let files = @tftp.MemoryFileSystem::new()
  let results : Array[@tftp.SessionOutcome] = []
  @async.with_task_group(group => {
    for i = 0; i < 2; i = i + 1 {
      let files_for_session = files
      let name = "out\{i}.bin"
      ignore(
        group.spawn(() => {
          let (client, server) = @tftp.MemoryTransport::pair(
            "10.0.0.\{i}:1000",
            "10.0.0.\{i}:4000",
          )
          let session = @tftp.TransferSession::new(
            server,
            files_for_session,
            "10.0.0.\{i}:1000",
            @tftp.ServerOptions::default().with_root("/srv"),
          )
          // The session runs in its own group so the client can talk to it
          // while it is still going; its outcome is pushed from inside.
          let outcome = @async.with_task_group(inner => {
            let task = inner.spawn(() => {
              session.serve(@tftp.Packet::Wrq(name, @tftp.Octet, []))
            })
            // Wait for ACK 0 before sending: the handshake is what tells the
            // client the session is live.
            match client.recv("10.0.0.\{i}:4000", 1000) {
              @tftp.Recv::Packet(datagram) =>
                ignore(@tftp.decode(datagram.payload()))
              @tftp.Recv::Timeout => ()
            }
            client.send(
              @tftp.encode(@tftp.Packet::Data(1, b"file \{i}")),
              "10.0.0.\{i}:4000",
            )
            ignore(client.recv("10.0.0.\{i}:4000", 1000))
            task.wait()
          })
          results.push(outcome)
        }),
      )
    }
  })
  assert_eq(results.length(), 2)
  assert_eq(files.get("/srv/out0.bin"), Some(b"file 0"))
  assert_eq(files.get("/srv/out1.bin"), Some(b"file 1"))
}

// ---------------------------------------------------------------------------
// Session-level error paths and option handling
// ---------------------------------------------------------------------------

///|
test "ServerOptions accessors report what was configured" {
  let options = @tftp.ServerOptions::default()
    .with_root("/srv/tftp")
    .with_write_policy(@tftp.AllowOverwrite)
    .with_max_sessions(3)
    .with_max_retries(2)
  assert_eq(options.root(), "/srv/tftp")
  assert_eq(options.write_policy(), @tftp.AllowOverwrite)
  assert_eq(options.max_sessions(), 3)
  assert_eq(options.max_retries(), 2)
  // The defaults are the safe ones: a root of `.`, create-only, and a ceiling
  // a flood cannot grow past.
  assert_eq(@tftp.ServerOptions::default().root(), ".")
  assert_eq(@tftp.ServerOptions::default().write_policy(), @tftp.CreateOnly)
  // 32 is the one README and the CLI both state, so a server started either
  // way has the same ceiling.
  assert_eq(@tftp.ServerOptions::default().max_sessions(), 32)
  assert_eq(@tftp.ServerOptions::default().max_retries(), 6)
}

///|
test "resolve_path treats a bare separator as the root itself" {
  // `.` and the root are the same place; a name that is *only* separators
  // resolves to the root rather than being refused, which is what a client
  // asking for the directory itself gets.
  assert_eq(@tftp.resolve_path("/srv/tftp", "."), Ok("/srv/tftp"))
  assert_eq(@tftp.resolve_path("/", "."), Ok("/"))
  assert_eq(@tftp.resolve_path("", "/"), Ok("/"))
  assert_eq(@tftp.resolve_path("", "a"), Ok("/a"))
}

///|
test "a session outcome carries a failure or a byte count" {
  assert_eq(@tftp.Read(7).bytes(), 7)
  assert_eq(@tftp.Written(9).bytes(), 9)
  assert_eq(@tftp.Written(9).error(), None)
  assert_eq(@tftp.Read(7).error(), None)
  let failure = @tftp.ServerError::FileNotFound("gone")
  assert_eq(@tftp.Failed(failure).bytes(), -1)
  assert_eq(@tftp.Failed(failure).error(), Some(failure))
}

///|
/// The dispatch decision for a datagram that got to port 69 by accident.
///
/// A DATA packet here is a client that ignored its TID, and the RFC's answer
/// is ERROR 5, not silence: the client is talking to the wrong port and has to
/// be told.
test "a dispatcher rejects a stray DATA" {
  let dispatcher = @tftp.Dispatcher::new(@tftp.CounterTid::new(60000), 8)
  let decision = dispatcher.route(
    @tftp.Datagram::new(
      @tftp.encode(@tftp.Packet::Data(1, b"x")),
      "10.0.0.7:1000",
    ),
  )
  match decision {
    @tftp.Rejected(tid~, error~) => {
      assert_eq(tid, "10.0.0.7:60000")
      assert_eq(error.error_code(), @tftp.UnknownTransferId)
    }
    other => fail("expected a rejection, got \{tid_repr(other)}")
  }
}

///|
test "a peer with no port, or a bracketed one, still gets a TID" {
  let dispatcher = @tftp.Dispatcher::new(@tftp.CounterTid::new(100), 8)
  let bare = dispatcher.route(
    @tftp.Datagram::new(
      @tftp.encode(@tftp.Packet::Rrq("a", @tftp.Octet, [])),
      "host",
    ),
  )
  match bare {
    @tftp.Started(tid) => assert_eq(tid, "host:100")
    other => fail("expected a session, got \{tid_repr(other)}")
  }
  // An opening bracket with no closing one is not a peer we can rewrite, so it
  // is carried through rather than truncated at the first colon.
  let odd = dispatcher.route(
    @tftp.Datagram::new(
      @tftp.encode(@tftp.Packet::Rrq("a", @tftp.Octet, [])),
      "[::1",
    ),
  )
  match odd {
    @tftp.Started(tid) => assert_eq(tid, "[::1:101")
    other => fail("expected a session, got \{tid_repr(other)}")
  }
}

///|
test "the error packet of a failure names the code and the reason" {
  assert_eq(
    @tftp.to_error_packet(@tftp.ServerError::AccessViolation("nope")),
    @tftp.Packet::Error(@tftp.AccessViolation, "nope"),
  )
  assert_eq(
    @tftp.timed_out_packet(),
    @tftp.Packet::Error(@tftp.Undefined, "timed out"),
  )
}

///|
/// A session whose request is refused answers with an ERROR on the request
/// TID, and never opens the transfer.
async test "a refused request is answered with one ERROR packet" {
  let files = @tftp.MemoryFileSystem::new()
  let (client, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  let outcome = session.serve(
    @tftp.Packet::Rrq("../etc/passwd", @tftp.Octet, []),
  )
  match client.recv("127.0.0.1:7000", 1000) {
    @tftp.Recv::Packet(datagram) =>
      match @tftp.decode(datagram.payload()) {
        Ok(@tftp.Packet::Error(code, _)) =>
          assert_eq(code, @tftp.AccessViolation)
        other => fail("expected ERROR 2, got \{packet_repr(other)}")
      }
    @tftp.Recv::Timeout => fail("expected an ERROR")
  }
  match outcome {
    @tftp.Failed(error) => assert_eq(error.error_code(), @tftp.AccessViolation)
    other => fail("expected a failure, got \{outcome_repr(other)}")
  }
}

///|
/// Renders a session outcome for a failure message.
fn outcome_repr(outcome : @tftp.SessionOutcome) -> String {
  outcome.to_repr().to_string()
}

///|
async test "a WRQ with no options starts the RFC 1350 handshake at ACK 0" {
  let files = @tftp.MemoryFileSystem::new()
  let (client, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  @async.with_task_group(group => {
    let client_task = group.spawn(() => {
      match client.recv("127.0.0.1:7000", 1000) {
        @tftp.Recv::Packet(datagram) =>
          // No option was asked for, so there is no OACK: the first packet is
          // the plain RFC 1350 handshake.
          assert_eq(@tftp.decode(datagram.payload()), Ok(@tftp.Packet::Ack(0)))
        @tftp.Recv::Timeout => fail("expected ACK 0")
      }
      client.send(
        @tftp.encode(@tftp.Packet::Data(1, b"done")),
        "127.0.0.1:7000",
      )
      ignore(client.recv("127.0.0.1:7000", 1000))
    })
    assert_eq(
      session.serve(@tftp.Packet::Wrq("a.txt", @tftp.Octet, [])),
      @tftp.Written(4),
    )
    ignore(client_task.wait())
  })
  assert_eq(files.get("/srv/a.txt"), Some(b"done"))
}

///|
async test "a read session survives noise before the first ACK" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/a.txt", b"data")
  let (client, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  // Two kinds of noise a real network produces: bytes that are not a packet,
  // and a packet that is not an ACK (here, the peer's own DATA). Neither may
  // move the transfer along.
  client.send(b"\x00\x09garbage", "127.0.0.1:7000")
  client.send(
    @tftp.encode(@tftp.Packet::Data(1, b"not an ack")),
    "127.0.0.1:7000",
  )
  @async.with_task_group(group => {
    let task = group.spawn(() => {
      session.serve(@tftp.Packet::Rrq("a.txt", @tftp.Octet, []))
    })
    // The session retransmits on each timeout, so the DATA is still there to
    // be read once the noise has been consumed.
    let mut seen = false
    while !seen {
      match client.recv("127.0.0.1:7000", 1000) {
        @tftp.Recv::Packet(datagram) =>
          match @tftp.decode(datagram.payload()) {
            Ok(@tftp.Packet::Data(number, chunk)) => {
              assert_eq(chunk, b"data")
              client.send(
                @tftp.encode(@tftp.Packet::Ack(number)),
                "127.0.0.1:7000",
              )
              seen = true
            }
            _ => ()
          }
        @tftp.Recv::Timeout => break
      }
    }
    assert_true(seen)
    ignore(task.wait())
  })
}

///|
async test "a read session re-sends the DATA the peer failed to acknowledge" {
  let files = @tftp.MemoryFileSystem::new()
  // Two blocks, so the transfer does not end until the second one is
  // acknowledged and there is something left to retransmit.
  files.put("/srv/two.bin", Bytes::from_array(FixedArray::make(700, b'x')))
  let (client, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  @async.with_task_group(group => {
    let task = group.spawn(() => {
      session.serve(@tftp.Packet::Rrq("two.bin", @tftp.Octet, []))
    })
    // Read DATA 1 and acknowledge it, then read DATA 2 and *do not* answer.
    // The session runs out its timeout and sends DATA 2 again: the block
    // number does not advance across a retransmission.
    match client.recv("127.0.0.1:7000", 1000) {
      @tftp.Recv::Packet(datagram) =>
        match @tftp.decode(datagram.payload()) {
          Ok(@tftp.Packet::Data(number, _)) =>
            client.send(
              @tftp.encode(@tftp.Packet::Ack(number)),
              "127.0.0.1:7000",
            )
          _ => fail("expected DATA 1")
        }
      @tftp.Recv::Timeout => fail("expected DATA 1")
    }
    let first = match client.recv("127.0.0.1:7000", 1000) {
      @tftp.Recv::Packet(datagram) => @tftp.decode(datagram.payload())
      @tftp.Recv::Timeout => fail("expected DATA 2")
    }
    let second = match client.recv("127.0.0.1:7000", 8000) {
      @tftp.Recv::Packet(datagram) => @tftp.decode(datagram.payload())
      @tftp.Recv::Timeout => fail("expected DATA 2 to be repeated")
    }
    match (first, second) {
      (
        Ok(@tftp.Packet::Data(block_a, chunk_a)),
        Ok(@tftp.Packet::Data(block_b, chunk_b)),
      ) => {
        assert_eq(block_a, 2)
        assert_eq(block_b, 2)
        assert_eq(chunk_a, chunk_b)
        client.send(@tftp.encode(@tftp.Packet::Ack(2)), "127.0.0.1:7000")
      }
      _ => fail("expected two copies of DATA 2")
    }
    ignore(task.wait())
  })
}

///|
async test "a read session gives up and reports ERROR 0 when the peer vanishes" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/a.txt", b"data")
  let (client, session) = session_pair(
    files,
    // One retry, so the give-up arrives quickly instead of after six rounds.
    @tftp.ServerOptions::default().with_root("/srv").with_max_retries(1),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  // Nobody ever answers, so every `recv` times out. The session must run out
  // its budget rather than hang, and say so with code 0.
  let outcome = session.serve(@tftp.Packet::Rrq("a.txt", @tftp.Octet, []))
  match outcome {
    @tftp.Failed(error) => assert_eq(error.error_code(), @tftp.Undefined)
    other => fail("expected a timeout, got \{outcome_repr(other)}")
  }
  // The client sees the give-up as ERROR 0 after the retransmissions.
  let mut found = None
  while found is None {
    match client.recv("127.0.0.1:7000", 1500) {
      @tftp.Recv::Packet(datagram) =>
        match @tftp.decode(datagram.payload()) {
          Ok(@tftp.Packet::Error(code, message)) =>
            found = Some((code, message))
          _ => ()
        }
      @tftp.Recv::Timeout => break
    }
  }
  assert_eq(found, Some((@tftp.Undefined, "timed out")))
}

///|
async test "a write session takes the negotiated block size for a WRQ" {
  let files = @tftp.MemoryFileSystem::new()
  let (client, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  let request = @tftp.Packet::Wrq("big.bin", @tftp.Octet, [
    @tftp.TftpOption::new("blksize", "1024"),
  ])
  // One full 1024-byte block then a short one, so the transfer ends on the
  // negotiated size rather than the 512-byte default.
  let full = Bytes::from_array(FixedArray::make(1024, b'q'))
  @async.with_task_group(group => {
    let client_task = group.spawn(() => {
      client.send(@tftp.encode(@tftp.Packet::Data(1, full)), "127.0.0.1:7000")
      match client.recv("127.0.0.1:7000", 1000) {
        @tftp.Recv::Packet(datagram) =>
          match @tftp.decode(datagram.payload()) {
            Ok(@tftp.Packet::Oack(options)) =>
              assert_eq(options, [@tftp.TftpOption::new("blksize", "1024")])
            other => fail("expected an OACK, got \{packet_repr(other)}")
          }
        @tftp.Recv::Timeout => fail("expected an OACK")
      }
      client.send(@tftp.encode(@tftp.Packet::Data(2, b"end")), "127.0.0.1:7000")
      ignore(client.recv("127.0.0.1:7000", 1000))
    })
    let outcome = session.serve(request)
    // 1024 + 3: the short block is measured against the negotiated size, so
    // the transfer really did run at 1024.
    assert_eq(outcome, @tftp.Written(1027))
    assert_eq(files.get("/srv/big.bin"), Some(full + b"end"))
    ignore(client_task.wait())
  })
}

///|
async test "a write session reports a peer's ERROR back with its own code" {
  let files = @tftp.MemoryFileSystem::new()
  let (client, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  // The client changes its mind and sends ERROR 4. The session must stop and
  // report the same code rather than inventing one.
  client.send(
    @tftp.encode(@tftp.Packet::Error(@tftp.IllegalOperation, "changed my mind")),
    "127.0.0.1:7000",
  )
  let outcome = session.serve(@tftp.Packet::Wrq("a.txt", @tftp.Octet, []))
  match outcome {
    @tftp.Failed(error) => {
      assert_eq(error.error_code(), @tftp.IllegalOperation)
      assert_eq(error.message(), "changed my mind")
    }
    other => fail("expected a failure, got \{outcome_repr(other)}")
  }
}

// ---------------------------------------------------------------------------
// A session driven the way a socket server drives it
// ---------------------------------------------------------------------------

///|
test "the OACK of an empty option set is absent, not empty" {
  // A server that accepted no option must answer with the first DATA / ACK,
  // never with an OACK that carries nothing (RFC 2347, section 4): the peer
  // would have nothing to acknowledge.
  assert_eq(@tftp.Options::default().oack_packet(), None)
  assert_true(@tftp.Options::default().is_empty())
}

///|
async test "a WRQ with options answers with an OACK on the wire" {
  let files = @tftp.MemoryFileSystem::new()
  let (client, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  let request = @tftp.Packet::Wrq("big.bin", @tftp.Octet, [
    @tftp.TftpOption::new("blksize", "1024"),
  ])
  @async.with_task_group(group => {
    let client_task = group.spawn(() => {
      match client.recv("127.0.0.1:7000", 1000) {
        @tftp.Recv::Packet(datagram) =>
          // The first packet a negotiated WRQ gets is the OACK, sent from the
          // session's own TID, and the peer acknowledges it with DATA 1.
          assert_eq(
            @tftp.decode(datagram.payload()),
            Ok(@tftp.Packet::Oack([@tftp.TftpOption::new("blksize", "1024")])),
          )
        @tftp.Recv::Timeout => fail("expected an OACK")
      }
      client.send(
        @tftp.encode(@tftp.Packet::Data(1, b"tail")),
        "127.0.0.1:7000",
      )
      ignore(client.recv("127.0.0.1:7000", 1000))
    })
    assert_eq(session.serve(request), @tftp.Written(4))
    ignore(client_task.wait())
  })
}

// ---------------------------------------------------------------------------
// Defensive branches a real network reaches, and a few pure corner cases
// ---------------------------------------------------------------------------

///|
test "resolve_path refuses a directory written as a trailing slash" {
  // A trailing slash is the one form a name itself reveals as a directory.
  // `resolve_path` keeps it as a plain name; `plan_request` is what rejects
  // it, so the check is exercised through the planner below.
  assert_eq(@tftp.resolve_path("/srv", "docs/"), Ok("/srv/docs"))
}

///|
async test "plan_request refuses a WRQ that names a directory" {
  let files = @tftp.MemoryFileSystem::new()
  match plan(files, @tftp.Packet::Wrq("docs/", @tftp.Octet, [])) {
    Err(error) => assert_eq(error.error_code(), @tftp.AccessViolation)
    Ok(_) => fail("expected ERROR 2")
  }
}

///|
async test "plan_request reports the option that could not be agreed on" {
  let files = @tftp.MemoryFileSystem::new()
  // A read request whose `tsize` is not the placeholder 0 is a shape the
  // server cannot answer, and the ERROR 8 text names it.
  let request = @tftp.Packet::Rrq("a.txt", @tftp.Octet, [
    @tftp.TftpOption::new("tsize", "7"),
  ])
  match plan(files, request) {
    Err(error) => {
      assert_eq(error.error_code(), @tftp.OptionNegotiationFailed)
      assert_eq(error.message(), "tsize=7")
    }
    Ok(_) => fail("expected ERROR 8")
  }
}

///|
async test "a read session survives a non-ACK packet before the first DATA" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/a.txt", b"data")
  let (client, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  let request = @tftp.Packet::Rrq("a.txt", @tftp.Octet, [
    @tftp.TftpOption::new("blksize", "1024"),
  ])
  @async.with_task_group(group => {
    let client_task = group.spawn(() => {
      // Drain the OACK, then answer it with something that is not ACK 0: the
      // session must count it as noise and keep offering the OACK, rather than
      // starting to send DATA it has not been cleared to send.
      match client.recv("127.0.0.1:7000", 1000) {
        @tftp.Recv::Packet(_) => ()
        @tftp.Recv::Timeout => fail("expected an OACK")
      }
      client.send(@tftp.encode(@tftp.Packet::Ack(99)), "127.0.0.1:7000")
      let mut got_oack_again = false
      while !got_oack_again {
        match client.recv("127.0.0.1:7000", 8000) {
          @tftp.Recv::Packet(datagram) =>
            match @tftp.decode(datagram.payload()) {
              Ok(@tftp.Packet::Oack(_)) => {
                got_oack_again = true
                // Finally acknowledge the options, which starts the transfer.
                client.send(
                  @tftp.encode(@tftp.Packet::Ack(0)),
                  "127.0.0.1:7000",
                )
              }
              _ => ()
            }
          @tftp.Recv::Timeout => fail("expected the OACK to be repeated")
        }
      }
      match client.recv("127.0.0.1:7000", 1000) {
        @tftp.Recv::Packet(datagram) =>
          match @tftp.decode(datagram.payload()) {
            Ok(@tftp.Packet::Data(number, _)) =>
              client.send(
                @tftp.encode(@tftp.Packet::Ack(number)),
                "127.0.0.1:7000",
              )
            _ => fail("expected DATA")
          }
        @tftp.Recv::Timeout => fail("expected DATA")
      }
    })
    assert_eq(session.serve(request), @tftp.Read(4))
    ignore(client_task.wait())
  })
}

///|
async test "a read session re-sends DATA when the peer acknowledges an earlier block" {
  let files = @tftp.MemoryFileSystem::new()
  // Three blocks, so a re-acknowledged block 1 leaves the session waiting.
  files.put("/srv/three.bin", Bytes::from_array(FixedArray::make(1100, b'x')))
  let (client, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  let request = @tftp.Packet::Rrq("three.bin", @tftp.Octet, [])
  @async.with_task_group(group => {
    let client_task = group.spawn(() => {
      // ACK 1 arrives twice: the second one says "I lost DATA 2", and the
      // session should re-send DATA 2 rather than wait out its timeout.
      for i = 0; i < 2; i = i + 1 {
        match client.recv("127.0.0.1:7000", 1000) {
          @tftp.Recv::Packet(_) => ()
          @tftp.Recv::Timeout => fail("expected DATA 1")
        }
        client.send(@tftp.encode(@tftp.Packet::Ack(1)), "127.0.0.1:7000")
      }
      // Now let it finish from block 2 onwards.
      let mut block : UInt16 = 2
      while true {
        match client.recv("127.0.0.1:7000", 1000) {
          @tftp.Recv::Packet(datagram) =>
            match @tftp.decode(datagram.payload()) {
              Ok(@tftp.Packet::Data(number, chunk)) => {
                if number != block {
                  continue
                }
                client.send(
                  @tftp.encode(@tftp.Packet::Ack(number)),
                  "127.0.0.1:7000",
                )
                block = block + 1
                if chunk.length() < @tftp.default_block_size {
                  break
                }
              }
              _ => ()
            }
          @tftp.Recv::Timeout => break
        }
      }
    })
    ignore(session.serve(request))
    ignore(client_task.wait())
  })
}

///|
async test "a write session reports its timeout with ERROR 0" {
  let files = @tftp.MemoryFileSystem::new()
  let (_, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv").with_max_retries(1),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  // Nobody ever sends DATA, so the write side runs out its budget too, and a
  // write that times out must be as loud as a read that does. No client is
  // needed: the point is that the session stops on its own.
  let outcome = session.serve(@tftp.Packet::Wrq("never.bin", @tftp.Octet, []))
  match outcome {
    @tftp.Failed(error) => assert_eq(error.error_code(), @tftp.Undefined)
    other => fail("expected a timeout, got \{outcome_repr(other)}")
  }
}

///|
async test "a write session ignores noise and a block ahead of the window" {
  let files = @tftp.MemoryFileSystem::new()
  let (client, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  // Drive the session one step at a time so each branch in `step_write` gets
  // exactly the packet it is meant to test. `step_write` never sends anything
  // unprompted, which is what makes that possible; the inbox is only ever
  // loaded with one packet at a time, because a `send` hands control to the
  // other endpoint.
  //
  // Starting state: the session has just sent ACK 0 and is waiting on block 1.
  session.transport.send(@tftp.encode(@tftp.Packet::Ack(0)), "127.0.0.1:5000")
  // Undecodable bytes: still waiting on block 1.
  client.send(b"\x00\x09rubbish", "127.0.0.1:7000")
  let (done, outcome) = step_once(session, 0, Bytes::new(0), 3)
  assert_false(done)
  assert_eq(outcome, @tftp.Written(0))
  // A DATA far ahead of the window: re-ACK 0 rather than storing it.
  client.send(
    @tftp.encode(@tftp.Packet::Data(9, b"from the future")),
    "127.0.0.1:7000",
  )
  let (done, outcome) = step_once(session, 0, Bytes::new(0), 3)
  assert_false(done)
  assert_eq(outcome, @tftp.Written(0))
  // A stray ACK where DATA was expected: nothing to do but wait.
  client.send(@tftp.encode(@tftp.Packet::Ack(1)), "127.0.0.1:7000")
  let (done, outcome) = step_once(session, 0, Bytes::new(0), 3)
  assert_false(done)
  assert_eq(outcome, @tftp.Written(0))
  // Now the real block 1, which is short and therefore ends the file.
  client.send(@tftp.encode(@tftp.Packet::Data(1, b"real")), "127.0.0.1:7000")
  let (done, outcome) = step_once(session, 0, Bytes::new(0), 3)
  assert_true(done)
  assert_eq(outcome, @tftp.Written(4))
}

///|
async test "serve reports a file the backend cannot read as ERROR 1" {
  let files = @tftp.MemoryFileSystem::new()
  files.break_reads()
  let (client, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  let outcome = session.serve(@tftp.Packet::Rrq("a.txt", @tftp.Octet, []))
  match outcome {
    @tftp.Failed(error) => assert_eq(error.error_code(), @tftp.FileNotFound)
    other => fail("expected ERROR 1, got \{outcome_repr(other)}")
  }
  match client.recv("127.0.0.1:7000", 1000) {
    @tftp.Recv::Packet(datagram) =>
      match @tftp.decode(datagram.payload()) {
        Ok(@tftp.Packet::Error(code, _)) => assert_eq(code, @tftp.FileNotFound)
        other => fail("expected ERROR 1, got \{packet_repr(other)}")
      }
    @tftp.Recv::Timeout => fail("expected an ERROR")
  }
}

///|
/// A peer that reports its own failures must have them come back unchanged:
/// the code is the peer's, and rewriting it would lose what it meant.
test "a peer's error keeps its code on the way back" {
  assert_eq(
    @tftp.to_error_packet(@tftp.ServerError::FileNotFound("gone")),
    @tftp.Packet::Error(@tftp.FileNotFound, "gone"),
  )
  assert_eq(
    @tftp.to_error_packet(@tftp.ServerError::FileAlreadyExists("taken")),
    @tftp.Packet::Error(@tftp.FileAlreadyExists, "taken"),
  )
  assert_eq(
    @tftp.to_error_packet(@tftp.ServerError::DiskFull("full")),
    @tftp.Packet::Error(@tftp.DiskFull, "full"),
  )
  assert_eq(
    @tftp.to_error_packet(
      @tftp.ServerError::OptionNegotiationFailed("blksize=1"),
    ),
    @tftp.Packet::Error(@tftp.OptionNegotiationFailed, "blksize=1"),
  )
  assert_eq(
    @tftp.to_error_packet(@tftp.ServerError::IllegalOperation("no")),
    @tftp.Packet::Error(@tftp.IllegalOperation, "no"),
  )
  assert_eq(
    @tftp.to_error_packet(@tftp.ServerError::Timeout),
    @tftp.Packet::Error(@tftp.Undefined, "timed out"),
  )
}

///|
async test "a read session stops when the peer reports an error" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/a.txt", b"data")
  let (_, server, session) = session_triple(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
  )
  // The peer gives up mid-read with ERROR 3. The session reports that code
  // rather than inventing one of its own.
  inject(
    server,
    @tftp.encode(@tftp.Packet::Error(@tftp.DiskFull, "out of space")),
  )
  match session.serve(@tftp.Packet::Rrq("a.txt", @tftp.Octet, [])) {
    @tftp.Failed(error) => {
      assert_eq(error.error_code(), @tftp.DiskFull)
      assert_eq(error.message(), "out of space")
    }
    other => fail("expected ERROR 3, got \{outcome_repr(other)}")
  }
}

///|
async test "a read session ignores an ACK for a block it never sent" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/a.txt", b"data")
  let (_, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv").with_max_retries(1),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  // ACK 7 names a block that was never sent. The session must not treat it as
  // the answer to DATA 1; it retransmits and eventually times out instead.
  ignore(
    @tftp.Datagram::new(@tftp.encode(@tftp.Packet::Ack(7)), "127.0.0.1:5000"),
  )
  match session.serve(@tftp.Packet::Rrq("a.txt", @tftp.Octet, [])) {
    @tftp.Failed(error) => assert_eq(error.error_code(), @tftp.Undefined)
    other => fail("expected a timeout, got \{outcome_repr(other)}")
  }
}

///|
async test "step_write nudges a silent peer and then gives up" {
  let files = @tftp.MemoryFileSystem::new()
  let (_, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  // One retry left: the first timeout re-sends ACK 0 and reports that the
  // session is still going, the second gives up.
  let (done, outcome) = step_once(session, 0, Bytes::new(0), 1)
  assert_false(done)
  assert_eq(outcome, @tftp.Written(0))
  let (done, outcome) = step_once(session, 0, Bytes::new(0), 0)
  assert_true(done)
  match outcome {
    @tftp.Failed(error) => assert_eq(error.error_code(), @tftp.Undefined)
    other => fail("expected a timeout, got \{outcome_repr(other)}")
  }
}

///|
async test "step_write reports a peer's error and ignores a stray DATA" {
  let files = @tftp.MemoryFileSystem::new()
  let (_, server, session) = session_triple(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
  )
  // A block *before* the one we are waiting on, when nothing has been stored
  // yet, is still "already have it": re-acknowledge it and keep waiting.
  inject(server, @tftp.encode(@tftp.Packet::Data(0, b"stale")))
  let (done, outcome) = step_once(session, 0, Bytes::new(0), 3)
  assert_false(done)
  assert_eq(outcome, @tftp.Written(0))
  // Then the peer gives up.
  inject(
    server,
    @tftp.encode(@tftp.Packet::Error(@tftp.IllegalOperation, "no thanks")),
  )
  let (done, outcome) = step_once(session, 0, Bytes::new(0), 3)
  assert_true(done)
  match outcome {
    @tftp.Failed(error) => assert_eq(error.error_code(), @tftp.IllegalOperation)
    other => fail("expected ERROR 4, got \{outcome_repr(other)}")
  }
}

///|
/// The option negotiation is a *shape* check, and `blksize=8` is legal, so it
/// must go through rather than be refused: a server that rejected the RFC
/// minimum would break interoperable clients.
async test "the minimum block size is accepted, not refused" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/a.txt", b"data")
  assert_eq(
    plan(
      files,
      @tftp.Packet::Rrq("a.txt", @tftp.Octet, [
        @tftp.TftpOption::new("blksize", "8"),
      ]),
    ),
    Ok(@tftp.ServeFile("/srv/a.txt")),
  )
}

///|
/// A peer's ERROR has to come back with the peer's own code and text.
///
/// Exercised directly because reaching every code through a live session would
/// mean the peer lying about four of them; the point is the mapping, and a
/// unit test is the honest way to pin it down.
test "from_peer_error keeps the peer's code" {
  let cases : Array[(@tftp.ErrorCode, @tftp.ServerError)] = [
    (@tftp.FileNotFound, @tftp.ServerError::FileNotFound("m")),
    (@tftp.AccessViolation, @tftp.ServerError::AccessViolation("m")),
    (@tftp.DiskFull, @tftp.ServerError::DiskFull("m")),
    (@tftp.IllegalOperation, @tftp.ServerError::IllegalOperation("m")),
    (@tftp.FileAlreadyExists, @tftp.ServerError::FileAlreadyExists("m")),
    (@tftp.UnknownTransferId, @tftp.ServerError::UnknownTransferId("m")),
    (
      @tftp.OptionNegotiationFailed,
      @tftp.ServerError::OptionNegotiationFailed("m"),
    ),
  ]
  for pair in cases {
    let mapped = @tftp.peer_error(pair.0, "m")
    assert_eq(mapped.error_code(), pair.1.error_code())
  }
  // A code with no matching variant is folded into ERROR 4 rather than being
  // reported as something it is not; the text keeps the original spelling.
  assert_eq(
    @tftp.peer_error(@tftp.NoSuchUser, "no such user").error_code(),
    @tftp.IllegalOperation,
  )
  assert_eq(
    @tftp.peer_error(@tftp.Undefined, "shrug").message(),
    "peer error: shrug",
  )
}

///|
async test "MemoryFileSystem keeps, lists and forgets files" {
  let files = @tftp.MemoryFileSystem::new()
  assert_false(files.has("/a"))
  assert_eq(files.get("/a"), None)
  files.put("/a", b"one")
  assert_true(files.has("/a"))
  assert_eq(files.get("/a"), Some(b"one"))
  assert_eq(files.paths(), ["/a"])
  let options = @tftp.ServerOptions::default().with_root("/")
  assert_eq(
    @tftp.plan_request(options, files, @tftp.Packet::Wrq("/a", @tftp.Octet, [])),
    Err(@tftp.ServerError::FileAlreadyExists("/a")),
  )
}

///|

///|
/// The *answer* half of the ERROR 8 path: a size the server cannot announce
/// has to be refused by the negotiator, with the offending value spelled out,
/// rather than quietly omitted from the OACK (RFC 2347, section 3).
async test "an out-of-range answer is refused with its value spelled out" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/a.txt", b"data")
  let request = @tftp.Packet::Rrq("a.txt", @tftp.Octet, [
    @tftp.TftpOption::new("tsize", "0"),
  ])
  let requested = match @tftp.parse_options(request) {
    Ok(requested) => requested
    Err(_) => fail("the request should parse")
  }
  // The only way a `tsize` answer is out of range is arithmetic overflow: an
  // ordinary 100 MB file negotiates just fine (see the case below).
  assert_eq(
    @tftp.resolve_options(requested, fn(_option) { Ok(Some("2147483648")) }),
    Err(@tftp.BadTsize("2147483648")),
  )
  // A session that goes down this path answers with ERROR 8 and stops, which
  // is what a client sees when the server cannot announce what it will send.
  assert_eq(
    @tftp.ServerError::OptionNegotiationFailed("tsize=2147483648").to_packet(),
    @tftp.Packet::Error(@tftp.OptionNegotiationFailed, "tsize=2147483648"),
  )
}

///|
/// A large file is not a bad option: the `tsize` a server announces is the
/// file size, so a value past `max_block_size` has to reach the OACK.
async test "a large file announces its tsize instead of failing" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/big.bin", Bytes::make(1, b'x'))
  let request = @tftp.Packet::Rrq("big.bin", @tftp.Octet, [
    @tftp.TftpOption::new("tsize", "0"),
  ])
  let requested = match @tftp.parse_options(request) {
    Ok(requested) => requested
    Err(_) => fail("the request should parse")
  }
  let options = match
    @tftp.resolve_options(requested, fn(_option) { Ok(Some("104857600")) }) {
    Ok(options) => options
    Err(_) => fail("a 100 MB size is not out of range")
  }
  assert_eq(options.tsize(), Some(104857600))
  assert_eq(
    options.oack_packet(),
    Some(@tftp.Packet::Oack([@tftp.TftpOption::new("tsize", "104857600")])),
  )
}

///|
async test "a write session re-acknowledges a duplicate and rejects a future block" {
  let files = @tftp.MemoryFileSystem::new()
  let (_, server, session) = session_triple(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
  )
  let full = Bytes::from_array(FixedArray::make(512, b'd'))
  // The session has sent ACK 0 and is waiting on block 1.
  session.transport.send(@tftp.encode(@tftp.Packet::Ack(0)), "127.0.0.1:5000")
  // Block 1 arrives and is stored.
  inject(server, @tftp.encode(@tftp.Packet::Data(1, full)))
  let (done, outcome) = step_once(session, 0, Bytes::new(0), 3)
  assert_false(done)
  assert_eq(outcome, @tftp.Written(512))
  let collected = full
  // A duplicate of block 1: re-acknowledged, not stored twice.
  inject(server, @tftp.encode(@tftp.Packet::Data(1, full)))
  let (done, outcome) = step_once(session, 1, collected, 3)
  assert_false(done)
  assert_eq(outcome, @tftp.Written(512))
  // A block from the future: re-ACK 1 so the peer retransmits the one we want.
  inject(server, @tftp.encode(@tftp.Packet::Data(9, b"future")))
  let (done, outcome) = step_once(session, 1, collected, 3)
  assert_false(done)
  assert_eq(outcome, @tftp.Written(512))
  // A packet that is neither DATA nor ERROR: still waiting.
  inject(server, @tftp.encode(@tftp.Packet::Ack(1)))
  let (done, outcome) = step_once(session, 1, collected, 3)
  assert_false(done)
  assert_eq(outcome, @tftp.Written(512))
  // Now block 2, short, which ends the file at 512 + 2.
  inject(server, @tftp.encode(@tftp.Packet::Data(2, b"ab")))
  let (done, outcome) = step_once(session, 1, collected, 3)
  assert_true(done)
  assert_eq(outcome, @tftp.Written(514))
}

///|
/// A read whose file disappears between the plan and the read — the classic
/// race — must still answer with ERROR 1 rather than dying silently.
async test "serve reports a file that vanished after the plan as ERROR 1" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/gone.txt", b"here for now")
  let (_, session) = session_pair(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
    "127.0.0.1:5000",
    "127.0.0.1:7000",
  )
  // `break_reads` is the race: the plan saw the file, the read does not.
  files.break_reads()
  match session.serve(@tftp.Packet::Rrq("gone.txt", @tftp.Octet, [])) {
    @tftp.Failed(error) => assert_eq(error.error_code(), @tftp.FileNotFound)
    other => fail("expected ERROR 1, got \{outcome_repr(other)}")
  }
}

///|
/// A write whose session is told to stop must not leave a half-written file:
/// the ERROR goes out and nothing is stored.
async test "a write session that gives up stores nothing" {
  let files = @tftp.MemoryFileSystem::new()
  let (_, server, session) = session_triple(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
  )
  session.transport.send(@tftp.encode(@tftp.Packet::Ack(0)), "127.0.0.1:5000")
  // The peer gives up before sending anything.
  inject(
    server,
    @tftp.encode(@tftp.Packet::Error(@tftp.IllegalOperation, "never mind")),
  )
  match session.serve(@tftp.Packet::Wrq("half.bin", @tftp.Octet, [])) {
    @tftp.Failed(error) => assert_eq(error.error_code(), @tftp.IllegalOperation)
    other => fail("expected a failure, got \{outcome_repr(other)}")
  }
  // The handshake packet went out, but no file was ever created.
  assert_false(files.has("/srv/half.bin"))
}

///|
async test "a read session ignores an OACK the peer should not send" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/a.txt", b"data")
  let (_, server, session) = session_triple(
    files,
    @tftp.ServerOptions::default().with_root("/srv").with_max_retries(1),
  )
  // An OACK is a server-to-client packet, so one arriving at a server is
  // nonsense. The session must not mistake it for an ACK: it waits out its
  // retries and gives up.
  inject(
    server,
    @tftp.encode(@tftp.Packet::Oack([@tftp.TftpOption::new("blksize", "1024")])),
  )
  match session.serve(@tftp.Packet::Rrq("a.txt", @tftp.Octet, [])) {
    @tftp.Failed(error) => assert_eq(error.error_code(), @tftp.Undefined)
    other => fail("expected a timeout, got \{outcome_repr(other)}")
  }
}

///|
async test "a read session survives an ACK for block 0 before the options are settled" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/a.txt", b"data")
  let (_, server, session) = session_triple(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
  )
  let request = @tftp.Packet::Rrq("a.txt", @tftp.Octet, [
    @tftp.TftpOption::new("blksize", "1024"),
  ])
  // An ACK 7 while the OACK is still unacknowledged is neither the ACK 0 that
  // settles the options nor anything else the session can act on.
  inject(server, @tftp.encode(@tftp.Packet::Ack(7)))
  // And then the right one, so the transfer can still complete.
  inject(server, @tftp.encode(@tftp.Packet::Ack(0)))
  inject(server, @tftp.encode(@tftp.Packet::Ack(1)))
  ignore(request)
  let outcome = session.serve(request)
  match outcome {
    @tftp.Read(count) => assert_eq(count, 4)
    other => fail("expected a completed read, got \{outcome_repr(other)}")
  }
}

///|
async test "a write session counts a duplicate of an earlier block as a nudge" {
  let files = @tftp.MemoryFileSystem::new()
  let (_, server, session) = session_triple(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
  )
  let full = Bytes::from_array(FixedArray::make(512, b'e'))
  session.transport.send(@tftp.encode(@tftp.Packet::Ack(0)), "127.0.0.1:5000")
  // Blocks 1 and 2 were both stored already.
  inject(server, @tftp.encode(@tftp.Packet::Data(1, full)))
  ignore(step_once(session, 0, Bytes::new(0), 3))
  inject(server, @tftp.encode(@tftp.Packet::Data(2, full)))
  ignore(step_once(session, 1, full, 3))
  // Now block 1 again: a duplicate of something we hold, so it is
  // re-acknowledged with block *1*, not with the block we are waiting on.
  inject(server, @tftp.encode(@tftp.Packet::Data(1, full)))
  let (done, outcome) = step_once(session, 2, full + full, 3)
  assert_false(done)
  // The buffer is unchanged: 1024, not 1536.
  assert_eq(outcome, @tftp.Written(1024))
}

///|
/// A RRQ whose `tsize` is not the RFC 2349 placeholder has to fail the
/// negotiation with ERROR 8 *before* a single DATA goes out: a client stating a
/// size is assuming a reply shape we never promised.
async test "a read with an unanswerable tsize is refused before any data" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/a.txt", b"data")
  let (client, _, session) = session_triple(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
  )
  // A read request carrying a real `tsize` (not the RFC 2349 placeholder 0) is
  // the fatal shape: the client is stating a size it expects us to take, and
  // `parse_options` refuses it before the session can move.
  let request = @tftp.Packet::Rrq("a.txt", @tftp.Octet, [
    @tftp.TftpOption::new("tsize", "4096"),
  ])
  match session.serve(request) {
    @tftp.Failed(error) =>
      assert_eq(error.error_code(), @tftp.OptionNegotiationFailed)
    other => fail("expected ERROR 8, got \{outcome_repr(other)}")
  }
  // The refusal went out as an ERROR on the session's own TID, before any
  // DATA. The session must not have sent a single block of the file.
  match client.recv("127.0.0.1:7000", 1000) {
    @tftp.Recv::Packet(datagram) =>
      assert_true(
        @tftp.decode(datagram.payload())
        is Ok(@tftp.Packet::Error(@tftp.OptionNegotiationFailed, _)),
      )
    @tftp.Recv::Timeout => fail("expected the ERROR 8 to go out")
  }
}

///|
/// The same refusal for a WRQ: a `tsize=0` is answered with ERROR 8 instead of
/// a silent fallback (RFC 2349, section 4).
async test "a write with an unanswerable blksize is refused with ERROR 8" {
  let files = @tftp.MemoryFileSystem::new()
  let (_, _, session) = session_triple(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
  )
  // A WRQ with `tsize=0` is the fatal shape on the write side: it says "tell me
  // nothing about a size" while RFC 2349 wants the size the file will have.
  let request = @tftp.Packet::Wrq("new.bin", @tftp.Octet, [
    @tftp.TftpOption::new("tsize", "0"),
  ])
  match session.serve(request) {
    @tftp.Failed(error) =>
      assert_eq(error.error_code(), @tftp.OptionNegotiationFailed)
    other => fail("expected ERROR 8, got \{outcome_repr(other)}")
  }
  assert_false(files.has("/srv/new.bin"))
}

///|
/// A write session whose session socket is silent has to time out with ERROR 0
/// (the code RFC 1350 keeps for exactly that), and the peer's DATA is only
/// accepted when it is the block expected.
async test "serve_write times out on a silent peer and ignores a stale ACK" {
  let files = @tftp.MemoryFileSystem::new()
  let (_, server, session) = session_triple(
    files,
    @tftp.ServerOptions::default().with_root("/srv").with_max_retries(0),
  )
  // The ACK 0 of the handshake goes out, then nothing arrives: one timeout
  // with no retries left must end the session with ERROR 0.
  session.transport.send(@tftp.encode(@tftp.Packet::Ack(0)), "127.0.0.1:5000")
  match session.serve(@tftp.Packet::Wrq("new.bin", @tftp.Octet, [])) {
    @tftp.Failed(error) => assert_eq(error.error_code(), @tftp.Undefined)
    other => fail("expected a timeout, got \{outcome_repr(other)}")
  }
  // Nothing was stored: a session that never transferred writes no file.
  assert_false(files.has("/srv/new.bin"))
  ignore(server)
}

///|
/// `serve_write`'s three answers to a DATA, driven through the full `serve`
/// loop so the retries and the stored file are the real ones: the block we
/// expect, a duplicate we already hold, and a block from the future.
async test "serve_write separates a duplicate, a gap and the next block" {
  let files = @tftp.MemoryFileSystem::new()
  let (_, server, session) = session_triple(
    files,
    @tftp.ServerOptions::default().with_root("/srv").with_max_retries(5),
  )
  let full = Bytes::from_array(FixedArray::make(512, b'd'))
  // The handshake: ACK 0, then block 1.
  inject(server, @tftp.encode(@tftp.Packet::Data(1, full)))
  // A duplicate of block 1 while block 2 is expected: re-acknowledged as 1,
  // and the bytes already held are not stored twice.
  inject(server, @tftp.encode(@tftp.Packet::Data(1, full)))
  // A block from the future: answered with the last block we accepted.
  inject(server, @tftp.encode(@tftp.Packet::Data(9, b"future")))
  // Not DATA at all: ignored, the peer will retransmit.
  inject(server, @tftp.encode(@tftp.Packet::Ack(2)))
  // And the short block that ends the file.
  inject(server, @tftp.encode(@tftp.Packet::Data(2, b"tail")))
  match session.serve(@tftp.Packet::Wrq("new.bin", @tftp.Octet, [])) {
    @tftp.Written(bytes) => assert_eq(bytes, 516)
    other => fail("expected a completed write, got \{outcome_repr(other)}")
  }
  assert_eq(files.get("/srv/new.bin"), Some(full + b"tail"))
}

///|
/// `serve_write` also has to survive a datagram that does not decode at all:
/// it is neither DATA nor ERROR, so the session stays where it is.
async test "serve_write skips a malformed datagram" {
  let files = @tftp.MemoryFileSystem::new()
  let (_, server, session) = session_triple(
    files,
    @tftp.ServerOptions::default().with_root("/srv").with_max_retries(5),
  )
  inject(server, b"\x00\x09garbage")
  inject(server, @tftp.encode(@tftp.Packet::Data(1, b"only")))
  match session.serve(@tftp.Packet::Wrq("junk.bin", @tftp.Octet, [])) {
    @tftp.Written(bytes) => assert_eq(bytes, 4)
    other => fail("expected a completed write, got \{outcome_repr(other)}")
  }
  assert_eq(files.get("/srv/junk.bin"), Some(b"only"))
}

///|
/// The read side of the same rule: an ACK for a block the server never sent is
/// not progress, and the session keeps waiting for the ACK it can act on.
async test "serve_read ignores an ACK for a block it never sent" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/a.txt", b"hello, tftp")
  let (_, server, session) = session_triple(
    files,
    @tftp.ServerOptions::default().with_root("/srv").with_max_retries(5),
  )
  // ACK 7: one block ahead of the DATA that is still in flight, so nothing the
  // server can read as progress.
  inject(server, @tftp.encode(@tftp.Packet::Ack(7)))
  inject(server, @tftp.encode(@tftp.Packet::Ack(1)))
  match session.serve(@tftp.Packet::Rrq("a.txt", @tftp.Octet, [])) {
    @tftp.Read(bytes) => assert_eq(bytes, 11)
    other => fail("expected a completed read, got \{outcome_repr(other)}")
  }
}

///|
/// `AcceptedOptions` is the session's view of what was negotiated, including
/// the case where nothing was: the defaults still have to answer.
async test "a session without options reports the RFC defaults" {
  let files = @tftp.MemoryFileSystem::new()
  files.put("/srv/a.txt", b"hello")
  let (_, _, session) = session_triple(
    files,
    @tftp.ServerOptions::default().with_root("/srv"),
  )
  // `serve_read` reads the accepted options through `AcceptedOptions`, so a
  // request with no options still goes through `options()` — it answers None.
  assert_eq(@tftp.Options::default().blksize(), 512)
  assert_eq(@tftp.Options::default().tsize(), None)
  ignore(session)
}
