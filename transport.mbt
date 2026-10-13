///|
/// The UDP transport the client and server sit on.
///
/// Everything below this layer is a pure function of packets and time, so the
/// endpoints only ever see one of two events: a datagram arrived, or the clock
/// ran out. Keeping that as a trait with two operations is what makes a whole
/// TFTP session testable without a socket, and what lets the same state machine
/// run on `native` sockets and on an in-memory pair in tests.
///
/// The datagram carries its peer address because TFTP's TID rule (RFC 1350,
/// section 4) is about *who* a packet came from, not just what it says.

///|
/// A datagram: the bytes and the peer that sent them.
pub struct Datagram {
  payload : Bytes
  peer : String
} derive(Eq, Debug)

///|
pub extend Datagram with Eq::{not_equal, equal}

///|
pub extend Datagram with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn Datagram::new(payload : Bytes, peer : String) -> Datagram {
  { payload, peer, }
}

///|
pub fn Datagram::payload(self : Datagram) -> Bytes {
  self.payload
}

///|
pub fn Datagram::peer(self : Datagram) -> String {
  self.peer
}

///|
/// How long a `recv` should wait before giving up.
pub(all) enum Recv {
  /// A datagram arrived.
  Packet(Datagram)
  /// Nothing arrived within the deadline: time to retransmit.
  Timeout
} derive(Eq, Debug)

///|
pub extend Recv with Eq::{not_equal, equal}

///|
pub extend Recv with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The minimal UDP interface the endpoints depend on.
///
/// Implementations are responsible for the TID rule: a `send` goes to `peer`,
/// and a `recv` filtered on `peer` never returns a datagram from anyone else.
/// The state machines above assume that, so a stray packet cannot be mistaken
/// for the peer's answer.
pub(open) trait Transport {
  /// Sends one datagram to `peer`.
  async fn send(Self, Bytes, peer : String) -> Unit
  /// Waits up to `timeout_ms` milliseconds for a datagram from `peer`.
  async fn recv(Self, peer : String, timeout_ms : Int32) -> Recv
  /// The address this endpoint is bound to, for logs and tests.
  fn local_peer(Self) -> String
}

///|
/// Turns a duration in seconds into the milliseconds `Transport::recv` takes.
pub fn timeout_to_ms(seconds : Int32) -> Int32 {
  // `Int` is 64-bit here, so a 255-second timeout cannot overflow.
  seconds * 1000
}
