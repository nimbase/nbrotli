import unittest
import std/[os, osproc, strutils]
import nbrotli

proc hasBrotliCli(): bool =
  let (_, code) = execCmdEx("brotli --version 2>&1")
  code == 0

suite "brotli large window (WBITS 10..30)":
  test "w10..24 via regular -w":
    if not hasBrotliCli(): skip()
    for w in [10, 16, 20, 24]:
      let s = "LargeWindow test w=" & $w & " " & "abc".repeat(2000)
      writeFile("/tmp/nb_lw.txt", s)
      let brFile = "/tmp/nb_lw_" & $w & ".br"
      let code = execShellCmd("brotli -w " & $w & " -q 6 -c /tmp/nb_lw.txt > " & brFile & " 2>/dev/null")
      check code == 0
      let data = cast[seq[byte]](readFile(brFile))
      let dec = decompress(data)
      check cast[string](dec) == s

  test "large window w25,27,30 via --large_window":
    if not hasBrotliCli(): skip()
    for w in [25, 27, 30]:
      let s = "Hello Large Window! ".repeat(2000) # ~40k
      writeFile("/tmp/nb_lw2.txt", s)
      let brFile = "/tmp/nb_lw2_" & $w & ".br"
      let code = execShellCmd("brotli --large_window=" & $w & " -q 6 -c /tmp/nb_lw2.txt > " & brFile & " 2>/dev/null")
      check code == 0
      let data = cast[seq[byte]](readFile(brFile))
      let dec = decompress(data)
      check cast[string](dec) == s

  test "large window with 500k and w30":
    if not hasBrotliCli(): skip()
    var s = newString(500_000)
    for i in 0..<s.len: s[i] = char((i*31) and 0xFF)
    writeFile("/tmp/nb_lw3.txt", s)
    let code = execShellCmd("brotli --large_window=30 -q 4 -c /tmp/nb_lw3.txt > /tmp/nb_lw3.br 2>/dev/null")
    check code == 0
    let data = cast[seq[byte]](readFile("/tmp/nb_lw3.br"))
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
    let s = "tiny"
    writeFile("/tmp/nb_lw_tiny.txt", s)
    let code = execShellCmd("brotli --large_window=30 -q 6 -c /tmp/nb_lw_tiny.txt > /tmp/nb_lw_tiny.br 2>/dev/null")
    check code == 0
    let data = cast[seq[byte]](readFile("/tmp/nb_lw_tiny.br"))
    # Should decode without allocating 1GB
    let dec = decompress(data)
    check cast[string](dec) == s
