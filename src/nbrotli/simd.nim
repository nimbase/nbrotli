## SIMD helpers — guarded by -d:features.nbrotli.nimsimd
## Build with `clue build --features:nimsimd` or `clue test --features:nimsimd`
## Falls back to scalar copyMem when feature not enabled or non-x86.

when defined(features.nbrotli.nimsimd) or defined(nimsimd):
  const simdEnabled* = true
else:
  const simdEnabled* = false

when defined(features.nbrotli.nimsimd) or defined(nimsimd):
  when defined(amd64):
    {.passC: "-mavx2 -mavx -msse4.2 -msse2".}
    import nimsimd/sse2
    import nimsimd/avx
    import nimsimd/avx2
  elif defined(arm64):
    import nimsimd/neon

# Feature flag detection helpers:
const hasSimdFeature* = defined(features.nbrotli.nimsimd) or defined(nimsimd)
const hasAvx2* = hasSimdFeature and defined(amd64)

proc copyMemSimd*(dst, src: pointer, len: int) {.inline.} =
  ## Fast copy, 32B AVX2 when available else scalar copyMem.
  ## Safe for non-overlapping regions; for overlapping LZ77 use copyLz77.
  when hasSimdFeature and defined(amd64):
    if len >= 32:
      var off = 0
      # 32B AVX2 loop
      let n32 = len and not 31
      while off < n32:
        let s = cast[ptr M256i](cast[int](src) + off)
        let d = cast[ptr M256i](cast[int](dst) + off)
        let v = mm256_loadu_si256(s)
        mm256_storeu_si256(d, v)
        off += 32
      let rem = len - off
      if rem > 0:
        copyMem(cast[pointer](cast[int](dst) + off), cast[pointer](cast[int](src) + off), rem)
      return
    # <32 fallback to 16B SSE
    if len >= 16:
      var off = 0
      let n16 = len and not 15
      while off < n16:
        let s = cast[ptr M128i](cast[int](src) + off)
        let d = cast[ptr M128i](cast[int](dst) + off)
        let v = mm_loadu_si128(s)
        mm_storeu_si128(d, v)
        off += 16
      let rem = len - off
      if rem > 0:
        copyMem(cast[pointer](cast[int](dst) + off), cast[pointer](cast[int](src) + off), rem)
      return
    if len > 0:
      copyMem(dst, src, len)
  else:
    if len > 0:
      copyMem(dst, src, len)

proc copyBytesSimd*(dst: var seq[byte], dstPos: int, src: ptr UncheckedArray[byte], srcPos, len: int) {.inline.} =
  if len <= 0: return
  copyMemSimd(addr dst[dstPos], addr src[srcPos], len)

proc copyRingSimd*(ring: var seq[byte], ringPos: int, src: ptr UncheckedArray[byte], srcPos, len: int) {.inline.} =
  if len <= 0: return
  copyMemSimd(addr ring[ringPos], addr src[srcPos], len)

proc lz77CopySimd*(ring: var seq[byte], rpos, spos, copyLen, mask: int, distance: int) {.inline.} =
  ## LZ77 copy handling wrap and overlap (distance < copyLen).
  ## For non-overlapping, uses 32B bulk; for overlapping uses per-byte or broadcast.
  if copyLen <= 0: return
  let rmask = mask
  # Fast path: distance >= copyLen and no wrap on both sides -> single bulk copy
  let srcWrap = (spos + copyLen) <= ring.len
  let dstWrap = (rpos + copyLen) <= ring.len
  # Also need contiguous in ring mask sense: rpos & mask consecutive
  # We check raw ring indices < ringSize to avoid mask wrap
  if distance >= copyLen and srcWrap and dstWrap:
    # Non-overlapping, contiguous
    copyMemSimd(addr ring[rpos], addr ring[spos], copyLen)
    return
  # Overlapping or wrap: scalar fallback with mask per iteration (correct)
  # For distance == 1 we could broadcast, but scalar is correct and handles all overlaps
  for i in 0..<copyLen:
    let s = (spos + i) and rmask  # spos already masked? caller passes ringPos-distance & mask
    let d = (rpos + i) and rmask
    ring[d] = ring[s]

# Backwards compat: expose copyMemSimd for external use even when scalar
