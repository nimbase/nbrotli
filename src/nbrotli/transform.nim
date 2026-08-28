## Transform — mirrors c/common/transform.h + transform.c
import transform_data

type BrotliTransformType* = enum
  Identity = 0
  OmitLast1 = 1
  OmitLast2 = 2
  OmitLast3 = 3
  OmitLast4 = 4
  OmitLast5 = 5
  OmitLast6 = 6
  OmitLast7 = 7
  OmitLast8 = 8
  OmitLast9 = 9
  UppercaseFirst = 10
  UppercaseAll = 11
  OmitFirst1 = 12
  OmitFirst2 = 13
  OmitFirst3 = 14
  OmitFirst4 = 15
  OmitFirst5 = 16
  OmitFirst6 = 17
  OmitFirst7 = 18
  OmitFirst8 = 19
  OmitFirst9 = 20
  ShiftFirst = 21
  ShiftAll = 22

func transformPrefixSlice*(idx: int, outSlice: var seq[byte]): int =
  let id = kTransformsData[idx*3].int
  let s = kPrefixSuffixMap[id].int
  let e = kPrefixSuffixMap[id+1].int
  result = e - s - 1
  outSlice.setLen(result)
  for i in 0..<result:
    outSlice[i] = kPrefixSuffix[s + 1 + i]

func transformType*(idx: int): int {.inline.} =
  kTransformsData[idx*3+1].int

proc transformSuffixSlice*(idx: int, outSlice: var seq[byte]): int =
  let id = kTransformsData[idx*3+2].int
  let s = kPrefixSuffixMap[id].int
  let e = kPrefixSuffixMap[id+1].int
  result = e - s - 1
  outSlice.setLen(result)
  for i in 0..<result:
    outSlice[i] = kPrefixSuffix[s + 1 + i]

func transformDictionaryWord*(dst: var seq[byte], dstOff: int,
    word: openArray[byte], transformIdx: int): int =
  ## Returns written length. dst must have enough capacity.
  let prefixId = kTransformsData[transformIdx*3].int
  let ttype = kTransformsData[transformIdx*3+1].int
  let suffixId = kTransformsData[transformIdx*3+2].int
  let pStart = kPrefixSuffixMap[prefixId].int
  let pEnd = kPrefixSuffixMap[prefixId+1].int
  let sStart = kPrefixSuffixMap[suffixId].int
  let sEnd = kPrefixSuffixMap[suffixId+1].int
  var off = dstOff
  for i in (pStart+1)..<pEnd:
    dst[off] = kPrefixSuffix[i]
    off.inc
  var omitFirst = 0
  var omitLast = 0
  if ttype >= 12 and ttype <= 20:
    omitFirst = ttype - 11
  elif ttype >= 1 and ttype <= 9:
    omitLast = ttype
  var srcOff = omitFirst
  var srcLen = word.len - omitFirst - omitLast
  if srcLen < 0: srcLen = 0
  if srcOff < 0: srcOff = 0
  for i in 0..<srcLen:
    dst[off] = word[srcOff + i]
    off.inc
  # uppercase transforms
  if ttype == 10 or ttype == 11:
    var upOff = off - srcLen
    var rem = if ttype == 10: 1 else: srcLen
    while rem > 0:
      let c0 = dst[upOff].int
      if c0 < 0xC0:
        if c0 >= 97 and c0 <= 122:
          dst[upOff] = byte(c0 xor 32)
        upOff.inc; rem.dec
      elif c0 < 0xE0:
        dst[upOff+1] = byte(dst[upOff+1].int xor 32)
        upOff += 2; rem -= 2
      else:
        dst[upOff+2] = byte(dst[upOff+2].int xor 5)
        upOff += 3; rem -= 3
  # shift transforms (RFC 7932 §9.2, c/common/transform.c Shift)
  proc shiftWord(p: var seq[byte], baseOff, wlen: int, param: uint16): int =
    # Returns bytes consumed (1..4) and modifies p in place. Mirrors C Shift().
    let scalarBase = (param and 0x7FFF'u16).uint32 + (0x1000000'u32 - (param and 0x8000'u16).uint32)
    if wlen <= 0: return 0
    let b0 = p[baseOff].int
    if b0 < 0x80:
      let scalar = scalarBase + b0.uint32
      p[baseOff] = byte(scalar and 0x7F'u32)
      return 1
    elif b0 < 0xC0:
      return 1
    elif b0 < 0xE0:
      if wlen < 2: return 1
      let s = ((p[baseOff].uint32 and 0x1F) shl 6) or (p[baseOff+1].uint32 and 0x3F)
      let scalar = scalarBase + s
      p[baseOff] = byte(0xC0 or ((scalar shr 6) and 0x1F))
      p[baseOff+1] = byte((p[baseOff+1] and 0xC0) or (scalar and 0x3F))
      return 2
    elif b0 < 0xF0:
      if wlen < 3: return wlen
      let s = ((p[baseOff].uint32 and 0x0F) shl 12) or ((p[baseOff+1].uint32 and 0x3F) shl 6) or (p[baseOff+2].uint32 and 0x3F)
      let scalar = scalarBase + s
      p[baseOff] = byte(0xE0 or ((scalar shr 12) and 0x0F))
      p[baseOff+1] = byte((p[baseOff+1] and 0xC0) or ((scalar shr 6) and 0x3F))
      p[baseOff+2] = byte((p[baseOff+2] and 0xC0) or (scalar and 0x3F))
      return 3
    elif b0 < 0xF8:
      if wlen < 4: return wlen
      let s = ((p[baseOff].uint32 and 0x07) shl 18) or ((p[baseOff+1].uint32 and 0x3F) shl 12) or ((p[baseOff+2].uint32 and 0x3F) shl 6) or (p[baseOff+3].uint32 and 0x3F)
      let scalar = scalarBase + s
      p[baseOff] = byte(0xF0 or ((scalar shr 18) and 0x07))
      p[baseOff+1] = byte((p[baseOff+1] and 0xC0) or ((scalar shr 12) and 0x3F))
      p[baseOff+2] = byte((p[baseOff+2] and 0xC0) or ((scalar shr 6) and 0x3F))
      p[baseOff+3] = byte((p[baseOff+3] and 0xC0) or (scalar and 0x3F))
      return 4
    else:
      return 1
  if ttype == 21: # ShiftFirst
    let param: uint16 = 0 # static transforms have NULL params -> 0
    discard shiftWord(dst, off - srcLen, srcLen, param)
  elif ttype == 22: # ShiftAll
    let param: uint16 = 0
    var sOff = off - srcLen
    var rem = srcLen
    while rem > 0:
      let step = shiftWord(dst, sOff, rem, param)
      if step <= 0: break
      sOff += step
      rem -= step
  for i in (sStart+1)..<sEnd:
    dst[off] = kPrefixSuffix[i]
    off.inc
  result = off - dstOff
