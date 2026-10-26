import unittest
import std/[os, osproc, strutils]
import nbrotli

proc hasBrotliCli(): bool =
  let (_, code) = execCmdEx("brotli --version")
  code == 0

proc brotliCompress(s: string, q: int): seq[byte] =
  # Portable: temp dir from std/os (no hardcoded /tmp), no shell pipes or
  # redirections (broken on Windows cmd). brotli -o writes the output file.
  let dir = getTempDir()
  let inPath = dir / "nb_test.txt"
  let brPath = dir / "nb_test.br"
  writeFile(inPath, s)
  let (_, code) = execCmdEx("brotli -q " & $q & " -f " & quoteShell(inPath) &
    " -o " & quoteShell(brPath))
  doAssert code == 0, "brotli compress failed"
  cast[seq[byte]](readFile(brPath))

suite "brotli decompress q=1 (low quality, no dictionary)":
  test "empty":
    if not hasBrotliCli(): skip()
    let c = brotliCompress("", 1)
    check decompress(c).len == 0
  test "single byte":
    if not hasBrotliCli(): skip()
    let c = brotliCompress("a", 1)
    check cast[string](decompress(c)) == "a"
  test "hello world":
    if not hasBrotliCli(): skip()
    let s = "Hello world"
    let c = brotliCompress(s, 1)
    check cast[string](decompress(c)) == s
  test "repeat 15x5":
    if not hasBrotliCli(): skip()
    let s = "Hello, Brotli! ".repeat(5)
    let c = brotliCompress(s, 1)
    check cast[string](decompress(c)) == s
  test "complex 81 bytes q1":
    if not hasBrotliCli(): skip()
    let s = "Hello, Brotli! Hello, Brotli! Hello, Brotli! This is a test of pure Nim decoder. "
    let c = brotliCompress(s, 1)
    check cast[string](decompress(c)) == s
  test "binary roundtrip":
    if not hasBrotliCli(): skip()
    # NOTE: toString(), not cast[string](): the cast drops Nim's
    # NUL-terminator invariant and Windows writeFile over-reads it.
    let s = toString(@[0'u8, 1, 2, 255, 128, 64, 32, 16, 8, 4, 2, 1])
    # use string with binary
    let c = brotliCompress(s, 1)
    check decompress(c) == cast[seq[byte]](s)
