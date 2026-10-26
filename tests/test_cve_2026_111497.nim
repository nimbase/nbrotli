## Regression test for CVE-2026-111497 (Node2Shell / block-switch OOB write).
##
## Upstream (google/brotli 1.2.1): DecodeBlockTypeAndLength() returned an
## ambiguous BOOL for an invalid block switch (stream declares a single block
## type, then asks to switch). The fast decode path discarded it (CWE-252),
## continued on corrupted state and wrote past the ring buffer (CWE-787).
## Fix: distinct BROTLI_DECODER_ERROR_FORMAT_BLOCK_SWITCH (-17) propagated via
## BROTLI_SAFE_WITH_STATUS instead of BROTLI_SAFE.
##
## nbrotli mirrors that contract:
##  - decodeBlockTypeAndLength() raises ErrFormatBlockSwitch (-17), never a
##    retryable "needs more input" signal.
##  - streaming decoder maps -17 to Error (fail fast, latch errorCode),
##    all other BrotliErrors stay NeedsMoreInput so truncated input can still
##    be completed via feed().
import unittest
import std/strutils
import nbrotli
import nbrotli/decode
import nbrotli/decoder
import nbrotli/bitreader

suite "CVE-2026-111497 invalid block switch":
  test "decodeBlockTypeAndLength rejects single-type switch for all tree types":
    for typeIdx in [0, 1, 2]:
      var br = initBitReader(@[0'u8])
      var rings: array[6, int] = [1, 0, 1, 0, 1, 0]
      let empty = initHuffmanDecoderEmpty()
      var raised = false
      try:
        decodeBlockTypeAndLength(br, 1, empty, empty, rings, typeIdx)
      except BrotliError as e:
        raised = true
        check e.code == ErrFormatBlockSwitch
        check e.code == -17
      check raised

  test "decodeBlockTypeAndLength rejects zero-type switch":
    var br = initBitReader(@[0'u8])
    var rings: array[6, int] = [1, 0, 1, 0, 1, 0]
    let empty = initHuffmanDecoderEmpty()
    expect BrotliError:
      decodeBlockTypeAndLength(br, 0, empty, empty, rings, 1)

  test "simulated hot-loop precondition (blockLens==0, numTypes==1) fails fast":
    # Mirrors decode.nim hot loop:
    #   if state.blockLens[1] == 0:
    #     decodeBlockTypeAndLength(br, state.numBlockTypes[1], ...)
    # With a single declared command block type and an exhausted block, the
    # switch must raise BLOCK_SWITCH, not return normally.
    var br = initBitReader(@[0xFF'u8, 0xFF'u8])
    var rings: array[6, int] = [1, 0, 1, 0, 1, 0]
    let empty = initHuffmanDecoderEmpty()
    let numBlockTypes = 1
    let blockLen = 0
    check blockLen == 0
    var raised = false
    try:
      decodeBlockTypeAndLength(br, numBlockTypes, empty, empty, rings, 1)
    except BrotliError as e:
      raised = true
      check e.code == ErrFormatBlockSwitch
    check raised

  test "streaming classifier: block switch is Error, others need more input":
    check classifyBrotliError(ErrFormatBlockSwitch) == Error
    check classifyBrotliError(ErrFormatExuberantNibble) == NeedsMoreInput
    check classifyBrotliError(ErrFormatHuffmanSpace) == NeedsMoreInput
    check classifyBrotliError(ErrFormatBlockLength1) == NeedsMoreInput

  test "streaming truncated input still returns NeedsMoreInput (no regression)":
    # A truncated store stream must remain retryable, not Error.
    let storeData = toBytes("x".repeat(100))
    let encStore = compressStore(storeData)
    check encStore.len > 4
    var dec = initDecoder()
    dec.feed(encStore.toOpenArray(0, 3))
    var tmp: seq[byte] = @[]
    let res = dec.decodeSome(tmp, 65536)
    check res == NeedsMoreInput
    check not dec.hasError()

  test "streaming valid roundtrip still succeeds":
    let data = toBytes("Hello CVE".repeat(10))
    let enc = compressStore(data)
    var dec = initDecoder()
    dec.feed(enc)
    var outBuf: seq[byte] = @[]
    let res = dec.decodeSome(outBuf, 65536)
    check res == Success
    check outBuf == data

  test "streaming latches block-switch error and ignores further input":
    # Fail-fast contract (upstream saveStateAndReturn on error): once a
    # BLOCK_SWITCH error is latched, feed() is a no-op and decodeSome()
    # keeps returning Error instead of retrying as NeedsMoreInput.
    var dec = initDecoder()
    dec.feed(toBytes("junk"))
    dec.errorCode = ErrFormatBlockSwitch
    dec.errorMsg = "block switch"
    dec.feed(toBytes("more junk"))
    check dec.compressed == toBytes("junk")
    var tmp: seq[byte] = @[]
    # Push through decodeSome with only junk buffered: one-shot raises some
    # BrotliError; but with the latched errorCode the decoder must report
    # Error, never silently retry. Reset to a clean latched state first.
    var dec2 = initDecoder()
    dec2.errorCode = ErrFormatBlockSwitch
    dec2.errorMsg = "block switch"
    var tmp2: seq[byte] = @[]
    check dec2.decodeSome(tmp2, 65536) == Error
    check dec2.hasError()
