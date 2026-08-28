## bench — brotli cli vs nbrotli (scalar) vs nbrotli+SIMD
## Run:
##   clue build tests/bench.nim --release               # scalar
##   clue build --features:nimsimd tests/bench.nim --release  # SIMD
##   ./tests/bench  (or ./bench if built to root)
## Compares decompress throughput for corpora compressed by brotli cli.

import std/[os, osproc, strutils, times, monotimes]
import nbrotli
import nbrotli/simd

const BenchRepeats = 20

proc hasBrotliCli(): bool =
  let (_, code) = execCmdEx("brotli --version 2>&1")
  code == 0

proc hasNbrotliCli(): bool =
  if fileExists("./nbrotli_cli"): return true
  if fileExists("./nbrotli"): return true
  let (_, code) = execCmdEx("nbrotli_cli --help 2>&1")
  if code == 0: return true
  let (_, code2) = execCmdEx("nbrotli --help 2>&1")
  code2 == 0

proc nbrotliCliBin(): string =
  if fileExists("./nbrotli_cli"): "./nbrotli_cli"
  elif fileExists("./nbrotli"): "./nbrotli"
  elif fileExists("/tmp/nbrotli_cli"): "/tmp/nbrotli_cli"
  else: "nbrotli_cli"

proc nbrotliCliSimdInfo(): string =
  let (outp, code) = execCmdEx(nbrotliCliBin() & " --help 2>&1")
  if outp.contains("SIMD: enabled"): "enabled"
  elif outp.contains("SIMD: disabled"): "disabled"
  else: "unknown"

proc ensureTempDir() =
  createDir("./tests/temp")

proc rndBytes(len: int): seq[byte] =
  result.setLen(len)
  for i in 0..<len:
    result[i] = byte((i*31 + 7) and 0xFF)

proc benchDecompress(data: seq[byte], repeats: int): tuple[nsPerOp: float, bytesPerSec: float] =
  # warmup
  discard decompress(data)
  let start = getMonoTime()
  for _ in 0..<repeats:
    discard decompress(data)
  let elapsed = getMonoTime() - start
  let dec = decompress(data)
  let decBytes = dec.len.float * repeats.float
  let ns = elapsed.inNanoseconds.float / repeats.float
  let secs = elapsed.inNanoseconds.float / 1e9
  let bps = if secs > 0: decBytes / secs else: 0
  (ns, bps)

proc benchDecompressFromFile(path: string, repeats: int): tuple[nsPerOp: float, bps: float] =
  discard decompressFromFile(path)
  let start = getMonoTime()
  for _ in 0..<repeats:
    discard decompressFromFile(path)
  let elapsed = getMonoTime() - start
  let dec = decompressFromFile(path)
  let decBytes = dec.len.float * repeats.float
  let ns = elapsed.inNanoseconds.float / repeats.float
  let secs = elapsed.inNanoseconds.float / 1e9
  (ns, if secs > 0: decBytes / secs else: 0)

proc benchCliDecompress(brPath: string, repeats: int, decLen: int): float =
  # brotli -d -c
  let outPath = brPath & ".bench.out"
  discard execCmdEx("brotli -d -c \"" & brPath & "\" > \"" & outPath & "\" 2>/dev/null")
  let start = getMonoTime()
  for _ in 0..<repeats:
    discard execShellCmd("brotli -d -c \"" & brPath & "\" > \"" & outPath & "\" 2>/dev/null")
  let elapsed = getMonoTime() - start
  let ns = elapsed.inNanoseconds.float / repeats.float
  ns

proc benchNbrotliCliDecompress(brPath: string, repeats: int): float =
  # nbrotli -d -c (external process, fair vs brotli cli)
  let bin = nbrotliCliBin()
  let outPath = brPath & ".nb.bench.out"
  discard execCmdEx(bin & " -d -c \"" & brPath & "\" > \"" & outPath & "\" 2>/dev/null")
  let start = getMonoTime()
  for _ in 0..<repeats:
    discard execShellCmd(bin & " -d -c \"" & brPath & "\" > \"" & outPath & "\" 2>/dev/null")
  let elapsed = getMonoTime() - start
  elapsed.inNanoseconds.float / repeats.float

