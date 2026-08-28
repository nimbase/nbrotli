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
