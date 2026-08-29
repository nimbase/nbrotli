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
nim c -d:features.nbrotli.nimsimd --path:src ...
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
# also: nim c -d:features.nbrotli.nimsimd --path:src src/nbrotli_cli.nim

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
nim c -d:features.nbrotli.nimsimd --path:src tests/bench.nim --release
./bench
```

`src/nbrotli/simd.nim` is guarded by dot form `-d:features.nbrotli.nimsimd` also accepted and falls back to `copyMem` when disabled or on non-x86.

### Benchmarks

```
nbrotli bench — cli vs nbrotli (fair external-process comparison)
  bench (in-mem) nimsimd: disabled hasAvx2=false
  nbrotli cli: ./nbrotli_cli SIMD=disabled
  cwd: /Users/georgelemon/Development/nimbase/ports/nbrotli
  fair = both clis spawned via shell (brotli -d -c vs nbrotli_cli -d -c); in-mem is warm, no spawn

  empty (0 -> 2 bytes, inf%) q=6
    nbrotli        : 1.1 µs  0.0 B/s  (decompress in-mem, same process)
    nbrotli memfile: 34. µs  0.0 B/s  (mmap, in-mem)
    nbrotli cli    : 6.1 ms  0.0 B/s  (nbrotli -d -c, external, fair)
    brotli cli     : 9.9 ms  0.0 B/s  (brotli -d -c, external)
    speedup in-mem vs cli : 8.9e+03x (faster)
    speedup fair cli vs cli: 1.6x (nbrotli faster)
  hello (11 -> 15 bytes, 1.e+02%) q=6
    nbrotli        : 4.7e+02 µs  24. KB/s  (decompress in-mem, same process)
    nbrotli memfile: 5.5e+02 µs  20. KB/s  (mmap, in-mem)
    nbrotli cli    : 7.5 ms  1.5 KB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 9.7 ms  1.1 KB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 21.x (faster)
    speedup fair cli vs cli: 1.3x (nbrotli faster)
  repeat 15x5 (75 -> 29 bytes, 4.e+01%) q=6
    nbrotli        : 9.1e+02 µs  83. KB/s  (decompress in-mem, same process)
    nbrotli memfile: 9.3e+02 µs  81. KB/s  (mmap, in-mem)
    nbrotli cli    : 7.8 ms  9.6 KB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 9.9 ms  7.6 KB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 11.x (faster)
    speedup fair cli vs cli: 1.3x (nbrotli faster)
  complex81 q6 (81 -> 62 bytes, 8.e+01%) q=6
    nbrotli        : 2.5 ms  33. KB/s  (decompress in-mem, same process)
    nbrotli memfile: 2.2 ms  36. KB/s  (mmap, in-mem)
    nbrotli cli    : 9.0 ms  9.0 KB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 10. ms  8.1 KB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 4.1x (faster)
    speedup fair cli vs cli: 1.1x (nbrotli faster)
  complex81 q11 (81 -> 67 bytes, 8.e+01%) q=11
    nbrotli        : 2.1 ms  38. KB/s  (decompress in-mem, same process)
    nbrotli memfile: 2.7 ms  30. KB/s  (mmap, in-mem)
    nbrotli cli    : 10. ms  8.1 KB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 10. ms  8.0 KB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 4.8x (faster)
    speedup fair cli vs cli: 1.0x (nbrotli faster)
  1k_random q6 (1024 -> 271 bytes, 3.e+01%) q=6
    nbrotli        : 13. ms  76. KB/s  (decompress in-mem, same process)
    nbrotli memfile: 13. ms  80. KB/s  (mmap, in-mem)
    nbrotli cli    : 15. ms  70. KB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 10. ms  1.0e+02 KB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 0.75x (slower)
    speedup fair cli vs cli: 0.69x (brotli faster)
  100k_random q6 (100000 -> 273 bytes, 0.3%) q=6
    nbrotli        : 12. ms  8.2 MB/s  (decompress in-mem, same process)
    nbrotli memfile: 13. ms  7.8 MB/s  (mmap, in-mem)
    nbrotli cli    : 16. ms  6.1 MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 10. ms  9.7 MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 0.85x (slower)
    speedup fair cli vs cli: 0.63x (brotli faster)
  500k_random q6 (500000 -> 273 bytes, 0.05%) q=6
    nbrotli        : 15. ms  34. MB/s  (decompress in-mem, same process)
    nbrotli memfile: 15. ms  34. MB/s  (mmap, in-mem)
    nbrotli cli    : 18. ms  28. MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 11. ms  45. MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 0.75x (slower)
    speedup fair cli vs cli: 0.63x (brotli faster)
  100k_text q11 (114000 -> 60 bytes, 0.05%) q=11
    nbrotli        : 3.1 ms  37. MB/s  (decompress in-mem, same process)
    nbrotli memfile: 3.2 ms  36. MB/s  (mmap, in-mem)
    nbrotli cli    : 10. ms  11. MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 10. ms  11. MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 3.3x (faster)
    speedup fair cli vs cli: 0.99x (brotli faster)
  500k_text q6 (495000 -> 54 bytes, 0.01%) q=6
    nbrotli        : 3.9 ms  1.3e+02 MB/s  (decompress in-mem, same process)
    nbrotli memfile: 4.0 ms  1.3e+02 MB/s  (mmap, in-mem)
    nbrotli cli    : 17. ms  29. MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 24. ms  21. MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 6.1x (faster)
    speedup fair cli vs cli: 1.4x (nbrotli faster)

