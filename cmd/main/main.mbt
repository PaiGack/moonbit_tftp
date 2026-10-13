///|
/// The command-line entry point: `get`, `put` and `serve`.
///
/// This file is intentionally thin — argument parsing and the handful of
/// host-specific bits (reading a file, picking a port) live here, and every
/// protocol decision is delegated to the library. That keeps the CLI from
/// growing a second, divergent implementation of the state machines.

///|
/// The version reported by `--version`; kept in step with `moon.mod`.
let version : String = "0.1.0"

///|
/// A failed command line, carrying the sentence to print for the user.
priv suberror CliError {
  CliError(String)
} derive(Debug)

///|
async fn main {
  let args = @env.args()
  // `args[0]` is the program path; the subcommand is what the user typed.
  let rest = if args.length() > 1 { args[1:].to_owned() } else { [] }
  if rest.is_empty() || rest[0] == "-h" || rest[0] == "--help" {
    print_usage()
    return
  }
  if rest[0] == "-v" || rest[0] == "--version" {
    println("moon-tftp \{version}")
    return
  }
  let command = match Command::parse(rest[0], rest[1:].to_owned()) {
    Ok(command) => command
    Err(CliError(message)) => {
      eprintln("error: \{message}")
      print_usage()
      exit(2)
      return
    }
  }
  match run(command) {
    Ok(_) => ()
    Err(CliError(message)) => {
      eprintln("error: \{message}")
      exit(1)
    }
  }
}

///|
/// Exits the process with `code`. Kept in one place so the CLI's exit codes
/// are visible at a glance.
extern "C" fn exit(code : Int32) = "exit"

///|
/// A parsed command line, once the subcommand and its flags are understood.
priv enum Command {
  Get(TransferArgs)
  Put(TransferArgs)
  Serve(ServeArgs)
}

///|
/// The flags shared by `get` and `put`.
priv struct TransferArgs {
  /// The server, `host:port`.
  remote : String
  /// The name used on the remote side.
  remote_file : String
  /// The local path: where `get` writes, where `put` reads.
  local_file : String
  options : @lib.ClientOptions
}

///|
/// The flags `serve` accepts.
priv struct ServeArgs {
  root : String
  port : Int32
  write_policy : @lib.WritePolicy
  max_sessions : Int32
}

///|
/// Parses `name` plus the rest of the command line.
///
/// Every error is a human-readable sentence: a CLI that says `missing value
/// for --blksize` is worth more than one that panics.
fn Command::parse(
  name : String,
  args : Array[String],
) -> Result[Command, CliError] {
  match name {
    "get" => parse_transfer("get", args).map(command => Command::Get(command))
    "put" => parse_transfer("put", args).map(command => Command::Put(command))
    "serve" => parse_serve(args).map(command => Command::Serve(command))
    other => Err(CliError("unknown subcommand `\{other}`"))
  }
}

///|
/// Parses the `get` / `put` argument list.
///
/// `get host:port remote [local]`: a third positional names the local file;
/// otherwise the download lands under the remote's own name.
fn parse_transfer(
  kind : String,
  args : Array[String],
) -> Result[TransferArgs, CliError] {
  let positionals : Array[String] = []
  let mut options = @lib.ClientOptions::default()
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--blksize" | "--timeout" | "--retries" => {
        let value = match next_value(args, i, arg) {
          Ok(value) => value
          Err(message) => return Err(message)
        }
        let number = match parse_int(value) {
          Some(number) => number
          None =>
            return Err(CliError("\{arg} expects a number, got `\{value}`"))
        }
        options = match arg {
          "--blksize" => options.with_block_size(number)
          "--timeout" => options.with_timeout(number)
          _ => options.with_max_retries(number)
        }
        i = i + 2
      }
      "--netascii" => {
        options = options.with_mode(@lib.Mode::Netascii)
        i = i + 1
      }
      _ =>
        if arg.has_prefix("-") {
          return Err(CliError("unknown flag `\{arg}`"))
        } else {
          positionals.push(arg)
          i = i + 1
        }
    }
  }
  // The two directions read their positionals in opposite orders, so the
  // parser keeps them apart instead of pretending one shape fits both.
  let (remote, remote_file, local_file) = if kind == "get" {
    match positionals {
      [remote, remote_file] => (remote, remote_file, remote_file)
      [remote, remote_file, local_file] => (remote, remote_file, local_file)
      [] => return Err(CliError("get needs at least <host:port> <remote>"))
      [_] => return Err(CliError("get needs a remote file name too"))
      _ =>
        return Err(CliError("get takes at most <host:port> <remote> [local]"))
    }
  } else {
    match positionals {
      // Without a remote name the file keeps its local base name, which is
      // what a caller typing `put host ./boot.img` means.
      [remote, local_file] => (remote, base_name(local_file), local_file)
      [remote, local_file, remote_file] => (remote, remote_file, local_file)
      [] => return Err(CliError("put needs at least <host:port> <local>"))
      [_] => return Err(CliError("put needs a local file name too"))
      _ =>
        return Err(CliError("put takes at most <host:port> <local> [remote]"))
    }
  }
  Ok({ remote, remote_file, local_file, options, })
}

