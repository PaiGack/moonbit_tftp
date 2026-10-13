///|
/// TFTP option negotiation (RFC 2347) with the three options this module
/// implements: `blksize` (RFC 2348), `timeout` and `tsize` (RFC 2349).
///
/// Like the packet layer, everything here is a pure function: parsing,
/// validation and OACK generation never touch a socket, so M3's client and
/// M4's server can be tested offline.
///
/// A server answers a request that carries options in two steps: `parse_options`
/// says what the client asked for, `resolve_options` folds the server's own
/// values in and yields the set both peers will use.
///
/// ```text
/// match parse_options(request) {
///   Ok(requested) =>
///     match resolve_options(requested, server_value) {
///       Ok(options) => options.oack_packet()  // None: answer with DATA / ACK
///       Err(reason) => Some(negotiation_error_packet(reason))  // ERROR code 8
///     }
///   Err(reason) => Some(negotiation_error_packet(reason))
/// }
/// ```
///
/// `server_value` is where a server looks at its file: `Some(text)` for the
/// `blksize` / `timeout` / `tsize` it is willing to answer with, or `Ok(None)`
/// to refuse the option (RFC 2347 section 3 turns that into ERROR 8).

///|
/// The option names RFC 1350's extensions define.
///
/// An unknown name is not a failure: a peer may ask for options this module
/// does not implement, and RFC 2347 section 2 says to ignore those.
pub(all) enum OptionKind {
  Blksize // RFC 2348: 8..65464 bytes
  Timeout // RFC 2349: 1..255 seconds
  Tsize // RFC 2349: file size in bytes
} derive(Eq, Debug)

///|
pub extend OptionKind with Eq::{not_equal, equal}

///|
pub extend OptionKind with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The lowercase option name as spelled on the wire.
fn OptionKind::name(self : OptionKind) -> String {
  match self {
    Blksize => "blksize"
    Timeout => "timeout"
    Tsize => "tsize"
  }
}

///|
fn option_kind_of(name : String) -> OptionKind? {
  match name {
    "blksize" => Some(Blksize)
    "timeout" => Some(Timeout)
    "tsize" => Some(Tsize)
    _ => None
  }
}

///|
/// Smallest `blksize` a peer may ask for (RFC 2348, section 3).
pub let min_block_size : Int32 = 8

///|
/// Largest `blksize` a peer may ask for.
///
/// A DATA payload has to fit a u16 block number plus a 4-byte header, so the
/// ceiling is 65535 - 4 = 65464, not 65535 (RFC 2348, section 3).
pub let max_block_size : Int32 = 65464

///|
/// Largest `tsize` a peer may announce, in bytes.
///
/// RFC 2349 puts no ceiling on `tsize`: it is a whole file size, not a packet
/// payload, so a value far past `max_block_size` is perfectly ordinary. This
/// bound is only the `Int32` arithmetic of this implementation, and it exists
/// so every accepted size has a definite maximum.
pub let max_tsize : Int32 = 2147483647

///|
/// Smallest `timeout` a peer may ask for, in seconds (RFC 2349, section 3).
pub let min_timeout : Int32 = 1

///|
/// Largest `timeout` a peer may ask for, in seconds (RFC 2349, section 3).
pub let max_timeout : Int32 = 255

///|
/// The retransmission timeout a transfer runs with when nobody negotiates one.
/// The RFC names no default; this is the value RFC 2349 was written against
/// and what most implementations pick.
pub let default_timeout : Int32 = 5

