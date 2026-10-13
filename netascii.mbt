///|
/// netascii, the text transfer mode of RFC 1350 section 2.
///
/// On the wire netascii is a 7-bit ASCII stream with CR LF for a line ending
/// and CR NUL for a lone CR; on this side it is ordinary bytes:
///
/// ```text
/// decode (wire -> local):  \r\n -> \n        \r\0 -> \r
/// encode (local -> wire):  \n   -> \r\n      \r   -> \r\0
/// ```
///
/// Both directions are pure functions of their buffer plus one carried flag,
/// because a `\r` can land on the last byte of a DATA block and its partner
/// then belongs to the next one. `NetasciiState` is that carried flag, which is
/// why the codec is a pair of stateful functions rather than one
/// `Bytes -> Bytes` conversion; each direction is closed with its `_finish`,
/// which settles a `\r` still pending at the end of a stream.
///
/// Decoding carries the same flag back the other way: a `\r` that lands on the
/// last byte of a received block may be the first half of a `\r\n` or `\r\0`
/// whose partner is the first byte of the next block. The decoder cannot
/// un-emit a byte, so it holds the `\r` back and lets the next block decide,
/// exactly as the encoder does. A stream that ends on a held `\r` gets it from
/// `netascii_decode_finish`: a lone CR by then is a real one.

///|
/// A pending `\r`, carried across a block boundary.
///
/// Both directions use it, for the same reason: a `\r` has two possible
/// encodings and its partner byte can land in the next block.
pub(all) enum NetasciiState {
  /// Nothing pending: the next byte starts a fresh character.
  Clean
  /// A `\r` was seen on this side with no partner settled yet.
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
/// `\r\n` becomes `\n` and `\r\0` becomes `\r`. A `\r` on the last byte of
/// the block has no partner yet, so it is *held back* in the returned state
/// rather than guessed at: the next block's first byte then decides whether it
/// becomes `\n` (a line ending split across the boundary) or `\r` (a real lone
/// CR). A stream that ends on a held `\r` is closed with
/// `netascii_decode_finish`, which emits the `\r` the encoder would have paired
/// with a NUL.
pub fn netascii_decode(
  state : NetasciiState,
  chunk : Bytes,
) -> (NetasciiState, Bytes) {
  let out = Writer::new()
  // A CR held from the previous block is resolved by this block's first byte.
  let mut pending_cr = state is LocalCr
  for byte in chunk {
    if pending_cr {
      pending_cr = false
      if byte == b'\n' {
        out.write_byte(b'\n')
        continue
      }
      // CR NUL, or a bare CR followed by anything else: both are a lone CR.
      out.write_byte(b'\r')
      if byte == 0 {
        continue
      }
    }
    if byte == b'\r' {
      // Hold it: the partner may be the first byte of the next block.
      pending_cr = true
    } else {
      out.write_byte(byte)
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
  let (state, decoded) = netascii_decode(Clean, bytes)
  netascii_decode_finish(state, decoded)
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
/// Closes the stream on the decoding side: a `\r` still pending at the end is
/// a real lone CR, because no partner byte is coming.
pub fn netascii_decode_finish(state : NetasciiState, tail : Bytes) -> Bytes {
  if state is LocalCr {
    tail + Bytes::from_array([b'\r'])
  } else {
    tail
  }
}
