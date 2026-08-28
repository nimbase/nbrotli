import unittest
import std/[os, osproc, strutils]
import nbrotli

proc hasBrotliCli(): bool =
  let (_, code) = execCmdEx("brotli --version 2>&1")
  code == 0

suite "brotli store encoder (compressStore)":
  test "empty roundtrip nim":
    let data: seq[byte] = @[]
    let enc = compressStore(data)
    check enc.len == 1 # wbits=16 (1 bit) + 2 bits empty header padded to byte
    check decompress(enc).len == 0
    check decompress(cast[string](enc)).len == 0

  test "empty string overload":
    let enc = compressStore("")
    check decompress(enc) == ""

  test "single byte":
    let data = @[42'u8]
    let enc = compressStore(data)
    check decompress(enc) == data
    check decompress(compressStore("a")) == "a"

  test "hello world":
    let s = "Hello World"
    let enc = compressStore(s)
    check decompress(enc) == s
    check decompressToString(compressStore(cast[seq[byte]](s))) == s

  test "1024 repeat":
    let s = "a".repeat(1024)
    let data = cast[seq[byte]](s)
    let enc = compressStore(data)
    check decompress(enc) == data
    # overhead: header + raw + terminator
    check enc.len > data.len and enc.len < data.len + 10

  test "chunk boundary 65535, 65536, 65537":
    for len in [65535, 65536, 65537]:
      var d = newSeq[byte](len)
      for i in 0..<len: d[i] = byte(i and 0xFF)
      let enc = compressStore(d)
      let dec = decompress(enc)
      check dec == d
      # 65537 should be 2 chunks + terminator, so at least one extra header
      if len == 65537:
        check enc.len == len + 7 # 3 byte header per chunk approx + wbits + terminator
      if len == 65536:
        check enc.len > len

  test "70k two chunks":
    let data = cast[seq[byte]]("x".repeat(70000))
    let enc = compressStore(data)
    check decompress(enc) == data

  test "100k random":
    var rnd = newSeq[byte](100000)
    for i in 0..<rnd.len: rnd[i] = byte((i*31 + 7) and 0xFF)
    let enc = compressStore(rnd)
    check decompress(enc) == rnd

  test "binary with NUL and high bytes":
    let data = @[0'u8, 1, 2, 255, 128, 64, 32, 16, 8, 4, 2, 1]
    let enc = compressStore(data)
    check decompress(enc) == data

  test "wbits variants 10..24":
    for w in [10,11,16,17,18,20,24]:
      let data = cast[seq[byte]]("test wbits " & $w)
      let enc = compressStore(data, w)
      let dec = decompress(enc)
      check dec == data

  test "wbits invalid raises":
    expect(ValueError):
      discard compressStore(@[1'u8,2'u8], 9)
    expect(ValueError):
      discard compressStore(@[1'u8], 25)
    expect(ValueError):
      discard compressStore(@[1'u8], 30)

  test "string overload large":
    let s = "abc".repeat(22000) # 66000 bytes, crosses chunk
    let enc = compressStore(s)
    check decompress(enc) == s

  test "brotli CLI decompresses store output":
    if not hasBrotliCli():
      skip()
    else:
      let data = cast[seq[byte]]("Hello Store via CLI " & "x".repeat(5000))
      let enc = compressStore(data)
      let tmpBr = "/tmp/nb_store_cli_test.br"
      let tmpOut = "/tmp/nb_store_cli_test.out"
      writeFile(tmpBr, cast[string](enc))
      let (outp, code) = execCmdEx("brotli -d -c " & tmpBr & " > " & tmpOut & " 2>&1; echo EXIT:$?")
      # brotli -d should succeed (we check file)
      let decoded = cast[seq[byte]](readFile(tmpOut))
      check decoded == data

  test "cli chunk boundaries via brotli -d":
    if not hasBrotliCli():
      skip()
    else:
      for len in [0,1,65536,65537,70000]:
        var d = newSeq[byte](len)
        for i in 0..<len: d[i]=byte((i*7) and 0xFF)
        let enc = compressStore(d)
        writeFile("/tmp/nb_store_cli2.br", cast[string](enc))
        let code = execShellCmd("brotli -d -c /tmp/nb_store_cli2.br > /tmp/nb_store_cli2.out 2>/dev/null")
        check code == 0
        let decoded = cast[seq[byte]](readFile("/tmp/nb_store_cli2.out"))
        check decoded == d
