///|
/// The host-filesystem backend, exercised against a real temporary directory
/// and real UDP sockets, in-process.
///
/// These are the two halves of `server_fs.mbt` that only exist because a
/// server runs on a host: the `FileSystem` that maps an OS error onto the TFTP
/// error code the peer is owed, and the `SocketSession` that enforces the TID
/// rule by construction. Neither can be reached through the in-memory fakes,
/// and both are one careless `try` away from leaking an OS error onto the
/// wire, so they are worth asserting on directly.

///|
/// A fresh directory under the system temp dir, removed when the test ends.
struct HostTmpDir {
  path : String
}

///|
async fn HostTmpDir::new() -> HostTmpDir {
  { path: @fs.tmpdir(prefix="moon-tftp-test-"), }
}

///|
fn HostTmpDir::file(self : HostTmpDir, name : String) -> String {
  "\{self.path}/\{name}"
}

///|
async fn HostTmpDir::drop(self : HostTmpDir) -> Unit {
  try @fs.rmdir(self.path, recursive=true) catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// One write of `payload` to `path`, then a read back.
async fn write_then_read(
  files : HostFileSystem,
  path : String,
  payload : Bytes,
) -> Result[Bytes, ServerError] {
  match files.write(path, payload) {
    Ok(_) => files.read(path)
    Err(error) => Err(error)
  }
}

// ---------------------------------------------------------------------------
// HostFileSystem
// ---------------------------------------------------------------------------

///|
async test "host filesystem round-trips a file" {
  let tmp = HostTmpDir::new()
  defer tmp.drop()
  let path = tmp.file("hello.txt")
  let files = HostFileSystem::new()
  match write_then_read(files, path, b"hello tftp") {
    Ok(payload) => assert_eq(payload, b"hello tftp")
    Err(error) => fail("expected a round-trip, got \{error.message()}")
  }
  assert_true(files.exists(path))
  assert_false(files.exists(tmp.file("missing.txt")))
}

///|
async test "host filesystem overwrites an existing file" {
  let tmp = HostTmpDir::new()
  defer tmp.drop()
  let path = tmp.file("blob.bin")
  let files = HostFileSystem::new()
  files.write(path, b"first") |> ignore
  // `write_file` truncates, so what comes back is exactly the new payload.
  match write_then_read(files, path, b"second-longer") {
    Ok(payload) => assert_eq(payload, b"second-longer")
    Err(error) => fail("expected an overwrite, got \{error.message()}")
  }
}

///|
async test "host filesystem reads a missing file as ERROR 1" {
  let tmp = HostTmpDir::new()
  defer tmp.drop()
  let files = HostFileSystem::new()
  match files.read(tmp.file("nope.bin")) {
    Err(error) => {
      assert_true(error is FileNotFound(_))
      assert_eq(error.error_code(), ErrorCode::FileNotFound)
    }
    Ok(_) => fail("expected the read to fail")
  }
}

///|
async test "host filesystem writes a missing directory as ERROR 1" {
  let tmp = HostTmpDir::new()
  defer tmp.drop()
  let files = HostFileSystem::new()
  // Not a permission error: nothing was denied, the path simply is not there.
  match files.write(tmp.file("no/such/dir/f.bin"), b"x") {
    Err(error) => {
      assert_true(error is FileNotFound(_))
      assert_eq(error.error_code(), ErrorCode::FileNotFound)
    }
    Ok(_) => fail("expected the write to fail")
  }
}

///|
async test "host filesystem maps a denied write onto ERROR 2" {
  let tmp = HostTmpDir::new()
  defer tmp.drop()
  let path = tmp.file("locked/f.bin")
  try @fs.mkdir(tmp.file("locked"), permission=0o500) catch {
    _ => ()
  } noraise {
    _ => ()
  }
  defer (@fs.rmdir(tmp.file("locked"), recursive=true) catch { _ => () })
  let files = HostFileSystem::new()
  match files.write(path, b"x") {
    Err(error) => {
      assert_true(error is AccessViolation(_))
      assert_eq(error.error_code(), ErrorCode::AccessViolation)
    }
    // Root ignores the mode bits, and so may a container without the matching
    // capability; either way the write simply succeeds.
    Ok(_) => assert_true(files.exists(path))
  }
}

///|
async test "host filesystem maps a denied read onto ERROR 2" {
  let tmp = HostTmpDir::new()
  defer tmp.drop()
  let path = tmp.file("secret.txt")
  let files = HostFileSystem::new()
  files.write(path, b"private") |> ignore
  try @fs.chmod(path, 0o000) catch {
    _ => ()
  } noraise {
    _ => ()
  }
  defer (@fs.chmod(path, 0o644) catch { _ => () })
  match files.read(path) {
    Err(error) => {
      assert_true(error is AccessViolation(_))
      assert_eq(error.error_code(), ErrorCode::AccessViolation)
    }
    // Root can read anything, and so can the owner of a mode-000 file on some
    // platforms; what matters is that no OS error escapes either way.
    Ok(payload) => assert_eq(payload, b"private")
  }
}

///|
async test "host filesystem answers an empty file with zero bytes" {
  let tmp = HostTmpDir::new()
  defer tmp.drop()
  let path = tmp.file("empty.bin")
  let files = HostFileSystem::new()
  files.write(path, b"") |> ignore
  match files.read(path) {
    Ok(payload) => assert_eq(payload.length(), 0)
    Err(error) => fail("expected an empty read, got \{error.message()}")
  }
}

///|
async test "host filesystem keeps a payload larger than one block" {
  let tmp = HostTmpDir::new()
  defer tmp.drop()
  let path = tmp.file("big.bin")
  let payload = Bytes::make(2048, b'\xAB')
  let files = HostFileSystem::new()
  match write_then_read(files, path, payload) {
    Ok(read) => {
      assert_eq(read.length(), 2048)
      assert_eq(read, payload)
    }
    Err(error) => fail("expected the whole file, got \{error.message()}")
  }
}

// ---------------------------------------------------------------------------
// host_error_message
// ---------------------------------------------------------------------------

///|
/// The whole point of `host_error_message`: an OS error never reaches the peer
/// as itself, it becomes one of RFC 1350's codes. These are the three branches
/// and nothing else, so they are asserted directly rather than through a file
/// operation that may not fail the way we want on every host.
test "a full disk is ERROR 3, a denied file is ERROR 2, anything else ERROR 1" {
  let full = host_error_message(Failure("No space left on device"), "write f")
  assert_true(full is DiskFull(_))
  assert_eq(full.error_code(), ErrorCode::DiskFull)
  assert_eq(
    host_error_message(Failure("ENOSPC"), "write f").error_code(),
    ErrorCode::DiskFull,
  )
  let denied = host_error_message(Failure("Permission denied"), "write f")
  assert_true(denied is AccessViolation(_))
  assert_eq(denied.error_code(), ErrorCode::AccessViolation)
  assert_eq(
    host_error_message(Failure("EACCES"), "write f").error_code(),
    ErrorCode::AccessViolation,
  )
  let other = host_error_message(Failure("something else"), "write f")
  assert_true(other is FileNotFound(_))
  assert_eq(other.error_code(), ErrorCode::FileNotFound)
  // The operation is what the ERROR names, so a client learns which file it
  // was that could not be served.
  assert_eq(other.message(), "write f")
}

// ---------------------------------------------------------------------------
// SocketSession
// ---------------------------------------------------------------------------

///|
/// A local port that is free right now, for a session to be handed as its TID.
///
/// `SocketSession::new` takes the TID as a string, so the test needs one that
/// nothing else holds. Binding port 0 and immediately releasing it is the
/// in-process way to get one.
async fn free_port() -> String {
  let probe = @socket.UdpServer(@socket.Addr::parse("127.0.0.1:0"))
  let addr = probe.addr.to_string()
  probe.close()
  addr
}

///|
/// Reads one datagram, or fails the test.
async fn recv_one(socket : @socket.UdpServer) -> (Bytes, @socket.Addr) {
  let buffer = FixedArray::make(1024, b'\x00')
  match @async.with_timeout_opt(2000, () => socket.recvfrom(buffer)) {
    Some((length, from)) =>
      (buffer.unsafe_reinterpret_as_bytes()[:length].to_owned(), from)
    None => fail("expected a datagram to arrive")
  }
}

///|
async test "socket session sends to its peer and hears the answer back" {
  let server = @socket.UdpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  let session = SocketSession::new(free_port(), server.addr.to_string())
  defer session.close()
  assert_eq(session.local_peer(), session.tid())
  session.send(b"ping")
  let (payload, from) = recv_one(server)
  assert_eq(payload, b"ping")
  // The datagram came from the session's own socket, not from some fresh port
  // the caller never heard of.
  assert_eq(from.to_string().has_prefix("127.0.0.1:"), true)
  assert_true(from.port() > 0)
  // The peer's answer finds its way back through the connected socket.
  server.sendto(b"pong", from)
  match session.recv(2000) {
    Recv::Packet(datagram) => assert_eq(datagram.payload(), b"pong")
    Recv::Timeout => fail("expected the answer to arrive")
  }
}

///|
async test "socket session reports a timeout instead of hanging" {
  // The peer is bound but silent, so the only honest answer is a timeout: a
  // session that hung here would hang the server's accept loop with it.
  let silent = @socket.UdpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer silent.close()
  let session = SocketSession::new(free_port(), silent.addr.to_string())
  defer session.close()
  match session.recv(300) {
    Recv::Timeout => ()
    Recv::Packet(_) => fail("expected a timeout")
  }
}

///|
async test "socket session drops a datagram from a stranger" {
  let server = @socket.UdpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  let session = SocketSession::new(free_port(), server.addr.to_string())
  defer session.close()
  session.send(b"hello")
  let (_payload, from) = recv_one(server)
  // A third socket, one the session was never connected to, now sends to the
  // session's address. The kernel's `connect` is what keeps it out
  // (RFC 1350, section 4).
  let stranger = @socket.UdpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer stranger.close()
  stranger.sendto(b"not for you", from)
  @async.sleep(100)
  match session.recv(500) {
    Recv::Timeout => ()
    Recv::Packet(_) => fail("a datagram from a stranger must not be delivered")
  }
}

///|
async test "a socket session is a transport whose peer is fixed" {
  let server = @socket.UdpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  let session = SocketSession::new(free_port(), server.addr.to_string())
  defer session.close()
  // The `peer` argument is redundant for a session and is ignored: the packet
  // still lands on the connected peer, whatever address was named.
  Transport::send(session, b"payload", "127.0.0.1:65535")
  let (payload, from) = recv_one(server)
  assert_eq(payload, b"payload")
  // Nothing was ever sent back, so the same redundant argument cannot make a
  // packet appear either.
  match Transport::recv(session, "127.0.0.1:65535", 300) {
    Recv::Timeout => ()
    Recv::Packet(_) => fail("expected no packet")
  }
  // Through the trait the packet does arrive, which is the path a session
  // state machine takes when it is driven by a real socket.
  server.sendto(b"oack", from)
  match Transport::recv(session, "127.0.0.1:65535", 2000) {
    Recv::Packet(datagram) => assert_eq(datagram.payload(), b"oack")
    Recv::Timeout => fail("expected the datagram to arrive")
  }
}
