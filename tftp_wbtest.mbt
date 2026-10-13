///|
test "opcode discriminants are distinct" {
  let opcodes : Array[Opcode] = [Rrq, Wrq, Data, Ack, Error, Oack]
  for i = 0; i < opcodes.length(); i = i + 1 {
    for j = i + 1; j < opcodes.length(); j = j + 1 {
      assert_true(opcodes[i] != opcodes[j])
    }
  }
}

///|
test "error code discriminants are distinct" {
  let codes : Array[ErrorCode] = [
    Undefined,
    FileNotFound,
    AccessViolation,
    DiskFull,
    IllegalOperation,
    UnknownTransferId,
    FileAlreadyExists,
    NoSuchUser,
    OptionNegotiationFailed,
  ]
  for i = 0; i < codes.length(); i = i + 1 {
    for j = i + 1; j < codes.length(); j = j + 1 {
      assert_true(codes[i] != codes[j])
    }
  }
}
