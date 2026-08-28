import bitreader, constants, prefix, context, dictionary, dictionary_data, transform, transform_data

type
  BrotliError* = object of CatchableError
    code*: int

const
  # Error codes matching Go/C
  ErrFormatExuberantNibble* = -1
  ErrFormatReserved* = -2
  ErrFormatExuberantMetaNibble* = -3
  ErrFormatSimpleHuffmanAlphabet* = -4
  ErrFormatSimpleHuffmanSame* = -5
  ErrFormatClSpace* = -6
  ErrFormatHuffmanSpace* = -7
  ErrFormatContextMapRepeat* = -8
  ErrFormatBlockLength1* = -9
  ErrFormatBlockLength2* = -10
  ErrFormatTransform* = -11
  ErrFormatDictionary* = -12
  ErrFormatWindowBits* = -13
  ErrFormatPadding1* = -14
  ErrFormatPadding2* = -15
  ErrFormatDistance* = -16
  ErrUnreachable* = -31

func raiseBrotli*(code: int, msg: string) =
  var e = newException(BrotliError, msg)
  e.code = code
  raise e

# ---------- Huffman decoder (brute map, 15 bits) ----------

type HuffmanDecoder* = object
  # maps[len][code] = symbol, -1 if none
  maps*: array[16, seq[int]]
  maxLen*: int

func reverseBitsN*(v: uint32, n: int): uint32 =
  var r = 0'u32
  for i in 0..<n:
    r = r or (((v shr i) and 1) shl (n-1-i))
  r

func initHuffmanDecoder*(codeLengths: openArray[uint8]): HuffmanDecoder =
  var blCount: array[16, int]
  for cl in codeLengths:
    if cl.int <= 15:
      blCount[cl.int].inc
  var nextCode: array[16, uint32]
  var code: uint32 = 0
  blCount[0] = 0
  for bits in 1..15:
    code = (code + blCount[bits-1].uint32) shl 1
    nextCode[bits] = code
  var codes = newSeq[uint32](codeLengths.len)
  var has = false
  for i, cl in codeLengths:
    if cl != 0:
      codes[i] = nextCode[cl.int]
      nextCode[cl.int].inc
      has = true
  # init maps
  for i in 0..15:
    if i == 0:
      result.maps[i] = @[]
    else:
      result.maps[i] = newSeq[int](1 shl i)
      for j in 0..<result.maps[i].len:
        result.maps[i][j] = -1
  result.maxLen = 0
  for i, cl in codeLengths:
    if cl != 0:
      let rev = reverseBitsN(codes[i], cl.int).int
      result.maps[cl.int][rev] = i
      if cl.int > result.maxLen: result.maxLen = cl.int
  # handle single-symbol case (code length 0)
  if not has and codeLengths.len > 0:
    # shouldn't happen for data codes except maybe trivial
    discard

func initHuffmanDecoderEmpty*(): HuffmanDecoder =
  for i in 0..15:
    result.maps[i] = @[]
  result.maxLen = 0

