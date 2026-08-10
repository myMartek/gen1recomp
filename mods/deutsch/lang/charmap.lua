-- Which byte sequence draws which glyph code.
--
-- Only the seven letters the vanilla pages lack. Everything else in
-- German is an English letter and already draws.
return {
  ["Ä"] = 0x100,
  ["Ö"] = 0x101,
  ["Ü"] = 0x102,
  ["ä"] = 0x103,
  ["ö"] = 0x104,
  ["ü"] = 0x105,
  ["ß"] = 0x106,
}
