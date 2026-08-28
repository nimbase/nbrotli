# Package

version       = "0.1.0"
author        = "George Lemon"
description   = "Pure Nim Brotli compressor/decompressor"
license       = "MIT"
srcDir        = "src"


# Dependencies

requires "nim >= 2.2.10"

feature "nimsimd":
  requires "nimsimd >= 1.3.2"