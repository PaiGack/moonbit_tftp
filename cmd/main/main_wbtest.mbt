///|
/// The CLI's argument parser, tested without a socket or a command line.
///
/// Parsing is the one part of `main.mbt` that is pure logic, so it is the one
/// part worth asserting on here: the IO glue below it is exercised by the
/// end-to-end runs recorded in `docs/interop.md`.

///|
/// The parser's answer, as an `Option`: `Some` for a command line that parsed,
/// `None` for one that did not. The parser raises `ParseError` (that is what
/// `main` catches to exit 2), so a test that wants to `match` on the answer
/// has to turn it into data first, and an `Option` is the one shape that does
/// not trip the "return a `Result` only for real failures" warning.
fn parsed(name : String, args : Array[String]) -> Command? {
  let answer = Some(Command::parse(name, args)) catch { ParseError(_) => None }
  answer
}

///|
/// The message a rejected command line prints, or `None` when it parses.
fn parse_error_of(name : String, args : Array[String]) -> String? {
  let message = try {
    ignore(Command::parse(name, args))
    None
  } catch {
    ParseError(message) => Some(message)
  }
  message
}

///|
test "parse_int accepts decimal and rejects the rest" {
  debug_inspect(parse_int("1428"), content="Some(1428)")
  debug_inspect(parse_int(""), content="None")
  debug_inspect(parse_int("12a"), content="None")
  debug_inspect(parse_int("-3"), content="None")
}

///|
test "get takes a remote and defaults the local name to it" {
  match parsed("get", ["127.0.0.1:69", "boot.img"]) {
    Some(Get(args)) => {
      assert_eq(args.remote, "127.0.0.1:69")
      assert_eq(args.remote_file, "boot.img")
      assert_eq(args.local_file, "boot.img")
    }
    _ => fail("expected a get command")
  }
}

///|
test "get takes an explicit local path" {
  match parsed("get", ["h:69", "remote.bin", "./out.bin"]) {
    Some(Get(args)) => {
      assert_eq(args.remote_file, "remote.bin")
      assert_eq(args.local_file, "./out.bin")
    }
    _ => fail("expected a get command")
  }
}

///|
test "put defaults the remote name to the local base name" {
  match parsed("put", ["h:69", "./dir/boot.img"]) {
    Some(Put(args)) => {
      assert_eq(args.local_file, "./dir/boot.img")
      assert_eq(args.remote_file, "boot.img")
    }
    _ => fail("expected a put command")
  }
}

///|
test "put takes an explicit remote name" {
  match parsed("put", ["h:69", "./boot.img", "remote.img"]) {
    Some(Put(args)) => {
      assert_eq(args.local_file, "./boot.img")
      assert_eq(args.remote_file, "remote.img")
    }
    _ => fail("expected a put command")
  }
}

///|
test "transfer flags are folded into the client options" {
  match
    parsed("get", [
      "h:69", "f", "--blksize", "1428", "--timeout", "3", "--retries", "2", "--netascii",
    ]) {
    Some(Get(args)) => {
      assert_eq(args.options.block_size(), 1428)
      assert_eq(args.options.timeout_seconds(), 3)
      assert_eq(args.options.max_retries(), 2)
      assert_eq(args.options.mode(), @lib.Mode::Netascii)
    }
    _ => fail("expected a get command")
  }
}

///|
test "a non-numeric flag value is refused" {
  assert_true(
    parse_error_of("get", ["h:69", "f", "--blksize", "big"])
    .unwrap()
    .contains("--blksize"),
  )
}

///|
test "a flag without a value is refused" {
  assert_true(
    parse_error_of("get", ["h:69", "f", "--timeout"])
    .unwrap()
    .contains("--timeout"),
  )
}

///|
test "an unknown flag is refused" {
  assert_true(
    parse_error_of("get", ["h:69", "f", "--turbo"]).unwrap().contains("--turbo"),
  )
}

///|
test "too few positionals is refused" {
  match parsed("get", ["h:69"]) {
    None => ()
    _ => fail("expected a parse error")
  }
  match parsed("get", []) {
    None => ()
    _ => fail("expected a parse error")
  }
}

///|
test "an unknown subcommand is refused" {
  assert_true(parse_error_of("frobnicate", []).unwrap().contains("frobnicate"))
}

///|
test "serve defaults are the RFC 1350 ones" {
  match parsed("serve", []) {
    Some(Serve(args)) => {
      assert_eq(args.root, ".")
      assert_eq(args.port, 69)
      assert_eq(args.write_policy, @lib.WritePolicy::CreateOnly)
      assert_eq(args.max_sessions, 32)
    }
    _ => fail("expected a serve command")
  }
}

