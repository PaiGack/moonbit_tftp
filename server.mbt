///|
/// The server half of a TFTP transfer: request intake, per-request TID
/// sessions, concurrent session management, a root-directory sandbox and the
/// ERROR semantics of RFC 1350 section 5.
///
/// The architecture rule holds here as it does for the client: sessions never
/// touch a socket. A session reads a packet or times out and writes a packet
/// or a result, so every branch — including a path-traversal attempt or a disk
/// that reports itself full — is exercised in a test without a network.
///
/// Three RFC details drive the shape of this file:
///
/// - **TID.** A request arrives on the well-known port (69), but RFC 1350
///   section 4 wants each transfer answered from a fresh port: the TID the
///   rest of the session is bound to. Anything that later arrives from another
///   address gets ERROR 5 and is *not* fed to the session.
/// - **Path safety.** A server with no authentication must not be talked into
///   reading `/etc/passwd`. `resolve_path` is the whole policy, kept as a pure
///   function so it is directly testable.
/// - **Error codes.** Every failure maps onto a specific code instead of a
///   generic one: a missing file is 1, a traversal attempt is 2, a host that
///   says it is out of space is 3, a malformed request is 4, a stranger is 5,
///   an existing file is 6, and a refused option is 8.

///|
/// One file a session may act on, and the errors that go with it.
///
/// The server only ever sees this interface, so the same sessions run against
/// the real filesystem and against an in-memory file that reports `DiskFull`
/// on purpose. That is what makes the disk-full branch — the hardest one to
/// reach on a test machine — an ordinary unit test.
pub(open) trait FileSystem {
  /// The whole file, for a read request. Its length is also the `tsize` a
  /// read announces, so there is no separate "size" operation to keep in step.
  async fn read(Self, String) -> Result[Bytes, ServerError]
  /// Writes the whole file, for a write request.
  async fn write(Self, String, Bytes) -> Result[Unit, ServerError]
  /// Whether the path names an existing file, for the WRQ's ERROR 6.
  async fn exists(Self, String) -> Bool
}

///|
/// Why a request could not be served. Each variant is a promise about what
/// goes on the wire (RFC 1350, section 5).
pub(all) enum ServerError {
  /// The session state machine observed something illegal (ERROR 4).
  IllegalOperation(String)
  /// The path leaves the served root, or names a directory (ERROR 2).
  AccessViolation(String)
  /// The host could not give us the file (ERROR 1).
  FileNotFound(String)
  /// The host could not store the file (ERROR 3).
  DiskFull(String)
  /// The file a WRQ names is already there (ERROR 6).
  FileAlreadyExists(String)
  /// A packet arrived on a TID this server has no session for (ERROR 5,
  /// RFC 1350 section 4).
  UnknownTransferId(String)
  /// Options could not be agreed on (ERROR 8, RFC 2347 section 3).
  OptionNegotiationFailed(String)
  /// The peer stopped answering (ERROR 0: the RFC defines no other code).
  Timeout
} derive(Eq, Debug)

///|
pub extend ServerError with Eq::{not_equal, equal}

///|
pub extend ServerError with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The wire error code this failure is reported with.
pub fn ServerError::error_code(self : ServerError) -> ErrorCode {
  match self {
    FileNotFound(_) => ErrorCode::FileNotFound
    AccessViolation(_) => ErrorCode::AccessViolation
    DiskFull(_) => ErrorCode::DiskFull
    IllegalOperation(_) => ErrorCode::IllegalOperation
    FileAlreadyExists(_) => ErrorCode::FileAlreadyExists
    UnknownTransferId(_) => ErrorCode::UnknownTransferId
    OptionNegotiationFailed(_) => ErrorCode::OptionNegotiationFailed
    Timeout => ErrorCode::Undefined
  }
}

///|
/// The message text of the ERROR packet.
pub fn ServerError::message(self : ServerError) -> String {
  match self {
    FileNotFound(message)
    | AccessViolation(message)
    | DiskFull(message)
    | IllegalOperation(message)
    | FileAlreadyExists(message)
    | UnknownTransferId(message)
    | OptionNegotiationFailed(message) => message
    Timeout => "timed out"
  }
}

///|
/// The ERROR packet this failure is answered with.
pub fn ServerError::to_packet(self : ServerError) -> Packet {
  Error(self.error_code(), self.message())
}

///|
/// Where a write request is allowed to put its file.
///
/// TFTP has no authentication at all, so opening a server to the whole disk is
/// never the right default: either the path is a plain name below the root, or
/// the request is refused.
pub(all) enum WritePolicy {
  /// Only publish a name that is not taken, so a client cannot overwrite what
  /// is already there (ERROR 6). The default.
  CreateOnly
  /// Replace an existing file.
  AllowOverwrite
} derive(Eq, Debug)

///|
pub extend WritePolicy with Eq::{not_equal, equal}

///|
pub extend WritePolicy with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The knobs a server owner sets, and the safe defaults.
pub struct ServerOptions {
  /// The directory every request is resolved against. Never left empty.
  root : String
  /// Whether a WRQ may replace an existing file.
  write_policy : WritePolicy
  /// How many sessions may run at once, 32 by default. A hard ceiling is what
  /// keeps a stream of requests from growing the server without bound: past it
  /// `Dispatcher::route` answers `Rejected(IllegalOperation)` (ERROR 4) and the
  /// caller refuses the request.
  max_sessions : Int32
  /// The retry budget of a session before it gives up and sends ERROR 0.
  max_retries : Int32
} derive(Eq, Debug)