///|
/// The last path segment, so `put host ./dir/boot.img` stores `boot.img`.
fn base_name(path : String) -> String {
  match path.rev_find("/") {
    Some(index) => path[index + 1:].to_owned()
    None => path
  }
}

///|
fn parse_serve(args : Array[String]) -> Result[ServeArgs, CliError] {
  let mut root = "."
  let mut port = @lib.default_port
  let mut write_policy = @lib.WritePolicy::CreateOnly
  let mut max_sessions = 32
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--root" | "--port" | "--max-sessions" => {
        let value = match next_value(args, i, arg) {
          Ok(value) => value
          Err(message) => return Err(message)
        }
        match arg {
          "--root" => root = value
          "--port" =>
            match parse_int(value) {
              Some(number) =>
                if number <= 0 || number > 65535 {
                  return Err(CliError("--port must be between 1 and 65535"))
                } else {
                  port = number
                }
              None =>
                return Err(CliError("--port expects a number, got `\{value}`"))
            }
          _ =>
            match parse_int(value) {
              Some(number) =>
                if number <= 0 {
                  return Err(CliError("--max-sessions must be positive"))
                } else {
                  max_sessions = number
                }
              None =>
                return Err(
                  CliError("--max-sessions expects a number, got `\{value}`"),
                )
            }
        }
        i = i + 2
      }
      "--allow-overwrite" => {
        write_policy = @lib.WritePolicy::AllowOverwrite
        i = i + 1
      }
      _ =>
        if arg.has_prefix("-") {
          return Err(CliError("unknown flag `\{arg}`"))
        } else {
          return Err(
            CliError("serve takes no positional arguments (got `\{arg}`)"),
          )
        }
    }
  }
  Ok({ root, port, write_policy, max_sessions, })
}

///|
/// The value after a flag, or a message naming the flag that lost it.
fn next_value(
  args : Array[String],
  index : Int32,
  flag : String,
) -> Result[String, CliError] {
  if index + 1 >= args.length() {
    Err(CliError("\{flag} needs a value"))
  } else {
    Ok(args[index + 1])
  }
}

///|
/// A decimal integer, or `None` if the text is not one.
///
/// Hand-rolled because the CLI only ever parses small non-negative counts,
/// and a second dependency for four lines is not worth it.
fn parse_int(text : String) -> Int32? {
  if text.is_empty() {
    return None
  }
  let mut value = 0
  for each in @utf8.encode(text) {
    if each < b'0' || each > b'9' {
      return None
    }
    value = value * 10 + (each - b'0').to_int()
  }
  Some(value)
}

///|
/// Runs a parsed command.
async fn run(command : Command) -> Result[Unit, CliError] {
  match command {
    Get(args) => get(args)
    Put(args) => put(args)
    Serve(args) => serve(args)
  }
}

///|
/// `get`: request a file and write it locally.
async fn get(args : TransferArgs) -> Result[Unit, CliError] {
  let transport = @lib.SocketTransport::new(args.remote)
  defer transport.close()
  let printer = ProgressPrinter::new(args.local_file)
  match
    @lib.get_with_progress(
      transport,
      args.remote,
      args.remote_file,
      args.options,
      report => printer.report(report),
    ) {
    Ok(outcome) =>
      match outcome.received() {
        Some(payload) =>
          match write_local(args.local_file, payload) {
            Ok(_) => {
              println(
                "received \{payload.length()} bytes -> \{args.local_file}",
              )
              Ok(())
            }
            Err(error) => Err(error)
          }
        None => Err(CliError("server sent no data"))
      }
    Err(error) => Err(describe_client_error(error))
  }
}

///|
/// `put`: read the file and send it to the peer.
async fn put(args : TransferArgs) -> Result[Unit, CliError] {
  let payload = match read_local(args.local_file) {
    Ok(payload) => payload
    Err(error) => return Err(error)
  }
  let transport = @lib.SocketTransport::new(args.remote)
  defer transport.close()
  let printer = ProgressPrinter::new(args.remote_file)
  match
    @lib.put_with_progress(
      transport,
      args.remote,
      args.remote_file,
      payload,
      args.options,
      report => printer.report(report),
    ) {
    Ok(outcome) => {
      // Capacity check: the peer's `tsize` is the size it agreed to store.
      // Anything but our own byte count means the transfer was cut short on
      // the far side, which a stop-and-wait protocol cannot otherwise report.
      match check_capacity(outcome.tsize(), payload.length(), args) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      match outcome.sent() {
        Some(bytes) => {
          println("sent \{bytes} bytes -> \{args.remote_file}")
          Ok(())
        }
        None => Err(CliError("transfer reported no acknowledged bytes"))
      }
    }
    Err(error) => Err(describe_client_error(error))
  }
}

