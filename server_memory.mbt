///|
/// An in-memory `FileSystem`, so a whole server session runs without a disk.
///
/// The point of this backend is not convenience: it is that a host out of
/// space, or one that refuses a file, is exactly the branch a real filesystem
/// will not produce on demand. Here they are just a field.

///|
/// A filesystem whose files live in memory.
pub struct MemoryFileSystem {
  /// Stored files, by path.
  files : Map[String, Bytes]
  /// Paths that behave as directories, for the planner's directory rule.
  directories : Map[String, Unit]
  /// Every path `read` was asked for, in order, so a test can assert that a
  /// refused request never touched the backend at all. Appended to, never
  /// reassigned, so the array itself is not `mut`.
  read_log : Array[String]
  /// Every path `write` was asked for, in order, for the same reason.
  write_log : Array[String]
  /// Makes every write fail with ERROR 3, to exercise the disk-full path.
  mut disk_full : Bool
  /// Makes every read fail with ERROR 1, to exercise the missing-file path.
  mut read_fails : Bool
}

///|
/// An empty in-memory filesystem.
pub fn MemoryFileSystem::new() -> MemoryFileSystem {
  {
    files: {},
    directories: {},
    read_log: [],
    write_log: [],
    disk_full: false,
    read_fails: false,
  }
}

///|
/// Puts `payload` at `path` as if it had been written there before.
pub fn MemoryFileSystem::put(
  self : MemoryFileSystem,
  path : String,
  payload : Bytes,
) -> Unit {
  self.files[path] = payload
}

///|
/// The bytes stored at `path`, for a test that wants to look at them.
pub fn MemoryFileSystem::get(self : MemoryFileSystem, path : String) -> Bytes? {
  self.files.get(path)
}

///|
/// Whether `path` is present.
pub fn MemoryFileSystem::has(self : MemoryFileSystem, path : String) -> Bool {
  self.files.contains(path)
}

///|
/// Makes `path` behave as a directory.
///
/// Nothing is stored there: the only thing a directory changes is the answer
/// `is_directory` gives, which is exactly the input the planner's rule needs.
/// The real backend reports directories because a host has them; this one
/// reports the ones a test declares.
pub fn MemoryFileSystem::declare_directory(
  self : MemoryFileSystem,
  path : String,
) -> Unit {
  self.directories[path] = ()
}

///|
/// Every path a read was attempted on, in order.
pub fn MemoryFileSystem::reads(self : MemoryFileSystem) -> Array[String] {
  self.read_log.copy()
}

///|
/// Every path a write was attempted on, in order.
pub fn MemoryFileSystem::writes(self : MemoryFileSystem) -> Array[String] {
  self.write_log.copy()
}

///|
/// Every path currently stored.
pub fn MemoryFileSystem::paths(self : MemoryFileSystem) -> Array[String] {
  self.files.keys().collect()
}

///|
/// Makes every subsequent write report a full disk.
pub fn MemoryFileSystem::make_full(self : MemoryFileSystem) -> Unit {
  self.disk_full = true
}

///|
/// Makes every subsequent read report a missing file.
pub fn MemoryFileSystem::break_reads(self : MemoryFileSystem) -> Unit {
  self.read_fails = true
}

///|
pub extend MemoryFileSystem with FileSystem::{read, write, exists, is_directory}

///|
pub impl FileSystem for MemoryFileSystem with fn read(self, path) {
  self.read_log.push(path)
  if self.read_fails {
    return Err(FileNotFound("read \{path}"))
  }
  match self.files.get(path) {
    Some(payload) => Ok(payload)
    None => Err(FileNotFound("read \{path}"))
  }
}

///|
pub impl FileSystem for MemoryFileSystem with fn write(self, path, payload) {
  self.write_log.push(path)
  if self.disk_full {
    return Err(DiskFull("write \{path}"))
  }
  self.files[path] = payload
  Ok(())
}

///|
pub impl FileSystem for MemoryFileSystem with fn exists(self, path) {
  ignore(self)
  self.files.contains(path)
}

///|
pub impl FileSystem for MemoryFileSystem with fn is_directory(self, path) {
  // Only the directories a test declared: a stored path is a file, and the
  // empty in-memory tree has no directories of its own.
  self.directories.contains(path)
}