///|
pub extend ServerOptions with Eq::{not_equal, equal}

///|
pub extend ServerOptions with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The safe defaults: a root of `.`, writes only create, and a session ceiling
/// that a plain server never reaches but a flood cannot pass. The ceiling is
/// the same `32` the CLI and README document, so there is one number to
/// remember rather than three that drift.
pub fn ServerOptions::default() -> ServerOptions {
  { root: ".", write_policy: CreateOnly, max_sessions: 32, max_retries: 6, }
}

///|
pub fn ServerOptions::root(self : ServerOptions) -> String {
  self.root
}

///|
pub fn ServerOptions::write_policy(self : ServerOptions) -> WritePolicy {
  self.write_policy
}

///|
pub fn ServerOptions::max_sessions(self : ServerOptions) -> Int32 {
  self.max_sessions
}

///|
/// How many times a session retransmits before it gives up.
pub fn ServerOptions::max_retries(self : ServerOptions) -> Int32 {
  self.max_retries
}

///|
/// A server rooted at `root`, the usual way to configure one.
pub fn ServerOptions::with_root(
  self : ServerOptions,
  root : String,
) -> ServerOptions {
  { ..self, root, }
}

///|
/// A server that lets a client replace an existing file.
pub fn ServerOptions::with_write_policy(
  self : ServerOptions,
  policy : WritePolicy,
) -> ServerOptions {
  { ..self, write_policy: policy, }
}

///|
/// A server with a different ceiling on concurrent sessions.
pub fn ServerOptions::with_max_sessions(
  self : ServerOptions,
  max_sessions : Int32,
) -> ServerOptions {
  { ..self, max_sessions, }
}

///|
/// A server with a different session retry budget.
pub fn ServerOptions::with_max_retries(
  self : ServerOptions,
  retries : Int32,
) -> ServerOptions {
  { ..self, max_retries: retries, }
}

// ---------------------------------------------------------------------------
// Path policy
// ---------------------------------------------------------------------------

///|
/// Resolves a client-supplied filename against `root`.
///
/// This is the whole traversal defence, so it is deliberately paranoid and
/// deliberately a pure function: the RFC puts no limit on a filename, and a
/// server that accepted `../../etc/passwd` would be a file disclosure with
/// extra steps.
///
/// The rule is structural rather than a substring search. `.` names the root,
/// `.` is a no-op segment, and *every* other segment — including `..`, which is
/// rejected outright rather than popped — must be a plain name. So
/// `docs/../secret` is refused just like `..`, not silently simplified to
/// `secret`, and no amount of `%2e%2e` helps because nothing here decodes: the
/// client's bytes are the bytes we look at.
///
/// Backslashes are refused too: on the platforms this server runs on they are
/// ordinary name characters, so a path that carries one is more likely an
/// attempt to look like a Windows escape than a real filename.
pub fn resolve_path(
  root : String,
  name : String,
) -> Result[String, ServerError] {
  if name.is_empty() {
    return Err(AccessViolation("empty filename"))
  }
  if name.contains("\\") {
    return Err(AccessViolation("backslash in filename"))
  }
  let absolute = name.has_prefix("/")
  // Whitespace control characters have no business in a filename and are a
  // habit worth refusing outright rather than trimming.
  for char in name {
    if char == '\u{00}' || char == '\n' || char == '\r' {
      return Err(AccessViolation("control character in filename"))
    }
  }
  let segments : Array[String] = []
  for segment in name.split("/") {
    if segment.is_empty() || segment == "." {
      continue
    }
    if segment == ".." {
      // Refused rather than popped: `a/../b` and `..` are told apart on
      // purpose, so a policy change never has to re-audit a `..` that was
      // quietly absorbed earlier.
      return Err(AccessViolation("path escapes the served root"))
    }
    segments.push(segment.to_owned())
  }
  let joined = segments.join("/")
  let base = root.trim_end(chars="/").to_owned()
  if joined.is_empty() {
    if absolute || base.is_empty() {
      return Ok("/")
    }
    return Ok(base)
  }
  if base.is_empty() {
    return Ok("/" + joined)
  }
  Ok(base + "/" + joined)
}

// ---------------------------------------------------------------------------
// Request intake
// ---------------------------------------------------------------------------

///|
/// What a server does with the first datagram of a session.
///
/// There is no "answer with this packet" variant on purpose. Every session's
/// first packet — including the OACK — is chosen and sent by the session
/// itself, so there is exactly one place that decides what a client is told
/// first, and a refused request keeps its ERROR on the request TID instead of
/// racing a session for it.
pub(all) enum RequestAction {
  /// An RRQ that was accepted: read the file, then send the OACK (if any) and
  /// the DATA.
  ServeFile(String)
  /// A WRQ that was accepted: send the OACK (if any) or ACK 0, then collect
  /// DATA into this path.
  ReceiveFile(String)
} derive(Eq, Debug)

///|
pub extend RequestAction with Eq::{not_equal, equal}

