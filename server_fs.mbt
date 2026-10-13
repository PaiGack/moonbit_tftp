///|
/// The real-filesystem `FileSystem` backend, and the socket backend a session
/// runs on.
///
/// Both live here, apart from the server logic, so the state machine file stays
/// free of platform imports and still runs on any backend. This file needs a
/// host filesystem and UDP sockets; it is the one place in the module that
/// does.

///|
/// A `FileSystem` backed by the host's filesystem.
///
/// Every failure is translated into the TFTP error code that describes it
/// (RFC 1350, section 5) *here*, at the one boundary that knows what a
/// filesystem error is, so the session above never sees an OS error.
pub struct HostFileSystem {
  /// Keeps the type non-empty so it reads as a distinct handle, and keeps the
  /// backend free to grow without changing callers.
  root : String
}

///|
/// A filesystem view of the host.
pub fn HostFileSystem::new() -> HostFileSystem {
  { root: "/", }
}

///|
/// The `ServerError` a failed host operation becomes.
///
/// A host that is out of space is rare in a test but real in the field, so it
/// gets its own code (ERROR 3) rather than being lumped into "access denied".
/// Anything else is read as "we cannot give you this file", which is what
/// ERROR 1 means.
fn host_error_message(error : Error, operation : String) -> ServerError {
  let text = error.to_string()
  if text.contains("No space") ||
    text.contains("no space") ||
    text.contains("ENOSPC") {
    DiskFull(operation)
  } else if text.contains("Permission") ||
    text.contains("EACCES") ||
    text.contains("permission") {
    AccessViolation(operation)
  } else {
    FileNotFound(operation)
  }
}

///|
pub extend HostFileSystem with FileSystem::{read, write, exists}

///|
pub impl FileSystem for HostFileSystem with fn read(self, path) {
  ignore(self)
  try {
    let data : &@io.Data = @fs.read_file(path)
    Ok(data.binary())
  } catch {
    error => Err(host_error_message(error, "read \{path}"))
  }
}

///|
pub impl FileSystem for HostFileSystem with fn write(self, path, payload) {
  ignore(self)
  try {
    @fs.write_file(path, payload)
    Ok(())
  } catch {
    error => Err(host_error_message(error, "write \{path}"))
  }
}

///|
pub impl FileSystem for HostFileSystem with fn exists(self, path) {
  ignore(self)
  @fs.exists(path)
}

///|
/// A session transport over a real UDP socket.
///
/// The socket is already bound to the session's TID, so `send`/`recv` only ever
/// take the peer's address: the TID rule (RFC 1350, section 4) is enforced by
/// the kernel's `connect`, which is exactly where a packet from a stranger
/// should be dropped.
pub struct SocketSession {
  socket : @socket.UdpClient
  tid : String
}

///|
/// Binds a session socket to `local` and locks it onto `peer`.
pub async fn SocketSession::new(
  bind_to : String,
  peer : String,
) -> SocketSession {
  let socket = @socket.UdpClient(@socket.Addr::parse(bind_to))
  let peer_addr = @socket.Addr::parse(peer)
  socket.connect(peer_addr)
  { socket, tid: bind_to, }
}

///|
/// The TID this session is bound to.
pub fn SocketSession::tid(self : SocketSession) -> String {
  self.tid
}

///|
/// Releases the TID's port.
pub fn SocketSession::close(self : SocketSession) -> Unit {
  self.socket.close()
}

///|
/// Sends one datagram to the peer this socket was connected to.
pub async fn SocketSession::send(self : SocketSession, payload : Bytes) -> Unit {
  self.socket.send(payload)
}

///|
/// Waits up to `timeout_ms` for a datagram, reporting `Recv::Timeout` if none
/// arrived.
///
/// This is where the retransmission timer lives: a real client that goes quiet
/// has to make the session time out, and the state machine above treats that
/// exactly like a lost packet.
pub async fn SocketSession::recv(
  self : SocketSession,
  timeout_ms : Int32,
) -> Recv {
  let buffer = FixedArray::make(65536, b'\x00')
  match
    @async.with_timeout_opt(timeout_ms, () => {
      let length = self.socket.recv(buffer)
      buffer.unsafe_reinterpret_as_bytes()[:length].to_owned()
    }) {
    Some(payload) =>
      Recv::Packet(Datagram::new(payload, self.socket.addr.to_string()))
    None => Recv::Timeout
  }
}

///|
pub extend SocketSession with Transport::{local_peer}

///|
/// A `SocketSession` is also a `Transport`: the peer is fixed at construction,
/// so the peer argument of `send` / `recv` is redundant but ignored. This is
/// what lets the session state machines above run unchanged on a real socket.
///
/// The bodies reach for the socket directly rather than calling `self.send` /
/// `self.recv`, which name the *inherent* single-argument helpers and would
/// not compile here.
pub impl Transport for SocketSession with fn local_peer(self) {
  self.tid
}

///|
pub impl Transport for SocketSession with fn send(self, payload, _peer) {
  self.socket.send(payload)
}

///|
pub impl Transport for SocketSession with fn recv(self, _peer, timeout_ms) {
  let buffer = FixedArray::make(65536, b'\x00')
  match
    @async.with_timeout_opt(timeout_ms, () => {
      let length = self.socket.recv(buffer)
      buffer.unsafe_reinterpret_as_bytes()[:length].to_owned()
    }) {
    Some(payload) =>
      Recv::Packet(Datagram::new(payload, self.socket.addr.to_string()))
    None => Recv::Timeout
  }
}
