///|
/// TFTP protocol primitives (RFC 1350 with options from RFC 2347/2348/2349).
///
/// This package currently publishes the packet layer: opcodes, mode and error
/// codes, encode/decode, and the canonical 512-byte default block size constant.
/// Client and server state machines are built on top of it in follow-up changes.

///|
/// Default TFTP data block size, in bytes (RFC 1350).
pub let default_block_size : Int32 = 512

///|
/// The UDP port a TFTP server listens on for the initial request (RFC 1350).
pub let default_port : Int32 = 69

///|
/// Longest filename accepted in a RRQ/WRQ, in bytes. The RFC imposes no limit;
/// this one only exists so a malformed packet cannot make us allocate forever.
///
/// Superseded by `max_field_length`, which caps every field at the size of a
/// legal UDP packet; kept so existing callers of the public name keep working.
pub let max_filename_length : Int32 = 512

///|
/// Longest `\0`-terminated field `decode` accepts, in bytes.
///
/// This is the single cap shared by every `\0`-terminated field — filename,
/// mode, option name, option value and ERROR message — so a malformed packet is
/// rejected on the same rule no matter which field is oversized. It is set to
/// the largest packet a legitimate RRQ/WRQ can produce: two bytes of opcode
/// below the 65535-byte UDP datagram ceiling, so nothing a real peer sends can
/// trip it. The RFC cap on `blksize` (65464, RFC 2348) leaves room to spare.
pub let max_field_length : Int32 = 65533

///|
/// TFTP opcodes as they appear on the wire (RFC 1350, section 5).
pub(all) enum Opcode {
  Rrq // 1: read request
  Wrq // 2: write request
  Data // 3: data
  Ack // 4: acknowledgment
  Error // 5: error
  Oack // 6: option acknowledgment (RFC 2347)
} derive(Eq, Debug)

///|
pub extend Opcode with Eq::{not_equal, equal}

///|
pub extend Opcode with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The numeric opcode of a packet, as written on the wire.
pub fn Opcode::code(self : Opcode) -> Int32 {
  match self {
    Rrq => 1
    Wrq => 2
    Data => 3
    Ack => 4
    Error => 5
    Oack => 6
  }
}

///|
/// The opcode encoded in the first two bytes of a packet.
pub fn opcode_of(code : Int32) -> Opcode? {
  match code {
    1 => Some(Rrq)
    2 => Some(Wrq)
    3 => Some(Data)
    4 => Some(Ack)
    5 => Some(Error)
    6 => Some(Oack)
    _ => None
  }
}

///|
/// Transfer modes of a RRQ/WRQ (RFC 1350, section 2).
///
/// `Mail` exists in the RFC but the conversion is out of scope: `mode_of`
/// rejects it, so it can only ever appear as a round-trip value, never on the
/// wire from this package.
pub(all) enum Mode {
  Netascii
  Octet
  Mail
} derive(Eq, Debug)

///|
pub extend Mode with Eq::{not_equal, equal}

///|
pub extend Mode with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The mode as it is spelled on the wire (RFC 1350, section 2).
fn Mode::name(self : Mode) -> String {
  match self {
    Netascii => "netascii"
    Octet => "octet"
    // `mail` cannot be produced by `mode_of`, so it never reaches the wire.
    Mail => "mail"
  }
}

///|
fn mode_of(name : String) -> Mode? {
  if name == "netascii" {
    Some(Netascii)
  } else if name == "octet" {
    Some(Octet)
  } else {
    // `mail` is spelled out in RFC 1350 but the conversion is out of scope;
    // rejecting it is safer than silently mishandling the payload.
    None
  }
}

///|
/// Error codes carried by ERROR packets (RFC 1350, section 5).
///
/// The variant name mirrors the code, so `Undefined` is code 0 ("not defined").
pub(all) enum ErrorCode {
  Undefined // 0
  FileNotFound // 1
  AccessViolation // 2
  DiskFull // 3
  IllegalOperation // 4
  UnknownTransferId // 5
  FileAlreadyExists // 6
  NoSuchUser // 7
  OptionNegotiationFailed // 8
} derive(Eq, Debug)

///|
pub extend ErrorCode with Eq::{not_equal, equal}

