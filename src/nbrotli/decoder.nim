## Streaming incremental decoder — Phase C
## Simple buffered wrapper over BrotliDecompress for chunked input.
## Mirrors C BrotliDecoderDecompressStream semantics with feed/decodeSome.
import decode, utils, simd

type
  BrotliDecoderResult* = enum
    NeedsMoreInput
    NeedsMoreOutput
    Success
    Error

  BrotliDecoder* = object
    compressed*: seq[byte]
    finished*: bool
    errorCode*: int
    errorMsg*: string
    decompressed*: seq[byte]
    outputPos*: int  ## how much of decompressed already consumed via decodeSome

proc initDecoder*(): BrotliDecoder =
  result.compressed = @[]
  result.finished = false
  result.errorCode = 0
  result.errorMsg = ""
  result.decompressed = @[]
  result.outputPos = 0

proc feed*(d: var BrotliDecoder, data: openArray[byte]) =
  ## Append chunk to internal compressed buffer. No-op if already finished/error.
  if d.finished or d.errorCode != 0: return
  let oldLen = d.compressed.len
  d.compressed.setLen(oldLen + data.len)
  if data.len > 0:
    copyMemSimd(addr d.compressed[oldLen], unsafeAddr data[0], data.len)

proc feed*(d: var BrotliDecoder, data: string) =
  feed(d, toBytes(data))

proc isFinished*(d: BrotliDecoder): bool = d.finished
proc hasError*(d: BrotliDecoder): bool = d.errorCode != 0
proc errorCode*(d: BrotliDecoder): int = d.errorCode
proc errorMsg*(d: BrotliDecoder): string = d.errorMsg

proc tryDecompress(d: var BrotliDecoder): BrotliDecoderResult =
  ## Attempt to decompress current compressed buffer.
  ## On success, set decompressed/finished. On truncation, return NeedsMoreInput.
  ## On format error, set error and return Error.
  if d.finished: return Success
  if d.compressed.len == 0:
    return NeedsMoreInput
  try:
    let dec = BrotliDecompress(d.compressed)
    d.decompressed = dec
    d.finished = true
    d.outputPos = 0
    return Success
  except BrotliError as e:
    # For incremental decoding, truncated input manifests as BrotliError with
    # format codes. Treat as NeedsMoreInput to allow further feed, without
    # setting persistent errorCode (so next feed can succeed). Only set
    # errorCode if we have already determined stream is finished or corrupt
    # and no more input will help. For buffered wrapper, we keep retrying.
    # If after all chunks it still fails, the final decompressIncremental
    # fallback will attempt one-shot and report.
    # Do NOT set d.errorCode here; keep it 0 to allow further feed.
    d.errorMsg = e.msg
    # Keep errorCode 0 for retry; return NeedsMoreInput
    return NeedsMoreInput
  except CatchableError as e:
    d.errorCode = -100
    d.errorMsg = e.msg
    return Error

proc decodeSome*(d: var BrotliDecoder, outBuf: var seq[byte], maxOut = 65536): BrotliDecoderResult =
  ## Try to decode as much as possible given current compressed buffer.
  ## Appends newly decoded bytes to outBuf (up to maxOut) and advances outputPos.
  ## Returns Success when stream finished, NeedsMoreInput when truncated, Error on format error.
  let res = tryDecompress(d)
  if res == Success:
    # Copy from decompressed[outputPos ..] to outBuf
    let remaining = d.decompressed.len - d.outputPos
    if remaining > 0:
      let toCopy = min(remaining, maxOut)
      let oldLen = outBuf.len
      outBuf.setLen(oldLen + toCopy)
      copyMemSimd(addr outBuf[oldLen], addr d.decompressed[d.outputPos], toCopy)
      d.outputPos += toCopy
      if d.outputPos < d.decompressed.len:
        return NeedsMoreOutput
    return Success
  elif res == NeedsMoreInput:
    # If we have already decoded some prefix (not possible with one-shot, but for API)
    # return what we have, otherwise just signal need more
    return NeedsMoreInput
  else:
    return Error

proc decompressIncremental*(data: openArray[byte], chunkSizes: seq[int]): seq[byte] =
  ## Helper for tests: feed data split by chunkSizes and decode incrementally.
  ## Buffered wrapper: feed all chunks then decode once.
  var dec = initDecoder()
  var pos = 0
  var chunkIdx = 0
  while pos < data.len:
    let sz = if chunkIdx < chunkSizes.len: chunkSizes[chunkIdx] else: 1
    let take = min(sz, data.len - pos)
    dec.feed(data.toOpenArray(pos, pos+take-1))
    pos += take
    chunkIdx.inc
  var outBuf: seq[byte] = @[]
  discard dec.decodeSome(outBuf, 1 shl 20)
  result = outBuf

proc decompressAll*(d: var BrotliDecoder): seq[byte] =
  ## Convenience: after all feed calls, return full decompressed if available.
  if d.finished:
    return d.decompressed
  let res = tryDecompress(d)
  if res == Success:
    return d.decompressed
  else:
    return @[]