///|
pub extend RequestAction with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The options a server agreed to, plus the first packet that says so.
///
/// Both are `None` for a plain RFC 1350 transfer, which is exactly what a
/// server has to answer with then: the first DATA / ACK, never an empty OACK
/// (RFC 2347, section 4).
pub struct AcceptedOptions {
  options : Options?
  first_packet : Packet?
  /// The mode the request asked for. A session needs it because netascii is
  /// the one mode whose payload is not the file as stored: the read has to
  /// encode what it sends and the write has to decode what it keeps, so the
  /// request's mode has to survive negotiation.
  mode : Mode
} derive(Eq, Debug)

///|
pub extend AcceptedOptions with Eq::{not_equal, equal}

///|
pub extend AcceptedOptions with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The negotiated values, or `None` when nothing was negotiated.
pub fn AcceptedOptions::options(self : AcceptedOptions) -> Options? {
  self.options
}

///|
/// The OACK, or `None` when the transfer runs as plain RFC 1350.
pub fn AcceptedOptions::first_packet(self : AcceptedOptions) -> Packet? {
  self.first_packet
}

///|
/// The transfer mode the request asked for, `Octet` unless it said otherwise.
pub fn AcceptedOptions::mode(self : AcceptedOptions) -> Mode {
  self.mode
}

///|
/// The mode a RRQ/WRQ asked for.
///
/// `Packet::mode` answers `None` for anything that is not a request, and
/// `accept_options` only ever sees one of those; a caller that somehow gets
/// something else falls back to the RFC 1350 default rather than failing a
/// session over it.
fn request_mode(request : Packet) -> Mode {
  match request.mode() {
    Some(mode) => mode
    None => Octet
  }
}

///|
/// The bytes a read has to put on the wire for `payload`.
///
/// `Octet` — and every mode that is not netascii — sends the file as stored;
/// netascii sends its encoded form, escapes included. Kept as one function so
/// the `tsize` a RRQ announces and the DATA blocks it is sliced into are
/// computed by the same conversion and cannot drift apart.
fn wire_payload(mode : Mode, payload : Bytes) -> Bytes {
  match mode {
    Netascii => netascii_encode_all(payload)
    _ => payload
  }
}

///|
/// The size `payload` will have on the wire under `mode`.
///
/// The only bytes netascii changes are `\n` and `\r`, and each of them grows
/// from one byte to two — except when they are each other's partner: a `\r\n`
/// already is the two bytes the wire wants, so the pair costs nothing. Counting
/// that is a single pass and no allocation, which matters because a read needs
/// this number *before* it sends anything: it is the `tsize` the OACK announces.
fn wire_size(mode : Mode, payload : Bytes) -> Int32 {
  match mode {
    Netascii => {
      let mut extra = 0
      let mut i = 0
      while i < payload.length() {
        let byte = payload[i]
        if byte == b'\n' {
          // A `\n` a `\r` precedes is already half of a `\r\n` on the wire.
          if i == 0 || payload[i - 1] != b'\r' {
            extra = extra + 1
          }
        } else if byte == b'\r' {
          // A `\r` a `\n` follows likewise: the pair needs no extra byte.
          if i + 1 >= payload.length() || payload[i + 1] != b'\n' {
            extra = extra + 1
          }
        }
        i = i + 1
      }
      payload.length() + extra
    }
    _ => payload.length()
  }
}

///|
/// The block size a transfer runs with: the negotiated one, or the RFC default.
fn AcceptedOptions::block_size(self : AcceptedOptions) -> Int32 {
  match self.options {
    Some(options) => options.blksize()
    None => default_block_size
  }
}

///|
/// The retransmission timeout a transfer runs with, in seconds.
fn AcceptedOptions::timeout_seconds(self : AcceptedOptions) -> Int32 {
  match self.options {
    Some(options) => options.timeout_seconds()
    None => default_timeout
  }
}

///|
/// Decides what to do with a request, before any file is touched.
///
/// This is the server's outer state machine: parse the request, check the path
/// against the sandbox, agree on options, and only then hand back a decision.
/// `exists` lets the file-exists rule be checked without a second file
/// backend interface, which keeps the filesystem trait to "read, size, write".
pub async fn[T : FileSystem] plan_request(
  options : ServerOptions,
  files : T,
  request : Packet,
) -> Result[RequestAction, ServerError] {
  let server_value : (RequestedOption) -> Result[String?, NegotiationError] = fn(
    option,
  ) {
    // The value itself matters only to the OACK, which the session builds;
    // here we only need the *shape* to be parsable.
    ignore(option.kind())
    Ok(Some(option.request_value().to_string()))
  }
  // The option *request* is validated here, before any I/O, so a bad
  // negotiation is refused without touching a file. The answer — especially
  // `tsize` — is built later, by the session, once it knows the file size.
  match accept_options(request, server_value) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match request {
    Rrq(filename, _, _) => {
      let path = match resolve_path(options.root, filename) {
        Ok(path) => path
        Err(error) => return Err(error)
      }
      // A directory is not a file to serve, and pretending it is would leak
      // the shape of the tree; ERROR 2 is the honest answer.
      if is_directory_like(filename) {
        return Err(AccessViolation("requested path is a directory"))
      }
      // Never answered here: a RRQ's OACK carries `tsize`, the file size, and
      // only the file backend can say what that is. The session reads the file
      // and sends the OACK itself.
      Ok(ServeFile(path))
    }
    Wrq(filename, _, _) => {
      let path = match resolve_path(options.root, filename) {
        Ok(path) => path
        Err(error) => return Err(error)
      }
      if is_directory_like(filename) {
        return Err(AccessViolation("requested path is a directory"))
      }
      if options.write_policy is CreateOnly && files.exists(path) {
        return Err(FileAlreadyExists(filename))
      }
      // A WRQ's OACK needs no file size: the client already told us what it
      // will send, so the session can answer immediately.
      Ok(ReceiveFile(path))
    }
    _ => Err(IllegalOperation("expected a RRQ or a WRQ"))
  }
}

