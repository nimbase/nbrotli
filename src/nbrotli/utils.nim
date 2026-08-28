proc toBytes*(s: string): seq[byte] =
  ## Convert string to seq[byte] without unsafe cast.
  result.setLen(s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc toBytes*(s: openArray[byte]): seq[byte] =
  result.setLen(s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc toString*(b: openArray[byte]): string =
  result.setLen(b.len)
  if b.len > 0:
    copyMem(addr result[0], unsafeAddr b[0], b.len)
