## Store (uncompressed) encoder — RFC 7932 §11.1
## Produces universally decodable stream with WBITS=16 (or 10..24).
import bitwriter, utils, simd

const StoreChunkSize* = 1 shl 16  # 65536, recommended; cap is 1<<24

proc encodeWindowBits(bw: var BitWriter, wbits: int) =
  ## Inverse of decodeWindowBits (decode.nim:202). wbits in 10..24, 16 is most common.
  if wbits == 16:
    bw.writeBits(1, 0)
  elif wbits >= 18 and wbits <= 24:
    # 1 + (wbits-17) in 3 bits
    bw.writeBits(1, 1)
    bw.writeBits(3, (wbits - 17).uint32)
  elif wbits == 17:
    # 1, 000, 000
    bw.writeBits(1, 1)
    bw.writeBits(3, 0)
    bw.writeBits(3, 0)
  elif wbits >= 10 and wbits <= 15:
    # 1, 000, M where M = wbits-8
    bw.writeBits(1, 1)
    bw.writeBits(3, 0)
    bw.writeBits(3, (wbits - 8).uint32)
  else:
    raise newException(ValueError, "unsupported wbits " & $wbits & " (expected 10..24)")

proc encodeBlockLen(bw: var BitWriter, blockLen: int) =
  ## Encode blockLen via MNIBBLES + nibbles LSB-first of blockLen-1.
  ## blockLen in 1..1<<24, nibbles 4..6 minimal, no exuberant zero top nibble.
  assert blockLen >= 1 and blockLen <= (1 shl 24)
  let v = blockLen - 1
  var nibbles = 4
  while nibbles < 6 and v >= (1 shl (nibbles * 4)):
    nibbles.inc
  # Minimal already ensures top nibble !=0 when nibbles>4
  bw.writeBits(2, (nibbles - 4).uint32)
  for i in 0..<nibbles:
    bw.writeBits(4, ((v shr (i * 4)) and 0xF).uint32)

proc compressStoreImpl(data: openArray[byte], wbits: int): seq[byte] =
  if wbits < 10 or wbits > 24:
    raise newException(ValueError, "wbits out of range 10..24")
  var bw = initBitWriter()
  encodeWindowBits(bw, wbits)

  if data.len == 0:
    bw.writeBits(1, 1)
    bw.writeBits(1, 1)
    bw.emitByteBoundaryZeroPad()
    return bw.toSeq()

  var pos = 0
  while pos < data.len:
    let remaining = data.len - pos
    let chunk = if remaining > StoreChunkSize: StoreChunkSize else: remaining
    bw.writeBits(1, 0)
    encodeBlockLen(bw, chunk)
    bw.writeBits(1, 1)
    bw.emitByteBoundaryZeroPad()
    let oldLen = bw.outBuf.len
    bw.outBuf.setLen(oldLen + chunk)
    copyMemSimd(addr bw.outBuf[oldLen], unsafeAddr data[pos], chunk)
    pos += chunk

  bw.writeBits(1, 1)
  bw.writeBits(1, 1)
  bw.emitByteBoundaryZeroPad()
  result = bw.toSeq()

proc compressStore*(data: openArray[byte], wbits = 16): seq[byte] =
  ## One-shot Store encoder. wbits 10..24 (default 16) — universally decodable.
  ## Each chunk ≤ 64 KiB, emitted as isLast=0 + isUncompressed=1, plus final empty block.
  compressStoreImpl(data, wbits)

proc compressStore*(data: string, wbits = 16): string =
  let tmp = compressStoreImpl(toBytes(data), wbits)
  result = newString(tmp.len)
  for i, c in tmp: result[i] = char(c)

proc compressStoreToString*(data: openArray[byte], wbits = 16): string =
  let tmp = compressStoreImpl(data, wbits)
  result = newString(tmp.len)
  for i, c in tmp: result[i] = char(c)
