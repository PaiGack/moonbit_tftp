///|
/// The real-socket `Transport` the client runs on.
///
/// The client state machines never touch a socket; this file is the one
/// implementation of `Transport` that does, so the same `get` / `put` runs
/// against a real UDP port here and against the in-memory pair in tests.
///
/// The socket is deliberately *not* connected to the server's port. TFTP's
/// TID rule (RFC 1350, section 4) says the server answers a request from a
/// fresh port, so a socket locked onto port 69 would drop every reply and
/// have the kernel answer the server with ICMP. The first datagram the peer
/// sends therefore *defines* the TID this transfer talks to, and only that
/// address is accepted from then on.

///|
/// A client `Transport` bound to a local ephemeral port.
pub struct SocketTransport {
  socket : @socket.UdpServer
  /// The request address the caller asked for. The reply may come from a
  /// different port, which becomes `peer` once it is seen.
  request_peer : String
  /// The address the peer is actually using, learnt from its first packet.
  mut peer : String
  address : String
}

///|
/// Binds an ephemeral local port for the transfer's own TID.
///
/// Port 0 lets the OS pick: the server answers the request back to whatever
/// port it came from, and that port is this transfer's TID.
pub async fn SocketTransport::new(remote : String) -> SocketTransport {
  let socket = @socket.UdpServer(@socket.Addr::parse("0.0.0.0:0"))
  {
    socket,
    request_peer: remote,
    peer: remote,
    address: socket.addr.to_string(),
  }
}

///|
/// Releases the local port.
pub fn SocketTransport::close(self : SocketTransport) -> Unit {
  self.socket.close()
}

///|
pub extend SocketTransport with Transport::{recv, local_peer, send}

///|
pub impl Transport for SocketTransport with fn local_peer(self) {
  self.address
}

///|
/// Sends to the peer address. The request goes to the well-known port; every
/// later packet goes to the TID the peer's first reply came from.
pub impl Transport for SocketTransport with fn send(self, payload, peer) {
  // Every packet goes to the TID the peer's reply came from once it is known.
  // Only the request itself — sent before any reply — goes to the well-known
  // port the caller named, because that is the one port the server listens on.
  let target = if self.peer == self.request_peer { peer } else { self.peer }
  self.socket.sendto(payload, @socket.Addr::parse(target))
}

///|
pub impl Transport for SocketTransport with fn recv(self, peer, timeout_ms) {
  let buffer = FixedArray::make(65536, b'\x00')
  let expected = if peer == self.request_peer { self.peer } else { peer }
  // One deadline covers the whole call: `read_expected` keeps reading past
  // datagrams from anyone else, so a stray packet is dropped without spending
  // the caller's budget.
  let received = @async.with_timeout_opt(timeout_ms, () => {
    self.read_expected(buffer, expected)
  })
  match received {
    Some((payload, from)) => {
      // The first reply may arrive from a port other than the one the request
      // went to; that address is the peer's TID from here on.
      if expected == self.request_peer {
        self.peer = from
      }
      Recv::Packet(Datagram::new(payload, from))
    }
    None => Recv::Timeout
  }
}

///|
/// Reads datagrams until one came from `expected`, and returns it.
///
/// A packet from anyone else is discarded and the read continues: that is what
/// `Transport::recv(peer, ...)` promises — only the peer's packets are ever
/// seen — and it is also how a stale packet from a previous TID is ignored.
async fn SocketTransport::read_expected(
  self : SocketTransport,
  buffer : FixedArray[Byte],
  expected : String,
) -> (Bytes, String) {
  while true {
    let (length, from) = self.socket.recvfrom(buffer)
    let address = from.to_string()
    if address == expected || expected == self.request_peer {
      break (buffer.unsafe_reinterpret_as_bytes()[:length].to_owned(), address)
    }
  } nobreak {
    (
      // Unreachable: the loop only ends via `break`.
      Bytes::new(0),
      expected,
    )
  }
}
