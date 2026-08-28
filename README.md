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

This is a 100 percent pure Nim port of Brotli (RFC 7932) with no C bindings and no FFI. It aims to be idiomatic Nim and easy to vendor, but it is still experimental and may not be stable. The API can change without notice, error handling is still being hardened, and performance has not been tuned. For production use, validate round trips against the reference `brotli` CLI and pin your dependency. This project is not affiliated with Google.

## Features
- Pure Nim, no C dependencies
- RFC 7932 decompression for `q=0..11`, including dictionary and context modeling
- Store (uncompressed) encoder per spec section 11.1 for reliable round trips
- Large Window Brotli (`WBITS 10..30`, `--large_window`) with lazy ring allocation
- Streaming incremental decoder (`feed` + `decodeSome`)
- Zero-copy friendly `BitReader`/`BitWriter` LSB-first core

## Examples

### One-shot decompress

```nim
import nbrotli

# from bytes (e.g. readFile, HTTP body)
let compressed = toBytes(readFile("hello.br"))
let decompressed = decompress(compressed)          # seq[byte]
echo cast[string](decompressed)

# from string
let text = decompress(compressed)                  # string overload
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

let data = toBytes("Hello World".repeat(1000))
let enc = compressStore(data)                      # wbits=16 by default
let dec = decompress(enc)
assert dec == data

# wbits 10..24
let enc24 = compressStore(data, wbits = 24)
assert decompress(enc24) == data

# string overloads
let sEnc = compressStore("hello")
assert decompress(sEnc) == "hello"
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

### Benchmarks
```
nbrotli bench — cli vs nbrotli (fair external-process comparison)
  bench (in-mem) nimsimd: disabled hasAvx2=false
  nbrotli cli: ./nbrotli_cli SIMD=disabled
  fair = both clis spawned via shell (brotli -d -c vs nbrotli_cli -d -c); in-mem is warm, no spawn

  empty (0 -> 2 bytes, inf%) q=6
    nbrotli        : 3.6e+02 ns  0.0 B/s  (decompress in-mem, same process)
    nbrotli memfile: 22. µs  0.0 B/s  (mmap, in-mem)
    nbrotli cli    : 6.8 ms  0.0 B/s  (nbrotli -d -c, external, fair)
    brotli cli     : 11. ms  0.0 B/s  (brotli -d -c, external)
    speedup in-mem vs cli : 3.0e+04x (faster)
    speedup fair cli vs cli: 1.6x (nbrotli faster)
  hello (11 -> 15 bytes, 1.e+02%) q=6
    nbrotli        : 5.5e+02 µs  20. KB/s  (decompress in-mem, same process)
    nbrotli memfile: 3.3e+02 µs  34. KB/s  (mmap, in-mem)
    nbrotli cli    : 8.4 ms  1.3 KB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 11. ms  1.0 KB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 20.x (faster)
    speedup fair cli vs cli: 1.3x (nbrotli faster)
  repeat 15x5 (75 -> 29 bytes, 4.e+01%) q=6
    nbrotli        : 9.3e+02 µs  81. KB/s  (decompress in-mem, same process)
    nbrotli memfile: 8.0e+02 µs  94. KB/s  (mmap, in-mem)
    nbrotli cli    : 8.5 ms  8.8 KB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 10. ms  7.2 KB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 11.x (faster)
    speedup fair cli vs cli: 1.2x (nbrotli faster)
  complex81 q6 (81 -> 62 bytes, 8.e+01%) q=6
    nbrotli        : 1.6 ms  51. KB/s  (decompress in-mem, same process)
    nbrotli memfile: 1.4 ms  58. KB/s  (mmap, in-mem)
    nbrotli cli    : 9.5 ms  8.5 KB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 11. ms  7.6 KB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 6.7x (faster)
    speedup fair cli vs cli: 1.1x (nbrotli faster)
  complex81 q11 (81 -> 67 bytes, 8.e+01%) q=11
    nbrotli        : 1.4 ms  58. KB/s  (decompress in-mem, same process)
    nbrotli memfile: 1.4 ms  60. KB/s  (mmap, in-mem)
    nbrotli cli    : 10. ms  7.8 KB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 11. ms  7.7 KB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 7.6x (faster)
    speedup fair cli vs cli: 1.0x (nbrotli faster)
  1k_random q6 (1024 -> 271 bytes, 3.e+01%) q=6
    nbrotli        : 7.5 ms  1.4e+02 KB/s  (decompress in-mem, same process)
    nbrotli memfile: 7.5 ms  1.4e+02 KB/s  (mmap, in-mem)
    nbrotli cli    : 16. ms  66. KB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 11. ms  96. KB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 1.4x (faster)
    speedup fair cli vs cli: 0.69x (brotli faster)
  100k_random q6 (100000 -> 273 bytes, 0.3%) q=6
    nbrotli        : 7.7 ms  13. MB/s  (decompress in-mem, same process)
    nbrotli memfile: 7.8 ms  13. MB/s  (mmap, in-mem)
    nbrotli cli    : 16. ms  6.3 MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 11. ms  9.5 MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 1.4x (faster)
    speedup fair cli vs cli: 0.66x (brotli faster)
  500k_random q6 (500000 -> 273 bytes, 0.05%) q=6
    nbrotli        : 9.6 ms  52. MB/s  (decompress in-mem, same process)
    nbrotli memfile: 9.6 ms  52. MB/s  (mmap, in-mem)
    nbrotli cli    : 29. ms  17. MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 15. ms  33. MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 1.6x (faster)
    speedup fair cli vs cli: 0.51x (brotli faster)
  100k_text q11 (114000 -> 60 bytes, 0.05%) q=11
    nbrotli        : 2.1 ms  54. MB/s  (decompress in-mem, same process)
    nbrotli memfile: 2.2 ms  53. MB/s  (mmap, in-mem)
    nbrotli cli    : 11. ms  11. MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 12. ms  9.2 MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 5.9x (faster)
    speedup fair cli vs cli: 1.1x (nbrotli faster)
  500k_text q6 (495000 -> 54 bytes, 0.01%) q=6
    nbrotli        : 3.1 ms  1.6e+02 MB/s  (decompress in-mem, same process)
    nbrotli memfile: 3.1 ms  1.6e+02 MB/s  (mmap, in-mem)
    nbrotli cli    : 24. ms  20. MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 22. ms  22. MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 7.1x (faster)
    speedup fair cli vs cli: 0.91x (brotli faster)

