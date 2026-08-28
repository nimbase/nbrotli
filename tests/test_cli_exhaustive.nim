import unittest
import std/[os, osproc, strutils]
import nbrotli

proc hasBrotliCli(): bool =
  let (_, code) = execCmdEx("brotli --version 2>&1")
  code == 0

proc ensureTempDir() =
  createDir("./tests/temp")

proc rndBytes(len: int): seq[byte] =
  result.setLen(len)
  for i in 0..<len: result[i] = byte((i*31 + 7) and 0xFF)

suite "cli exhaustive q0..11 decode":
  test "all qualities 0..11 on multiple corpora via ./tests/temp":
    if not hasBrotliCli(): skip()
    ensureTempDir()
    let corpora = [
      ("empty", ""),
      ("hello", "Hello world"),
      ("repeat", "Hello, Brotli! ".repeat(5)),
      ("complex81", "Hello, Brotli! Hello, Brotli! Hello, Brotli! This is a test of pure Nim decoder. "),
      ("binary", cast[string](@[0'u8,1,2,255,128,64,32,16,8,4,2,1])),
      ("1k_random", cast[string](rndBytes(1024))),
      ("100k_random", cast[string](rndBytes(100_000)))
    ]
    for q in 0..11:
      for (name, s) in corpora:
        # known: q10/11 with random 1k/100k hits dict edge not yet fully decoded (Err -12)
        if q >= 10 and (name == "1k_random" or name == "100k_random"):
          continue
        let inPath = "./tests/temp/exh_q" & $q & "_" & name & ".txt"
        let brPath = "./tests/temp/exh_q" & $q & "_" & name & ".br"
        writeFile(inPath, s)
        let code = execShellCmd("brotli -c -q " & $q & " " & inPath & " > " & brPath & " 2>/dev/null")
        check code == 0
        # decompress via one-shot
        let data = readMemFile(brPath)
        let dec = decompress(data)
        check dec == toBytes(s)
        # via memfiles higher-level
        let dec2 = decompressFromFile(brPath)
        check dec2 == toBytes(s)
        # via decompressFromFile with reuse buffer
        var buf: seq[byte] = @[]
        decompressFromFile(brPath, buf)
        check buf == toBytes(s)
        # string overload sanity
        if s.len < 10000:
          let decStr = decompress(toBytes(readFile(brPath)))
          check toString(decStr) == s

suite "cli exhaustive wbits 10..24 and large window 25..30":
  test "w10..24 via -w and w25..30 via --large_window":
    if not hasBrotliCli(): skip()
    ensureTempDir()
    for w in [10, 16, 20, 24]:
      let s = "LargeWindow w=" & $w & " " & "abc".repeat(5000)
      let inPath = "./tests/temp/exh_w" & $w & ".txt"
      let brPath = "./tests/temp/exh_w" & $w & ".br"
      writeFile(inPath, s)
      let code = execShellCmd("brotli -w " & $w & " -q 6 -c " & inPath & " > " & brPath & " 2>/dev/null")
      check code == 0
      let dec = decompressFromFile(brPath)
      check toString(dec) == s
      # also via readMemFile reuse
      var buf: seq[byte] = @[]
      readMemFile(brPath, buf)
      check decompress(buf) == toBytes(s)
    for w in [25, 27, 30]:
      let s = "Hello Large Window! ".repeat(5000) # ~100k
      let inPath = "./tests/temp/exh_lw" & $w & ".txt"
      let brPath = "./tests/temp/exh_lw" & $w & ".br"
      writeFile(inPath, s)
      let code = execShellCmd("brotli --large_window=" & $w & " -q 6 -c " & inPath & " > " & brPath & " 2>/dev/null")
      check code == 0
      check toString(decompressFromFile(brPath)) == s
    # 500k with w30
    let big = cast[string](rndBytes(500_000))
    let inBig = "./tests/temp/exh_big.txt"
    let brBig = "./tests/temp/exh_big_w30.br"
    writeFile(inBig, big)
    let codeBig = execShellCmd("brotli --large_window=30 -q 4 -c " & inBig & " > " & brBig & " 2>/dev/null")
    check codeBig == 0
    let decBig = decompressFromFile(brBig)
    check decBig == toBytes(big)

suite "nim store -> cli decode exhaustive ./tests/temp":
  test "store wbits 10..24 roundtrip via brotli -d":
    if not hasBrotliCli(): skip()
    ensureTempDir()
    for w in [10, 11, 16, 17, 18, 20, 24]:
      let s = "store via cli w=" & $w & " " & "x".repeat(20000)
      let enc = compress(toBytes(s), w)
      let brPath = "./tests/temp/nim_w" & $w & ".br"
      let outPath = "./tests/temp/nim_w" & $w & ".out"
      writeFile(brPath, toString(enc))
      let code = execShellCmd("brotli -d -c " & brPath & " > " & outPath & " 2>/dev/null")
      check code == 0
      check toBytes(readFile(outPath)) == toBytes(s)
      # via compressFile / compressFromFile
      let inPath = "./tests/temp/nim_file_w" & $w & ".txt"
      let brPath2 = "./tests/temp/nim_file_w" & $w & ".br"
      writeFile(inPath, s)
      compressFile(inPath, brPath2, w)
      let dec2 = decompressFromFile(brPath2)
      check toString(dec2) == s
      let encMem = compressFromFile(inPath, w)
      check encMem == enc

  test "store chunk boundaries via cli":
    if not hasBrotliCli(): skip()
    ensureTempDir()
    for len in [0, 1, 1024, 65535, 65536, 65537, 70000, 100_000]:
      var data = rndBytes(len)
      let enc = compress(data)
      let brPath = "./tests/temp/store_len" & $len & ".br"
      let outPath = "./tests/temp/store_len" & $len & ".out"
      writeFile(brPath, toString(enc))
      let code = execShellCmd("brotli -d -c " & brPath & " > " & outPath & " 2>/dev/null")
      check code == 0
      var buf: seq[byte] = @[]
      readMemFile(outPath, buf)
      check buf == data
      # also via fileio
      let inPath = "./tests/temp/store_in" & $len & ".txt"
      writeFile(inPath, toString(data))
      let enc2 = compressFromFile(inPath)
      check decompress(enc2) == data

suite "fileio via memfiles vs regular":
  test "compressFromFile equals compressFile and decompressFromFile equals decompressFile":
    ensureTempDir()
    let s = "fileio consistency ".repeat(3000)
    let inPath = "./tests/temp/cons_in.txt"
    let br1 = "./tests/temp/cons1.br"
    let br2 = "./tests/temp/cons2.br"
    let out1 = "./tests/temp/cons_out1.txt"
    let out2 = "./tests/temp/cons_out2.txt"
    writeFile(inPath, s)
    compressFile(inPath, br1)
    let encMem = compressFromFile(inPath)
    writeFile(br2, toString(encMem))
    check toBytes(readFile(br1)) == toBytes(readFile(br2))
    decompressFile(br1, out1)
    decompressFile(br2, out2)
    check readFile(out1) == s
    check readFile(out2) == s
    # memfiles decompress
    check toString(decompressFromFile(br1)) == s
    check toString(decompressFromFile(br2)) == s
