///|
/// An in-memory `Transport`, so a whole session can run without a socket.
///
/// Two endpoints are wired together with `Transport::pair`; each `send` lands
/// in the other's inbox tagged with the sender's address, so the peer filter a
/// real socket gets from `connect`/`recvfrom` is reproduced exactly.
///
/// The inbox is a plain queue, which means a test can *also* deliver packets by
/// hand: `inject` fakes a packet from any address, which is how the "a packet
/// from a stranger must be ignored" case is exercised. Congestion control is
/// deliberately left to the test by not queueing more than one datagram at a
/// time unless it asks for it.

///|
/// The shared mailbox two in-memory endpoints talk through.
///
/// A `Mailbox` is a mutable class so both endpoints see the same queues after
/// the pair is split.
pub struct Mailbox {
  queue : Array[Datagram]
  /// Whether the next send is dropped, to make a retransmission happen.
  mut drop_next : Bool
} derive(Debug)

///|
pub extend Mailbox with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn Mailbox::new() -> Mailbox {
  { queue: [], drop_next: false, }
}

///|
/// Drops the next datagram sent through this mailbox, so a sender runs into its
/// retransmission timeout. Tests use it instead of sleeping.
pub fn Mailbox::drop_next_packet(self : Mailbox) -> Unit {
  self.drop_next = true
}

///|
/// Delivers a datagram as if it came from `peer`, bypassing the pair.
pub fn Mailbox::inject(self : Mailbox, datagram : Datagram) -> Unit {
  self.queue.push(datagram)
}

///|
/// Queues `datagram` unless a drop was requested.
fn Mailbox::deliver(self : Mailbox, datagram : Datagram) -> Unit {
  if self.drop_next {
    self.drop_next = false
    return
  }
  self.queue.push(datagram)
}

///|
/// Takes the first datagram from `peer`, if there is one.
fn Mailbox::take_from(self : Mailbox, peer : String) -> Datagram? {
  for i = 0; i < self.queue.length(); i = i + 1 {
    if self.queue[i].peer() == peer {
      let datagram = self.queue[i]
      ignore(self.queue.remove(i))
      return Some(datagram)
    }
  }
  None
}

///|
/// One end of an in-memory link.
pub struct MemoryTransport {
  address : String
  outbox : Mailbox
  inbox : Mailbox
}

///|
/// Creates two endpoints wired to each other.
///
/// `left` sends into `right`'s inbox and receives from it, and vice versa; the
/// addresses are the TIDs each side expects the other to use.
pub fn MemoryTransport::pair(
  left_address : String,
  right_address : String,
) -> (MemoryTransport, MemoryTransport) {
  let left_inbox = Mailbox::new()
  let right_inbox = Mailbox::new()
  let left = { address: left_address, outbox: right_inbox, inbox: left_inbox, }
  let right = {
    address: right_address,
    outbox: left_inbox,
    inbox: right_inbox,
  }
  (left, right)
}

///|
/// The mailbox this endpoint reads from, for tests that inject by hand.
pub fn MemoryTransport::inbox(self : MemoryTransport) -> Mailbox {
  self.inbox
}

///|
/// The mailbox the other endpoint reads from; a test drops packets here to
/// force a retransmission.
pub fn MemoryTransport::outbox(self : MemoryTransport) -> Mailbox {
  self.outbox
}

///|
pub extend MemoryTransport with Transport::{recv, local_peer, send}

///|
pub impl Transport for MemoryTransport with fn local_peer(self) {
  self.address
}

///|
pub impl Transport for MemoryTransport with fn send(self, payload, _peer) {
  self.outbox.deliver(Datagram::new(payload, self.address))
  // Hand control back so the other endpoint can run: an in-memory send is a
  // scheduling point, exactly like a real socket write.
  @async.pause()
}

///|
pub impl Transport for MemoryTransport with fn recv(self, peer, timeout_ms) {
  // Poll the mailbox for the caller's whole budget instead of checking once:
  // a test that drops a packet relies on the client really waiting out its
  // timeout, otherwise the retransmission it wants to observe never happens.
  // The mailbox has no wake-up channel, so polling is the honest option here.
  let mut waited = 0
  while true {
    match self.inbox.take_from(peer) {
      Some(datagram) => return Recv::Packet(datagram)
      None =>
        if waited >= timeout_ms {
          return Recv::Timeout
        } else {
          @async.sleep(1)
          waited = waited + 1
        }
    }
  }
  Recv::Timeout
}
