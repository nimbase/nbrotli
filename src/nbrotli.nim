import nbrotli/decode
import nbrotli/encode_store
import nbrotli/bitwriter
import nbrotli/decoder
import nbrotli/utils
import nbrotli/fileio
export decode
export encode_store
export bitwriter
export decoder
export utils
export fileio

proc add*(x, y: int): int =
  ## Kept for backward compat with scaffold test.
  x + y

proc decompress*(data: openArray[byte]): seq[byte] =
  ## One-shot decompression. Raises BrotliError on invalid stream.
  BrotliDecompress(data)

proc decompress*(data: string): string =
  let b = BrotliDecompress(toBytes(data))
  result = newString(b.len)
  for i, c in b: result[i] = char(c)

proc decompressToString*(data: openArray[byte]): string =
  let b = BrotliDecompress(data)
  result = newString(b.len)
  for i, c in b: result[i] = char(c)
