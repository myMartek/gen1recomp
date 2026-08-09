Put your glyph sheet here.

A page is a PNG of 8x8 cells, 16 per row by default, black on white. Codes
run left to right and top to bottom starting at the page's `base`, so the
first cell is `base`, the second `base + 1`, and so on.

`assets/generated/font.png` in the player's cache is the vanilla sheet at
the same scale; open it alongside yours to match weight and baseline.

Declare the sheet in `lang/font.lua` and map sequences to codes in
`lang/charmap.lua`.
