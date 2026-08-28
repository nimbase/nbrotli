import unittest
import std/[os, osproc, strutils]
import nbrotli

proc hasBrotliCli(): bool =
  let (_, c) = execCmdEx("brotli --version 2>&1")
  c == 0

suite "streaming incremental decoder":
  test "one-shot vs chunked feed (q=6)":
    if not hasBrotliCli(): skip()
    let s = "Hello, Brotli! Hello, Brotli! Hello, Brotli! This is a test of pure Nim decoder. "
    writeFile("/tmp/stream_input.txt", s)
    discard execShellCmd("cat /tmp/stream_input.txt | brotli -c -q 6 > /tmp/stream.br 2>/dev/null")
    let data = cast[seq[byte]](readFile("/tmp/stream.br"))
    let expected = decompress(data)
    check cast[string](expected) == s
    for chunk in [1, 7, 28, 100]:
      var dec = initDecoder()
      var outBuf: seq[byte] = @[]
      # Feed all chunks first, then decode once (buffered wrapper)
      var pos = 0
      while pos < data.len:
        let take = min(chunk, data.len - pos)
        dec.feed(data.toOpenArray(pos, pos+take-1))
        pos += take
      var tmp: seq[byte] = @[]
      let res = dec.decodeSome(tmp, 65536)
      outBuf.add(tmp)
      # Also try incremental helper
      let out2 = decompressIncremental(data, @[chunk])
      check outBuf == expected
      check out2 == expected
      check res in {Success, NeedsMoreOutput}

  test "store stream chunked":
    let storeData = cast[seq[byte]]("x".repeat(70000))
    let encStore = compressStore(storeData)
    for chunk in [1, 100, 7000]:
      var dec = initDecoder()
      var pos = 0
      while pos < encStore.len:
        let take = min(chunk, encStore.len - pos)
        dec.feed(encStore.toOpenArray(pos, pos+take-1))
        pos += take
      var outBuf: seq[byte] = @[]
      while true:
        var tmp: seq[byte] = @[]
        let res = dec.decodeSome(tmp, 65536)
        outBuf.add(tmp)
        if res == Success: break
        if res == Error: break
        if res == NeedsMoreInput: break
        # NeedsMoreOutput -> continue loop
        if tmp.len == 0: break
      check outBuf == storeData

  test "large window chunked":
    if not hasBrotliCli(): skip()
    let s = "LargeWindow chunked test ".repeat(5000) # ~125k
    writeFile("/tmp/stream_lw.txt", s)
    discard execShellCmd("brotli --large_window=25 -q 4 -c /tmp/stream_lw.txt > /tmp/stream_lw.br 2>/dev/null")
    let data = cast[seq[byte]](readFile("/tmp/stream_lw.br"))
    let expected = decompress(data)
    check cast[string](expected) == s
    var dec = initDecoder()
    var pos = 0
    let chunk = 100
    while pos < data.len:
      let take = min(chunk, data.len - pos)
      dec.feed(data.toOpenArray(pos, pos+take-1))
      pos += take
    var outBuf: seq[byte] = @[]
    while true:
      var tmp: seq[byte] = @[]
      let res = dec.decodeSome(tmp, 65536)
      outBuf.add(tmp)
      if res == Success: break
      if res in {Error, NeedsMoreInput}: break
      if tmp.len == 0: break
    check outBuf == expected