///|
/// Parses the decimal text of a non-negative integer.
///
/// The RFCs spell option values as plain decimal ASCII, so `+1`, `-1`, ` 1`
/// and the empty string are rejected instead of being quietly accepted by a
/// general purpose integer parser.
fn parse_decimal(text : String) -> Int32? {
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

///|
/// The decimal text of a whole number, i.e. what goes into an OACK value.
fn decimal_text(value : Int32) -> String {
  if value == 0 {
    return "0"
  }
  let digits : Array[Char] = []
  let mut rest = value
  while rest > 0 {
    digits.push(('0'.to_int() + rest % 10).unsafe_to_char())
    rest = rest / 10
  }
  digits.rev_in_place()
  String::from_array(digits)
}

///|
/// A syntactically valid `Option\0Value\0` pair of a RRQ/WRQ.
pub struct RequestedOption {
  kind : OptionKind
  request_value : Int32
} derive(Eq, Debug)

///|
pub extend RequestedOption with Eq::{not_equal, equal}

///|
pub extend RequestedOption with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn RequestedOption::new(
  kind : OptionKind,
  request_value : Int32,
) -> RequestedOption {
  { kind, request_value, }
}

///|
/// Which option the peer asked for.
pub fn RequestedOption::kind(self : RequestedOption) -> OptionKind {
  self.kind
}

///|
/// The numeric value the peer sent for it.
pub fn RequestedOption::request_value(self : RequestedOption) -> Int32 {
  self.request_value
}

///|
/// The options a request asked for, in request order.
///
/// `tsize` is the odd one out: a read request states the placeholder 0 because
/// only the server knows the file size, while a write request already carries
/// the size it will send. `tsize_hint` is therefore the number a server should
/// echo, or `None` when it first has to look at its file.
pub struct RequestedOptions {
  options : Array[RequestedOption]
  tsize_hint : Int32?
} derive(Eq, Debug)

///|
pub extend RequestedOptions with Eq::{not_equal, equal}

///|
pub extend RequestedOptions with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The accepted options, in request order.
pub fn RequestedOptions::options(
  self : RequestedOptions,
) -> Array[RequestedOption] {
  self.options.copy()
}

///|
/// The `tsize` the client already told us, if it told us anything useful.
pub fn RequestedOptions::tsize_hint(self : RequestedOptions) -> Int32? {
  self.tsize_hint
}

///|
/// Whether the request asked for anything at all. `false` means the transfer
/// runs exactly as plain RFC 1350: no OACK, no `tsize`.
pub fn RequestedOptions::is_empty(self : RequestedOptions) -> Bool {
  self.options.is_empty()
}

///|
/// Parses the `Option\0Value\0` sequence of a RRQ/WRQ.
///
/// RFC 2347 section 2 makes a server ignore options it cannot honor, so an
/// unknown name or an out-of-range value is dropped while the rest of the
/// request still counts: no failure, just fewer options in the result. The one
/// fatal case is `tsize` (RFC 2349, section 4), whose request side is a *shape*
/// rather than a bound: a read request states the placeholder 0, and anything
/// else means the peer expects us to accept a size that is not a request. That
/// is the `Err` a server turns into ERROR 8.
///
/// `tsize` is a whole file size, so unlike `blksize` it is *not* bounded by the
/// block-size ceiling the other options share: a 100 MB firmware image carries
/// a `tsize` far past any single packet, and refusing it would break exactly
/// the transfers the option exists for. `max_tsize` is the only ceiling, and it
/// is `Int32` arithmetic rather than anything the RFC asks for.
///
/// Note that `parse_decimal` does not check overflow, so a decimal wider than
/// `Int32` wraps around before `max_tsize` ever sees it; the wrapped value is
/// what gets kept. Such a request is outside the range the protocol cares
/// about, so it is not worth a special case.
pub fn parse_options(
  request : Packet,
) -> Result[RequestedOptions, NegotiationError] {
  let raw = match request {
    Rrq(_, _, options) | Wrq(_, _, options) => options
    _ => return Ok({ options: [], tsize_hint: None, })
  }
  let is_read = request is Rrq(_, _, _)
  let accepted : Array[RequestedOption] = []
  let mut tsize_hint : Int32? = None
  for option in raw {
    let kind = match option_kind_of(option.name()) {
      Some(kind) => kind
      None => continue // RFC 2347 §2: unimplemented option, ignore it.
    }
    if accepted.any(seen => seen.kind() == kind) {
      // RFC 2347 gives a repeated option no meaning. Keeping the first makes
      // the result deterministic instead of last-one-wins by accident.
      continue
    }
    let value = match parse_decimal(option.value()) {
      Some(value) => value
      None => continue // Malformed value: drop the option, keep its peers.
    }
    match kind {
      Blksize =>
        if value >= min_block_size && value <= max_block_size {
          accepted.push(RequestedOption::new(kind, value))
        }
      Timeout =>
        if value >= min_timeout && value <= max_timeout {
          accepted.push(RequestedOption::new(kind, value))
        }
      Tsize =>
        // Only the shape is checked, plus the Int32 arithmetic ceiling; never
        // `max_block_size`, because the value is a file size unrelated to what
        // one packet can hold.
        if value > max_tsize {
          continue
        } else if is_read {
          if value == 0 {
            accepted.push(RequestedOption::new(kind, 0))
          } else {
            return Err(BadTsize(decimal_text(value)))
          }
        } else if value == 0 {
          return Err(BadTsize("0"))
        } else {
          tsize_hint = Some(value)
          accepted.push(RequestedOption::new(kind, value))
        }
    }
  }
  Ok({ options: accepted, tsize_hint, })
}

///|
/// A validated option set, ready to be echoed in an OACK.
///
/// Options nobody negotiated keep their defaults, so a transfer just reads
/// `blksize()` and `timeout_seconds()` without branching on "did the peer ask".
pub struct Options {
  blksize : Int32
  timeout_seconds : Int32
  tsize : Int32?
  oack_values : Array[(String, String)]
} derive(Eq, Debug)

///|
pub extend Options with Eq::{not_equal, equal}

///|
pub extend Options with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The RFC 1350 defaults: a plain 512-byte, no-options transfer.
pub fn Options::default() -> Options {
  {
    blksize: 512,
    timeout_seconds: default_timeout,
    tsize: None,
    oack_values: [],
  }
}

///|
/// The block size both peers agreed on, in bytes.
pub fn Options::blksize(self : Options) -> Int32 {
  self.blksize
}

///|
/// The retransmission timeout both peers agreed on, in seconds.
pub fn Options::timeout_seconds(self : Options) -> Int32 {
  self.timeout_seconds
}

///|
/// The transfer size the server announced, if one was negotiated. A read
/// request answers with the real file size, a write request with what the
/// client claimed (RFC 2349, section 4).
pub fn Options::tsize(self : Options) -> Int32? {
  self.tsize
}

///|
/// Whether anything was negotiated at all: `false` means plain RFC 1350.
pub fn Options::is_empty(self : Options) -> Bool {
  self.oack_values.is_empty()
}

///|
/// The `name`/`value` pairs to echo in an OACK, in request order.
pub fn Options::oack_values(self : Options) -> Array[(String, String)] {
  self.oack_values.copy()
}

///|
/// The OACK (opcode 6) that accepts these options (RFC 2347, section 4).
///
/// `None` when nothing was negotiated: a server that accepts no option must
/// answer with the first DATA / ACK, never with an empty OACK.
pub fn Options::oack_packet(self : Options) -> Packet? {
  if self.is_empty() {
    None
  } else {
    Some(Oack(self.oack_values.map(pair => TftpOption::new(pair.0, pair.1))))
  }
}

///|
/// Why an option set could not be accepted.
///
/// Every variant maps to ERROR code 8 on the wire (RFC 2347, section 3), but
/// they stay distinct so logs and tests can tell the cases apart.
pub(all) enum NegotiationError {
  /// A value this module cannot accept: not a decimal number, an option that
  /// is not implemented, or a number outside the range its RFC allows.
  BadOption(String, String)
  /// `tsize` arrived in a shape we cannot answer (RFC 2349, section 4).
  BadTsize(String)
} derive(Eq, Debug)

///|
pub extend NegotiationError with Eq::{not_equal, equal}

///|
pub extend NegotiationError with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The `name=value` text carried by the error packet.
fn NegotiationError::description(self : NegotiationError) -> String {
  match self {
    BadOption(name, value) => "\{name}=\{value}"
    BadTsize(value) => "tsize=\{value}"
  }
}

///|
/// The ERROR packet that refuses an option set (RFC 2347, section 3).
pub fn negotiation_error_packet(error : NegotiationError) -> Packet {
  Error(OptionNegotiationFailed, error.description())
}

///|
/// What a server answers for one requested option, as decimal text.
///
/// `Ok(None)` refuses the option: RFC 2347 section 3 wants the whole
/// negotiation withdrawn then, which is `Err(BadOption)` in the result below.

///|
/// Turns a parsed request into the option set both peers will use, after the
/// server has had a say (RFC 2347, section 2).
///
/// For `blksize` and `timeout` the server may answer with at most what the
/// client asked for: a larger value would overrun the client's buffers or its
/// patience, a smaller one is always safe. `tsize` is exempt twice over: the
/// server's value *is* the file size, and a file is not bounded by a packet
/// payload, so neither `max_block_size` nor the client's request applies.
///
/// `server_value` supplies the server-side number for an option as decimal
/// text, or `Ok(None)` to refuse it. A refusal is fatal on purpose: the client
/// explicitly asked and could not be answered, so the server rejects the
/// negotiation with ERROR 8 instead of silently ignoring the option.
pub fn resolve_options(
  requested : RequestedOptions,
  server_value : (RequestedOption) -> Result[String?, NegotiationError],
) -> Result[Options, NegotiationError] {
  let mut blksize = 512
  let mut timeout_seconds = default_timeout
  let mut tsize : Int32? = None
  let oack_values : Array[(String, String)] = []
  for option in requested.options() {
    let kind = option.kind()
    let answer = match server_value(option) {
      Ok(answer) => answer
      Err(error) => return Err(error)
    }
    match kind {
      Blksize | Timeout => {
        let (floor_value, ceiling) = match kind {
          Blksize => (min_block_size, max_block_size)
          _ => (min_timeout, max_timeout)
        }
        let value = match answer {
          Some(text) =>
            match parse_bounded(text, floor_value, ceiling) {
              Some(value) => value
              None => return Err(BadOption(kind.name(), text))
            }
          // No server value: RFC 2347 lets us hand the client's own request
          // back, which for a plain transfer is exactly the answer.
          None => option.request_value()
        }
        // Never answer with more than was asked for.
        let value = if value > option.request_value() {
          option.request_value()
        } else {
          value
        }
        if kind is Blksize {
          blksize = value
        } else {
          timeout_seconds = value
        }
        oack_values.push((kind.name(), decimal_text(value)))
      }
      Tsize => {
        let value = match answer {
          Some(text) =>
            match parse_bounded(text, 0, max_tsize) {
              Some(value) => value
              None => return Err(BadTsize(text))
            }
          None =>
            // The server did not look at its file: a write request already
            // told us the size, a read request left us nothing to answer.
            match requested.tsize_hint() {
              Some(hint) => hint
              None => return Err(BadTsize(decimal_text(option.request_value())))
            }
        }
        tsize = Some(value)
        oack_values.push((kind.name(), decimal_text(value)))
      }
    }
  }
  Ok({ blksize, timeout_seconds, tsize, oack_values, })
}

///|
/// `parse_decimal` restricted to a range, so a huge value cannot wrap around
/// into a legal-looking one.
fn parse_bounded(text : String, min_value : Int32, max_value : Int32) -> Int32? {
  match parse_decimal(text) {
    Some(value) =>
      if value >= min_value && value <= max_value {
        Some(value)
      } else {
        None
      }
    None => None
  }
}