///|
/// The number the CLI prints as the default and the number the library uses
/// have to be the same one: README, `--help` and `ServerOptions::default()`
/// all quote it, and when they drifted apart (32 vs 64) nothing caught it.
test "the CLI's default session ceiling is the library's" {
  match parsed("serve", []) {
    Some(Serve(args)) =>
      assert_eq(args.max_sessions, @lib.ServerOptions::default().max_sessions())
    _ => fail("expected a serve command")
  }
}

///|
test "serve flags override the defaults" {
  match
    parsed("serve", [
      "--root", "/srv/tftp", "--port", "6969", "--max-sessions", "8", "--allow-overwrite",
    ]) {
    Some(Serve(args)) => {
      assert_eq(args.root, "/srv/tftp")
      assert_eq(args.port, 6969)
      assert_eq(args.max_sessions, 8)
      assert_eq(args.write_policy, @lib.WritePolicy::AllowOverwrite)
    }
    _ => fail("expected a serve command")
  }
}

///|
test "serve refuses an out-of-range port and stray positionals" {
  assert_true(
    parse_error_of("serve", ["--port", "70000"]).unwrap().contains("between"),
  )
  match parsed("serve", ["stray"]) {
    None => ()
    _ => fail("expected a parse error")
  }
}

///|
test "base_name keeps the last path segment" {
  assert_eq(base_name("boot.img"), "boot.img")
  assert_eq(base_name("./dir/boot.img"), "boot.img")
  assert_eq(base_name("a/b/c.bin"), "c.bin")
}

///|
test "a negotiated tsize must match what was sent" {
  let args : TransferArgs = {
    remote: "h:69",
    remote_file: "f",
    local_file: "f",
    options: @lib.ClientOptions::default(),
  }
  // Same size: the peer took the whole file.
  check_capacity(Some(2048), 2048, args) catch {
    _ => fail("a matching tsize must pass")
  }
  // The peer agreed to less than we sent: the far side will truncate, and a
  // stop-and-wait protocol has no other way to say so.
  check_capacity(Some(2048), 4096, args) catch {
    CliError(message) => assert_true(message.contains("capacity check failed"))
  }
  // No tsize negotiated: the option is optional, so it is not an error.
  check_capacity(None, 4096, args) catch {
    _ => fail("an absent tsize must pass")
  }
}

///|
test "a progress line only prints when the percentage moves" {
  // The printer is a state machine on the last printed percentage, so the
  // reporting rule can be checked without a terminal or a transfer. The state
  // has to live *inside* the printer: the callback the library invokes returns
  // `Unit`, so nothing can hand a fresh printer back in.
  let printer = ProgressPrinter::new("f")
  assert_eq(printer.last_percent, -1)
  // An unknown total (no tsize) is not reportable, and must leave the state
  // untouched so the first real percentage still prints.
  printer.report(@lib.Progress::{ done: 10, total: 0, })
  assert_eq(printer.last_percent, -1)
  printer.report(@lib.Progress::{ done: 25, total: 100, })
  assert_eq(printer.last_percent, 25)
  // Same percentage again: the state is the printer's own, so this second
  // report sees the 25% already recorded and prints nothing.
  printer.report(@lib.Progress::{ done: 25, total: 100, })
  assert_eq(printer.last_percent, 25)
  printer.report(@lib.Progress::{ done: 80, total: 100, })
  assert_eq(printer.last_percent, 80)
  // A netascii decode can report more local bytes than the wire total; the
  // percentage is clamped so it can never print past 100.
  printer.report(@lib.Progress::{ done: 120, total: 100, })
  assert_eq(printer.last_percent, 100)
}

///|
test "error codes are spelled for humans" {
  assert_eq(error_code_text(@lib.ErrorCode::FileNotFound), "1 file not found")
  assert_eq(
    error_code_text(@lib.ErrorCode::UnknownTransferId),
    "5 unknown transfer id",
  )
}

