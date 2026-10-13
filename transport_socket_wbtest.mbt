///|
/// The real-socket transport, exercised against real UDP sockets in the same
/// process. Both ends are in-process, so there is no flakiness from a network
/// hop, but the kernel still does the port handling the transport depends on.

///|
/// Once a reply has established the peer's TID, later packets go to that TID
/// and not to the address the request was addressed to.
async test "socket transport learns the peer TID from the first reply" {
  let server = @socket.UdpServer(@socket.Addr::parse("127.0.0.1:0"))
  let request_addr = server.addr.to_string()
  // The peer answers from a *different* port, exactly like TFTP's TID rule.
  let reply_socket = @socket.UdpServer(@socket.Addr::parse("127.0.0.1:0"))
  let tid = reply_socket.addr.to_string()
  let buffer = FixedArray::make(1024, b'\x00')
  let transport = SocketTransport::new(request_addr)
  defer transport.close()
  defer reply_socket.close()
  transport.send(b"request", request_addr)
  @async.with_task_group(group => {
    group.spawn_bg() <| () => {
      let (n, from) = server.recvfrom(buffer)
      inspect(n, content="7")
      reply_socket.sendto(b"reply", from)
    }
    match transport.recv(request_addr, 2000) {
      Recv::Packet(datagram) => {
        // The reply is reported with the address it came from, not the one
        // that was asked for.
        assert_eq(datagram.peer(), tid)
        assert_eq(datagram.payload(), b"reply")
      }
      Recv::Timeout => fail("expected a reply")
    }
  })
  // The transport now sends the rest of the session to the TID socket.
  transport.send(b"again", request_addr)
  @async.with_task_group(group => {
    group.spawn_bg() <| () => {
      let (n, _from) = reply_socket.recvfrom(buffer)
      inspect(n, content="5")
      assert_eq(buffer.unsafe_reinterpret_as_bytes()[:5], b"again")
    }
    @async.sleep(500)
  })
}

///|
async test "socket transport times out when nothing arrives" {
  let transport = SocketTransport::new("127.0.0.1:1")
  defer transport.close()
  match transport.recv("127.0.0.1:1", 300) {
    Recv::Timeout => ()
    Recv::Packet(_) => fail("expected no packet")
  }
}

///|
/// The socket transport has to report the address it is bound to: a caller
/// that needs to tell a peer where to answer reads it from here.
async test "socket transport reports its own bound address" {
  let transport = SocketTransport::new("127.0.0.1:69")
  defer transport.close()
  let bound = transport.local_peer()
  assert_true(bound.has_prefix("0.0.0.0:"))
  // A real port, not the 0 that was asked for: the kernel picked it.
  assert_true(!bound.has_suffix(":0"))
}
