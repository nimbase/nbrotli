import std/[os, memfiles]

proc toBytes*(s: string): seq[byte] =
  ## Convert string to seq[byte] without unsafe cast.
  result.setLen(s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc toBytes*(s: openArray[byte]): seq[byte] =
  result.setLen(s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc toString*(b: openArray[byte]): string =
  result.setLen(b.len)
  if b.len > 0:
    copyMem(addr result[0], unsafeAddr b[0], b.len)

proc toBytesReuse*(s: string, buf: var seq[byte]) =
  ## Fill `buf` with `s` bytes, reusing allocation.
  if buf.len != s.len:
    buf.setLen(s.len)
  if s.len > 0:
    copyMem(addr buf[0], unsafeAddr s[0], s.len)

proc toBytesReuse*(s: openArray[byte], buf: var seq[byte]) =
  if buf.len != s.len:
    buf.setLen(s.len)
  if s.len > 0:
    copyMem(addr buf[0], unsafeAddr s[0], s.len)

proc toStringReuse*(b: openArray[byte], buf: var string) =
  if buf.len != b.len:
    buf.setLen(b.len)
  if b.len > 0:
    copyMem(addr buf[0], unsafeAddr b[0], b.len)

# --- MemFile view (zero-copy mmap) ---

type MemFileView* = object
  mf*: MemFile
  size*: int
  data*: ptr UncheckedArray[byte]
  isOpen*: bool

proc openMemFile*(path: string): MemFileView =
  ## Open file via mmap. Caller must `close` when done.
  ## Raises IOError if file cannot be opened.
  if not fileExists(path):
    raise newException(IOError, "file not found: " & path)
  let sz = getFileSize(path)
  if sz == 0:
    result.size = 0
    result.data = nil
    result.isOpen = false
    return
  var mf: MemFile
  try:
    mf = memfiles.open(path, fmRead)
  except CatchableError as e:
    raise newException(IOError, "openMemFile failed: " & e.msg)
  result.mf = mf
  result.size = mf.size
  result.isOpen = true
  if mf.size > 0:
    result.data = cast[ptr UncheckedArray[byte]](mf.mem)
  else:
    result.data = nil

proc close*(v: var MemFileView) =
  if v.isOpen:
    memfiles.close(v.mf)
    v.isOpen = false
    v.data = nil
    v.size = 0

template asOpenArray*(v: MemFileView): openArray[byte] =
  ## Zero-copy view into mmap region. Valid only while `v` is open.
  toOpenArray(v.data, 0, v.size - 1)

# --- readMemFile with buffer reuse ---

proc readMemFile*(path: string): seq[byte] =
  ## Allocating variant: reads entire file via mmap when possible.
  if not fileExists(path):
    raise newException(IOError, "file not found: " & path)
  var v = openMemFile(path)
  defer: v.close()
  result.setLen(v.size)
  if v.size > 0:
    copyMem(addr result[0], v.data, v.size)

proc readMemFile*(path: string, buf: var seq[byte]) =
  ## Reuse `buf` to avoid allocation. Fills `buf` with file contents.
  ## `buf` is resized to file size if needed, otherwise reused in-place.
  if not fileExists(path):
    raise newException(IOError, "file not found: " & path)
  var v = openMemFile(path)
  defer: v.close()
  if buf.len != v.size:
    buf.setLen(v.size)
  if v.size > 0:
    copyMem(addr buf[0], v.data, v.size)

proc readMemFileInto*(path: string, buf: var seq[byte]): int =
  ## Alias that returns size; fills `buf`.
  readMemFile(path, buf)
  result = buf.len