///|
/// A filename that names a directory rather than a file. A trailing slash is
/// the one form visible in the name itself; the real check is whether the
/// resolved path turns out to be a directory, which a filesystem reports as
/// `AccessViolation`.
fn is_directory_like(name : String) -> Bool {
  name.has_suffix("/")
}

///|
/// Folds the peer's options into the ones the server is willing to answer.
///
/// `server_value` is the per-option callback `resolve_options` expects. The
/// server refuses nothing here: what it *can* answer, `resolve_options`
/// bounds-check, and an option whose value it cannot produce becomes ERROR 8
/// there rather than being silently dropped (RFC 2347, section 3).
fn accept_options(
  request : Packet,
  server_value : (RequestedOption) -> Result[String?, NegotiationError],
) -> Result[AcceptedOptions, ServerError] {
  let requested = match parse_options(request) {
    Ok(requested) => requested
    Err(error) => return Err(OptionNegotiationFailed(error_description(error)))
  }
  if requested.is_empty() {
    return Ok({
      options: None,
      first_packet: None,
      mode: request_mode(request),
    })
  }
  let options = match resolve_options(requested, server_value) {
    Ok(options) => options
    Err(error) => return Err(OptionNegotiationFailed(error_description(error)))
  }
  Ok({
    options: Some(options),
    first_packet: options.oack_packet(),
    mode: request_mode(request),
  })
}

///|
/// The text of a refused option, so the ERROR 8 packet says what was wrong.
fn error_description(error : NegotiationError) -> String {
  match error {
    BadOption(name, value) => "\{name}=\{value}"
    BadTsize(value) => "tsize=\{value}"
  }
}

// ---------------------------------------------------------------------------
// Read session
// ---------------------------------------------------------------------------

///|
/// The server half of a read: send DATA, wait for ACK, finish on the last one.
///
/// `first_packet` is the OACK a peer with options gets instead of DATA 1, and
/// it is retransmitted like any other packet, because until the client
/// acknowledges the options nothing about the transfer is settled.
///
/// The state machine is the client's mirror image. The two asymmetries worth
/// naming: the server hears *only* ACKs, so a duplicate ACK for an already
/// acknowledged block is answered by repeating the current DATA (the peer
/// missed it), and the transfer ends when *our* DATA was shorter than the
/// block size, not when the ACK arrives.
pub async fn[T : Transport] serve_read(
  transport : T,
  peer : String,
  payload : Bytes,
  accepted : AcceptedOptions,
  options : ServerOptions,
) -> Result[Int32, ServerError] {
  let block_size = accepted.block_size()
  let timeout = timeout_to_ms(accepted.timeout_seconds())
  // netascii is the one mode in which the file is not the bytes it is stored
  // as: every `\n` becomes `\r\n` and every `\r` becomes `\r\0`, so the wire
  // form is a different length and has to be built before it is sliced. It is
  // sliced *after* the conversion, not before, because a block that starts with
  // an escaped line ending would otherwise be one byte longer than the
  // negotiated `blksize`. The whole stream is encoded in one pass for the same
  // reason the client's `put` does it that way: a held-back CR is resolved
  // inside `netascii_encode_all`, and a `\r\n` split across two blocks is
  // something the peer's decoder is required to reassemble anyway.
  let blocks = split_blocks(wire_payload(accepted.mode(), payload), block_size)
  let mut index = 0
  let mut retries = 0
  let mut packet = match accepted.first_packet() {
    Some(packet) => packet
    None => Data(1, blocks[0])
  }
  // Whether the packet we are waiting on is the OACK (index -1) or DATA n.
  let mut is_oack = accepted.first_packet() is Some(_)
  while true {
    transport.send(encode(packet), peer)
    match transport.recv(peer, timeout) {
      Recv::Timeout =>
        if retries < options.max_retries {
          retries = retries + 1
        } else {
          // RFC 1350 has no "timed out" code, and code 0 exists exactly for
          // situations the RFC does not define, so that is what goes out.
          transport.send(encode(timed_out_packet()), peer)
          return Err(peer_timeout)
        }
      Recv::Packet(datagram) =>
        // Only an ACK moves a read forward. Anything else is either the
        // peer's ERROR, which ends us, or noise we keep waiting through.
        match decode(datagram.payload()) {
          Err(_) => retries = retries + 1
          Ok(Error(code, message)) => return Err(from_peer_error(code, message))
          Ok(Ack(acked)) => {
            if is_oack {
              if acked != 0 {
                retries = retries + 1
                continue
              }
              is_oack = false
              index = 0
              packet = Data(1, blocks[0])
              retries = 0
              continue
            }
            let sent = (index + 1).to_uint16()
            if acked == sent {
              retries = 0
              if blocks[index].length() < block_size {
                // A short block is the end of the file (RFC 1350, section 1):
                // the DATA we just sent was the last one and its ACK arrived.
                // The count is the wire size: it is what was actually sent,
                // and the `tsize` the OACK announced is the same number.
                let mut total = 0
                for i = 0; i <= index; i = i + 1 {
                  total = total + blocks[i].length()
                }
                return Ok(total)
              }
              index = index + 1
              packet = Data((index + 1).to_uint16(), blocks[index])
            } else if acked == index.to_uint16() {
              // Our DATA n+1 went missing: the peer re-acknowledged n, so send
              // n+1 again instead of waiting out the timeout.
              retries = 0
            } else {
              // An ACK for a block we never sent. Nothing to do but wait.
              retries = retries + 1
            }
          }
          Ok(_) => retries = retries + 1
        }
    }
  }
  Err(IllegalOperation("serve_read: unreachable"))
}

