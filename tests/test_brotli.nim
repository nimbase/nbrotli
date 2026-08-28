import unittest
import std/[os, strutils]
import nbrotli

proc brotliCompress(s: string, q: int): seq[byte] =
  writeFile("/tmp/nb_test.txt", s)
  discard execShellCmd("cat /tmp/nb_test.txt | brotli -c -q " & $q & " > /tmp/nb_test.br")
  cast[seq[byte]](readFile("/tmp/nb_test.br"))

suite "brotli decompress q=1 (low quality, no dictionary)":
  test "empty":
    let c = brotliCompress("", 1)
    check decompress(c).len == 0
  test "single byte":
    let c = brotliCompress("a", 1)
    check cast[string](decompress(c)) == "a"
  test "hello world":
    let s = "Hello world"
    let c = brotliCompress(s, 1)
    check cast[string](decompress(c)) == s
  test "repeat 15x5":
    let s = "Hello, Brotli! ".repeat(5)
    let c = brotliCompress(s, 1)
    check cast[string](decompress(c)) == s
  test "complex 81 bytes q1":
    let s = "Hello, Brotli! Hello, Brotli! Hello, Brotli! This is a test of pure Nim decoder. "
    let c = brotliCompress(s, 1)
    check cast[string](decompress(c)) == s
  test "binary roundtrip":
    let s = cast[string](@[0'u8, 1, 2, 255, 128, 64, 32, 16, 8, 4, 2, 1])
    # use string with binary
    let c = brotliCompress(s, 1)
    check decompress(c) == cast[seq[byte]](s)