///|
pub extend ErrorCode with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The numeric error code as written on the wire.
fn ErrorCode::code(self : ErrorCode) -> Int32 {
  match self {
    Undefined => 0
    FileNotFound => 1
    AccessViolation => 2
    DiskFull => 3
    IllegalOperation => 4
    UnknownTransferId => 5
    FileAlreadyExists => 6
    NoSuchUser => 7
    OptionNegotiationFailed => 8
  }
}

///|
fn error_code_of(code : Int32) -> ErrorCode? {
  match code {
    0 => Some(Undefined)
    1 => Some(FileNotFound)
    2 => Some(AccessViolation)
    3 => Some(DiskFull)
    4 => Some(IllegalOperation)
    5 => Some(UnknownTransferId)
    6 => Some(FileAlreadyExists)
    7 => Some(NoSuchUser)
    8 => Some(OptionNegotiationFailed)
    _ => None
  }
}

///|
/// Why a packet could not be decoded. Returned as data, never raised, so callers
/// on any backend (including wasm) can inspect it without an error type.
pub(all) enum DecodeError {
  /// Fewer bytes than the fixed part of the packet needs.
  Truncated
  /// The opcode field is not one of RFC 1350's 1..6.
  UnknownOpcode(Int32)
  /// A `\0`-terminated field runs past the end of the packet.
  MissingTerminator
  /// A `\0`-terminated field runs past `max_field_length`.
  ///
  /// The RFC puts no cap on any field, so this is our own guard, not a
  /// protocol rule. It is reported rather than silently truncated or
  /// allocated: a peer that sends an oversized field is broken, not merely
  /// unusual, and the size of the allocation must never be the peer's choice.
  FieldTooLong
  /// Well-formed bytes we deliberately do not implement (e.g. `mail` mode).
  Unsupported(String)
} derive(Eq, Debug)

///|
pub extend DecodeError with Eq::{not_equal, equal}

///|
pub extend DecodeError with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// An `Option\0Value\0` pair of a RRQ/WRQ (RFC 2347, section 2).
///
/// Values stay `String` here: M2 owns validation, so this layer only splits.
pub struct TftpOption {
  name : String
  value : String
} derive(Eq, Debug)

///|
pub fn TftpOption::new(name : String, value : String) -> TftpOption {
  { name, value, }
}

///|
pub fn TftpOption::name(self : TftpOption) -> String {
  self.name
}

///|
pub fn TftpOption::value(self : TftpOption) -> String {
  self.value
}

///|
pub extend TftpOption with Eq::{not_equal, equal}

///|
pub extend TftpOption with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Every TFTP packet, in decoded form.
pub(all) enum Packet {
  Rrq(String, Mode, Array[TftpOption])
  Wrq(String, Mode, Array[TftpOption])
  Data(UInt16, Bytes)
  Ack(UInt16)
  Error(ErrorCode, String)
  Oack(Array[TftpOption])
} derive(Eq, Debug)

///|
pub extend Packet with Eq::{not_equal, equal}

///|
pub extend Packet with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The payload of a DATA packet, `None` for every other packet.
///
/// The packet layer stays encoding-only; the client and server state machines
/// read packets through these accessors so `Packet` keeps its payload opaque.
pub fn Packet::data_payload(self : Packet) -> Bytes? {
  match self {
    Data(_, payload) => Some(payload)
    _ => None
  }
}

///|
/// The block number of a DATA or ACK packet, `None` for every other packet.
pub fn Packet::block_number(self : Packet) -> UInt16? {
  match self {
    Data(block, _) | Ack(block) => Some(block)
    _ => None
  }
}

///|
/// The mode of a RRQ/WRQ, `None` for every other packet.
pub fn Packet::mode(self : Packet) -> Mode? {
  match self {
    Rrq(_, mode, _) | Wrq(_, mode, _) => Some(mode)
    _ => None
  }
}

///|
/// The options carried by a RRQ/WRQ/OACK, `None` for every other packet.
pub fn Packet::options(self : Packet) -> Array[TftpOption]? {
  match self {
    Rrq(_, _, options) | Wrq(_, _, options) | Oack(options) => Some(options)
    _ => None
  }
}

///|
/// The error code and message of an ERROR packet, `None` for every other packet.
pub fn Packet::error_info(self : Packet) -> (ErrorCode, String)? {
  match self {
    Error(code, message) => Some((code, message))
    _ => None
  }
}

