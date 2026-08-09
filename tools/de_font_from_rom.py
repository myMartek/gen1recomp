#!/usr/bin/env python3
"""Cut the German letters out of a German cartridge into a glyph page.

The engine draws from glyph pages -- an 8x8 sheet plus a charmap saying which
sequence draws which cell -- and the vanilla pages have no umlauts, so German
text would draw with holes in it however well it was translated. This adds a
page rather than replacing one: 0x100 and up is free space above the vanilla
$60/$80 pages, so the English alphabet stays exactly as it was.

Only the seven letters the vanilla sheet lacks are taken. é is already in it
(POKéMON needs it), and every other German letter is an English one.

FontGraphics is 1bpp, one byte per row, and its tiles run in character-code
order from 0x80 -- tile 0 is A, tile 32 is a, which is what pins the rest.
Verified by eye before anything was written: at 0xC3 there really is an a with
two dots over it.

    python3 tools/de_font_from_rom.py path/to/rot_de.gb mods/deutsch
"""
import sys
from pathlib import Path

from PIL import Image

# Where the sheet lives, and what a tile index means. Same address in the
# German build as in the American one -- font tiles are not text and did not
# have to move.
FONT = 0x11A80
FIRST_CODE = 0x80

# The letters the vanilla pages do not have, in the order they will sit on the
# new page. Capitals first so the sheet reads like an alphabet.
LETTERS = [("Ä", 0xC0), ("Ö", 0xC1), ("Ü", 0xC2),
           ("ä", 0xC3), ("ö", 0xC4), ("ü", 0xC5), ("ß", 0xBE)]

BASE = 0x100
PER_ROW = 16


def tile(rom, code):
    """One glyph as 8 rows of 8 booleans."""
    at = FONT + (code - FIRST_CODE) * 8
    return [[(row >> (7 - x)) & 1 for x in range(8)] for row in rom[at:at + 8]]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    rom = Path(sys.argv[1]).read_bytes()
    mod = Path(sys.argv[2])

    rows = (len(LETTERS) + PER_ROW - 1) // PER_ROW
    sheet = Image.new("RGBA", (PER_ROW * 8, rows * 8), (255, 255, 255, 0))
    px = sheet.load()
    for i, (char, code) in enumerate(LETTERS):
        ox, oy = (i % PER_ROW) * 8, (i // PER_ROW) * 8
        for y, line in enumerate(tile(rom, code)):
            for x, on in enumerate(line):
                if on:
                    px[ox + x, oy + y] = (0, 0, 0, 255)

    image = mod / "assets" / "font" / "deutsch.png"
    image.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(image)

    (mod / "lang" / "font.lua").write_text(
        "-- Glyph pages this translation adds.\n"
        "--\n"
        "-- Seven letters, cut from the German cartridge's own FontGraphics so\n"
        "-- they match the vanilla weight and baseline exactly rather than\n"
        "-- approximately. base is above the vanilla $60/$80 pages, so this ADDS\n"
        "-- an alphabet instead of replacing one and English is untouched.\n"
        "return {\n"
        "  deutsch = {\n"
        '    image = "assets/font/deutsch.png",\n'
        "    base = 0x%X,\n" % BASE +
        "    glyphsPerRow = %d,\n" % PER_ROW +
        "  },\n"
        "}\n")

    lines = ["-- Which byte sequence draws which glyph code.",
             "--",
             "-- Only the seven letters the vanilla pages lack. Everything else in",
             "-- German is an English letter and already draws.",
             "return {"]
    for i, (char, _code) in enumerate(LETTERS):
        lines.append('  ["%s"] = 0x%X,' % (char, BASE + i))
    lines.append("}")
    (mod / "lang" / "charmap.lua").write_text("\n".join(lines) + "\n")

    print("wrote %s (%dx%d, %d glyphs)"
          % (image, sheet.width, sheet.height, len(LETTERS)))
    for char, code in LETTERS:
        print("  %s  cartridge 0x%02X -> page 0x%X"
              % (char, code, BASE + LETTERS.index((char, code))))


if __name__ == "__main__":
    main()