proc fmtBps(bps: float): string =
  if bps > 1e9: formatFloat(bps/1e9, precision=2) & " GB/s"
  elif bps > 1e6: formatFloat(bps/1e6, precision=2) & " MB/s"
  elif bps > 1e3: formatFloat(bps/1e3, precision=2) & " KB/s"
  else: formatFloat(bps, precision=2) & " B/s"

proc fmtNs(ns: float): string =
  if ns > 1e6: formatFloat(ns/1e6, precision=2) & " ms"
  elif ns > 1e3: formatFloat(ns/1e3, precision=2) & " µs"
  else: formatFloat(ns, precision=2) & " ns"

proc runBench(name: string, s: string, q: int, w: int = 0, largeWindow = 0) =
  ensureTempDir()
  let safe = name.replace(" ", "_")
  let inPath = "./tests/temp/bench_" & safe & ".txt"
  let brPath = "./tests/temp/bench_" & safe & ".br"
  writeFile(inPath, s)
  var cmd: string
  if largeWindow != 0:
    cmd = "brotli --large_window=" & $largeWindow & " -q " & $q & " -c \"" & inPath & "\" > \"" & brPath & "\" 2>/dev/null"
  elif w != 0:
    cmd = "brotli -w " & $w & " -q " & $q & " -c \"" & inPath & "\" > \"" & brPath & "\" 2>/dev/null"
  else:
    cmd = "brotli -c -q " & $q & " \"" & inPath & "\" > \"" & brPath & "\" 2>/dev/null"
  let code = execShellCmd(cmd)
  if code != 0:
    echo "  skip ", name, " (brotli compress failed)"
    return
  let compressed = readMemFile(brPath)
  let dec = decompress(compressed)
  if dec != toBytes(s):
    echo "  FAIL ", name, " decompress mismatch"
    return
  let repeats = if s.len > 500_000: 20 else: BenchRepeats
  let (nsNb, bpsNb) = benchDecompress(compressed, repeats)
  let (nsMem, bpsMem) = benchDecompressFromFile(brPath, repeats)
  var nsCli = 0.0
  var cliOk = false
  if hasBrotliCli():
    nsCli = benchCliDecompress(brPath, repeats, s.len)
    cliOk = true
  var nsNbCli = 0.0
  var nbCliOk = false
  if hasNbrotliCli():
    nsNbCli = benchNbrotliCliDecompress(brPath, repeats)
    nbCliOk = true
  let compRatio = formatFloat(compressed.len.float / s.len.float * 100, precision=1)
  echo "  ", name, " (", s.len, " -> ", compressed.len, " bytes, ", compRatio, "%) q=", q, (if w != 0: " w=" & $w else: ""), (if largeWindow != 0: " lw=" & $largeWindow else: "")
  echo "    nbrotli        : ", fmtNs(nsNb), "  ", fmtBps(bpsNb), "  (decompress in-mem, same process)"
  echo "    nbrotli memfile: ", fmtNs(nsMem), "  ", fmtBps(bpsMem), "  (mmap, in-mem)"
  if nbCliOk:
    let nbCliBps = s.len.float / (nsNbCli/1e9)
    echo "    nbrotli cli    : ", fmtNs(nsNbCli), "  ", fmtBps(nbCliBps), "  (nbrotli -d -c, external, fair)"
  if cliOk:
    let cliBps = s.len.float / (nsCli/1e9)
    echo "    brotli cli     : ", fmtNs(nsCli), "  ", fmtBps(cliBps), "  (brotli -d -c, external)"
    let speedup = nsCli / nsNb
    echo "    speedup in-mem vs cli : ", formatFloat(speedup, precision=2), "x (", (if speedup > 1: "faster" else: "slower"), ")"
    if nbCliOk:
      let fairSpeedup = nsCli / nsNbCli
      echo "    speedup fair cli vs cli: ", formatFloat(fairSpeedup, precision=2), "x (", (if fairSpeedup > 1: "nbrotli faster" else: "brotli faster"), ")"

