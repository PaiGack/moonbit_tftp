///|
/// The client half of a TFTP transfer: the `get` / `put` stop-and-wait state
/// machines (RFC 1350 sections 1 and 4).
///
/// The rule the architecture doc sets out holds here: the state machine never
/// touches a socket. It only reads a packet or times out, then decides what to
/// send next, so a whole session runs against an in-memory `Transport` in a
/// test.
///
/// Three RFC details are worth pointing at, because they are the ones that
/// silently break naive implementations:
///
/// - **Retransmission.** Every DATA/ACK waits for its answer and is resent on
///   timeout. The retry count is bounded so a dead peer cannot spin forever.
/// - **Sorcerer's Apprentice Syndrome.** A duplicate DATA is answered with the
///   same ACK and is *not* fed into the file again, otherwise a second copy of
///   the last block doubles itself on every round trip.
/// - **Block wrap.** Block numbers are compared with `block.mbt`'s half-circle
///   rule, so a transfer past 65535 blocks keeps working.

///|
/// Why a transfer ended badly.
pub(all) enum ClientError {
  /// The peer sent an ERROR packet (RFC 1350, section 5).
  PeerError(ErrorCode, String)
  /// The peer stopped answering and the retry budget ran out.
  Timeout
  /// A packet that makes no sense here: wrong opcode, or a block from a peer
  /// that is not the transfer's.
  Protocol(String)
  /// The request itself could not be built.
  BadRequest(String)
} derive(Eq, Debug)

///|
pub extend ClientError with Eq::{not_equal, equal}

///|
pub extend ClientError with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// What a `get` / `put` produced.
pub(all) enum TransferResult {
  /// The bytes read from the peer, for `get`.
  Received(Bytes)
  /// For `put`, the number of bytes acknowledged.
  Sent(Int32)
} derive(Eq, Debug)

///|
/// A finished transfer plus the negotiated details worth reporting.
///
/// `tsize` is the size the peer announced in its OACK (RFC 2349) when it
/// announced one; `None` means no `tsize` was negotiated.
pub struct TransferOutcome {
  result : TransferResult
  tsize : Int32?
} derive(Eq, Debug)

///|
pub extend TransferOutcome with Eq::{not_equal, equal}

///|
pub extend TransferOutcome with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The bytes or byte count the transfer produced.
pub fn TransferOutcome::result(self : TransferOutcome) -> TransferResult {
  self.result
}

///|
/// The size the peer announced in its OACK, if it announced one.
pub fn TransferOutcome::tsize(self : TransferOutcome) -> Int32? {
  self.tsize
}

///|
/// The file contents of a `get`, or `None` for a `put`.
pub fn TransferOutcome::received(self : TransferOutcome) -> Bytes? {
  match self.result {
    Received(bytes) => Some(bytes)
    Sent(_) => None
  }
}

///|
/// The number of bytes a `put` got acknowledged, or `None` for a `get`.
pub fn TransferOutcome::sent(self : TransferOutcome) -> Int32? {
  match self.result {
    Sent(count) => Some(count)
    Received(_) => None
  }
}

///|
pub extend TransferResult with Eq::{not_equal, equal}

///|
pub extend TransferResult with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The knobs a caller sets, and the defaults RFC 1350 gives them.
pub struct ClientOptions {
  mode : Mode
  block_size : Int32
  timeout_seconds : Int32
  max_retries : Int32
  options : Array[TftpOption]
} derive(Eq, Debug)

///|
pub extend ClientOptions with Eq::{not_equal, equal}

///|
pub extend ClientOptions with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The RFC 1350 defaults: `octet`, 512-byte blocks, a 5-second timeout, and a
/// retry budget that survives a handful of lost packets without hanging.
pub fn ClientOptions::default() -> ClientOptions {
  {
    mode: Octet,
    block_size: default_block_size,
    timeout_seconds: default_timeout,
    max_retries: 6,
    options: [],
  }
}

///|
pub fn ClientOptions::mode(self : ClientOptions) -> Mode {
  self.mode
}

///|
pub fn ClientOptions::block_size(self : ClientOptions) -> Int32 {
  self.block_size
}

///|
pub fn ClientOptions::timeout_seconds(self : ClientOptions) -> Int32 {
  self.timeout_seconds
}

///|
/// How many times a packet is retransmitted before the transfer gives up.
pub fn ClientOptions::max_retries(self : ClientOptions) -> Int32 {
  self.max_retries
}

///|
/// The RFC 2347 options to put in the request.
pub fn ClientOptions::options(self : ClientOptions) -> Array[TftpOption] {
  self.options.copy()
}

