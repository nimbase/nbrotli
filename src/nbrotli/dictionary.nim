## Dictionary wrapper — mirrors c/common/dictionary.h + dictionary.c
# kBrotliDictionaryData is defined in dictionary_data.nim and used via
# `import dictionary_data` in decode.nim; no direct use here.

const
  SizeBitsByLength*: array[32, uint8] = [
    0'u8, 0'u8, 0'u8, 0'u8, 10'u8, 10'u8, 11'u8, 11'u8,
    10'u8, 10'u8, 10'u8, 10'u8, 10'u8, 9'u8, 9'u8, 8'u8,
    7'u8, 7'u8, 8'u8, 7'u8, 7'u8, 6'u8, 6'u8, 5'u8,
    5'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8
  ]
  OffsetsByLength*: array[32, uint32] = [
    0'u32, 0'u32, 0'u32, 0'u32, 0'u32, 4096'u32, 9216'u32, 21504'u32,
    35840'u32, 44032'u32, 53248'u32, 63488'u32, 74752'u32, 87040'u32, 93696'u32, 100864'u32,
    104704'u32, 106752'u32, 108928'u32, 113536'u32, 115968'u32, 118528'u32, 119872'u32, 121280'u32,
    122016'u32, 122784'u32, 122784'u32, 122784'u32, 122784'u32, 122784'u32, 122784'u32, 122784'u32
  ]
  DataSize* = 122784

func dictWordOffset*(len: int, index: int): int {.inline.} =
  OffsetsByLength[len].int + index * len
