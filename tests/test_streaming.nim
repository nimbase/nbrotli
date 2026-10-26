import unittest
import std/[os, osproc, strutils]
import nbrotli

proc hasBrotliCli(): bool =
  let (_, c) = execCmdEx("brotli --version")
  c == 0

suite "streaming incremental decoder":
  test "one-shot vs chunked feed (q=6)":
    if not hasBrotliCli(): skip()
    let s = "Hello, Brotli! Hello, Brotli! Hello, Brotli! This is a test of pure Nim decoder. "
    let dir = getTempDir()
    let inPath = dir / "stream_input.txt"
    let brPath = dir / "stream.br"
    writeFile(inPath, s)
    let (_, cc) = execCmdEx("brotli -q 6 -f " & quoteShell(inPath) &
      " -o " & quoteShell(brPath))
    check cc == 0
    let data = cast[seq[byte]](readFile(brPath))
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
    let dir = getTempDir()
    let inPath = dir / "stream_lw.txt"
    let brPath = dir / "stream_lw.br"
    writeFile(inPath, s)
    let (_, cc) = execCmdEx("brotli --large_window=25 -q 4 -f " &
      quoteShell(inPath) & " -o " & quoteShell(brPath))
    check cc == 0
    let data = cast[seq[byte]](readFile(brPath))
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