///|
/// A client with a plain transfer mode, e.g. `with_mode(Netascii)`.
pub fn ClientOptions::with_mode(
  self : ClientOptions,
  mode : Mode,
) -> ClientOptions {
  { ..self, mode, }
}

///|
/// A client that asks for a specific block size (RFC 2348).
pub fn ClientOptions::with_block_size(
  self : ClientOptions,
  block_size : Int32,
) -> ClientOptions {
  { ..self, block_size, }
}

///|
/// A client that asks for a specific retransmission timeout (RFC 2349).
pub fn ClientOptions::with_timeout(
  self : ClientOptions,
  seconds : Int32,
) -> ClientOptions {
  { ..self, timeout_seconds: seconds, }
}

///|
/// A client with a different retry budget.
pub fn ClientOptions::with_max_retries(
  self : ClientOptions,
  retries : Int32,
) -> ClientOptions {
  { ..self, max_retries: retries, }
}

///|
/// A client that asks for additional RFC 2347 options.
pub fn ClientOptions::with_options(
  self : ClientOptions,
  options : Array[TftpOption],
) -> ClientOptions {
  { ..self, options, }
}

///|
/// The block size and timeout a transfer actually runs with, after the peer's
/// OACK is folded in (RFC 2347, section 4).
///
/// A peer that does not answer with an OACK leaves the request's own values in
/// place, so the state machine reads one struct either way instead of branching
/// on "did negotiation happen".
priv struct Session {
  mut block_size : Int32
  mut timeout_seconds : Int32
  mut tsize : Int32?
}

///|
/// The session a peer that answers with no OACK gets: exactly what was asked.
fn Session::plain(request : ClientOptions) -> Session {
  {
    block_size: request.block_size,
    timeout_seconds: request.timeout_seconds,
    tsize: None,
  }
}

///|
/// Reads the options an OACK accepted, falling back to the request's values.
///
/// Only the options this module implements are understood; anything else is
/// ignored, which mirrors the request side.
fn Session::from_oack(request : ClientOptions, oack : Packet) -> Session {
  let session = Session::plain(request)
  match oack.options() {
    Some(options) =>
      for option in options {
        match option.name() {
          "blksize" =>
            match parse_option_int(option.value()) {
              Some(value) => session.block_size = value
              None => ()
            }
          "timeout" =>
            match parse_option_int(option.value()) {
              Some(value) => session.timeout_seconds = value
              None => ()
            }
          "tsize" =>
            match parse_option_int(option.value()) {
              Some(value) => session.tsize = Some(value)
              None => ()
            }
          _ => ()
        }
      }
    None => ()
  }
  session
}

///|
/// The `get` half: request a file, receive DATA, acknowledge, finish on a short
/// block.
///
/// Returns the file contents with the transfer mode already undone, so a
/// `Netascii` download comes back with local line endings.
pub async fn[T : Transport] get(
  transport : T,
  remote : String,
  filename : String,
  request : ClientOptions,
) -> Result[TransferOutcome, ClientError] {
  let rrq = Packet::Rrq(
    filename,
    request.mode,
    [
      TftpOption::new("blksize", request.block_size.to_string()),
      TftpOption::new("timeout", request.timeout_seconds.to_string()),
    ] +
    request.options,
  )
  let rrq_bytes = encode(rrq)
  transport.send(rrq_bytes, remote)
  let handshake = match await_options(transport, remote, request, rrq_bytes) {
    Ok(handshake) => handshake
    Err(error) => return Err(error)
  }
  let session = handshake.session
  // An OACK is not DATA: it restarts the count, and the client owes an ACK 0
  // before the server will send block 1 (RFC 2347, section 4).
  if handshake.oack_pending {
    transport.send(encode(Packet::Ack(0)), remote)
  }
  // The first DATA a server sends is block 1.
  let mut expected : UInt16 = 1
  let mut retries = 0
  let mut out : Bytes = Bytes::new(0)
  let mut netascii : NetasciiState = Clean
  // A server that skipped the OACK sent its first DATA while we were still
  // waiting for the answer; fold it in before reading the wire again, instead
  // of dropping the first block of the file.
  let mut pending = handshake.first_data
  while true {
    let incoming = match pending {
      Some((block, payload)) => {
        pending = None
        Recv::Packet(Datagram::new(encode(Data(block, payload)), ""))
      }
      None => transport.recv(remote, timeout_to_ms(session.timeout_seconds))
    }
    match incoming {
      Recv::Timeout =>
        if retries >= request.max_retries {
          return Err(Timeout)
        } else {
          retries = retries + 1
          // A read is driven by the server retransmitting DATA, so the client
          // nudges it: repeat the request before the first block arrives, and
          // re-acknowledge the last block afterwards. Without this a single
          // lost packet would stall the transfer until the budget ran out.
          let nudge = if expected == 1 {
            rrq
          } else {
            Packet::Ack(expected - 1)
          }
          transport.send(encode(nudge), remote)
        }
      Recv::Packet(datagram) => {
        let packet = match decode(datagram.payload()) {
          Ok(packet) => packet
          Err(_) => continue // Malformed: ignore, the peer will retransmit.
        }
        match packet {
          Error(code, message) => return Err(PeerError(code, message))
          Data(block, payload) => {
            if block == expected - 1 {
              // A stale duplicate: acknowledge it again but do not deliver it
              // twice (Sorcerer's Apprentice, RFC 1350 section 4).
              transport.send(encode(Packet::Ack(block)), remote)
              continue
            }
            if !block_follows(block, expected - 1) {
              // Older than the block we hold: re-acknowledge so the peer can
              // move on, without touching the file.
              transport.send(encode(Packet::Ack(block)), remote)
              continue
            }
            expected = block + 1
            retries = 0
            transport.send(encode(Packet::Ack(block)), remote)
            let chunk = match request.mode {
              Netascii => {
                let (state, decoded) = netascii_decode(netascii, payload)
                netascii = state
                decoded
              }
              _ => payload
            }
            out = out + chunk
            // A payload shorter than the negotiated block size ends the file
            // (RFC 1350, section 1).
            if payload.length() < session.block_size {
              let tail = match request.mode {
                Netascii => netascii_decode_finish(netascii, Bytes::new(0))
                _ => Bytes::new(0)
              }
              return Ok({ result: Received(out + tail), tsize: session.tsize, })
            }
          }
          _ =>
            // An unexpected ACK/OACK/RRQ: ignore and keep waiting.
            continue
        }
      }
    }
  }
  Err(Protocol("get: unreachable"))
}