when isMainModule:
  echo "nbrotli bench — cli vs nbrotli (fair external-process comparison)"
  echo "  bench (in-mem) nimsimd: ", (when hasSimdFeature: "enabled (AVX2/SSE2)" else: "disabled"), " hasAvx2=", hasAvx2
  if hasNbrotliCli():
    echo "  nbrotli cli: ", nbrotliCliBin(), " SIMD=", nbrotliCliSimdInfo()
  else:
    echo "  nbrotli cli: NOT FOUND (build with: clue build src/nbrotli_cli.nim --release [--features:nimsimd])"
    echo "  -> nbrotli cli bench will be skipped, only in-mem will run (unfair, includes no process spawn)"
  if not hasBrotliCli():
    echo "  warning: brotli cli not found, only nbrotli will be benched"
  echo "  cwd: ", getCurrentDir()
  echo "  fair = both clis spawned via shell (brotli -d -c vs nbrotli_cli -d -c); in-mem is warm, no spawn"
  echo ""

  # corpora
  let corpora = [
    ("empty", "", 6),
    ("hello", "Hello world", 6),
    ("repeat 15x5", "Hello, Brotli! ".repeat(5), 6),
    ("complex81 q6", "Hello, Brotli! Hello, Brotli! Hello, Brotli! This is a test of pure Nim decoder. ", 6),
    ("complex81 q11", "Hello, Brotli! Hello, Brotli! Hello, Brotli! This is a test of pure Nim decoder. ", 11),
    ("1k_random q6", toString(rndBytes(1024)), 6),
    ("100k_random q6", toString(rndBytes(100_000)), 6),
    ("500k_random q6", toString(rndBytes(500_000)), 6),
    ("100k_text q11", "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ".repeat(2000), 11),
    ("500k_text q6", "The quick brown fox jumps over the lazy dog. ".repeat(11000), 6),
  ]

  for (name, s, q) in corpora:
    runBench(name, s, q)

  echo ""
  echo "wbits / large window:"
  for w in [10, 16, 20, 24]:
    let s = "LargeWindow w=" & $w & " " & "abc".repeat(10000)
    runBench("w" & $w, s, 6, w=w)
  for w in [25, 27, 30]:
    let s = "Hello Large Window! ".repeat(5000)
    runBench("lw" & $w, s, 6, largeWindow=w)

  echo ""
  echo "store (nbrotli Store encode) vs decode (fair cli vs cli):"
  for w in [10, 16, 24]:
    let s = "store bench w=" & $w & " " & "x".repeat(100_000)
    let enc = compress(toBytes(s), w)
    let compRatio = formatFloat(enc.len.float / s.len.float * 100, precision=1)
    let brPath = "./tests/temp/bench_store_w" & $w & ".br"
    writeFile(brPath, toString(enc))
    if decompress(enc) != toBytes(s):
      echo "  FAIL store w=", w
      continue
    let (nsNb, bpsNb) = benchDecompress(enc, 50)
    let (nsMem, bpsMem) = benchDecompressFromFile(brPath, 50)
    var nsCli = 0.0
    var cliOk = false
    if hasBrotliCli():
      nsCli = benchCliDecompress(brPath, 50, s.len)
      cliOk = true
    var nsNbCli = 0.0
    var nbCliOk = false
    if hasNbrotliCli():
      nsNbCli = benchNbrotliCliDecompress(brPath, 50)
      nbCliOk = true
    echo "  store w=", w, " (", s.len, " -> ", enc.len, " bytes, ", compRatio, "%)"
    echo "    nbrotli        : ", fmtNs(nsNb), "  ", fmtBps(bpsNb), "  (decompress in-mem)"
    echo "    nbrotli memfile: ", fmtNs(nsMem), "  ", fmtBps(bpsMem), "  (mmap)"
    if nbCliOk:
      let nbCliBps = s.len.float / (nsNbCli/1e9)
      echo "    nbrotli cli    : ", fmtNs(nsNbCli), "  ", fmtBps(nbCliBps), "  (nbrotli -d -c, fair)"
    if cliOk:
      let cliBps = s.len.float / (nsCli/1e9)
      echo "    brotli cli     : ", fmtNs(nsCli), "  ", fmtBps(cliBps), "  (brotli -d -c, fair)"
      if nbCliOk:
        echo "    fair speedup   : ", formatFloat(nsCli/nsNbCli, precision=2), "x (cli vs cli)"

  echo ""
  echo "done. Run with:"
  echo "  clue build tests/bench.nim --release          # scalar"
  echo "  clue build --features:nimsimd tests/bench.nim --release  # SIMD"