///|
test "too many positionals is refused in both directions" {
  // The `get` and `put` shapes differ in what a third positional means, so
  // each has its own "too many" answer rather than one generic message.
  assert_true(
    parse_error_of("get", ["h:69", "a", "b", "c"]).unwrap().contains("at most"),
  )
  assert_true(
    parse_error_of("put", ["h:69", "a", "b", "c"]).unwrap().contains("at most"),
  )
  // A single positional is one short in both directions, and the message
  // names what is missing rather than repeating "at least".
  assert_true(
    parse_error_of("put", ["h:69"]).unwrap().contains("local file name"),
  )
  assert_true(parse_error_of("put", []).unwrap().contains("at least"))
  match parsed("get", ["h:69", "a", "b"]) {
    Some(Get(args)) => assert_eq(args.local_file, "b")
    _ => fail("expected three positionals to be accepted")
  }
}

///|
test "serve refuses a missing value and a bad number for each numeric flag" {
  // A flag at the end of the argument list has no value to take.
  assert_true(parse_error_of("serve", ["--root"]).unwrap().contains("--root"))
  assert_true(
    parse_error_of("serve", ["--port", "http"]).unwrap().contains("--port"),
  )
  assert_true(
    parse_error_of("serve", ["--max-sessions", "0"])
    .unwrap()
    .contains("positive"),
  )
  assert_true(
    parse_error_of("serve", ["--max-sessions", "many"])
    .unwrap()
    .contains("--max-sessions"),
  )
  // An unknown flag is refused rather than treated as a root path.
  assert_true(parse_error_of("serve", ["--turbo"]).unwrap().contains("--turbo"))
}

///|
test "a bare `-v` is a version request, not a transfer flag" {
  // `-v` and `--version` are the same request spelled two ways; the parser
  // only sees the subcommand, so the flag form is what `main` checks.
  assert_true(parse_error_of("-v", []).unwrap().contains("-v"))
}

///|
test "a blksize outside the RFC range is refused" {
  // The library drops an option it cannot honour, and the client then has to
  // run at the default — which is only safe because the CLI refuses these
  // here, before the request is built. A value this far off is a typo, not a
  // preference.
  for value in ["7", "0", "65465", "70000"] {
    assert_true(
      parse_error_of("get", ["h:69", "f", "--blksize", value])
      .unwrap()
      .contains("between"),
    )
  }
  // The ends of the range are the RFC's own, and must still parse.
  match parsed("get", ["h:69", "f", "--blksize", "8"]) {
    Some(Get(args)) => assert_eq(args.options.block_size(), 8)
    _ => fail("expected --blksize 8 to be accepted")
  }
  match parsed("get", ["h:69", "f", "--blksize", "65464"]) {
    Some(Get(args)) => assert_eq(args.options.block_size(), 65464)
    _ => fail("expected --blksize 65464 to be accepted")
  }
}

///|
test "a timeout outside the RFC range is refused" {
  for value in ["0", "256"] {
    assert_true(
      parse_error_of("get", ["h:69", "f", "--timeout", value])
      .unwrap()
      .contains("between"),
    )
  }
  match parsed("get", ["h:69", "f", "--timeout", "1"]) {
    Some(Get(args)) => assert_eq(args.options.timeout_seconds(), 1)
    _ => fail("expected --timeout 1 to be accepted")
  }
  match parsed("get", ["h:69", "f", "--timeout", "255"]) {
    Some(Get(args)) => assert_eq(args.options.timeout_seconds(), 255)
    _ => fail("expected --timeout 255 to be accepted")
  }
}

///|
test "a retry budget of zero is refused" {
  // `0` retries means one attempt and no second chance, which is not what
  // the flag promises; a negative number does not even reach the wire.
  assert_true(
    parse_error_of("get", ["h:69", "f", "--retries", "0"])
    .unwrap()
    .contains("positive"),
  )
}

///|
test "the reported version comes from moon.mod, not a copy of it" {
  // `--version` used to print a literal that had already drifted a release
  // behind `moon.mod` (0.1.1 against 0.1.2). The value is now generated from
  // the one `moon.mod` by the `gen` rule in `shadow/`, so this test pins the
  // shape rather than the number: a hand-written literal would pass any
  // equality check against itself, but it would not survive the generator
  // being what supplies it.
  let info = @moon_shadow.current()
  assert_eq(version, info.version)
  assert_eq(info.name, "PaiGack/tftp")
  // An empty version would mean the generator never ran and the field fell
  // back to a default, which `--version` would print as `moon-tftp `.
  assert_false(version.is_empty())
  // `build_info()` only compiles because the implementation imports
  // `buildinfo`, which is the half of `shadow/generated.mbt` that 0.3.2 added:
  // if the rule and the import ever drift apart again, this fails to build
  // rather than reporting a version nobody generated.
  let build = @moon_shadow.build()
  assert_true(build.profile == "debug" || build.profile == "release")
}