///|
/// The `put` half: request to write a file, send DATA one block at a time, wait
/// for each ACK.
///
/// Returns the number of bytes acknowledged. The data is already in memory, so
/// the caller hands the whole file in and the state machine slices it.
pub async fn[T : Transport] put(
  transport : T,
  remote : String,
  filename : String,
  data : Bytes,
  request : ClientOptions,
) -> Result[TransferOutcome, ClientError] {
  let encoded = match request.mode {
    Netascii => netascii_encode_all(data)
    _ => data
  }
  let wrq = Packet::Wrq(
    filename,
    request.mode,
    [
      TftpOption::new("blksize", request.block_size.to_string()),
      TftpOption::new("timeout", request.timeout_seconds.to_string()),
      TftpOption::new("tsize", encoded.length().to_string()),
    ] +
    request.options,
  )
  transport.send(encode(wrq), remote)
  let session = match await_write_ack(transport, remote, request) {
    Ok(session) => session
    Err(error) => return Err(error)
  }
  let blocks = split_blocks(encoded, session.block_size)
  let mut index = 0
  let mut acknowledged = 0
  while index < blocks.length() {
    let payload = blocks[index]
    let block = (index + 1).to_uint16()
    match
      send_block_with_retry(transport, remote, block, payload, session, request) {
      Ok(size) => {
        acknowledged = acknowledged + size
        index = index + 1
      }
      Err(error) => return Err(error)
    }
  }
  Ok({ result: Sent(acknowledged), tsize: session.tsize, })
}

///|
/// The first thing a server said: the accepted options, and the first DATA if
/// it skipped the OACK.
///
/// The DATA has to be handed back because `await_options` already read it off
/// the transport; dropping it would lose the first block of the file.
priv struct Handshake {
  session : Session
  first_data : (UInt16, Bytes)?
  /// Whether the handshake was an OACK that still needs its ACK 0. RFC 2347
  /// section 4: the client acknowledges an OACK with ACK 0, and only then does
  /// the server start sending DATA.
  oack_pending : Bool
}

