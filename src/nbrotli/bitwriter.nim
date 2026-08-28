## LSB-first bit writer — RFC 7932 §1.5.1, mirrors bitreader.nim / c/enc/bit_cost.h
import bitreader

type
  BitWriter* = object
    val*: uint64   ## accumulator, low bitPos bits pending
    bitPos*: int   ## 0..63
    outBuf*: seq[byte]

func initBitWriter*(): BitWriter =
  result.val = 0
  result.bitPos = 0
  result.outBuf = @[]

proc writeBits*(bw: var BitWriter, n: uint32, v: uint32) {.inline.} =
  ## LSB-first append n bits of v.
  if n == 0: return
  bw.val = bw.val or ((v.uint64 and kBitMask[n].uint64) shl bw.bitPos)
  bw.bitPos += n.int
  while bw.bitPos >= 8:
    bw.outBuf.add(byte(bw.val and 0xFF))
    bw.val = bw.val shr 8
    bw.bitPos -= 8

proc emitByteBoundaryZeroPad*(bw: var BitWriter) {.inline.} =
  ## Zero-pad to next byte, as validated by jumpToByteBoundary.
  let pad = bw.bitPos and 7
  if pad != 0:
    writeBits(bw, (8 - pad).uint32, 0)

proc flush*(bw: var BitWriter) {.inline.} =
  ## Drain remaining bits (should be 0 after pad, but emit zeros for safety).
  while bw.bitPos > 0:
    let n = if bw.bitPos >= 8: 8 else: bw.bitPos
    # emit low n bits
    bw.outBuf.add(byte(bw.val and 0xFF))
    bw.val = bw.val shr n
    bw.bitPos -= n

func toSeq*(bw: BitWriter): seq[byte] {.inline.} = bw.outBuf

func len*(bw: BitWriter): int {.inline.} = bw.outBuf.len
