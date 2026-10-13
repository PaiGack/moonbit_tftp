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
  /// Makes every write fail with ERROR 3, to exercise the disk-full path.
  mut disk_full : Bool
  /// Makes every read fail with ERROR 1, to exercise the missing-file path.
  mut read_fails : Bool
}

///|
/// An empty in-memory filesystem.
pub fn MemoryFileSystem::new() -> MemoryFileSystem {
  { files: {}, disk_full: false, read_fails: false, }
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
pub extend MemoryFileSystem with FileSystem::{read, write, exists}

///|
pub impl FileSystem for MemoryFileSystem with fn read(self, path) {
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
  ignore(path)
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
