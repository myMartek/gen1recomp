-- Glyph pages this translation adds.
--
-- Seven letters, cut from the German cartridge's own FontGraphics so
-- they match the vanilla weight and baseline exactly rather than
-- approximately. base is above the vanilla $60/$80 pages, so this ADDS
-- an alphabet instead of replacing one and English is untouched.
return {
  deutsch = {
    image = "assets/font/deutsch.png",
    base = 0x100,
    glyphsPerRow = 16,
  },
}