///|
/// The opcode a packet would be sent with.
fn Packet::opcode(self : Packet) -> Opcode {
  match self {
    Rrq(_, _, _) => Opcode::Rrq
    Wrq(_, _, _) => Opcode::Wrq
    Data(_, _) => Opcode::Data
    Ack(_) => Opcode::Ack
    Error(_, _) => Opcode::Error
    Oack(_) => Opcode::Oack
  }
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

///|
/// A growable byte buffer, so encoding never needs to concatenate `Bytes`.
priv struct Writer {
  mut buf : FixedArray[Byte]
  mut len : Int32
}

///|
fn Writer::new() -> Writer {
  { buf: FixedArray::make(64, b'\x00'), len: 0, }
}

///|
fn Writer::reserve(self : Writer, extra : Int32) -> Unit {
  let needed = self.len + extra
  if needed <= self.buf.length() {
    return
  }
  let mut capacity = self.buf.length() * 2
  while capacity < needed {
    capacity = capacity * 2
  }
  let grown = FixedArray::make(capacity, b'\x00')
  for i = 0; i < self.len; i = i + 1 {
    grown[i] = self.buf[i]
  }
  self.buf = grown
}

///|
fn Writer::write_byte(self : Writer, byte : Byte) -> Unit {
  self.reserve(1)
  self.buf[self.len] = byte
  self.len += 1
}

///|
fn Writer::write_u16(self : Writer, value : UInt16) -> Unit {
  self.reserve(2)
  FixedArray::unsafe_write_uint16_be(self.buf, self.len, value)
  self.len += 2
}

///|
/// Writes `text` followed by its `\0` terminator (RFC 1350, section 1).
fn Writer::write_cstring(self : Writer, text : String) -> Unit {
  for char in text {
    self.write_byte(char.to_int().to_byte())
  }
  self.write_byte(0)
}

///|
fn Writer::write_bytes(self : Writer, payload : Bytes) -> Unit {
  for byte in payload {
    self.write_byte(byte)
  }
}

///|
fn Writer::to_bytes(self : Writer) -> Bytes {
  Bytes::from_array(self.buf.clamped_view(end=self.len))
}

///|
/// Serializes a packet to its wire form (RFC 1350, section 5).
pub fn encode(packet : Packet) -> Bytes {
  let writer = Writer::new()
  writer.write_u16(packet.opcode().code().to_uint16())
  match packet {
    Rrq(filename, mode, options) | Wrq(filename, mode, options) => {
      writer.write_cstring(filename)
      writer.write_cstring(mode.name())
      for option in options {
        writer.write_cstring(option.name())
        writer.write_cstring(option.value())
      }
    }
    Data(block, payload) => {
      writer.write_u16(block)
      writer.write_bytes(payload)
    }
    Ack(block) => writer.write_u16(block)
    Error(code, message) => {
      writer.write_u16(code.code().to_uint16())
      writer.write_cstring(message)
    }
    Oack(options) =>
      for option in options {
        writer.write_cstring(option.name())
        writer.write_cstring(option.value())
      }
  }
  writer.to_bytes()
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

///|
/// Reads the 2-byte opcode at `offset` and advances past it.
pub fn take_opcode(bytes : Bytes, offset : Int32) -> (Opcode, Int32)? {
  if offset + 2 > bytes.length() {
    None
  } else {
    let code = bytes.unsafe_read_uint16_be(offset).to_int()
    match opcode_of(code) {
      Some(opcode) => Some((opcode, offset + 2))
      None => None
    }
  }
}

///|
/// Reads a 2-byte unsigned integer at `offset` and advances past it.
pub fn take_u16(bytes : Bytes, offset : Int32) -> (UInt16, Int32)? {
  if offset + 2 > bytes.length() {
    None
  } else {
    Some((bytes.unsafe_read_uint16_be(offset), offset + 2))
  }
}

///|
/// Reads a `\0`-terminated field starting at `offset`, returning the field and
/// the offset just past its terminator.
///
/// Failure says *which* way the field is malformed: `Truncated` when the packet
/// ends before the field starts, `MissingTerminator` when the field runs to the
/// last byte without a `\0`, `FieldTooLong` when a terminated field exceeds
/// `max_field_length`. They are separate variants so a caller (or a test) can
/// tell a short packet from an oversized field instead of guessing.
pub fn take_cstring(
  bytes : Bytes,
  offset : Int32,
) -> Result[(String, Int32), DecodeError] {
  let mut end = offset
  while end < bytes.length() && bytes[end] != 0 {
    end = end + 1
  }
  if end >= bytes.length() {
    // Ran out of bytes before the terminator; no byte to distinguish "field
    // started past the end" from "field consumed the rest of the packet".
    if offset >= bytes.length() {
      Err(Truncated)
    } else {
      Err(MissingTerminator)
    }
  } else if end - offset > max_field_length {
    Err(FieldTooLong)
  } else {
    let chars : Array[Char] = []
    for i in offset..<end {
      chars.push(bytes[i].to_char())
    }
    Ok((String::from_array(chars), end + 1))
  }
}

///|
/// Reads `Option\0Value\0` pairs until the packet ends.
///
/// Every field goes through the same rule as a filename, so an oversized option
/// name or value is reported as `FieldTooLong` rather than passed on to the
/// option layer.
pub fn take_options(
  bytes : Bytes,
  offset : Int32,
) -> Result[Array[TftpOption], DecodeError] {
  let options : Array[TftpOption] = []
  let mut cursor = offset
  while cursor < bytes.length() {
    let name = match take_cstring(bytes, cursor) {
      Ok(pair) => pair
      Err(e) => return Err(e)
    }
    let value = match take_cstring(bytes, name.1) {
      Ok(pair) => pair
      Err(e) => return Err(e)
    }
    options.push(TftpOption::new(name.0, value.0))
    cursor = value.1
  }
  Ok(options)
}

///|
/// Alias of `take_cstring`, kept because it reads better at the call sites in
/// `decode` that pull one field off the wire.
pub fn take_field(
  bytes : Bytes,
  offset : Int32,
) -> Result[(String, Int32), DecodeError] {
  take_cstring(bytes, offset)
}

///|
/// Decodes a packet from its wire form.
///
/// Malformed input is reported as `DecodeError` instead of raising, so the same
/// path works on every backend.
pub fn decode(bytes : Bytes) -> Result[Packet, DecodeError] {
  let (opcode, offset) = match take_opcode(bytes, 0) {
    Some(pair) => pair
    None =>
      if bytes.length() < 2 {
        return Err(Truncated)
      } else {
        return Err(UnknownOpcode(bytes.unsafe_read_uint16_be(0).to_int()))
      }
  }
  match opcode {
    Rrq | Wrq => {
      let filename = match take_field(bytes, offset) {
        Ok(pair) => pair
        Err(e) => return Err(e)
      }
      let mode_field = match take_field(bytes, filename.1) {
        Ok(pair) => pair
        Err(e) => return Err(e)
      }
      let mode = match mode_of(mode_field.0) {
        Some(mode) => mode
        None => return Err(Unsupported(mode_field.0))
      }
      let options = match take_options(bytes, mode_field.1) {
        Ok(options) => options
        Err(e) => return Err(e)
      }
      if opcode is Rrq {
        Ok(Rrq(filename.0, mode, options))
      } else {
        Ok(Wrq(filename.0, mode, options))
      }
    }
    Data => {
      let (block, after_block) = match take_u16(bytes, offset) {
        Some(pair) => pair
        None => return Err(Truncated)
      }
      Ok(Data(block, bytes.clamped_view(start=after_block).to_owned()))
    }
    Ack =>
      match take_u16(bytes, offset) {
        Some((block, _)) => Ok(Ack(block))
        None => Err(Truncated)
      }
    Error => {
      let (code, after_code) = match take_u16(bytes, offset) {
        Some(pair) => pair
        None => return Err(Truncated)
      }
      let error_code = match error_code_of(code.to_int()) {
        Some(error_code) => error_code
        None => return Err(UnknownOpcode(code.to_int()))
      }
      let message = match take_field(bytes, after_code) {
        Ok(pair) => pair
        Err(e) => return Err(e)
      }
      Ok(Error(error_code, message.0))
    }
    Oack =>
      match take_options(bytes, offset) {
        Ok(options) => Ok(Oack(options))
        Err(e) => Err(e)
      }
  }
}