wbits / large window:
  w10 (30017 -> 34 bytes, 0.1%) q=6 w=10
    nbrotli        : 7.4e+02 µs  41. MB/s  (decompress in-mem, same process)
    nbrotli memfile: 7.9e+02 µs  38. MB/s  (mmap, in-mem)
    nbrotli cli    : 8.9 ms  3.4 MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 11. ms  2.8 MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 15.x (faster)
    speedup fair cli vs cli: 1.2x (nbrotli faster)
  w16 (30017 -> 33 bytes, 0.1%) q=6 w=16
    nbrotli        : 7.9e+02 µs  38. MB/s  (decompress in-mem, same process)
    nbrotli memfile: 8.6e+02 µs  35. MB/s  (mmap, in-mem)
    nbrotli cli    : 9.4 ms  3.2 MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 12. ms  2.6 MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 15.x (faster)
    speedup fair cli vs cli: 1.2x (nbrotli faster)
  w20 (30017 -> 34 bytes, 0.1%) q=6 w=20
    nbrotli        : 8.2e+02 µs  36. MB/s  (decompress in-mem, same process)
    nbrotli memfile: 8.1e+02 µs  37. MB/s  (mmap, in-mem)
    nbrotli cli    : 9.3 ms  3.2 MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 12. ms  2.6 MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 14.x (faster)
    speedup fair cli vs cli: 1.2x (nbrotli faster)
  w24 (30017 -> 34 bytes, 0.1%) q=6 w=24
    nbrotli        : 7.9e+02 µs  38. MB/s  (decompress in-mem, same process)
    nbrotli memfile: 8.1e+02 µs  37. MB/s  (mmap, in-mem)
    nbrotli cli    : 9.3 ms  3.2 MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 14. ms  2.2 MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 18.x (faster)
    speedup fair cli vs cli: 1.5x (nbrotli faster)
  lw25 (100000 -> 35 bytes, 0.03%) q=6 lw=25
    nbrotli        : 9.4e+02 µs  1.1e+02 MB/s  (decompress in-mem, same process)
    nbrotli memfile: 9.8e+02 µs  1.0e+02 MB/s  (mmap, in-mem)
    nbrotli cli    : 9.3 ms  11. MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 11. ms  8.8 MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 12.x (faster)
    speedup fair cli vs cli: 1.2x (nbrotli faster)
  lw27 (100000 -> 35 bytes, 0.03%) q=6 lw=27
    nbrotli        : 9.3e+02 µs  1.1e+02 MB/s  (decompress in-mem, same process)
    nbrotli memfile: 1.0 ms  1.0e+02 MB/s  (mmap, in-mem)
    nbrotli cli    : 9.1 ms  11. MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 11. ms  9.0 MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 12.x (faster)
    speedup fair cli vs cli: 1.2x (nbrotli faster)
  lw30 (100000 -> 35 bytes, 0.03%) q=6 lw=30
    nbrotli        : 9.5e+02 µs  1.1e+02 MB/s  (decompress in-mem, same process)
    nbrotli memfile: 9.9e+02 µs  1.0e+02 MB/s  (mmap, in-mem)
    nbrotli cli    : 9.3 ms  11. MB/s  (nbrotli -d -c, external, fair)
    brotli cli     : 11. ms  9.1 MB/s  (brotli -d -c, external)
    speedup in-mem vs cli : 12.x (faster)
    speedup fair cli vs cli: 1.2x (nbrotli faster)