wbits / large window:
  w10 (30017 -> 34 bytes, 0.1%) q=6 w=10
    nbrotli        : 1.2 ms  26. MB/s  (decompress in-mem, same process)
    nbrotli memfile: 1.2 ms  26. MB/s  (mmap, in-mem)
    nbrotli cli    : 8.4 ms  3.6 MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 9.7 ms  3.1 MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 8.4x (faster)
    speedup fair cli vs cli: 1.2x (nbrotli faster)
  w16 (30017 -> 33 bytes, 0.1%) q=6 w=16
    nbrotli        : 1.2 ms  26. MB/s  (decompress in-mem, same process)
    nbrotli memfile: 1.2 ms  25. MB/s  (mmap, in-mem)
    nbrotli cli    : 8.3 ms  3.6 MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 11. ms  2.8 MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 9.0x (faster)
    speedup fair cli vs cli: 1.3x (nbrotli faster)
  w20 (30017 -> 34 bytes, 0.1%) q=6 w=20
    nbrotli        : 1.1 ms  26. MB/s  (decompress in-mem, same process)
    nbrotli memfile: 1.2 ms  25. MB/s  (mmap, in-mem)
    nbrotli cli    : 8.2 ms  3.6 MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 9.9 ms  3.0 MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 8.6x (faster)
    speedup fair cli vs cli: 1.2x (nbrotli faster)
  w24 (30017 -> 34 bytes, 0.1%) q=6 w=24
    nbrotli        : 1.1 ms  26. MB/s  (decompress in-mem, same process)
    nbrotli memfile: 1.2 ms  26. MB/s  (mmap, in-mem)
    nbrotli cli    : 8.2 ms  3.7 MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 9.8 ms  3.1 MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 8.6x (faster)
    speedup fair cli vs cli: 1.2x (nbrotli faster)
  lw25 (100000 -> 35 bytes, 0.03%) q=6 lw=25
    nbrotli        : 1.4 ms  74. MB/s  (decompress in-mem, same process)
    nbrotli memfile: 1.3 ms  74. MB/s  (mmap, in-mem)
    nbrotli cli    : 8.6 ms  12. MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 9.9 ms  10. MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 7.3x (faster)
    speedup fair cli vs cli: 1.2x (nbrotli faster)
  lw27 (100000 -> 35 bytes, 0.03%) q=6 lw=27
    nbrotli        : 1.4 ms  74. MB/s  (decompress in-mem, same process)
    nbrotli memfile: 1.4 ms  70. MB/s  (mmap, in-mem)
    nbrotli cli    : 8.3 ms  12. MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 10. ms  9.9 MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 7.5x (faster)
    speedup fair cli vs cli: 1.2x (nbrotli faster)
  lw30 (100000 -> 35 bytes, 0.03%) q=6 lw=30
    nbrotli        : 1.4 ms  74. MB/s  (decompress in-mem, same process)
    nbrotli memfile: 1.4 ms  72. MB/s  (mmap, in-mem)
    nbrotli cli    : 8.3 ms  12. MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 10. ms  9.9 MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 7.5x (faster)
    speedup fair cli vs cli: 1.2x (nbrotli faster)

store (nbrotli Store encode) vs decode (fair cli vs cli):
  store w=10 (100017 -> 100025 bytes, 1.e+02%)
    nbrotli        : 4.0e+02 µs  2.5e+02 MB/s  (decompress in-mem)
    nbrotli memfile: 4.5e+02 µs  2.2e+02 MB/s  (mmap)
    nbrotli cli    : 6.9 ms  14. MB/s  (nbrotli -d -c, fair)
    brotli cli     : 10. ms  10. MB/s  (brotli -d -c, fair)
    fair speedup   : 1.4x (cli vs cli)
  store w=16 (100017 -> 100024 bytes, 1.e+02%)
    nbrotli        : 46. µs  2.2 GB/s  (decompress in-mem)
    nbrotli memfile: 86. µs  1.2 GB/s  (mmap)
    nbrotli cli    : 6.5 ms  15. MB/s  (nbrotli -d -c, fair)
    brotli cli     : 9.8 ms  10. MB/s  (brotli -d -c, fair)
    fair speedup   : 1.5x (cli vs cli)
  store w=24 (100017 -> 100024 bytes, 1.e+02%)
    nbrotli        : 79. µs  1.3 GB/s  (decompress in-mem)
    nbrotli memfile: 1.2e+02 µs  8.0e+02 MB/s  (mmap)
    nbrotli cli    : 6.4 ms  16. MB/s  (nbrotli -d -c, fair)
    brotli cli     : 10. ms  10. MB/s  (brotli -d -c, fair)
    fair speedup   : 1.5x (cli vs cli)
```


### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/nimbase/nbrotli/issues)
- 👋 Wanna help? [Fork it!](https://github.com/nimbase/nbrotli/fork)

### 🎩 License
MIT license | Nimbase Community