///|
/// Confirms the transfer stored exactly what was handed over.
///
/// `tsize` is the number the WRQ announced (RFC 2349) and a server echoes it
/// in the OACK once it has accepted the write, so a mismatch is the server
/// saying it will take less than the whole file. A peer that does not
/// negotiate `tsize` is not an error — the option is optional — so `None`
/// passes.
fn check_capacity(
  negotiated : Int32?,
  sent : Int32,
  args : TransferArgs,
) -> Result[Unit, CliError] {
  match negotiated {
    Some(size) =>
      if size == sent {
        Ok(())
      } else {
        Err(
          CliError(
            "capacity check failed: \{args.remote_file} negotiated \{size} bytes but \{sent} were sent",
          ),
        )
      }
    None => Ok(())
  }
}

///|
/// Prints a progress line when a transfer's percentage moves far enough to be
/// worth a line.
///
/// TFTP is stop-and-wait, so a per-block line would be one line per RTT and
/// bury the terminal during a big transfer; reporting on whole-percent steps
/// keeps the output readable while still showing that the transfer is moving.
priv struct ProgressPrinter {
  name : String
  last_percent : Int32
} derive(Debug)

///|
fn ProgressPrinter::new(name : String) -> ProgressPrinter {
  { name, last_percent: -1, }
}

///|
fn ProgressPrinter::report(self : ProgressPrinter, progress : @lib.Progress) {
  if !progress.is_known() {
    return
  }
  let total = progress.total()
  // A netascii `get` decodes as it goes, so `done` can edge past the wire
  // `total`; the percent is clamped rather than allowed to print 103%.
  let percent = if progress.done() >= total {
    100
  } else {
    progress.done() * 100 / total
  }
  if percent == self.last_percent {
    return
  }
  self.last_percent = percent
  println("\{self.name}: \{percent}% (\{progress.done()}/\{total} bytes)")
}

///|
/// The server's accept loop: one UDP socket on the request port, one session
/// per request, each session on its own TID.
///
/// Only the request socket is shared; a session gets a fresh socket bound to
/// the TID it was allocated, so two concurrent transfers never see each
/// other's packets (RFC 1350, section 4).
///
/// All sessions live in one task group, and each one catches its own errors:
/// a peer that disappears mid-transfer must not take the server down with it.
async fn serve(args : ServeArgs) -> Result[Unit, CliError] {
  let files = @lib.HostFileSystem::new()
  let options = @lib.ServerOptions::default()
    .with_root(args.root)
    .with_write_policy(args.write_policy)
    .with_max_sessions(args.max_sessions)
  let server = @socket.UdpServer(@socket.Addr::parse("0.0.0.0:\{args.port}"))
  defer server.close()
  println("moon-tftp serving \{args.root} on port \{args.port}")
  let allocator = @lib.CounterTid::new(args.port + 1)
  let dispatcher = @lib.Dispatcher::new(allocator, args.max_sessions)
  let buffer = FixedArray::make(65536, b'\x00')
  @async.with_task_group(group => {
    while true {
      let (length, peer_addr) = server.recvfrom(buffer)
      let peer = peer_addr.to_string()
      let payload = buffer.unsafe_reinterpret_as_bytes()[:length].to_owned()
      match dispatcher.route(@lib.Datagram::new(payload, peer)) {
        @lib.Dispatch::Started(tid) =>
          match @lib.decode(payload) {
            Ok(packet) => {
              println("session \{tid} for \{peer}")
              group.spawn_bg() <| () => {
                // Swallow everything: the session's failure is reported in
                // its own log line, not by terminating the accept loop.
                run_session(tid, peer, packet, files, options) catch {
                  _ => ()
                }
                // Hand the slot back, or the dispatcher's ceiling would count
                // finished sessions as running ones.
                dispatcher.release()
              }
            }
            Err(_) => ()
          }
        @lib.Dispatch::Rejected(tid~, error~) =>
          // A refused request still gets an answer on the client's own port:
          // ERROR 5 for a client on the wrong TID, ERROR 4 when the session
          // ceiling is full. The dispatcher already decided which.
          reject_session(
            tid,
            peer,
            error.error_code(),
            error.message(),
          )
        @lib.Dispatch::Ignored => ()
      }
    }
  })
  Ok(())
}