// ---------------------------------------------------------------------------
// Write session
// ---------------------------------------------------------------------------

///|
/// The server half of a write: acknowledge DATA, collect it, answer the short
/// block that ends the file.
///
/// The duplicate rule is the one that makes or breaks this loop. A DATA that
/// repeats the block we already hold is a retransmission of an ACK we lost, so
/// it must be re-acknowledged and *not* appended again. `block.mbt`'s
/// half-circle comparison is what tells "duplicate" from "the peer moved two
/// blocks ahead", so the check survives the u16 wrap.
pub async fn[T : Transport] serve_write(
  transport : T,
  peer : String,
  accepted : AcceptedOptions,
  options : ServerOptions,
) -> Result[Bytes, ServerError] {
  let block_size = accepted.block_size()
  let timeout = timeout_to_ms(accepted.timeout_seconds())
  let mut out : Bytes = Bytes::new(0)
  let mut expected : UInt16 = 1
  let mut retries = 0
  // The mirror of `serve_read`: a netascii write receives the encoded form and
  // has to store the local one, so each block is decoded as it is accepted and
  // a CR the decoder is still holding at the end of the last block is a real
  // lone CR (RFC 1350, section 2).
  let mut netascii : NetasciiState = Clean
  // With options, the OACK is what the peer acknowledges with DATA 1; without
  // them the RFC 1350 handshake is ACK 0.
  let mut packet = match accepted.first_packet() {
    Some(packet) => packet
    None => Ack(0)
  }
  while true {
    transport.send(encode(packet), peer)
    match transport.recv(peer, timeout) {
      Recv::Timeout =>
        if retries < options.max_retries {
          retries = retries + 1
        } else {
          // RFC 1350 has no "timed out" code, and code 0 exists exactly for
          // situations the RFC does not define, so that is what goes out.
          transport.send(encode(timed_out_packet()), peer)
          return Err(peer_timeout)
        }
      Recv::Packet(datagram) =>
        match decode(datagram.payload()) {
          Err(_) => retries = retries + 1
          Ok(Error(code, message)) => return Err(from_peer_error(code, message))
          Ok(Data(block, chunk)) =>
            if block == expected {
              retries = 0
              let (state, stored) = match accepted.mode() {
                Netascii => netascii_decode(netascii, chunk)
                _ => (Clean, chunk)
              }
              netascii = state
              out = out + stored
              expected = expected + 1
              packet = Ack(block)
              if chunk.length() < block_size {
                // The peer sent a short block: that was the file. Its ACK is
                // owed before we return, otherwise a client that is waiting on
                // it retransmits into a session that has already gone.
                transport.send(encode(Ack(block)), peer)
                let stored = match accepted.mode() {
                  Netascii => netascii_decode_finish(netascii, out)
                  _ => out
                }
                return Ok(stored)
              }
            } else if block_before(block, expected) {
              // A duplicate we already have: answer it again, keep the bytes
              // we hold (Sorcerer's Apprentice, RFC 1350 section 4).
              packet = Ack(block)
              retries = 0
            } else {
              // Ahead of what we can accept: an ACK for a block we never took
              // is the honest answer, and the peer will retransmit.
              packet = Ack(expected - 1)
              retries = retries + 1
            }
          Ok(_) => retries = retries + 1
        }
    }
  }
  Err(IllegalOperation("serve_write: unreachable"))
}

///|
/// The error a peer's own ERROR packet becomes, so a session that is told
/// "I cannot" reports the same code back instead of inventing one. `fn` is
/// private, so this is the exported spelling of the same mapping.
pub fn peer_error(code : ErrorCode, message : String) -> ServerError {
  from_peer_error(code, message)
}

///|
/// The error a peer's own ERROR packet becomes, so a session that is told
/// "I cannot" reports the same code back instead of inventing one.
fn from_peer_error(code : ErrorCode, message : String) -> ServerError {
  match code {
    FileNotFound => FileNotFound(message)
    AccessViolation => AccessViolation(message)
    DiskFull => DiskFull(message)
    IllegalOperation => IllegalOperation(message)
    FileAlreadyExists => FileAlreadyExists(message)
    UnknownTransferId => UnknownTransferId(message)
    OptionNegotiationFailed => OptionNegotiationFailed(message)
    _ => IllegalOperation("peer error: \{message}")
  }
}

