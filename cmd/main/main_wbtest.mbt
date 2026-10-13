///|
/// The CLI's argument parser, tested without a socket or a command line.
///
/// Parsing is the one part of `main.mbt` that is pure logic, so it is the one
/// part worth asserting on here: the IO glue below it is exercised by the
/// end-to-end runs recorded in `docs/interop.md`.

///|
test "parse_int accepts decimal and rejects the rest" {
  debug_inspect(parse_int("1428"), content="Some(1428)")
  debug_inspect(parse_int(""), content="None")
  debug_inspect(parse_int("12a"), content="None")
  debug_inspect(parse_int("-3"), content="None")
}

///|
test "get takes a remote and defaults the local name to it" {
  match Command::parse("get", ["127.0.0.1:69", "boot.img"]) {
    Ok(Get(args)) => {
      assert_eq(args.remote, "127.0.0.1:69")
      assert_eq(args.remote_file, "boot.img")
      assert_eq(args.local_file, "boot.img")
    }
    _ => fail("expected a get command")
  }
}

///|
test "get takes an explicit local path" {
  match Command::parse("get", ["h:69", "remote.bin", "./out.bin"]) {
    Ok(Get(args)) => {
      assert_eq(args.remote_file, "remote.bin")
      assert_eq(args.local_file, "./out.bin")
    }
    _ => fail("expected a get command")
  }
}

///|
test "put defaults the remote name to the local base name" {
  match Command::parse("put", ["h:69", "./dir/boot.img"]) {
    Ok(Put(args)) => {
      assert_eq(args.local_file, "./dir/boot.img")
      assert_eq(args.remote_file, "boot.img")
    }
    _ => fail("expected a put command")
  }
}

///|
test "put takes an explicit remote name" {
  match Command::parse("put", ["h:69", "./boot.img", "remote.img"]) {
    Ok(Put(args)) => {
      assert_eq(args.local_file, "./boot.img")
      assert_eq(args.remote_file, "remote.img")
    }
    _ => fail("expected a put command")
  }
}

///|
test "transfer flags are folded into the client options" {
  match
    Command::parse("get", [
      "h:69", "f", "--blksize", "1428", "--timeout", "3", "--retries", "2", "--netascii",
    ]) {
    Ok(Get(args)) => {
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
  match Command::parse("get", ["h:69", "f", "--blksize", "big"]) {
    Err(CliError(message)) => assert_true(message.contains("--blksize"))
    _ => fail("expected a parse error")
  }
}

///|
test "a flag without a value is refused" {
  match Command::parse("get", ["h:69", "f", "--timeout"]) {
    Err(CliError(message)) => assert_true(message.contains("--timeout"))
    _ => fail("expected a parse error")
  }
}

///|
test "an unknown flag is refused" {
  match Command::parse("get", ["h:69", "f", "--turbo"]) {
    Err(CliError(message)) => assert_true(message.contains("--turbo"))
    _ => fail("expected a parse error")
  }
}

///|
test "too few positionals is refused" {
  match Command::parse("get", ["h:69"]) {
    Err(CliError(_)) => ()
    _ => fail("expected a parse error")
  }
  match Command::parse("get", []) {
    Err(CliError(_)) => ()
    _ => fail("expected a parse error")
  }
}

///|
test "an unknown subcommand is refused" {
  match Command::parse("frobnicate", []) {
    Err(CliError(message)) => assert_true(message.contains("frobnicate"))
    _ => fail("expected a parse error")
  }
}

///|
test "serve defaults are the RFC 1350 ones" {
  match Command::parse("serve", []) {
    Ok(Serve(args)) => {
      assert_eq(args.root, ".")
      assert_eq(args.port, 69)
      assert_eq(args.write_policy, @lib.WritePolicy::CreateOnly)
      assert_eq(args.max_sessions, 32)
    }
    _ => fail("expected a serve command")
  }
}

///|
test "serve flags override the defaults" {
  match
    Command::parse("serve", [
      "--root", "/srv/tftp", "--port", "6969", "--max-sessions", "8", "--allow-overwrite",
    ]) {
    Ok(Serve(args)) => {
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
  match Command::parse("serve", ["--port", "70000"]) {
    Err(CliError(message)) => assert_true(message.contains("between"))
    _ => fail("expected a parse error")
  }
  match Command::parse("serve", ["stray"]) {
    Err(CliError(_)) => ()
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
  assert_true(check_capacity(Some(2048), 2048, args) is Ok(_))
  // The peer agreed to less than we sent: the far side will truncate, and a
  // stop-and-wait protocol has no other way to say so.
  match check_capacity(Some(2048), 4096, args) {
    Err(CliError(message)) =>
      assert_true(message.contains("capacity check failed"))
    _ => fail("expected a capacity mismatch to fail")
  }
  // No tsize negotiated: the option is optional, so it is not an error.
  assert_true(check_capacity(None, 4096, args) is Ok(_))
}

///|
test "a progress line only prints when the percentage moves" {
  // The printer is a state machine on the last printed percentage, so the
  // reporting rule can be checked without a terminal or a transfer.
  let printer = ProgressPrinter::new("f")
  assert_eq(printer.last_percent, -1)
  // An unknown total (no tsize) is not reportable, and must leave the state
  // untouched so the first real percentage still prints.
  printer.report(@lib.Progress::{ done: 10, total: 0, })
  assert_eq(printer.last_percent, -1)
  printer.report(@lib.Progress::{ done: 25, total: 100, })
  assert_eq(printer.last_percent, 25)
  // Same percentage again: no second line.
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