///|
/// Sends one ERROR packet from a fresh TID, for a request the accept loop
/// refuses before a session exists (a client on the wrong TID, or a request
/// past the session ceiling).
///
/// A socket that cannot be opened or written is not worth failing over: the
/// peer is already being told "no", and a second failure is just the same
/// silence with extra noise in the log.
fn reject_session(
  tid : String,
  peer : String,
  code : @lib.ErrorCode,
  message : String,
) -> Unit {
  try {
    let socket = @lib.SocketSession::new(tid, peer)
    let error = @lib.peer_error(code, message)
    socket.send(@lib.encode(@lib.to_error_packet(error)))
    socket.close()
  } catch {
    _ => ()
  }
}

///|
/// Serves exactly one request on its own TID and logs how it went.
async fn run_session(
  tid : String,
  peer : String,
  request : @lib.Packet,
  files : @lib.HostFileSystem,
  options : @lib.ServerOptions,
) -> Unit {
  let session = @lib.SocketSession::new(tid, peer)
  defer session.close()
  let transfer = @lib.TransferSession::new(session, files, peer, options)
  match transfer.serve(request) {
    @lib.SessionOutcome::Read(bytes) => println("\{peer}: sent \{bytes} bytes")
    @lib.SessionOutcome::Written(bytes) =>
      println("\{peer}: received \{bytes} bytes")
    @lib.SessionOutcome::Failed(error) =>
      eprintln("\{peer}: \{error.message()}")
  }
}

///|
/// Reads a file from the host, translating an OS error into a CLI message.
async fn read_local(path : String) -> Result[Bytes, CliError] {
  Ok(@fs.read_file(path).binary()) catch {
    _ => Err(CliError("cannot read \{path}"))
  }
}

///|
/// Writes a file on the host, creating or truncating it.
async fn write_local(path : String, payload : Bytes) -> Result[Unit, CliError] {
  try {
    @fs.write_file(path, payload)
    Ok(())
  } catch {
    _ => Err(CliError("cannot write \{path}"))
  }
}

///|
/// The message a failed client transfer prints.
fn describe_client_error(error : @lib.ClientError) -> CliError {
  match error {
    @lib.ClientError::PeerError(code, message) =>
      CliError("peer error (\{error_code_text(code)}): \{message}")
    @lib.ClientError::Timeout => CliError("timed out waiting for the peer")
    @lib.ClientError::Protocol(message) =>
      CliError("protocol error: \{message}")
    @lib.ClientError::BadRequest(message) => CliError("bad request: \{message}")
  }
}

///|
/// The numeric code of an ERROR packet, spelled for a human.
///
/// Hand-written rather than reusing the wire code so the CLI never depends on
/// a library-internal helper just to print a number.
fn error_code_text(code : @lib.ErrorCode) -> String {
  match code {
    @lib.ErrorCode::Undefined => "0 undefined"
    @lib.ErrorCode::FileNotFound => "1 file not found"
    @lib.ErrorCode::AccessViolation => "2 access violation"
    @lib.ErrorCode::DiskFull => "3 disk full"
    @lib.ErrorCode::IllegalOperation => "4 illegal operation"
    @lib.ErrorCode::UnknownTransferId => "5 unknown transfer id"
    @lib.ErrorCode::FileAlreadyExists => "6 file already exists"
    @lib.ErrorCode::NoSuchUser => "7 no such user"
    @lib.ErrorCode::OptionNegotiationFailed => "8 option negotiation failed"
  }
}

///|
/// The usage text, printed for `--help` and for a bad command line.
fn print_usage() -> Unit {
  println(
    "moon-tftp \{version} — TFTP (RFC 1350/2347/2348/2349) client and server",
  )
  println("")
  println("usage:")
  println("  moon-tftp get <host:port> <remote> [local] [options]")
  println("  moon-tftp put <host:port> <local> [remote] [options]")
  println("  moon-tftp serve [--root DIR] [--port N] [--allow-overwrite]")
  println("                  [--max-sessions N]")
  println("")
  println("options for get / put:")
  println("  --blksize N    negotiated block size (default 512)")
  println("  --timeout N    per-packet timeout in seconds (default 5)")
  println("  --retries N    retransmissions before giving up (default 6)")
  println("  --netascii     use netascii mode instead of octet")
  println("")
  println("examples:")
  println("  moon-tftp get 192.168.1.10:69 boot.img")
  println("  moon-tftp put 192.168.1.10:69 ./boot.img boot.img --blksize 1428")
  println("  moon-tftp serve --root ./tftpboot --port 6969 --allow-overwrite")
}
