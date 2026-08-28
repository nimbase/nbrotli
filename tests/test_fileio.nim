import unittest
import std/[os, strutils]
import nbrotli

proc ensureTempDir() =
  createDir("./tests/temp")

suite "fileio high-level API":
  test "compress alias vs compressStore":
    let data = toBytes("Hello fileio")
    check compress(data) == compressStore(data)
    check compress("Hello fileio") == compressStore("Hello fileio")
    for w in [10, 16, 20, 24]:
      check compress(data, w) == compressStore(data, w)

  test "compressFile and decompressFile roundtrip":
    ensureTempDir()
    let s = "Hello file API! ".repeat(1000)
    let inPath = "./tests/temp/fileio_in.txt"
    let brPath = "./tests/temp/fileio_in.br"
    let outPath = "./tests/temp/fileio_out.txt"
    writeFile(inPath, s)
    compressFile(inPath, brPath)
    check fileExists(brPath)
    decompressFile(brPath, outPath)
    check readFile(outPath) == s
    # also verify via decompress
    check toString(decompress(toBytes(readFile(brPath)))) == s

  test "compressFromFile via memfiles":
    ensureTempDir()
    let s = "memfiles compress ".repeat(5000)
    let inPath = "./tests/temp/mem_in.txt"
    let brPath = "./tests/temp/mem_cli.br"
    writeFile(inPath, s)
    let viaMem = compressFromFile(inPath)
    let viaRegular = compressStore(toBytes(s))
    check viaMem == viaRegular
    # write via fileio helper and decompress
    let enc = compressFromFile(inPath, 16)
    check decompress(enc) == toBytes(s)
    # decompress via memfiles
    writeFile(brPath, toString(viaMem))
    let dec = decompressFromFile(brPath)
    check toString(dec) == s

  test "decompressFromFile via memfiles":
    ensureTempDir()
    let s = "Hello mem decompress! ".repeat(2000)
    let enc = compressStore(s)
    let brPath = "./tests/temp/decomp_mem.br"
    writeFile(brPath, enc)
    let dec = decompressFromFile(brPath)
    check toString(dec) == s
    check decompressFromFileToString(brPath) == s

  test "compressFromFile wbits variants":
    ensureTempDir()
    for w in [10, 16, 17, 18, 20, 24]:
      let s = "wbits " & $w & " " & "x".repeat(5000)
      let p = "./tests/temp/wbits_in.txt"
      writeFile(p, s)
      let enc = compressFromFile(p, w)
      check decompress(enc) == toBytes(s)

  test "buffer reuse readMemFile":
    ensureTempDir()
    let s1 = "first file content ".repeat(1000)
    let s2 = "second much longer content ".repeat(5000)
    let p1 = "./tests/temp/reuse1.txt"
    let p2 = "./tests/temp/reuse2.txt"
    writeFile(p1, s1)
    writeFile(p2, s2)
    var buf: seq[byte] = @[]
    readMemFile(p1, buf)
    check buf == toBytes(s1)
    let cap1 = buf.len
    readMemFile(p2, buf)
    check buf == toBytes(s2)
    # reuse via compressFromFile with buf
    var outBuf: seq[byte] = @[]
    compressFromFile(p1, 16, outBuf)
    let first = outBuf.len
    compressFromFile(p2, 16, outBuf)
    check outBuf.len > 0
    # ensure decompressFromFile with reuse
    let brPath = "./tests/temp/reuse.br"
    writeFile(brPath, compressStore(s1))
    var decBuf: seq[byte] = @[]
    decompressFromFile(brPath, decBuf)
    check toString(decBuf) == s1

  test "readMemFile allocating variant":
    ensureTempDir()
    let s = "alloc test ".repeat(1000)
    let p = "./tests/temp/alloc.txt"
    writeFile(p, s)
    let b = readMemFile(p)
    check b == toBytes(s)
    var v = openMemFile(p)
    defer: v.close()
    check v.size == s.len

  test "toBytesReuse and toStringReuse":
    var buf: seq[byte] = @[]
    toBytesReuse("hello", buf)
    check buf == toBytes("hello")
    toBytesReuse("longer string ".repeat(100), buf)
    check buf == toBytes("longer string ".repeat(100))
    var sbuf = ""
    toStringReuse(toBytes("world"), sbuf)
    check sbuf == "world"

  test "compressFile empty file":
    ensureTempDir()
    let p = "./tests/temp/empty_in.txt"
    let br = "./tests/temp/empty.br"
    let outPath = "./tests/temp/empty_out.txt"
    writeFile(p, "")
    compressFile(p, br)
    decompressFile(br, outPath)
    check readFile(outPath).len == 0
    check decompressFromFile(br).len == 0
