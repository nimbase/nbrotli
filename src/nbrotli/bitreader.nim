## LSB-first bit reader — RFC 7932 §1.5.1, mirrors c/dec/bit_reader.h
import simd

const kBitMask*: array[33, uint32] = [
  0x00000000'u32, 0x00000001'u32, 0x00000003'u32, 0x00000007'u32,
  0x0000000F'u32, 0x0000001F'u32, 0x0000003F'u32, 0x0000007F'u32,
  0x000000FF'u32, 0x000001FF'u32, 0x000003FF'u32, 0x000007FF'u32,
  0x00000FFF'u32, 0x00001FFF'u32, 0x00003FFF'u32, 0x00007FFF'u32,
  0x0000FFFF'u32, 0x0001FFFF'u32, 0x0003FFFF'u32, 0x0007FFFF'u32,
  0x000FFFFF'u32, 0x001FFFFF'u32, 0x003FFFFF'u32, 0x007FFFFF'u32,
  0x00FFFFFF'u32, 0x01FFFFFF'u32, 0x03FFFFFF'u32, 0x07FFFFFF'u32,
  0x0FFFFFFF'u32, 0x1FFFFFFF'u32, 0x3FFFFFFF'u32, 0x7FFFFFFF'u32,
  0xFFFFFFFF'u32,
]

func bitMask*(n: uint32): uint32 {.inline.} =
  if n <= 32: kBitMask[n] else: 0xFFFFFFFF'u32

type
  BitReader* = object
    val*: uint64       ## accumulator, low bits are next to read
    bitPos*: int       ## number of valid bits in val (0..64)
    nextIn*: int       ## index into input seq
    guardIn*: int      ## prohibit fast path beyond here
    input*: seq[byte]  ## owned copy
    lastIn*: int       ## input.len
    borrowed*: ptr UncheckedArray[byte] ## zero-copy view (if isBorrowed)
    borrowedLen*: int
    isBorrowed*: bool

const FastInputSlack* = 28

func initBitReader*(data: openArray[byte]): BitReader =
  result.input = @data
  result.lastIn = data.len
  result.nextIn = 0
  result.val = 0
  result.bitPos = 0
  result.isBorrowed = false
  result.borrowed = nil
  result.borrowedLen = 0
  if data.len > FastInputSlack:
    result.guardIn = data.len - FastInputSlack
  else:
    result.guardIn = 0

func initBitReaderBorrowed*(data: openArray[byte]): BitReader =
  ## Zero-copy: does NOT copy data, holds pointer to caller's buffer/mmap.
  ## Caller must keep `data` alive for lifetime of BitReader.
  result.input = @[]
  result.lastIn = data.len
  result.nextIn = 0
  result.val = 0
  result.bitPos = 0
  result.isBorrowed = true
  result.borrowedLen = data.len
  if data.len > 0:
    result.borrowed = cast[ptr UncheckedArray[byte]](unsafeAddr data[0])
  else:
    result.borrowed = nil
  if data.len > FastInputSlack:
    result.guardIn = data.len - FastInputSlack
  else:
    result.guardIn = 0

func getByte*(br: BitReader, idx: int): byte {.inline.} =
  if br.isBorrowed:
    br.borrowed[idx]
  else:
    br.input[idx]

proc feedInput*(br: var BitReader, data: openArray[byte]) =
  ## Append input for streaming; preserves val/bitPos/nextIn/guardIn.
  if data.len == 0: return
  if br.isBorrowed:
    # Materialize borrowed into owned before append
    let prevLen = br.lastIn
    var owned = newSeq[byte](prevLen)
    if prevLen > 0:
      copyMemSimd(addr owned[0], br.borrowed, prevLen)
    br.input = owned
    br.isBorrowed = false
    br.borrowed = nil
    br.borrowedLen = 0
  let oldLen = br.input.len
  br.input.setLen(oldLen + data.len)
  if data.len > 0:
    copyMemSimd(addr br.input[oldLen], unsafeAddr data[0], data.len)
  br.lastIn = br.input.len
  if br.lastIn > FastInputSlack:
    br.guardIn = br.lastIn - FastInputSlack
  else:
    br.guardIn = 0

proc updateGuard*(br: var BitReader) {.inline.} =
  if br.lastIn > FastInputSlack:
    br.guardIn = br.lastIn - FastInputSlack
  else:
    br.guardIn = 0

func warmup*(br: var BitReader): bool =
  ## Ensure accumulator has at least 1 bit; pull up to 7 bytes.
  ## Returns false if no input available.
  while br.bitPos < 8 and br.nextIn < br.lastIn:
    br.val = br.val or (uint64(br.getByte(br.nextIn)) shl br.bitPos)
    br.bitPos += 8
    br.nextIn.inc
  result = br.bitPos > 0 or br.nextIn < br.lastIn or br.bitPos > 0

func availableBits*(br: BitReader): int {.inline.} = br.bitPos

func checkInputAmount*(br: BitReader): bool {.inline.} =
  br.nextIn < br.guardIn

func getAvailableBits*(br: BitReader): uint32 {.inline.} =
  br.bitPos.uint32

func getBitsUnmasked*(br: BitReader): uint64 {.inline.} =
  br.val