///|
/// The give-up a session reports when the peer stopped answering.
///
/// Named rather than spelled inline because `Timeout` on its own is ambiguous
/// with the client's `ClientError::Timeout` and `options.mbt`'s
/// `OptionKind::Timeout`, and a bare `Err(Timeout)` would not say whose.
let peer_timeout : ServerError = ServerError::Timeout

// ---------------------------------------------------------------------------
// Sessions and dispatch
// ---------------------------------------------------------------------------

///|
/// How a session ended, for logs and for tests that want to assert it.
pub(all) enum SessionOutcome {
  /// A read finished; the count is the bytes sent.
  Read(Int32)
  /// A write finished; the count is the bytes stored.
  Written(Int32)
  /// The session ended with an ERROR packet; the variant says why.
  Failed(ServerError)
} derive(Eq, Debug)

///|
pub extend SessionOutcome with Eq::{not_equal, equal}

///|
pub extend SessionOutcome with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The `Int32` an outcome stands for, or `-1` for a failure.
pub fn SessionOutcome::bytes(self : SessionOutcome) -> Int32 {
  match self {
    Read(count) | Written(count) => count
    Failed(_) => -1
  }
}

///|
/// The failure an outcome carries, or `None` when the session succeeded.
pub fn SessionOutcome::error(self : SessionOutcome) -> ServerError? {
  match self {
    Failed(error) => Some(error)
    _ => None
  }
}

///|
/// Takes one step of a write session, from the caller's side of the wire.
///
/// A write session cannot be driven like a read one *from the session's own
/// task*: the first packet (ACK 0, or the OACK) has to be on its way before
/// the peer sends DATA, so whoever owns the socket sends that packet itself
/// and then steps this function once per expected datagram. `serve` does
/// exactly that internally; this is the same loop, exposed.
///
/// This is the shape a socket server wants, and the shape tests want too: the
/// first packet of a write session (ACK 0 / the OACK) cannot be sent inside
/// this call, because the task that owns the socket has to send it *before*
/// the peer's DATA is read. Nothing here sends anything unprompted, so the
/// caller stays in control of when the wire is touched.
///
/// `acknowledged` is the block the caller last acknowledged, and `collected`
/// is the bytes gathered so far; both come back in the outcome, and the caller
/// threads them into the next call. The block size is the RFC default here:
/// this is the plain RFC 1350 loop, where a socket server would have
/// negotiated one before the first packet.
///
/// Returns `(finished, outcome)`; `outcome` is only meaningful once `finished`
/// is true.
pub async fn[U : Transport, T] TransferSession::step_write(
  self : TransferSession[U, T],
  acknowledged : UInt16,
  collected : Bytes,
  max_retries : Int32,
) -> (Bool, SessionOutcome) {
  let timeout = timeout_to_ms(default_timeout)
  let next = acknowledged + 1
  match self.transport.recv(self.peer, timeout) {
    Recv::Timeout =>
      if max_retries <= 0 {
        (true, Failed(ServerError::Timeout))
      } else {
        // A nudge: repeat the last ACK, which is what a stalled write needs.
        self.transport.send(encode(Ack(acknowledged)), self.peer)
        (false, Written(collected.length()))
      }
    Recv::Packet(datagram) =>
      match decode(datagram.payload()) {
        Err(_) => (false, Written(collected.length()))
        Ok(Error(code, message)) =>
          (true, Failed(from_peer_error(code, message)))
        Ok(Data(block, chunk)) =>
          if block == next {
            // The block we were waiting for. A short one ends the file.
            let collected = collected + chunk
            self.transport.send(encode(Ack(block)), self.peer)
            let finished = chunk.length() < default_block_size
            (finished, Written(collected.length()))
          } else if block_before(block, next) {
            // Already have it: re-acknowledge, keep the bytes we hold
            // (Sorcerer's Apprentice, RFC 1350 section 4).
            self.transport.send(encode(Ack(block)), self.peer)
            (false, Written(collected.length()))
          } else {
            self.transport.send(encode(Ack(acknowledged)), self.peer)
            (false, Written(collected.length()))
          }
        Ok(_) => (false, Written(collected.length()))
      }
  }
}

///|
/// One TFTP session on its own TID, driven by the transport it was handed.
///
/// A session owns exactly one transfer and stops talking the moment it is
/// done. `peer` is the client's address, and the transport is already bound to
/// the session's TID, which is why nothing below has to think about ports.
pub struct TransferSession[U, T] {
  transport : U
  files : T
  peer : String
  options : ServerOptions
}

///|
/// A session that reads one file, writes one file, or gives up with an ERROR.
pub fn[U, T] TransferSession::new(
  transport : U,
  files : T,
  peer : String,
  options : ServerOptions,
) -> TransferSession[U, T] {
  { transport, files, peer, options, }
}

