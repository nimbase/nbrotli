## RFC 7932 constants — mirrors c/common/constants.h

const
  # Specification: 7.3 context map RLE
  BrotliContextMapMaxRle* = 16

  # Specification: 2. overview
  BrotliMaxNumberOfBlockTypes* = 256

  # Specification: 3.3 alphabet sizes
  BrotliNumLiteralSymbols* = 256
  BrotliNumCommandSymbols* = 704
  BrotliNumBlockLenSymbols* = 26
  BrotliMaxContextMapSymbols* = BrotliMaxNumberOfBlockTypes + BrotliContextMapMaxRle # 272
  BrotliMaxBlockTypeSymbols* = BrotliMaxNumberOfBlockTypes + 2 # 258

  # Specification: 3.5 complex prefix codes
  BrotliRepeatPreviousCodeLength* = 16
  BrotliRepeatZeroCodeLength* = 17
  BrotliCodeLengthCodes* = BrotliRepeatZeroCodeLength + 1 # 18
  BrotliInitialRepeatedCodeLength* = 8

  # Large Window Brotli
  BrotliLargeMaxDistanceBits* = 62'u32
  BrotliLargeMinWbits* = 10
  BrotliLargeMaxWbits* = 30

  # Specification: 4. distances
  BrotliNumDistanceShortCodes* = 16
  BrotliMaxNPostfix* = 3
  BrotliMaxNDirect* = 120
  BrotliMaxDistanceBits* = 24'u32

  # Derived
  BrotliNumDistanceSymbolsLarge* = BrotliNumDistanceShortCodes + BrotliMaxNDirect +
      (int(BrotliLargeMaxDistanceBits) shl (BrotliMaxNPostfix + 1)) # 1128 with large params

  # 4. copy lengths
  BrotliNumInsCopyCodes* = 24

  # 7.1 literal contexts
  BrotliLiteralContextBits* = 6
  # 7.2 distance contexts
  BrotliDistanceContextBits* = 2

  # 9.1 Stream header
  BrotliWindowGap* = 16
  BrotliMaxDistance* = 0x3FFFFFC
  BrotliMaxAllowedDistance* = 0x7FFFFFFC

  # Huffman
  BrotliHuffmanMaxCodeLength* = 15
  BrotliHuffmanMaxCodeLengthCodeLength* = 5
  BrotliHuffmanTableBits* = 8
  BrotliHuffmanTableMask* = 0xFF

  BrotliHuffmanMaxSize26* = 396
  BrotliHuffmanMaxSize258* = 632
  BrotliHuffmanMaxSize272* = 646

  # Block size cap (same as max meta-block 1<<24)
  BrotliBlockSizeCap* = 1'u32 shl 24

  # Static dictionary word lengths
  BrotliMinDictionaryWordLength* = 4
  BrotliMaxDictionaryWordLength* = 24

  # Ring buffer slack for 2x16-byte copy + transformed dict word
  BrotliRingBufferWriteAheadSlack* = 42

func maxBackwardLimit*(wbits: int): int {.inline.} =
  (1 shl wbits) - BrotliWindowGap

type
  BrotliPrefixCodeRange* = object
    offset*: uint16
    nbits*: uint8

type
  BrotliDistanceCodeLimit* = object
    maxAlphabetSize*: uint32
    maxDistance*: uint32

func distanceAlphabetSize*(npostfix, ndirect, maxNbits: int): int {.inline.} =
  BrotliNumDistanceShortCodes + ndirect + (maxNbits shl (npostfix + 1))

func calculateDistanceCodeLimit*(maxDistance: uint32, npostfix, ndirect: uint32): BrotliDistanceCodeLimit =
  if maxDistance <= ndirect:
    return BrotliDistanceCodeLimit(
      maxAlphabetSize: maxDistance + BrotliNumDistanceShortCodes.uint32,
      maxDistance: maxDistance)
  else:
    let forbidden = maxDistance + 1
    var offset = forbidden - ndirect - 1
    var ndistbits = 0'u32
    var tmp: uint32
    var half: uint32
    var group: uint32
    let postfix = (1'u32 shl npostfix) - 1
    var extra: uint32
    var start: uint32
    offset = (offset shr npostfix) + 4
    tmp = offset div 2
    while tmp != 0:
      ndistbits.inc
      tmp = tmp shr 1
    ndistbits.dec
    half = (offset shr ndistbits) and 1
    group = ((ndistbits - 1) shl 1) or half
    if group == 0:
      return BrotliDistanceCodeLimit(
        maxAlphabetSize: ndirect + BrotliNumDistanceShortCodes.uint32,
        maxDistance: ndirect)
    group.dec
    ndistbits = (group shr 1) + 1
    extra = (1'u32 shl ndistbits) - 1
    start = (1'u32 shl (ndistbits + 1)) - 4
    start += (group and 1) shl ndistbits
    result.maxAlphabetSize = ((group shl npostfix) or postfix) + ndirect +
        BrotliNumDistanceShortCodes.uint32 + 1
    result.maxDistance = ((start + extra) shl npostfix) + postfix + ndirect + 1