proc decodeSymbol*(h: HuffmanDecoder, br: var BitReader): int =
  ## Brute 1..maxLen lookup. Assumes enough bits available (fills if needed)
  # ensure at least maxLen bits
  fillBitWindow(br, h.maxLen.uint32)
  let peek = (br.val and 0x7FFF'u64).uint32 # up to 15 bits
  for len in 1..h.maxLen:
    let mask = (1 shl len) - 1
    let idx = (peek and mask.uint32).int
    if h.maps[len].len > idx and h.maps[len][idx] != -1:
      # verify that code length matches; need to ensure we consume correct len
      # But there could be ambiguity where shorter code also matches prefix of longer?
      # Huffman is prefix-free, so earliest len that matches is correct.
      br.dropBits(len.uint32)
      return h.maps[len][idx]
  raiseBrotli(ErrFormatHuffmanSpace, "huffman decode failed")

proc decodeSymbolSafe*(h: HuffmanDecoder, br: var BitReader, outSym: var int): bool =
  if br.bitPos == 0 and br.nextIn >= br.lastIn:
    return false
  fillBitWindow(br, h.maxLen.uint32)
  if br.bitPos < 1:
    return false
  let peek = (br.val and 0x7FFF'u64).uint32
  for len in 1..h.maxLen:
    if br.bitPos < len: return false
    let mask = (1 shl len) - 1
    let idx = (peek and mask.uint32).int
    if idx < h.maps[len].len and h.maps[len][idx] != -1:
      br.dropBits(len.uint32)
      outSym = h.maps[len][idx]
      return true
  return false

# ---------- Helpers for code length alphabet ----------

const kCodeLengthCodeOrder* = [1'u8,2,3,4,0,5,17,6,16,7,8,9,10,11,12,13,14,15]
const kCodeLengthPrefixLength* = [2'u8,2,2,3,2,2,2,4,2,2,2,3,2,2,2,4]
const kCodeLengthPrefixValue* = [0'u8,4,3,2,0,4,3,1,0,4,3,2,0,4,3,5]

# ---------- State ----------

type DecoderState* = object
  br*: BitReader
  windowBits*: int
  largeWindow*: bool
  maxBackwardDistance*: int
  maxDistance*: int
  ring*: seq[byte]
  ringSize*: int
  ringMask*: int
  ringPos*: int
  newRingbufferSize*: int
  cannyRingbufferAllocation*: bool
  # distance ring
  distRb*: array[4, int]
  distRbIdx*: int
  # block types
  numBlockTypes*: array[3, int]
  blockTypeTrees*: array[3, HuffmanDecoder]
  blockLenTrees*: array[3, HuffmanDecoder]
  blockTypesRb*: array[6, int]
  blockLens*: array[3, int]
  # context
  numLiteralBlockTypes*: int
  numCommandBlockTypes*: int
  numDistanceBlockTypes*: int
  distancePostfixBits*: int
  distancePostfixMask*: int
  numDirectDistanceCodes*: int
  contextModes*: seq[uint8]
  contextMap*: seq[uint8]
  distContextMap*: seq[uint8]
  # huffman groups
  literalDecoders*: seq[HuffmanDecoder] # per htree
  commandDecoders*: seq[HuffmanDecoder]
  distanceDecoders*: seq[HuffmanDecoder]
  # maps slices
  trivialLiteralContexts*: array[8, uint32]
  # current decoding pointers
  literalTreeIdx*: int
  commandTreeIdx*: int
  distTreeIdx*: int
  contextMapSliceOff*: int
  distContextMapSliceOff*: int
  # distance LUT
  distExtraBits*: seq[uint8]
  distOffset*: seq[uint64]

func initDecoderState*(data: openArray[byte]): DecoderState =
  result.br = initBitReader(data)
  result.distRb = [16,15,11,4]
  result.distRbIdx = 0
  result.ringPos = 0
  result.blockTypesRb = [1,0,1,0,1,0]
  result.cannyRingbufferAllocation = true
  result.newRingbufferSize = 0
  result.ringSize = 0
  result.ringMask = 0
  result.largeWindow = false

# ---------- Low level decoders ----------

func log2Floor*(x: uint32): uint32 =
  var r = 0'u32
  var v = x
  while v != 0:
    v = v shr 1
    r.inc
  r

proc decodeVarLenUint8*(br: var BitReader): uint32 =
  var bits: uint32
  if not br.safeReadBits(1, bits):
    raiseBrotli(ErrFormatExuberantNibble, "needs more input varlen")
  if bits == 0: return 0
  if not br.safeReadBits(3, bits):
    raiseBrotli(ErrFormatExuberantNibble, "needs more input varlen short")
  if bits == 0: return 1
  let n = bits
  if not br.safeReadBits(n, bits):
    raiseBrotli(ErrFormatExuberantNibble, "needs more input varlen long")
  result = (1'u32 shl n) + bits

proc decodeWindowBits*(br: var BitReader, largeWindow: var bool): int =
  var n: uint32
  fillBitWindow(br, 8)
  br.takeBits(1, n)
  if n == 0:
    largeWindow = false
    return 16
  br.takeBits(3, n)
  if n != 0:
    largeWindow = false
    return (17 + n.int) and 63
  br.takeBits(3, n)
  if n == 1:
    if largeWindow:
      br.takeBits(1, n)
      if n == 1:
        raiseBrotli(ErrFormatWindowBits, "large window bit")
      largeWindow = true
      return 0 # signal large window not supported fully; caller handles
    else:
      raiseBrotli(ErrFormatWindowBits, "window bits")
  if n != 0:
    largeWindow = false
    return (8 + n.int) and 63
  largeWindow = false
  return 17

# ---------- Huffman code reading (simple/complex) ----------

proc readSimpleHuffmanSymbols(br: var BitReader, alphabetMax, alphabetLimit: int, symbols: var seq[uint16], nSym: int) =
  let maxBits = log2Floor(alphabetMax.uint32 - 1).int
  for i in 0..<nSym:
    var v: uint32
    if not br.safeReadBits(maxBits.uint32, v):
      raiseBrotli(ErrFormatSimpleHuffmanAlphabet, "simple huffman need bits")
    if v.int >= alphabetLimit:
      raiseBrotli(ErrFormatSimpleHuffmanAlphabet, "simple alphabet")
    symbols[i] = v.uint16
  for i in 0..<nSym:
    for k in (i+1)..<nSym:
      if symbols[i] == symbols[k]:
        raiseBrotli(ErrFormatSimpleHuffmanSame, "simple same")

proc readHuffmanCode*(br: var BitReader, alphabetMax, alphabetLimit: int): HuffmanDecoder =
  var skip: uint32
  if not br.safeReadBits(2, skip):
    raiseBrotli(ErrFormatHuffmanSpace, "huffman skip")
  if skip == 1:
    # simple
    var nSym: uint32
    if not br.safeReadBits(2, nSym):
      raiseBrotli(ErrFormatHuffmanSpace, "simple n")
    let numSymbols = (nSym + 1).int
    var symbols = newSeq[uint16](4)
    readSimpleHuffmanSymbols(br, alphabetMax, alphabetLimit, symbols, numSymbols)
    # dedup already checked
    var codeLengths = newSeq[uint8](alphabetLimit)
    # assign lengths per spec 3.4
    if numSymbols == 1:
      # single symbol gets length 0? Actually spec says 0 length for that symbol, but for decoding we handle as single-symbol huffman
      # We'll map it as 1 symbol with len 0 -> special decoder with single value
      # For our generic decoder, we fake length 1 for that symbol and others 0? But C handles as simple table with single entry.
      # Simplify: create decoder with single symbol
      codeLengths[symbols[0].int] = 1
      # Actually for NSYM=1 spec says code length 0 -> no bits. We'll handle via special case where decoder always returns that symbol without reading bits.
      # Implement by having maxLen 0 and special decode path
      # So we set special lengths where single symbol has 0 len -> our init will produce empty maps -> need special handling.
      # Instead produce a decoder that returns symbols[0] without consuming bits.
      # We'll handle by creating a decoder with maps[0] set.
      # For now create a single-symbol decoder via lengths where one symbol has 1? But that would consume 1 bit incorrectly.
      # Let's handle special: if NSYM==1, we create decoder with length 0 meaning no bits
      codeLengths = newSeq[uint8](alphabetLimit)
      # use 0 length for that symbol indicates single
      # We'll make decoder with maxLen 0 and store symbol in separate
      # Hack: create codeLengths where symbol has 1 and we will treat reading 0 bits as not needing to read
      # Actually C BuildSimpleHuffmanTable with 1 symbol creates table[0] = code 0 bits 0, so we need similar
      # Our generic decode expects bits>0, so we need special case here: return a single-symbol decoder
      var single: HuffmanDecoder
      single.maxLen = 0
      # store symbol in maps[0] size 1
      single.maps[0] = @[symbols[0].int]
      return single
    elif numSymbols == 2:
      codeLengths[symbols[0].int] = 1
      codeLengths[symbols[1].int] = 1
    elif numSymbols == 3:
      codeLengths[symbols[0].int] = 1
      codeLengths[symbols[1].int] = 2
      codeLengths[symbols[2].int] = 2
    else: # 4
      var treeSelect: uint32
      # numSymbols==4 may have extra bit
      # Actually for NSYM=4 we need to read tree-select bit per spec
      if numSymbols == 4:
        # In C, they read 1 bit only if symbol==3 (i.e., 4 symbols)
        if not br.safeReadBits(1, treeSelect):
          raiseBrotli(ErrFormatHuffmanSpace, "tree select")
        if treeSelect == 0:
          for i in 0..<4: codeLengths[symbols[i].int] = 2
        else:
          codeLengths[symbols[0].int] = 1
          codeLengths[symbols[1].int] = 2
          codeLengths[symbols[2].int] = 3
          codeLengths[symbols[3].int] = 3
      else:
        for i in 0..<4: codeLengths[symbols[i].int] = 2
    return initHuffmanDecoder(codeLengths)
  else:
    # complex
    var hskip = skip.int
    # read code length code lengths
    var codeLengthCodeLengths = newSeq[uint8](18)
    var space = 32
    var numCodes = 0
    var histo: array[16, int]
    for i in 0..<18:
      if i < hskip: continue # skip 0, or 2,3?
      # mapping: hskip 0 -> start 0, 2 -> start 2, 3 -> start 3
      # But our loop handle: if hskip==2 then first two are zero implicit, so we start at i=2
      # We'll just iterate over order array
      discard
    # Use order array iteration as in C
    space = 32
    numCodes = 0
    # Build prefix table for code length alphabet
    # For simplicity, read lengths via small huffman table built from kCodeLengthPrefix*
    # That table is fixed: we can decode lengths by directly reading via lookup in table?
    # Instead implement same as C: build fixed table from kCodeLengthPrefixLength/Value
    # Simpler: we can decode code length code lengths by reading 2-4 bits using that fixed table brute force
    # Let's build small decoder for the 16 symbols of code length code lengths
    # Fixed Huffman: symbols 0..15 with lengths kCodeLengthPrefixLength and values kCodeLengthPrefixValue
    # But kCodeLengthPrefixLength is indexed by ix (0..15) which is 4-bit peek value; table decodes v.
    # Actually C builds a table from kCodeLengthPrefixLength array? No, they use direct lookup via 4-bit peek and fixedTable?
    # Alternative simpler: directly read code length code lengths using the variable-length code table given in spec 3.5:
    # Symbol Code : 0 00, 1 0111, 2 011, 3 10, 4 01, 5 1111
    # But easier to replicate C's method: they have fixedTable of size 16 mapping 4-bit peek to (bits, value)
    # We'll just directly decode via reading 4 bits peek and mapping using arrays.
    # For codeLengthCodes we iterate over kCodeLengthCodeOrder
    var order = kCodeLengthCodeOrder
    # hskip handling: if hskip==0 start idx 0, if 2 start at 2 (skip 1,2), if 3 start at 3 (skip 1,2,3)
    var startIdx = 0
    if hskip == 2: startIdx = 2
    elif hskip == 3: startIdx = 3
    else: startIdx = 0
    for oi in startIdx..<18:
      let codeLenIdx = order[oi].int
      var ix: uint32
      # peek 4 bits
      if not br.safeGetBits(4, ix):
        # need more bits but we have safe path; for now we require bits
        raiseBrotli(ErrFormatClSpace, "code length code need bits")
      # map ix via prefix length/value
      # That mapping is in Go fixedTable or C fixedTable; we use arrays:
      let v = kCodeLengthPrefixValue[ix.int].int
      let l = kCodeLengthPrefixLength[ix.int].int
      br.dropBits(l.uint32)
      codeLengthCodeLengths[codeLenIdx] = v.uint8
      if v != 0:
        space -= 32 shr v
        numCodes.inc
        histo[v].inc
        if space <= 0: break
      if space == 0:
        break
      if space < 0 or space > 32:
        break
    if numCodes != 1 and space != 0:
      raiseBrotli(ErrFormatClSpace, "cl space")
    # build code length code huffman
    var clHisto: array[16, int]
    for i in 0..15: clHisto[i] = histo[i]
    # build decoder for code lengths alphabet (size 18, but we have 16..?) Actually alphabet is 18 for code length symbols (0..17)
    # The above only gives lengths for 0..15 plus implicit zeros for skipped? Code lengths for 16,17 are part of alphabet too.
    # We have full 18 lengths (for symbols 0..15,16,17) where 16/17 are repeat codes. Our codeLengthCodeLengths already covers 0..15 plus 16,17 at order positions.
    # So we have full array size 18.
    # Build Huffman for code length code decoding (max code length 5)
    var codeLenCodeLengthsFull = newSeq[uint8](18)
    for i in 0..<18: codeLenCodeLengthsFull[i] = codeLengthCodeLengths[i]
    # Special case: if only one non-zero length (numCodes==1)
    var codeLengthDecoder: HuffmanDecoder
    if numCodes == 1:
      var singleIdx = -1
      for i in 0..<18:
        if codeLengthCodeLengths[i] != 0:
          singleIdx = i; break
      codeLengthDecoder.maxLen = 0
      codeLengthDecoder.maps[0] = @[singleIdx]
      for i in 1..15: codeLengthDecoder.maps[i] = @[]
    else:
      codeLengthDecoder = initHuffmanDecoder(codeLenCodeLengthsFull)
    # Now read symbol code lengths (alphabetLimit many)
    var symbol = 0
    var prevCodeLen = 8
    var repeat = 0
    var repeatCodeLen = 0
    var space2 = 32768
    var symbolLists: array[16, seq[int]]
    for i in 0..15: symbolLists[i] = @[]
    var codeLens = newSeq[uint8](alphabetLimit)
    var countHist: array[16, int]
    while symbol < alphabetLimit and space2 > 0:
      var codeLenSym: int
      # decode via codeLengthDecoder
      if codeLengthDecoder.maxLen == 0:
        # single symbol case
        codeLenSym = codeLengthDecoder.maps[0][0] # symbol index
      else:
        codeLenSym = codeLengthDecoder.decodeSymbol(br)
      if codeLenSym < 16:
        # single
        let cl = codeLenSym
        codeLens[symbol] = cl.uint8
        if cl != 0:
          prevCodeLen = cl
          space2 -= 32768 shr cl
          countHist[cl].inc
        repeat = 0
        symbol.inc
      else:
        # repeat
        var extraBits = if codeLenSym == 16: 2 else: 3
        var repeatDelta: uint32
        if not br.safeReadBits(extraBits.uint32, repeatDelta):
          raiseBrotli(ErrFormatHuffmanSpace, "repeat bits")
        var newLen = 0
        if codeLenSym == 16: newLen = prevCodeLen
        if repeatCodeLen != newLen:
          repeat = 0
          repeatCodeLen = newLen
        var oldRepeat = repeat
        if repeat > 0:
          repeat = repeat - 2
          repeat = repeat shl extraBits
        repeat = repeat + repeatDelta.int + 3
        let delta = repeat - oldRepeat
        if symbol + delta > alphabetLimit:
          raiseBrotli(ErrFormatHuffmanSpace, "symbol overflow")
        if repeatCodeLen != 0:
          for i in 0..<delta:
            codeLens[symbol + i] = repeatCodeLen.uint8
          space2 -= (delta shl (15 - repeatCodeLen))
          countHist[repeatCodeLen] += delta
        # else delta zeros, just skip
        symbol += delta
    # Phase A5: single-symbol final table -> 0 bits (RFC 3.5)
    var nonZero = 0
    var singleSym = 0
    for i in 0..<alphabetLimit:
      if codeLens[i] != 0:
        nonZero.inc
        singleSym = i
    if nonZero == 1:
      var single: HuffmanDecoder
      single.maxLen = 0
      single.maps[0] = @[singleSym]
      for i in 1..15: single.maps[i] = @[]
      return single
    if nonZero == 0:
      raiseBrotli(ErrFormatHuffmanSpace, "huffman empty")
    if space2 != 0:
      raiseBrotli(ErrFormatHuffmanSpace, "huffman space not zero")
    return initHuffmanDecoder(codeLens)

# ---------- Context map ----------

func inverseMoveToFront*(v: var seq[uint8]) =
  var mtf: array[256, uint8]
  for i in 0..<256: mtf[i] = i.uint8
  for i in 0..<v.len:
    let idx = v[i].int
    let val = mtf[idx]
    v[i] = val
    # move to front
    for j in countdown(idx, 1):
      mtf[j] = mtf[j-1]
    mtf[0] = val

proc decodeContextMap*(br: var BitReader, contextMapSize: int, numHTrees: var int, ctxMap: var seq[uint8]) =
  var v = decodeVarLenUint8(br)
  numHTrees = (v + 1).int
  ctxMap.setLen(contextMapSize)
  if numHTrees <= 1:
    for i in 0..<contextMapSize: ctxMap[i] = 0
    return
  var useRle: uint32
  if not br.safeReadBits(1, useRle):
    raiseBrotli(ErrFormatContextMapRepeat, "context rle")
  var maxRun: uint32 = 0
  if useRle == 1:
    var tmp: uint32
    if not br.safeReadBits(4, tmp):
      raiseBrotli(ErrFormatContextMapRepeat, "rle4")
    maxRun = tmp + 1
  let alphabet = numHTrees + maxRun.int
  var ctxTable = readHuffmanCode(br, alphabet, alphabet)
  var idx = 0
  while idx < contextMapSize:
    let code = if ctxTable.maxLen == 0: ctxTable.maps[0][0] else: ctxTable.decodeSymbol(br)
    if code == 0:
      ctxMap[idx] = 0; idx.inc
    elif code <= maxRun.int:
      var reps: uint32
      if not br.safeReadBits(code.uint32, reps):
        raiseBrotli(ErrFormatContextMapRepeat, "reps")
      reps += 1'u32 shl code
      if idx + reps.int > contextMapSize:
        raiseBrotli(ErrFormatContextMapRepeat, "overflow")
      for i in 0..<reps.int:
        ctxMap[idx] = 0; idx.inc
    else:
      ctxMap[idx] = (code - maxRun.int).uint8
      idx.inc
  var doMtf: uint32
  if not br.safeReadBits(1, doMtf):
    raiseBrotli(ErrFormatContextMapRepeat, "mtf")
  if doMtf == 1:
    inverseMoveToFront(ctxMap)

# ---------- Block type/len helpers ----------

proc readBlockLength*(br: var BitReader, dec: HuffmanDecoder): int =
  let code = if dec.maxLen == 0: dec.maps[0][0] else: dec.decodeSymbol(br)
  let rng = kBlockLengthPrefixCode[code]
  var extra: uint32 = 0
  if rng.nbits > 0:
    if not br.safeReadBits(rng.nbits.uint32, extra):
      raiseBrotli(ErrFormatBlockLength1, "block len extra")
  result = rng.offset.int + extra.int

proc decodeBlockTypeAndLength*(br: var BitReader, maxType: int,
    typeDec, lenDec: HuffmanDecoder, rings: var array[6, int], typeIdx: int) =
  discard lenDec
  if maxType <= 1:
    raiseBrotli(ErrFormatBlockLength1, "block type")
  let blockType = if typeDec.maxLen == 0: typeDec.maps[0][0] else: typeDec.decodeSymbol(br)
  # ring is two consecutive ints per treeType
  var rb0 = rings[typeIdx*2]
  var rb1 = rings[typeIdx*2+1]
  var bt: int
  if blockType == 1:
    bt = rb1 + 1
  elif blockType == 0:
    bt = rb0
  else:
    bt = blockType - 2
  if bt >= maxType:
    bt -= maxType
  rings[typeIdx*2] = rb1
  rings[typeIdx*2+1] = bt
  # caller sets blockLens[typeIdx] = blkLen

# ---------- Distance LUT ----------

func buildDistanceLUT*(postfixBits, directCodes: int, alphabetLimit: int,
    extra: var seq[uint8], offset: var seq[uint64]) =
  extra.setLen(alphabetLimit)
  offset.setLen(alphabetLimit)
  var npost = postfixBits
  var ndir = directCodes
  var postfix = 1 shl npost
  var bits = 1
  var half = 0
  var i = 16
  for j in 0..<ndir:
    if i < alphabetLimit:
      extra[i] = 0
      offset[i] = (j+1).uint64
      i.inc
  while i < alphabetLimit:
    # cap bits to avoid overflow for large window (max 62)
    let curBits = if bits > 62: 62 else: bits
    let base = ndir.uint64 + (((( (2+half).uint64 shl curBits) - 4) shl npost)) + 1
    for j in 0..<postfix:
      if i >= alphabetLimit: break
      extra[i] = curBits.uint8
      offset[i] = base + j.uint64
      i.inc
    bits += half
    half = half xor 1

func takeDistanceFromRingBuffer(state: var DecoderState, code: int): tuple[dist:int, ctx:int] =
  ## Mirrors C TakeDistanceFromRingBuffer. Returns (distance, distance_context).
  ## Updates distRbIdx appropriately for code <=3.
  var ctx = 0
  var dist = 0
  if code <= 3:
    ctx = 1 shr code
    let off = code - 3
    dist = state.distRb[(state.distRbIdx - off) and 3]
    state.distRbIdx -= ctx
  else:
    var indexDelta = 3
    var base: int
    if code < 10:
      base = code - 4
    else:
      base = code - 10
      indexDelta = 2
    let delta = ((0x605142 shr (4*base)) and 0xF) - 3
    dist = state.distRb[(state.distRbIdx + indexDelta) and 3] + delta
    if dist <= 0:
      dist = 0x7FFFFFFF
    ctx = 0
  result = (dist, ctx)

proc calculateRingBufferSize(state: var DecoderState, windowSize: int, metaRemaining: int, isMetadata: bool) =
  ## Mirrors C BrotliCalculateRingBufferSize, updates state.newRingbufferSize.
  var newSize = windowSize
  var minSize = if state.ringSize != 0: state.ringSize else: 1024
  if state.ringSize == windowSize:
    return
  if isMetadata:
    return
  var outputSize = if state.ring.len == 0: 0 else: state.ringPos
  outputSize += metaRemaining
  if minSize < outputSize:
    minSize = outputSize
  if state.cannyRingbufferAllocation:
    while (newSize shr 1) >= minSize:
      newSize = newSize shr 1
  state.newRingbufferSize = newSize

proc ensureRingBuffer(state: var DecoderState): bool =
  if state.ringSize == state.newRingbufferSize:
    return true
  let needed = state.newRingbufferSize + BrotliRingBufferWriteAheadSlack
  if state.ring.len < needed:
    var newRing = newSeq[byte](needed)
    if state.ring.len > 0 and state.ringPos > 0:
      let copyLen = min(state.ringPos, state.ring.len)
      for i in 0..<copyLen:
        newRing[i] = state.ring[i]
    state.ring = newRing
  # last two bytes initialized to 0 for context
  if state.newRingbufferSize >= 2:
    state.ring[state.newRingbufferSize - 2] = 0
    state.ring[state.newRingbufferSize - 1] = 0
  state.ringSize = state.newRingbufferSize
  state.ringMask = state.ringSize - 1
  return true

# ---------- Main decompression one-shot ----------

proc BrotliDecompress*(data: openArray[byte]): seq[byte] =
  var state = initDecoderState(data)
  var br = state.br
  var supportsLargeWindow = true
  var largeWindowDetected = false
  largeWindowDetected = supportsLargeWindow
  # window bits — support large window (2-stage)
  fillBitWindow(br, 8)
  state.windowBits = decodeWindowBits(br, largeWindowDetected)
  if largeWindowDetected:
    # Large Window Brotli: read 6 bits for actual W=10..30
    var wbits: uint32
    if not br.safeReadBits(6, wbits):
      raiseBrotli(ErrFormatWindowBits, "large window wbits")
    let wb = (wbits and 63).int
    if wb < BrotliLargeMinWbits or wb > BrotliLargeMaxWbits:
      raiseBrotli(ErrFormatWindowBits, "large window range")
    state.windowBits = wb
    state.largeWindow = true
  else:
    state.largeWindow = false
    if state.windowBits == 0:
      raiseBrotli(ErrFormatWindowBits, "large window not supported")
  state.maxBackwardDistance = (1 shl state.windowBits) - BrotliWindowGap
  state.maxDistance = state.maxBackwardDistance
  # ring allocation via Calculate/Ensure (lazy, handles large W without OOM)
  var windowSize = 1 shl state.windowBits
  # initial size calculation — metadata false, metaRemaining 0 for now, will grow on demand
  state.newRingbufferSize = windowSize
  calculateRingBufferSize(state, windowSize, 0, false)
  if state.newRingbufferSize == 0:
    state.newRingbufferSize = min(windowSize, 1024)
  discard ensureRingBuffer(state)
  # Ensure at least 2 bytes zeroed for context (handled in ensure)
  # distance ring already init
  # block type rings init - C initializes to [1,0] per type, persists across metablocks
  state.blockTypesRb = [1,0,1,0,1,0]
  # distance ring already
  # block type rings init - C initializes to [1,0] per type, persists across metablocks
  state.blockTypesRb = [1,0,1,0,1,0]
  # main loop
  var output = newSeq[byte]()
  output.setLen(0)
  var isLast = false
  while not isLast:
    # decode metablock length
    var tmp: uint32
    if not br.safeReadBits(1, tmp):
      raiseBrotli(ErrFormatExuberantNibble, "metablock is_last")
    isLast = tmp == 1
    if isLast:
      var emptyBit: uint32
      if not br.safeReadBits(1, emptyBit):
        raiseBrotli(ErrFormatReserved, "empty")
      if emptyBit == 1:
        # empty last block
        break
    var sizeNibbles: uint32
    var isMetadata = false
    var blockLen = 0
    if not br.safeReadBits(2, sizeNibbles):
      raiseBrotli(ErrFormatExuberantNibble, "nibbles")
    if sizeNibbles == 3:
      # metadata
      isMetadata = true
      var reserved: uint32
      if not br.safeReadBits(1, reserved):
        raiseBrotli(ErrFormatReserved, "reserved")
      if reserved != 0:
        raiseBrotli(ErrFormatReserved, "reserved bit")
      var sizeBytes: uint32
      if not br.safeReadBits(2, sizeBytes):
        raiseBrotli(ErrFormatExuberantMetaNibble, "sizeBytes")
      if sizeBytes == 0:
        continue # empty metadata
      var metaSizeBytes = 0
      for i in 0..<sizeBytes.int:
        var b: uint32
        if not br.safeReadBits(8, b):
          raiseBrotli(ErrFormatExuberantMetaNibble, "meta size")
        if b == 0 and i+1 == sizeBytes.int and sizeBytes > 1:
          raiseBrotli(ErrFormatExuberantMetaNibble, "exuberant meta")
        metaSizeBytes = metaSizeBytes or (b.int shl (i*8))
      metaSizeBytes.inc
      # metadata content: skip bytes after byte align, but need to be byte aligned
      if not br.jumpToByteBoundary():
        raiseBrotli(ErrFormatPadding1, "metadata pad")
      # skip metaSizeBytes bytes from bitreader input (byte aligned)
      # drain accumulator then skip
      if br.bitPos != 0:
        raiseBrotli(ErrFormatPadding1, "metadata not aligned")
      br.nextIn += metaSizeBytes
      if br.nextIn > br.lastIn:
        raiseBrotli(ErrFormatExuberantNibble, "metadata over input")
      continue
    else:
      let nibbles = (sizeNibbles + 4).int
      blockLen = 0
      for i in 0..<nibbles:
        var b: uint32
        if not br.safeReadBits(4, b):
          raiseBrotli(ErrFormatExuberantNibble, "size")
        if b == 0 and i+1 == nibbles and nibbles > 4:
          raiseBrotli(ErrFormatExuberantNibble, "exuberant nibble")
        blockLen = blockLen or (b.int shl (i*4))
      blockLen.inc
      if not isLast:
        var isUncompressed: uint32
        if not br.safeReadBits(1, isUncompressed):
          raiseBrotli(ErrFormatExuberantNibble, "uncompressed")
        if isUncompressed == 1:
          # uncompressed block: align to byte, copy raw bytes to output via ring
          calculateRingBufferSize(state, 1 shl state.windowBits, blockLen, false)
          discard ensureRingBuffer(state)
          if not br.jumpToByteBoundary():
            raiseBrotli(ErrFormatPadding1, "uncompressed pad")
          # copy blockLen bytes
          if br.bitPos != 0:
            raiseBrotli(ErrFormatPadding1, "align")
          # ensure enough bytes
          if br.nextIn + blockLen > br.lastIn:
            raiseBrotli(ErrFormatExuberantNibble, "uncompressed size")
          # copy to ring and output
          for i in 0..<blockLen:
            let b = br.input[br.nextIn]; br.nextIn.inc
            state.ring[state.ringPos and state.ringMask] = b
            output.add(b)
            state.ringPos.inc
          if state.ringPos >= state.maxBackwardDistance:
            state.maxDistance = state.maxBackwardDistance
          else:
            state.maxDistance = state.ringPos
          continue
      # else compressed
      if blockLen == 0:
        continue
    # compressed meta-block: read header
    # Now blockLen is remaining compressed block's uncompressed bytes count
    var metaRemaining = blockLen
    calculateRingBufferSize(state, 1 shl state.windowBits, metaRemaining, false)
    discard ensureRingBuffer(state)
    # read block type partitions
    # Re-init if first block?
    # NBLTYPES
    var nLitTypes = decodeVarLenUint8(br).int + 1
    var nCmdTypes = decodeVarLenUint8(br).int + 1
    var nDistTypes = decodeVarLenUint8(br).int + 1
    state.numBlockTypes[0] = nLitTypes
    state.numBlockTypes[1] = nCmdTypes
    state.numBlockTypes[2] = nDistTypes
    # for each type, read huffman codes for block type and len if >1
    for t in 0..2:
      let n = state.numBlockTypes[t]
      if n <= 1:
        # single type, htrees are dummy
        state.blockTypeTrees[t] = initHuffmanDecoderEmpty()
        state.blockLenTrees[t] = initHuffmanDecoderEmpty()
      else:
        let typeAlphabet = n + 2
        state.blockTypeTrees[t] = readHuffmanCode(br, typeAlphabet, typeAlphabet)
        state.blockLenTrees[t] = readHuffmanCode(br, BrotliNumBlockLenSymbols, BrotliNumBlockLenSymbols)
    # init block lengths per type
    for t in 0..2:
      if state.numBlockTypes[t] <= 1:
        state.blockLens[t] = 1 shl 24 # large cap
      else:
        state.blockLens[t] = readBlockLength(br, state.blockLenTrees[t])
    # distance postfix/direct
    var postfixBits: uint32
    if not br.safeReadBits(2, postfixBits):
      raiseBrotli(ErrFormatExuberantNibble, "postfix")
    state.distancePostfixBits = postfixBits.int
    state.distancePostfixMask = (1 shl state.distancePostfixBits) - 1
    var directBits: uint32
    if not br.safeReadBits(4, directBits):
      raiseBrotli(ErrFormatExuberantNibble, "direct")
    state.numDirectDistanceCodes = (directBits.int shl state.distancePostfixBits)
    # context modes
    state.contextModes.setLen(nLitTypes)
    for i in 0..<nLitTypes:
      var cm: uint32
      if not br.safeReadBits(2, cm):
        raiseBrotli(ErrFormatExuberantNibble, "ctx mode")
      state.contextModes[i] = cm.uint8
    # context maps
    var ctxMapSizeLit = nLitTypes shl 6
    var nLitTrees: int
    state.contextMap.setLen(0)
    decodeContextMap(br, ctxMapSizeLit, nLitTrees, state.contextMap)
    var ctxMapSizeDist = nDistTypes shl 2
    var nDistTrees: int
    state.distContextMap.setLen(0)
    decodeContextMap(br, ctxMapSizeDist, nDistTrees, state.distContextMap)
    # trivial literal contexts
    for i in 0..<8: state.trivialLiteralContexts[i] = 0
    for i in 0..<nLitTypes:
      let off = i shl 6
      let sample = state.contextMap[off].int
      var ok = true
      for j in 0..<64:
        if state.contextMap[off + j].int != sample:
          ok = false; break
      if ok:
        state.trivialLiteralContexts[i shr 5] = state.trivialLiteralContexts[i shr 5] or (1'u32 shl (i and 31))
    # HTrees
    state.literalDecoders.setLen(nLitTrees)
    for i in 0..<nLitTrees:
      state.literalDecoders[i] = readHuffmanCode(br, 256, 256)
    state.commandDecoders.setLen(nCmdTypes)
    for i in 0..<nCmdTypes:
      state.commandDecoders[i] = readHuffmanCode(br, 704, 704)
    # distance alphabet
    let maxDistBits = if state.largeWindow: 62 else: 24
    let alphabetLimit = BrotliNumDistanceShortCodes + state.numDirectDistanceCodes + (maxDistBits shl (state.distancePostfixBits+1))
    var distanceAlphabetMax = alphabetLimit # same for non-large
    state.distanceDecoders.setLen(nDistTrees)
    for i in 0..<nDistTrees:
      state.distanceDecoders[i] = readHuffmanCode(br, distanceAlphabetMax, alphabetLimit)
    buildDistanceLUT(state.distancePostfixBits, state.numDirectDistanceCodes, alphabetLimit,
      state.distExtraBits, state.distOffset)
    # C resets block_type_rb per metablock to [1,0] (see BrotliDecoderStateMetablockBegin)
    state.blockTypesRb = [1,0,1,0,1,0]
    if nLitTypes <= 1:
      state.blockLens[0] = 1 shl 24
    else:
      # already set above, keep it
      discard
    # Our earlier blockLens already set via readBlockLength for each type — that is the first block's length.
    # So no re-read.

    # Prepare literal decoding helpers

    # Hot loop: decode commands until metaRemaining exhausted
    var prevByte1: uint8 = 0
    var prevByte2: uint8 = 0
    # Initialize ring tail bytes 0 for first context
    # prev bytes for first literals are 0 (ring tail)
    # Process commands
    while metaRemaining > 0:
      if state.blockLens[1] == 0:
        # need block switch for commands
        decodeBlockTypeAndLength(br, state.numBlockTypes[1], state.blockTypeTrees[1], state.blockLenTrees[1], state.blockTypesRb, 1)
        state.blockLens[1] = readBlockLength(br, state.blockLenTrees[1])
      # set command tree
      state.commandTreeIdx = state.blockTypesRb[3] # for cmd type (rings[6]=? Actually index 3 is second element of type 1? Let's map: type0 -> rb0,1; type1 -> 2,3; type2 ->4,5
      let cmdDec = state.commandDecoders[state.commandTreeIdx]
      # handle single-symbol decoder case
      var cmdCode: int
      if cmdDec.maxLen == 0:
        cmdCode = cmdDec.maps[0][0]
      else:
        cmdCode = cmdDec.decodeSymbol(br)
      state.blockLens[1].dec
      let lut = kCmdLut[cmdCode]
      var insertLen = lut.insertLenOffset.int
      if lut.insertLenExtraBits != 0:
        var extra: uint32
        if not br.safeReadBits(lut.insertLenExtraBits.uint32, extra):
          raiseBrotli(ErrFormatBlockLength1, "insert extra")
        insertLen += extra.int
      var distanceCode = lut.distanceCode.int
      var distContext = lut.context.int
      var copyLen = lut.copyLenOffset.int
      if lut.copyLenExtraBits != 0:
        var extra: uint32
        if not br.safeReadBits(lut.copyLenExtraBits.uint32, extra):
          raiseBrotli(ErrFormatBlockLength1, "copy extra")
        copyLen += extra.int
      # Literals
      if insertLen > 0:
        if metaRemaining < insertLen:
          raiseBrotli(ErrFormatBlockLength1, "insert exceeds meta")
        for i in 0..<insertLen:
          if state.blockLens[0] == 0:
            decodeBlockTypeAndLength(br, state.numBlockTypes[0], state.blockTypeTrees[0], state.blockLenTrees[0], state.blockTypesRb, 0)
            state.blockLens[0] = readBlockLength(br, state.blockLenTrees[0])
          let litType = state.blockTypesRb[1]
          let ctxMapOff = litType shl 6
          let isTrivial = (state.trivialLiteralContexts[litType shr 5] shr (litType and 31)) and 1
          var litSym: int
          if isTrivial == 1:
            let dec = state.literalDecoders[state.contextMap[ctxMapOff].int]
            if dec.maxLen == 0:
              litSym = dec.maps[0][0]
            else:
              litSym = dec.decodeSymbol(br)
          else:
            let ctx = brotliContext(prevByte1, prevByte2, state.contextModes[litType].int).int
            let treeIdx = state.contextMap[ctxMapOff + ctx].int
            let dec = state.literalDecoders[treeIdx]
            if dec.maxLen == 0:
              litSym = dec.maps[0][0]
            else:
              litSym = dec.decodeSymbol(br)
          state.blockLens[0].dec
          let b = litSym.uint8
          # write to ring and output
          state.ring[state.ringPos and state.ringMask] = b
          output.add(b)
          state.ringPos.inc
          prevByte2 = prevByte1
          prevByte1 = b
        metaRemaining -= insertLen
        if metaRemaining == 0: break
      if copyLen == 0:
        continue
      # Distance
      var distance = 0
      var distanceRingCtx = 0
      var isImplicit = false
      if distanceCode >= 0:
        # implicit distance - last distance
        distanceRingCtx = if distanceCode == 0: 1 else: 0
        isImplicit = true
        state.distRbIdx = (state.distRbIdx - 1) and 3
        distance = state.distRb[state.distRbIdx]
      else:
        if state.blockLens[2] == 0:
          decodeBlockTypeAndLength(br, state.numBlockTypes[2], state.blockTypeTrees[2], state.blockLenTrees[2], state.blockTypesRb, 2)
          state.blockLens[2] = readBlockLength(br, state.blockLenTrees[2])
        let dCtxMapOff = state.blockTypesRb[5] shl 2
        let dTreeIdx = state.distContextMap[dCtxMapOff + distContext].int
        let dDec = state.distanceDecoders[dTreeIdx]
        var dCode: int
        if dDec.maxLen == 0:
          dCode = dDec.maps[0][0]
        else:
          dCode = dDec.decodeSymbol(br)
        state.blockLens[2].dec
        distanceCode = dCode
        if distanceCode < 16:
          let res = takeDistanceFromRingBuffer(state, distanceCode)
          distance = res.dist
          distanceRingCtx = res.ctx
          if distance <= 0 or distance > 0x7FFFFFFC:
            raiseBrotli(ErrFormatDistance, "distance short")
        else:
          var bits = state.distExtraBits[distanceCode].int
          var off = state.distOffset[distanceCode]
          var extra: uint32 = 0
          if bits > 0:
            if not br.safeReadBits(bits.uint32, extra):
              raiseBrotli(ErrFormatDistance, "dist extra")
          let distance64 = off + (extra.uint64 shl state.distancePostfixBits.uint64)
          if distance64 == 0 or distance64 > 0x7FFFFFFC'u64:
            raiseBrotli(ErrFormatDistance, "distance long")
          distance = distance64.int
          distanceRingCtx = 0
        isImplicit = false
      # Update max distance
      if state.ringPos < state.maxBackwardDistance:
        state.maxDistance = state.ringPos
      else:
        state.maxDistance = state.maxBackwardDistance
      if distance.uint64 > state.maxDistance.uint64:
        # dictionary word
        if copyLen < 4 or copyLen > 24:
          raiseBrotli(ErrFormatDictionary, "dict len")
        let address = distance - state.maxDistance - 1
        let dict = kBrotliDictionaryData
        # compute offset via sizeBits
        let bits = SizeBitsByLength[copyLen].int
        if bits == 0:
          raiseBrotli(ErrFormatDictionary, "dict bits 0")
        let offBase = OffsetsByLength[copyLen].int
        let mask = (1 shl bits) - 1
        let wordIdx = address and mask
        let transIdx = address shr bits
        if transIdx >= kNumTransforms:
          raiseBrotli(ErrFormatTransform, "trans idx")
        let dictOff = offBase + wordIdx * copyLen
        var word = newSeq[byte](copyLen)
        for i in 0..<copyLen:
          word[i] = dict[dictOff + i]
        var dstTmp = newSeq[byte](copyLen + 20) # enough for prefix/suffix
        let written = transformDictionaryWord(dstTmp, 0, word, transIdx)
        for i in 0..<written:
          let b = dstTmp[i]
          state.ring[state.ringPos and state.ringMask] = b
          output.add(b)
          state.ringPos.inc
          prevByte2 = prevByte1
          prevByte1 = b
        metaRemaining -= written
        # compensate double roll for dictionary (C: dist_rb_idx += distance_context)
        state.distRbIdx = (state.distRbIdx + distanceRingCtx) and 3
      else:
        # LZ77 copy - update ring with distance
        state.distRb[state.distRbIdx and 3] = distance
        state.distRbIdx = (state.distRbIdx + 1) and 3
        if copyLen > metaRemaining:
          raiseBrotli(ErrFormatBlockLength1, "copy exceeds")
        for i in 0..<copyLen:
          let srcPos = (state.ringPos - distance) and state.ringMask
          let b = state.ring[srcPos]
          state.ring[state.ringPos and state.ringMask] = b
          output.add(b)
          state.ringPos.inc
          prevByte2 = prevByte1
          prevByte1 = b
        metaRemaining -= copyLen
      # end while
    # next meta block
    state.br = br
    # update output handling already via ringPos
    discard
  return output
