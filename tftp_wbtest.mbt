///|
test "opcode discriminants are distinct" {
  let opcodes = [Rrq, Wrq, Data, Ack, Error]
  for i = 0; i < opcodes.length(); i = i + 1 {
    for j = i + 1; j < opcodes.length(); j = j + 1 {
      assert_true(opcodes[i] != opcodes[j])
    }
  }
}