///|
/// Waits for the first answer to a RRQ: an OACK, or the first DATA.
///
/// `request_packet` is the RRQ to repeat on a timeout, so a lost first DATA
/// makes the client re-ask instead of stalling until the budget runs out. That
/// repeat is what a real client does: for a read there is no ACK to resend yet.
async fn[T : Transport] await_options(
  transport : T,
  remote : String,
  request : ClientOptions,
  request_packet : Bytes,
) -> Result[Handshake, ClientError] {
  let mut retries = 0
  while retries <= request.max_retries {
    match transport.recv(remote, timeout_to_ms(request.timeout_seconds)) {
      Recv::Timeout => {
        retries = retries + 1
        if retries <= request.max_retries {
          transport.send(request_packet, remote)
        }
      }
      Recv::Packet(datagram) =>
        match decode(datagram.payload()) {
          Err(_) => retries = retries + 1
          Ok(packet) =>
            match packet {
              Error(code, message) => return Err(PeerError(code, message))
              Oack(_) =>
                return Ok({
                  session: Session::from_oack(request, packet),
                  first_data: None,
                  oack_pending: true,
                })
              // No OACK: the peer ignored the options and went straight to
              // RFC 1350, so the request's own values stand.
              Data(block, payload) =>
                return Ok({
                  session: Session::plain(request),
                  first_data: Some((block, payload)),
                  oack_pending: false,
                })
              _ => retries = retries + 1
            }
        }
    }
  }
  Err(Timeout)
}

///|
/// Waits for the answer to a WRQ: ACK 0, or an OACK when options were accepted.
async fn[T : Transport] await_write_ack(
  transport : T,
  remote : String,
  request : ClientOptions,
) -> Result[Session, ClientError] {
  let mut retries = 0
  while retries <= request.max_retries {
    match transport.recv(remote, timeout_to_ms(request.timeout_seconds)) {
      Recv::Timeout => retries = retries + 1
      Recv::Packet(datagram) =>
        match decode(datagram.payload()) {
          Err(_) => retries = retries + 1
          Ok(packet) =>
            match packet {
              Error(code, message) => return Err(PeerError(code, message))
              Oack(_) => return Ok(Session::from_oack(request, packet))
              Ack(block) =>
                if block == 0 {
                  return Ok(Session::plain(request))
                } else {
                  retries = retries + 1
                }
              _ => retries = retries + 1
            }
        }
    }
  }
  Err(Timeout)
}

///|
/// Sends one DATA block and waits for its ACK, retransmitting on timeout and
/// ignoring acknowledgements for earlier blocks.
///
/// Returns how many payload bytes this block carried.
async fn[T : Transport] send_block_with_retry(
  transport : T,
  remote : String,
  block : UInt16,
  payload : Bytes,
  session : Session,
  request : ClientOptions,
) -> Result[Int32, ClientError] {
  let packet = encode(Data(block, payload))
  let mut retries = 0
  while retries <= request.max_retries {
    transport.send(packet, remote)
    match transport.recv(remote, timeout_to_ms(session.timeout_seconds)) {
      Recv::Timeout => retries = retries + 1
      Recv::Packet(datagram) =>
        match decode(datagram.payload()) {
          Err(_) => retries = retries + 1
          Ok(answer) =>
            match answer {
              Error(code, message) => return Err(PeerError(code, message))
              Ack(acked) =>
                if acked == block {
                  return Ok(payload.length())
                } else if block_before(acked, block) {
                  // A delayed ACK for an earlier block: wait for ours.
                  retries = retries + 1
                } else {
                  retries = retries + 1
                }
              _ => retries = retries + 1
            }
        }
    }
  }
  Err(Timeout)
}

///|
/// Splits `data` into DATA payloads of at most `block_size` bytes.
///
/// Public because a caller that wants to show progress, or to feed the blocks
/// to a server of its own, needs the same slicing the client uses.
///
/// A file whose length is an exact multiple of the block size needs one extra,
/// empty block for the peer to see the end (RFC 1350, section 1).
pub fn split_blocks(data : Bytes, block_size : Int32) -> Array[Bytes] {
  let blocks : Array[Bytes] = []
  let size = if block_size <= 0 { default_block_size } else { block_size }
  let mut offset = 0
  while offset < data.length() {
    let end = if offset + size > data.length() {
      data.length()
    } else {
      offset + size
    }
    blocks.push(data.clamped_view(start=offset, end~).to_owned())
    offset = end
  }
  if blocks.is_empty() || data.length() % size == 0 {
    blocks.push(Bytes::new(0))
  }
  blocks
}

///|
/// The inverse of `split_blocks`, for callers that want the file back.
pub fn join_blocks(blocks : Array[Bytes]) -> Bytes {
  let mut out : Bytes = Bytes::new(0)
  for block in blocks {
    out = out + block
  }
  out
}

///|
/// Reads the decimal value an OACK carried for a known option.
///
/// The same tolerant decimal parser the request side uses, so a peer cannot
/// negotiate a value with `+` or whitespace that we would then reject.
fn parse_option_int(text : String) -> Int32? {
  if text.is_empty() {
    return None
  }
  let mut value = 0
  for char in text {
    let digit = char.to_int() - '0'.to_int()
    if digit < 0 || digit > 9 {
      return None
    }
    value = value * 10 + digit
  }
  Some(value)
}
