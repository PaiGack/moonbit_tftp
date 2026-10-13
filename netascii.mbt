///|
/// netascii, the text transfer mode of RFC 1350 section 2.
///
/// On the wire netascii is a 7-bit ASCII stream with CR LF for a line ending
/// and CR NUL for a lone CR; on this side it is ordinary bytes. The two
/// directions are not symmetric, because a newline has exactly one encoding
/// while a lone CR has two possible sources:
///
/// ```text
/// decode (wire -> local):  \r\n -> \n        \r\0 -> \r
/// encode (local -> wire):  \n   -> \r\n      \r   -> \r\0
/// ```
///
/// Both directions therefore need one carried flag, because a `\r` can land on
/// the last byte of a DATA block and its partner then belongs to the next one.
/// `NetasciiState` is that carried flag, and it is why the codec is a pair of
/// stateful functions rather than one `Bytes -> Bytes` conversion. On encoding
/// the CR is held back and re-emitted when the next block says whether it is a
/// line ending or a lone CR; on decoding the held CR is likewise resolved by
/// the next block's first byte. The one thing either direction must never do
/// is drop a byte.

///|
/// The byte a pending escape belongs to, carried across a block boundary.
pub(all) enum NetasciiState {
  /// Nothing pending: the next byte starts a fresh character.
  Clean
  /// A `\r` was seen on this side with no partner encoded yet.
  LocalCr
} derive(Eq, Debug)

///|
pub extend NetasciiState with Eq::{not_equal, equal}

///|
pub extend NetasciiState with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Encodes one block of local bytes for the netascii wire.
///
/// Every `\n` becomes `\r\n` and every `\r` becomes `\r\0`. A `\r` that lands
/// on the last byte of a block is *held back* rather than written: the next
/// block's first byte then decides whether the held CR becomes `\r\n` (a line
/// ending split across the boundary) or `\r\0` (a real lone CR). A stream that
/// ends with a held CR gets its NUL from `netascii_encode_finish`.
pub fn netascii_encode(
  state : NetasciiState,
  chunk : Bytes,
) -> (NetasciiState, Bytes) {
  let out = Writer::new()
  let mut pending_cr = state is LocalCr
  for byte in chunk {
    if pending_cr {
      pending_cr = false
      out.write_byte(b'\r')
      if byte == b'\n' {
        out.write_byte(b'\n')
        continue
      }
      out.write_byte(0)
    }
    if byte == b'\n' {
      out.write_byte(b'\r')
      out.write_byte(b'\n')
    } else if byte == b'\r' {
      pending_cr = true
    } else {
      out.write_byte(byte)
    }
  }
  (if pending_cr { LocalCr } else { Clean }, out.to_bytes())
}

///|
/// Decodes one block of netascii received from the wire.
///
/// `\r\n` becomes `\n` and `\r\0` becomes `\r`. A `\r` on the last byte of the
/// block cannot be resolved yet: its partner may be the first byte of the next
/// block, so the decoder *holds it back* and returns `LocalCr`, exactly as the
/// encoder does. The caller then folds the next block in with that state, and
/// the held CR is emitted (or joined to its `\n`) once its partner is known.
/// A stream that ends on a held CR gets it from `netascii_decode_finish`.
pub fn netascii_decode(
  state : NetasciiState,
  chunk : Bytes,
) -> (NetasciiState, Bytes) {
  let out = Writer::new()
  let mut pending_cr = state is LocalCr
  let mut i = 0
  while i < chunk.length() {
    let byte = chunk[i]
    if pending_cr {
      // The partner of the previous block's CR, which was held back.
      pending_cr = false
      if byte == b'\n' {
        out.write_byte(b'\n')
        i = i + 1
        continue
      }
      // A held CR followed by NUL is the wire spelling of a lone CR: emit the
      // CR and swallow the NUL. Any other byte means the CR was on its own
      // (a tolerant bare CR), so emit it and reprocess this byte normally.
      out.write_byte(b'\r')
      if byte == 0 {
        i = i + 1
        continue
      }
    }
    if byte == b'\r' {
      if i + 1 < chunk.length() {
        let partner = chunk[i + 1]
        if partner == b'\n' {
          out.write_byte(b'\n')
          i = i + 2
          continue
        } else if partner == 0 {
          out.write_byte(b'\r')
          i = i + 2
          continue
        }
      }
      // No partner inside this block: hold the CR for the next block.
      pending_cr = true
      i = i + 1
    } else {
      out.write_byte(byte)
      i = i + 1
    }
  }
  (if pending_cr { LocalCr } else { Clean }, out.to_bytes())
}

///|
/// Encodes a whole buffer in one go, for the cases with no block boundary to
/// straddle (a file read into memory, a `tsize` computation).
pub fn netascii_encode_all(bytes : Bytes) -> Bytes {
  let (state, encoded) = netascii_encode(Clean, bytes)
  // At the end of the stream a pending CR is a real lone CR and gets its NUL.
  netascii_encode_finish(state, encoded)
}

///|
/// Decodes a whole buffer in one go.
pub fn netascii_decode_all(bytes : Bytes) -> Bytes {
  let (_, decoded) = netascii_decode(Clean, bytes)
  decoded
}

///|
/// Closes the stream on the encoding side: whatever is still pending is a real
/// lone CR and gets its `\0` partner.
pub fn netascii_encode_finish(state : NetasciiState, tail : Bytes) -> Bytes {
  if state is LocalCr {
    let out = Writer::new()
    out.write_bytes(tail)
    out.write_byte(b'\r')
    out.write_byte(0)
    out.to_bytes()
  } else {
    tail
  }
}

///|
/// Closes the stream on the decoding side. A `\r` still held back at the end of
/// the stream had no partner on the wire, so it is a real lone CR and is
/// emitted here; nothing else is pending.
pub fn netascii_decode_finish(state : NetasciiState, tail : Bytes) -> Bytes {
  if state is LocalCr {
    let out = Writer::new()
    out.write_bytes(tail)
    out.write_byte(b'\r')
    out.to_bytes()
  } else {
    tail
  }
}
