<p align="center">
  A port of Brotli compressor/decompressor in pure Nim
</p>

<p align="center">
  <code>nimble install nbrotli</code>
</p>

<p align="center">
  <a href="https://nimbase.github.io/nbrotli/">API reference</a><br>
  <img src="https://github.com/nimbase/nbrotli/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/nimbase/nbrotli/workflows/docs/badge.svg" alt="Github Actions">
</p>

## About

**This is a 100% pure Nim port of Brotli** (RFC 7932) with **no C bindings and no FFI** It aims to be idiomatic Nim and easy to vendor, but it is still experimental and may not be stable. The API can change without notice, error handling is still being hardened, and performance has not been tuned. For production use, validate round trips against the reference `brotli` CLI and pin your dependency. This project is not affiliated with Google.

## Features
- Pure Nim, no C dependencies
- RFC 7932 decompression for `q=0..11`, including dictionary and context modeling
- Store (uncompressed) encoder per spec section 11.1 for reliable round trips
- Large Window Brotli (`WBITS 10..30`, `--large_window`) with lazy ring allocation
- Streaming incremental decoder (`feed` + `decodeSome`)
- High-level file API (`compress`, `compressFile`, `compressFromFile`, `decompress`, `decompressFile`, `decompressFromFile`, `readMemFile` with buffer reuse)
- CLI `nbrotli` / `nbrotli_cli` compatible with `brotli` (`-c`, `-d`, `-q`, `-w`, `--large_window`)
- Optional SIMD via `nimsimd` (`--features:nimsimd`, `-d:features.nbrotli.nimsimd`, AVX2/SSE2)
- Zero-copy friendly `BitReader`/`BitWriter` LSB-first core

## Installation

```sh
nimble install nbrotli
# or with clue
clue install nbrotli
# with SIMD
clue install --features:nimsimd nbrotli
# or
nim c -d:features_nbrotli_nimsimd --path:src ...
```

## Examples

### One-shot decompress

```nim
import nbrotli

# from bytes (e.g. readFile, HTTP body)
let compressed = toBytes(readFile("hello.br"))
let decompressed = decompress(compressed)          # seq[byte]
echo toString(decompressed)

# string overload
let text = toString(decompress(compressed))
echo text

# explicit error handling
try:
  discard decompress(badData)
except BrotliError as e:
  echo "brotli error code ", e.code, ": ", e.msg
```

### Store encoder (uncompressed, always decodable)

```nim
import nbrotli

let data = toBytes(readFile("input.txt"))
# or: let data = toBytes("Hello World".repeat(1000))
let enc = compress(data)                           # alias to compressStore, wbits=16 by default
let dec = decompress(enc)
assert dec == data

# wbits 10..24
let enc24 = compress(data, wbits = 24)
assert decompress(enc24) == data

# string overloads
let sEnc = compressStore("hello")
assert toString(decompress(toBytes(sEnc))) == "hello"
```

### Large Window Brotli

```nim
import nbrotli

# Decoding large-window streams produced by `brotli --large_window=25..30`
# is supported. The decoder allocates the ring lazily, so `w=30` does not
# require 1 GiB up front.
let large = toBytes(readFile("large_w30.br")) # produced with --large_window=30
let plain = decompress(large)
echo plain.len
```

### Streaming incremental decoder

```nim
import nbrotli

let compressed = toBytes(readFile("hello.br"))

# feed in arbitrary chunks (e.g. from async TCP)
var dec = initDecoder()
var pos = 0
while pos < compressed.len:
  let chunk = min(7, compressed.len - pos)
  dec.feed(compressed.toOpenArray(pos, pos + chunk - 1))
  pos += chunk

var outBuf: seq[byte] = @[]
while true:
  var tmp: seq[byte] = @[]
  let res = dec.decodeSome(tmp, maxOut = 65536)
  outBuf.add(tmp)
  if res == Success: break
  if res == Error:
    echo "format error ", dec.errorMsg
    break
  if res == NeedsMoreInput: break # need more compressed data
  # NeedsMoreOutput continues loop

assert outBuf == decompress(compressed)

# helper for tests
let all = decompressIncremental(compressed, @[7, 28])
assert all == decompress(compressed)
```

### High-level file API

```nim
import nbrotli

# simple file roundtrip (uses toBytes/readFile internally)
compressFile("input.txt", "input.txt.br")
decompressFile("input.txt.br", "output.txt")
assert readFile("input.txt") == readFile("output.txt")

# one-shot helpers (read file, compress/decompress)
let enc2 = compressFromFile("input.txt")
let dec2 = decompressFromFile("input.txt.br")
assert toString(dec2) == readFile("input.txt")

# buffer reuse (avoid alloc per chunk) — also available via readMemFile
var buf: seq[byte] = @[]
readMemFile("input.txt", buf)                  # reuse buf
compressFromFile("input.txt", 16, buf)         # reuse buf for output
decompressFromFile("input.txt.br", buf)

# utilities
let b = toBytes(readFile("hello.br"))
let s = toString(b)
```

### CLI

```sh
# build
clue build src/nbrotli_cli.nim --release
# or with SIMD
clue build --features:nimsimd src/nbrotli_cli.nim --release
# also: nim c -d:features_nbrotli_nimsimd --path:src src/nbrotli_cli.nim

# compress (Store, wbits 10..24)
./nbrotli_cli -c input.txt > input.txt.br
./nbrotli_cli -w 24 -c input.txt -o out.br

# decompress (handles q=0..11, wbits 10..30)
./nbrotli_cli -d -c input.txt.br > output.txt
brotli -d -c input.txt.br > output.txt  # interoperable
./nbrotli_cli -d input.txt.br -o output.txt

# large window
brotli --large_window=30 -q 6 -c input.txt > large.br
./nbrotli_cli -d -c large.br > out.txt
```

### SIMD

```sh
# scalar (default)
clue build tests/bench.nim --release
./bench

# SIMD (AVX2/SSE2 on amd64, NEON on arm64)
clue build --features:nimsimd tests/bench.nim --release
# or raw nim
nim c -d:features_nbrotli_nimsimd --path:src tests/bench.nim --release
./bench
```

`src/nbrotli/simd.nim` is guarded by `-d:features_nbrotli_nimsimd` (dot form `-d:features.nbrotli.nimsimd` also accepted) and falls back to `copyMem` when disabled or on non-x86.

### Benchmarks

Fair external-process comparison (`brotli -d -c` vs `nbrotli_cli -d -c` via `tests/bench.nim`):

```sh
clue build src/nbrotli_cli.nim --release
clue build tests/bench.nim --release && ./bench
```

Bench compresses corpora with `brotli` cli (`q=6/11`, `w=10..24`, `large_window=25..30`) then benches `nbrotli` in-mem, `nbrotli` mmap, `nbrotli_cli` (fair), `brotli` cli.

### Installation

```sh
nimble install nbrotli
# or pin to a commit
nimble install https://github.com/nimbase/nbrotli@main
```

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/nimbase/nbrotli/issues)
- 👋 Wanna help? [Fork it!](https://github.com/nimbase/nbrotli/fork)

### 🎩 License
MIT license | Nimbase Community
