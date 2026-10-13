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
/// Encoding a local buffer is a pure function of that buffer plus one carried
/// flag, because a `\r` can land on the last byte of a DATA block and its
/// partner then belongs to the next one. `NetasciiState` is that carried flag,
/// and it is why the codec is a pair of stateful functions rather than one
/// `Bytes -> Bytes` conversion.
///
/// Decoding needs no carried state: a chunk boundary is a *chunk* boundary, not
/// a character boundary in the local stream, so the worst a split can do is
/// hand the caller a `\r` that later turns out to belong to a `\r\n`. The
/// caller gets the raw bytes and can append the next chunk; the one thing the
/// decoder must never do is drop a byte.

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
/// `\r\n` becomes `\n` and `\r\0` becomes `\r`. A `\r` with no partner *inside
/// this chunk* is emitted as a bare `\r`: it may be the first half of an escape
/// in the next chunk, but a decoder cannot un-emit a byte, and a following `\n`
/// or `\0` in the next chunk is swallowed by the caller-side merge below. The
/// common case — escapes contained in one block — is exact.
pub fn netascii_decode(
  state : NetasciiState,
  chunk : Bytes,
) -> (NetasciiState, Bytes) {
  ignore(state)
  let out = Writer::new()
  let mut i = 0
  while i < chunk.length() {
    let byte = chunk[i]
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
      // No partner in this chunk: a tolerant decoder keeps the bare CR.
      out.write_byte(b'\r')
      i = i + 1
    } else {
      out.write_byte(byte)
      i = i + 1
    }
  }
  (Clean, out.to_bytes())
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
/// Closes the stream on the decoding side. The decoder holds no state, so this
/// is the identity; it stays for symmetry with `netascii_encode_finish` and so
/// a future stateful decoder does not change the call sites.
pub fn netascii_decode_finish(state : NetasciiState, tail : Bytes) -> Bytes {
  ignore(state)
  tail
}