///|
/// Serves one request on this session and returns how it went.
///
/// Everything that can be decided without I/O — the path, the options, the
/// file-exists rule — is decided first, so a refused request costs exactly one
/// ERROR packet and never opens a file.
pub async fn[U : Transport, T : FileSystem] TransferSession::serve(
  self : TransferSession[U, T],
  request : Packet,
) -> SessionOutcome {
  let action = match plan_request(self.options, self.files, request) {
    Ok(action) => action
    Err(error) => {
      let packet = error.to_packet()
      self.transport.send(encode(packet), self.peer)
      return Failed(error)
    }
  }
  match action {
    ServeFile(path) => {
      let payload = match self.files.read(path) {
        Ok(payload) => payload
        Err(error) => return self.fail(error)
      }
      let wire_size = wire_size(request_mode(request), payload)
      // The `tsize` answer is the size the wire will carry, which only becomes
      // known here, so the OACK a RRQ carries is rebuilt once the file has
      // been read — and, for a netascii read, once it has been encoded.
      let accepted = match accepted_read(request, wire_size) {
        Ok(accepted) => accepted
        Err(error) => return self.fail(error)
      }
      match
        serve_read(self.transport, self.peer, payload, accepted, self.options) {
        Ok(sent) => Read(sent)
        Err(error) => Failed(error)
      }
    }
    ReceiveFile(path) => {
      let accepted = match accepted_write(request) {
        Ok(accepted) => accepted
        Err(error) => return self.fail(error)
      }
      let payload = match
        serve_write(self.transport, self.peer, accepted, self.options) {
        Ok(payload) => payload
        Err(error) => return self.fail(error)
      }
      match self.files.write(path, payload) {
        Ok(_) => Written(payload.length())
        Err(error) => self.fail(error)
      }
    }
  }
}

///|
/// Sends the ERROR a failed session owes the peer, and reports it.
///
/// A transport that cannot take the ERROR is not worth failing the session
/// over: the session is already over, and the outcome is what the caller acts
/// on.
async fn[U : Transport, T] TransferSession::fail(
  self : TransferSession[U, T],
  error : ServerError,
) -> SessionOutcome {
  let packet = error.to_packet()
  self.transport.send(encode(packet), self.peer)
  Failed(error)
}

///|
/// Re-runs option negotiation for a RRQ once the file size is known.
///
/// A read request's `tsize` is a placeholder: the client says 0 because only
/// the server can know the size, so the value has to be supplied here and the
/// OACK rebuilt with it (RFC 2349, section 4).
///
/// `size` is the *encoded* size, not the size on disk: a netascii read
/// announces the number of bytes it will put on the wire, and that is the
/// number RFC 2349's `tsize` is about.
fn accepted_read(
  request : Packet,
  size : Int32,
) -> Result[AcceptedOptions, ServerError] {
  accept_options(request, fn(option) {
    match option.kind() {
      Tsize => Ok(Some(size.to_string()))
      _ => Ok(Some(option.request_value().to_string()))
    }
  })
}

///|
/// Option negotiation for a WRQ, where every answer is already in the request.
fn accepted_write(request : Packet) -> Result[AcceptedOptions, ServerError] {
  accept_options(request, fn(option) {
    Ok(Some(option.request_value().to_string()))
  })
}

///|
/// What a dispatcher decided to do with a datagram that arrived on the
/// well-known port.
pub(all) enum Dispatch {
  /// The datagram started a new session addressed to `tid`.
  Started(String)
  /// The datagram was refused, and `error` says which ERROR packet is owed
  /// back on `tid`.
  ///
  /// An ERROR is not bound to a TID like the rest of a transfer: the RFC asks
  /// for it to come from a fresh port too, but the packet has to win the race
  /// with the new session, so it is sent here rather than from the session.
  ///
  /// The reason travels with the decision instead of being re-derived by the
  /// caller, because there are three distinct reasons and the RFC gives each
  /// its own code: a packet that is not a request is a client on the wrong TID
  /// (ERROR 5), a request beyond the session ceiling is a server that is
  /// momentarily full (ERROR 4), and a datagram that does not decode at all is
  /// a malformed request (ERROR 4). Existing sessions are untouched either way.
  Rejected(tid~ : String, error~ : ServerError)
  /// Neither: reserved for a decision the dispatcher never makes. Every
  /// datagram it receives is either a session or a refusal, so a caller that
  /// matches on this variant is matching on a case that cannot arrive.
  Ignored
} derive(Eq, Debug)

///|
pub extend Dispatch with Eq::{not_equal, equal}

///|
pub extend Dispatch with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The TID a request is answered from (RFC 1350, section 4).
///
/// The RFC only says "a new TID", not how to pick one, so this derives it from
/// the peer's address and a counter: deterministic, so a test can assert it,
/// and distinct per request, which is the property that matters. A real socket
/// backend overrides this with whatever port its ephemeral bind picked; the
/// interface is the same either way.
pub trait TidAllocator {
  /// A fresh TID for a request that arrived from `peer`.
  fn allocate(Self, peer : String) -> String
}

///|
/// The default allocator: the peer's address with a monotonically increasing
/// port, so scripts and tests see a stable answer.
pub struct CounterTid {
  mut next_port : Int32
} derive(Debug)

///|
pub extend CounterTid with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// An allocator that starts handing out `base_port`, `base_port + 1`, ...
pub fn CounterTid::new(base_port : Int32) -> CounterTid {
  { next_port: base_port, }
}

///|
pub extend CounterTid with TidAllocator::{allocate}