func fillBitWindow*(br: var BitReader, n: uint32) {.inline.} =
  ## Ensure at least n bits in accumulator (n <= 24 typical).
  # Fast path: 64-bit preload when guard allows and SIMD enabled (32B alignment not needed for 8B)
  when hasSimdFeature and defined(amd64):
    if br.bitPos <= 56 and br.nextIn + 8 <= br.lastIn and br.nextIn < br.guardIn:
      # Load 8 bytes at once (unaligned)
      let p = if br.isBorrowed: cast[pointer](cast[int](br.borrowed) + br.nextIn)
              else: cast[pointer](addr br.input[br.nextIn])
      let v = cast[ptr uint64](p)[]
      br.val = br.val or (v shl br.bitPos)
      let need = n.int - br.bitPos
      let take = min(8, (need + 7) div 8)
      br.bitPos += take * 8
      br.nextIn += take
      if br.bitPos >= n.int: return
  while br.bitPos < n.int and br.nextIn < br.lastIn:
    br.val = br.val or (uint64(br.getByte(br.nextIn)) shl br.bitPos)
    br.bitPos += 8
    br.nextIn.inc

func fillBitWindow16*(br: var BitReader) {.inline.} =
  fillBitWindow(br, 17)

func getBits*(br: var BitReader, n: uint32): uint32 {.inline.} =
  fillBitWindow(br, n)
  result = (br.val and bitMask(n).uint64).uint32

func get16BitsUnmasked*(br: var BitReader): uint32 {.inline.} =
  fillBitWindow(br, 16)
  result = (br.val and 0xFFFF).uint32

func pullByte*(br: var BitReader): bool {.inline.} =
  if br.nextIn >= br.lastIn: return false
  br.val = br.val or (uint64(br.getByte(br.nextIn)) shl br.bitPos)
  br.bitPos += 8
  br.nextIn.inc
  return true

func dropBits*(br: var BitReader, n: uint32) {.inline.} =
  br.val = br.val shr n
  br.bitPos -= n.int

func takeBits*(br: var BitReader, n: uint32, val: var uint32) {.inline.} =
  val = (br.val and bitMask(n).uint64).uint32
  dropBits(br, n)

func readBits*(br: var BitReader, n: uint32): uint32 {.inline.} =
  fillBitWindow(br, n)
  var v: uint32
  takeBits(br, n, v)
  result = v

func safeGetBits*(br: var BitReader, n: uint32, val: var uint32): bool =
  while br.bitPos < n.int:
    if not pullByte(br): return false
  val = (br.val and bitMask(n).uint64).uint32
  return true

func safeReadBits*(br: var BitReader, n: uint32, val: var uint32): bool =
  if not safeGetBits(br, n, val): return false
  dropBits(br, n)
  return true

func safeReadBitsMaybeZero*(br: var BitReader, n: uint32, val: var uint32): bool =
  if n == 0:
    val = 0
    return true
  return safeReadBits(br, n, val)

func jumpToByteBoundary*(br: var BitReader): bool =
  ## Advance to next byte, check padding bits are zero.
  let pad = br.bitPos and 7
  if pad != 0:
    var v: uint32
    takeBits(br, pad.uint32, v)
    if v != 0: return false
  # normalize: val should only contain bitPos bits
  if br.bitPos < 64:
    br.val = br.val and ((1'u64 shl br.bitPos) - 1)
  return true

func remainingBytes*(br: BitReader): int =
  let avail = br.lastIn - br.nextIn
  result = avail + (br.bitPos shr 3)

func copyBytes*(dst: var seq[byte], dstPos: int, br: var BitReader, n: int) =
  ## Copy n bytes from bitreader (must be byte-aligned) to dst.
  assert br.bitPos == 0 or (br.bitPos and 7) == 0
  var pos = dstPos
  # first drain accumulator bytes
  var remaining = n
  while br.bitPos >= 8 and remaining > 0:
    dst[pos] = byte(br.val and 0xFF)
    br.val = br.val shr 8
    br.bitPos -= 8
    pos.inc
    remaining.dec
  if br.bitPos == 0:
    br.val = 0
  if remaining > 0:
    if br.isBorrowed:
      copyMemSimd(addr dst[pos], addr br.borrowed[br.nextIn], remaining)
    else:
      copyMemSimd(addr dst[pos], addr br.input[br.nextIn], remaining)
    br.nextIn += remaining

func copyBytesToRing*(ring: var seq[byte], ringPos: int, br: var BitReader, n: int) =
  ## Copy into ring buffer slice ring[ringPos .. ringPos+n)
  var remaining = n
  var rp = ringPos
  while br.bitPos >= 8 and remaining > 0:
    ring[rp] = byte(br.val and 0xFF)
    br.val = br.val shr 8
    br.bitPos -= 8
    rp.inc
    remaining.dec
  if br.bitPos == 0:
    br.val = 0
  if remaining > 0:
    if br.isBorrowed:
      copyMemSimd(addr ring[rp], addr br.borrowed[br.nextIn], remaining)
    else:
      copyMemSimd(addr ring[rp], addr br.input[br.nextIn], remaining)
    br.nextIn += remaining

# For debugging parity with C logging
func bitReaderAvailIn*(br: BitReader): int {.inline.} =
  br.lastIn - br.nextIn