store (nbrotli Store encode) vs decode (fair cli vs cli):
  store w=10 (100017 -> 100025 bytes, 1.e+02%)
    nbrotli        : 3.8e+02 µs  2.6e+02 MB/s  (decompress in-mem)
    nbrotli memfile: 4.3e+02 µs  2.3e+02 MB/s  (mmap)
    nbrotli cli    : 7.4 ms  13. MB/s  (nbrotli -d -c, fair)
    brotli cli     : 11. ms  9.4 MB/s  (brotli -d -c, fair)
    fair speedup   : 1.4x (cli vs cli)
  store w=16 (100017 -> 100024 bytes, 1.e+02%)
    nbrotli        : 33. µs  3.0 GB/s  (decompress in-mem)
    nbrotli memfile: 72. µs  1.4 GB/s  (mmap)
    nbrotli cli    : 7.1 ms  14. MB/s  (nbrotli -d -c, fair)
    brotli cli     : 11. ms  9.3 MB/s  (brotli -d -c, fair)
    fair speedup   : 1.5x (cli vs cli)
  store w=24 (100017 -> 100024 bytes, 1.e+02%)
    nbrotli        : 36. µs  2.8 GB/s  (decompress in-mem)
    nbrotli memfile: 78. µs  1.3 GB/s  (mmap)
    nbrotli cli    : 7.0 ms  14. MB/s  (nbrotli -d -c, fair)
    brotli cli     : 11. ms  9.3 MB/s  (brotli -d -c, fair)
    fair speedup   : 1.5x (cli vs cli)

done. Run with:
  clue build tests/bench.nim --release          # scalar
  clue build --features:nimsimd tests/bench.nim --release  # SIMD
```

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/nimbase/nbrotli/issues)
- 👋 Wanna help? [Fork it!](https://github.com/nimbase/nbrotli/fork)

### 🎩 License
MIT license | Nimbase Community