///|
pub impl TidAllocator for CounterTid with fn allocate(self, peer) {
  // Strip only the *last* colon-separated field, and only when there are no
  // brackets: those two rules together are what keep `[::1]:1000` an address
  // and hand back `[::1]` rather than a mangled `[::1]:1000`.
  let host = if peer.has_prefix("[") {
    match peer.find("]:") {
      Some(index) => peer[:index + 1].to_owned()
      None => peer
    }
  } else {
    match peer.find(":") {
      Some(index) => peer[:index].to_owned()
      None => peer
    }
  }
  let port = self.next_port
  self.next_port = self.next_port + 1
  "\{host}:\{port}"
}

///|
/// The rule a dispatcher applies to the datagrams arriving on port 69.
///
/// Kept separate from any socket so the TID rules can be tested directly: a
/// session is started once per request, and anything that is not a RRQ/WRQ
/// from the initial TID is either answered with ERROR 5 or ignored.
pub struct Dispatcher[A] {
  allocator : A
  /// Sessions started so far, lifetime total.
  mut started : Int32
  /// Sessions currently running, which is what the ceiling is compared against:
  /// a `started`-only count would lock the server out after the first N
  /// transfers instead of bounding concurrency.
  mut active : Int32
  max_sessions : Int32
} derive(Debug)

///|
pub extend Dispatcher with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// A dispatcher that hands out TIDs through `allocator` and starts at most
/// `max_sessions` sessions.
pub fn[A] Dispatcher::new(allocator : A, max_sessions : Int32) -> Dispatcher[A] {
  { allocator, started: 0, active: 0, max_sessions, }
}

///|
/// How many sessions this dispatcher has started.
pub fn[A] Dispatcher::started(self : Dispatcher[A]) -> Int32 {
  self.started
}

///|
/// How many sessions are running right now.
pub fn[A] Dispatcher::active(self : Dispatcher[A]) -> Int32 {
  self.active
}

///|
/// Reports a session as over, releasing its slot.
///
/// The ceiling is on concurrent sessions, so it only means anything if a
/// finished session gives its slot back; without this the dispatcher would
/// refuse every request after the first `max_sessions` transfers.
pub fn[A] Dispatcher::release(self : Dispatcher[A]) -> Unit {
  if self.active > 0 {
    self.active = self.active - 1
  }
}

///|
/// Decides what one datagram arriving on the request port means.
///
/// A request starts a session; a DATA/ACK/ERROR that got here instead of to a
/// session is a client using the wrong TID, which RFC 1350 section 4 answers
/// with ERROR 5.
///
/// A datagram that does not decode is answered with ERROR 4 rather than
/// dropped: RFC 1350 section 5 gives code 4 to "this request is not one I can
/// take right now", and a body that cannot be parsed is exactly that. Silence
/// would leave the peer retransmitting until its budget is spent, which is the
/// failure mode the ERROR packet exists to prevent.
///
/// A request that arrives once `max_sessions` are already running is refused
/// rather than started: the ceiling is the whole point of the field, and a
/// session that is silently dropped leaves the client retransmitting into the
/// void. The refusal is an ERROR 4, the RFC's one code for "not right now".
pub fn[A : TidAllocator] Dispatcher::route(
  self : Dispatcher[A],
  datagram : Datagram,
) -> Dispatch {
  match decode(datagram.payload()) {
    Err(reason) =>
      Rejected(
        tid=self.allocator.allocate(datagram.peer()),
        error=IllegalOperation(
          "malformed request: \{decode_error_text(reason)}",
        ),
      )
    Ok(packet) =>
      match packet {
        Rrq(_, _, _) | Wrq(_, _, _) => {
          let tid = self.allocator.allocate(datagram.peer())
          if self.active >= self.max_sessions {
            // Refuse the new session, but leave the running ones alone: the
            // ceiling bounds concurrency, it does not cancel work in flight.
            Rejected(
              tid~,
              error=IllegalOperation(
                "too many concurrent sessions (limit \{self.max_sessions})",
              ),
            )
          } else {
            self.started = self.started + 1
            self.active = self.active + 1
            Started(tid)
          }
        }
        // A DATA / ACK / OACK / ERROR that reached the request port is a
        // client using the wrong TID, whether it is a stale ACK from a session
        // that ended or a stray packet that never had one.
        _ =>
          Rejected(
            tid=self.allocator.allocate(datagram.peer()),
            error=UnknownTransferId("unknown transfer id"),
          )
      }
  }
}

// ---------------------------------------------------------------------------
// Errors as packets
// ---------------------------------------------------------------------------

///|
/// The packet a session sends when the peer stopped answering.
///
/// A thin alias for `to_error_packet(peer_timeout)`, kept because the call
/// site reads better saying what happened than naming the variable.
pub fn timed_out_packet() -> Packet {
  to_error_packet(peer_timeout)
}

///|
/// Turns a `ServerError` into the packet the peer is owed.
pub fn to_error_packet(error : ServerError) -> Packet {
  error.to_packet()
}

///|
/// The phrase a `DecodeError` becomes in an ERROR 4's message.
///
/// Spelled out here rather than reusing the library's own error type in the
/// message: the message is a human-readable string on the wire, and naming the
/// internal variant would only help someone reading the source of both ends.
fn decode_error_text(reason : DecodeError) -> String {
  match reason {
    Truncated => "packet too short"
    UnknownOpcode(code) => "unknown opcode \{code}"
    MissingTerminator => "unterminated field"
    Unsupported(value) => "unsupported mode \{value}"
  }
}
