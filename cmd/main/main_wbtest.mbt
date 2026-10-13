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
/// The number the CLI prints as the default and the number the library uses
/// have to be the same one: README, `--help` and `ServerOptions::default()`
/// all quote it, and when they drifted apart (32 vs 64) nothing caught it.
test "the CLI's default session ceiling is the library's" {
  match Command::parse("serve", []) {
    Ok(Serve(args)) =>
      assert_eq(args.max_sessions, @lib.ServerOptions::default().max_sessions())
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
  match Command::parse("get", ["h:69", "a", "b", "c"]) {
    Err(CliError(message)) => assert_true(message.contains("at most"))
    _ => fail("expected a parse error")
  }
  match Command::parse("put", ["h:69", "a", "b", "c"]) {
    Err(CliError(message)) => assert_true(message.contains("at most"))
    _ => fail("expected a parse error")
  }
  // A single positional is one short in both directions, and the message
  // names what is missing rather than repeating "at least".
  match Command::parse("put", ["h:69"]) {
    Err(CliError(message)) => assert_true(message.contains("local file name"))
    _ => fail("expected a parse error")
  }
  match Command::parse("put", []) {
    Err(CliError(message)) => assert_true(message.contains("at least"))
    _ => fail("expected a parse error")
  }
  match Command::parse("get", ["h:69", "a", "b"]) {
    Ok(Get(args)) => assert_eq(args.local_file, "b")
    _ => fail("expected three positionals to be accepted")
  }
}

///|
test "serve refuses a missing value and a bad number for each numeric flag" {
  // A flag at the end of the argument list has no value to take.
  match Command::parse("serve", ["--root"]) {
    Err(CliError(message)) => assert_true(message.contains("--root"))
    _ => fail("expected a parse error")
  }
  match Command::parse("serve", ["--port", "http"]) {
    Err(CliError(message)) => assert_true(message.contains("--port"))
    _ => fail("expected a parse error")
  }
  match Command::parse("serve", ["--max-sessions", "0"]) {
    Err(CliError(message)) => assert_true(message.contains("positive"))
    _ => fail("expected a parse error")
  }
  match Command::parse("serve", ["--max-sessions", "many"]) {
    Err(CliError(message)) => assert_true(message.contains("--max-sessions"))
    _ => fail("expected a parse error")
  }
  // An unknown flag is refused rather than treated as a root path.
  match Command::parse("serve", ["--turbo"]) {
    Err(CliError(message)) => assert_true(message.contains("--turbo"))
    _ => fail("expected a parse error")
  }
}

///|
test "a bare `-v` is a version request, not a transfer flag" {
  // `-v` and `--version` are the same request spelled two ways; the parser
  // only sees the subcommand, so the flag form is what `main` checks.
  match Command::parse("-v", []) {
    Err(CliError(message)) => assert_true(message.contains("-v"))
    _ => fail("expected a parse error")
  }
}
