## High-level file API — compress/decompress via Store (RFC 7932 §11.1)
## Provides path-based helpers and memfiles variants with buffer reuse.
import std/os
import utils, encode_store, decode

# -- in-memory aliases (high-level) --

proc compress*(data: openArray[byte], wbits = 16): seq[byte] =
  ## High-level alias for Store encoder.
  compressStore(data, wbits)

proc compress*(data: string, wbits = 16): string =
  compressStore(data, wbits)

# -- compressFile / decompressFile (regular file I/O) --

proc compressFile*(srcPath, dstPath: string, wbits = 16) =
  ## Read `srcPath` and write Store-compressed `dstPath`.
  ## Uses regular file I/O (readFile) for simplicity.
  if not fileExists(srcPath):
    raise newException(IOError, "file not found: " & srcPath)
  let s = readFile(srcPath)
  let enc = compressStore(s, wbits)
  writeFile(dstPath, enc)

proc decompressFile*(srcPath, dstPath: string) =
  ## Read Brotli-compressed `srcPath` and write decompressed `dstPath`.
  if not fileExists(srcPath):
    raise newException(IOError, "file not found: " & srcPath)
  let c = readFile(srcPath)
  let dec = BrotliDecompress(toBytes(c))
  writeFile(dstPath, toString(dec))

# -- memfiles variants (zero-copy read) --

proc compressFromFile*(srcPath: string, wbits = 16): seq[byte] =
  ## Read `srcPath` via mmap (memfiles) and compress with Store encoder.
  ## Encoding itself is via memfiles — zero-copy read, no intermediate string copy.
  if not fileExists(srcPath):
    raise newException(IOError, "file not found: " & srcPath)
  var v = openMemFile(srcPath)
  defer: v.close()
  if v.size == 0:
    compressStore([], wbits)
  else:
    compressStore(v.asOpenArray, wbits)

proc compressFromFileToString*(srcPath: string, wbits = 16): string =
  ## String variant for memfiles compress.
  let b = compressFromFile(srcPath, wbits)
  toString(b)

proc compressFromFile*(srcPath: string, wbits: int, buf: var seq[byte]) =
  ## Reuse `buf` to avoid allocation for intermediate read.
  ## Fills `buf` with compressed bytes.
  if not fileExists(srcPath):
    raise newException(IOError, "file not found: " & srcPath)
  var v = openMemFile(srcPath)
  defer: v.close()
  let enc =
    if v.size == 0: compressStore([], wbits)
    else: compressStore(v.asOpenArray, wbits)
  if buf.len != enc.len:
    buf.setLen(enc.len)
  if enc.len > 0:
    copyMem(addr buf[0], unsafeAddr enc[0], enc.len)

proc decompressFromFile*(srcPath: string): seq[byte] =
  ## Read Brotli file via mmap and decompress. Zero-copy read path.
  if not fileExists(srcPath):
    raise newException(IOError, "file not found: " & srcPath)
  var v = openMemFile(srcPath)
  defer: v.close()
  if v.size == 0:
    BrotliDecompressBorrowed([])
  else:
    BrotliDecompressBorrowed(v.asOpenArray)

proc decompressFromFileToString*(srcPath: string): string =
  let b = decompressFromFile(srcPath)
  toString(b)

proc decompressFromFile*(srcPath: string, buf: var seq[byte]) =
  ## Reuse `buf` for decompressed output.
  let dec = decompressFromFile(srcPath)
  if buf.len != dec.len:
    buf.setLen(dec.len)
  if dec.len > 0:
    copyMem(addr buf[0], unsafeAddr dec[0], dec.len)

# -- additional helpers with explicit buffer reuse --

proc readMemFileCompress*(srcPath: string, wbits: int, outBuf: var seq[byte]) =
  ## Convenience: compress via memfiles into reusable outBuf.
  compressFromFile(srcPath, wbits, outBuf)

proc readMemFileDecompress*(srcPath: string, outBuf: var seq[byte]) =
  decompressFromFile(srcPath, outBuf)
