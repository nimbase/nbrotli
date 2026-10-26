import unittest
import std/[os, osproc, strutils]
import nbrotli

proc hasBrotliCli(): bool =
  let (_, code) = execCmdEx("brotli --version")
  code == 0

suite "brotli large window (WBITS 10..30)":
  test "w10..24 via regular -w":
    if not hasBrotliCli(): skip()
    let dir = getTempDir()
    for w in [10, 16, 20, 24]:
      let s = "LargeWindow test w=" & $w & " " & "abc".repeat(2000)
      let inPath = dir / "nb_lw.txt"
      let brFile = dir / ("nb_lw_" & $w & ".br")
      writeFile(inPath, s)
      let (_, code) = execCmdEx("brotli -w " & $w & " -q 6 -f " &
        quoteShell(inPath) & " -o " & quoteShell(brFile))
      check code == 0
      let data = cast[seq[byte]](readFile(brFile))
      let dec = decompress(data)
      check cast[string](dec) == s

  test "large window w25,27,30 via --large_window":
    if not hasBrotliCli(): skip()
    let dir = getTempDir()
    for w in [25, 27, 30]:
      let s = "Hello Large Window! ".repeat(2000) # ~40k
      let inPath = dir / "nb_lw2.txt"
      let brFile = dir / ("nb_lw2_" & $w & ".br")
      writeFile(inPath, s)
      let (_, code) = execCmdEx("brotli --large_window=" & $w & " -q 6 -f " &
        quoteShell(inPath) & " -o " & quoteShell(brFile))
      check code == 0
      let data = cast[seq[byte]](readFile(brFile))
      let dec = decompress(data)
      check cast[string](dec) == s

  test "large window with 500k and w30":
    if not hasBrotliCli(): skip()
    let dir = getTempDir()
    var s = newString(500_000)
    for i in 0..<s.len: s[i] = char((i*31) and 0xFF)
    let inPath = dir / "nb_lw3.txt"
    let brPath = dir / "nb_lw3.br"
    writeFile(inPath, s)
    let (_, code) = execCmdEx("brotli --large_window=30 -q 4 -f " &
      quoteShell(inPath) & " -o " & quoteShell(brPath))
    check code == 0
    let data = cast[seq[byte]](readFile(brPath))
    let dec = decompress(data)
    check dec.len == s.len
    check cast[string](dec) == s

  test "invalid large window bits rejected":
    expect(ValueError):
      discard compressStore(@[1'u8,2'u8], 9)
    expect(ValueError):
      discard compressStore(@[1'u8], 30) # 30 >24 not allowed for store (store only 10..24)
    check true

  test "lazy ring allocation does not OOM for w30 small data":
    if not hasBrotliCli(): skip()
    let dir = getTempDir()
    let s = "tiny"
    let inPath = dir / "nb_lw_tiny.txt"
    let brPath = dir / "nb_lw_tiny.br"
    writeFile(inPath, s)
    let (_, code) = execCmdEx("brotli --large_window=30 -q 6 -f " &
      quoteShell(inPath) & " -o " & quoteShell(brPath))
    check code == 0
    let data = cast[seq[byte]](readFile(brPath))
    # Should decode without allocating 1GB
    let dec = decompress(data)
    check cast[string](dec) == s
