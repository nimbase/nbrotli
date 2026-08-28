## Prefix code LUTs — mirrors c/dec/prefix.h + c/dec/prefix.c
import constants

type
  CmdLutElement* = object
    insertLenExtraBits*: uint8
    copyLenExtraBits*: uint8
    distanceCode*: int8
    context*: uint8
    insertLenOffset*: uint16
    copyLenOffset*: uint16

const kBlockLengthPrefixCode*: array[26, BrotliPrefixCodeRange] = [
  BrotliPrefixCodeRange(offset: 1, nbits: 2),
  BrotliPrefixCodeRange(offset: 5, nbits: 2),
  BrotliPrefixCodeRange(offset: 9, nbits: 2),
  BrotliPrefixCodeRange(offset: 13, nbits: 2),
  BrotliPrefixCodeRange(offset: 17, nbits: 3),
  BrotliPrefixCodeRange(offset: 25, nbits: 3),
  BrotliPrefixCodeRange(offset: 33, nbits: 3),
  BrotliPrefixCodeRange(offset: 41, nbits: 3),
  BrotliPrefixCodeRange(offset: 49, nbits: 4),
  BrotliPrefixCodeRange(offset: 65, nbits: 4),
  BrotliPrefixCodeRange(offset: 81, nbits: 4),
  BrotliPrefixCodeRange(offset: 97, nbits: 4),
  BrotliPrefixCodeRange(offset: 113, nbits: 5),
  BrotliPrefixCodeRange(offset: 145, nbits: 5),
  BrotliPrefixCodeRange(offset: 177, nbits: 5),
  BrotliPrefixCodeRange(offset: 209, nbits: 5),
  BrotliPrefixCodeRange(offset: 241, nbits: 6),
  BrotliPrefixCodeRange(offset: 305, nbits: 6),
  BrotliPrefixCodeRange(offset: 369, nbits: 7),
  BrotliPrefixCodeRange(offset: 497, nbits: 8),
  BrotliPrefixCodeRange(offset: 753, nbits: 9),
  BrotliPrefixCodeRange(offset: 1265, nbits: 10),
  BrotliPrefixCodeRange(offset: 2289, nbits: 11),
  BrotliPrefixCodeRange(offset: 4337, nbits: 12),
  BrotliPrefixCodeRange(offset: 8433, nbits: 13),
  BrotliPrefixCodeRange(offset: 16625, nbits: 24),
]

let kCmdLut*: array[704, CmdLutElement] = block:
  var lut: array[704, CmdLutElement]
  const kInsertExtra: array[24, uint8] = [0,0,0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,7,8,9,10,12,14,24]
  const kCopyExtra: array[24, uint8] = [0,0,0,0,0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,7,8,9,10,24]
  const kCellPos: array[11, uint8] = [0,1,0,1,8,9,2,16,10,17,18]
  var insertOff: array[24, uint16]
  var copyOff: array[24, uint16]
  insertOff[0] = 0
  copyOff[0] = 2
  for i in 0..<23:
    insertOff[i+1] = insertOff[i] + (1'u16 shl kInsertExtra[i].int)
    copyOff[i+1] = copyOff[i] + (1'u16 shl kCopyExtra[i].int)
  for sym in 0..<704:
    let cellIdx = sym shr 6
    let cellPos = kCellPos[cellIdx].int
    let copyCode = ((cellPos shl 3) and 0x18) + (sym and 7)
    let insertCode = (cellPos and 0x18) + ((sym shr 3) and 7)
    let co = copyOff[copyCode]
    lut[sym].copyLenExtraBits = kCopyExtra[copyCode]
    lut[sym].context = if co > 4: 3'u8 else: uint8(co.int - 2)
    lut[sym].copyLenOffset = co
    lut[sym].distanceCode = if cellIdx >= 2: -1'i8 else: 0'i8
    lut[sym].insertLenExtraBits = kInsertExtra[insertCode]
    lut[sym].insertLenOffset = insertOff[insertCode]
  lut
