#!/usr/bin/env python3
"""Fill a translation mod's dialogue catalog from a German Gen 1 cartridge.

The text itself moves between releases -- German is longer than English and
sits at different addresses -- but what points AT it does not. Both cartridges
are the same build: a map's header is at the same address in each, the text
pointer table it names is at the same address, and the nth entry in that table
is the nth text of that map in both. So a label is resolved by POSITION in a
structure, never by matching words:

    map header (same address in both)
      -> text pointer table (same address in both)
        -> entry n: TX_FAR, then a 3-byte far pointer
          -> the text, wherever this release happens to keep it

Proof it lines up: for Pallet Town the US table's second entry points at bank
41 $42DC, which is exactly the address the manifest's symbol table gives for
_PalletTownGirlText. The German table's second entry points at $433A -- a
different address, the same slot, the same line of dialogue.

Entries that are not TX_FAR are inline script rather than text and are skipped;
the manifest marks those `asm`. Its output is ROM content: run it locally,
against your own dump.

Which slot holds which label is read from the US cartridge rather than
assumed: the manifest lists a map's texts alphabetically, not in table order,
so counting down the list put the fisherman's line where the girl's belongs.
Instead every US slot is followed to the text it points at, and that ADDRESS is
looked up in the symbol table. The label comes from the cartridge; only the
German words come from the German one.

    python3 tools/de_text_from_rom.py path/to/rot_de.gb path/to/red_us.gb mods/deutsch
"""
import json
import re
import sys
from pathlib import Path

TX_FAR = 0x17

# Control codes as the engine's own extraction writes them, so a translated
# line carries the same markers the English one does.
# The engine writes three control characters and no others -- checked against
# data/generated/text.lua, where 2585 English texts use 10, 11 and 12 and
# nothing else. The \p and \c I invented here were literal backslash-p and
# backslash-c: the box drew them and, worse, never waited, because what makes
# it wait is chr(11) and chr(12) rather than a marker that looks like one.
CTRL = {0x50: None,   # end
        0x57: None,   # end, close box
        0x58: None,   # end, prompt
        0x00: "",     # TX_START, the byte every far text opens with
        0x4E: "\n",   # next line
        0x4F: "\n",   # bottom line -- the English extraction writes 10 for it too
        0x51: "\x0c", # paragraph: clear the box and wait
        0x55: "\x0b", # cont: wait, then scroll
        0x49: "\n",
        0x5F: "", 0x7F: " "}
CHARMAP = {0xE0: "'", 0xE1: "PK", 0xE2: "MN", 0xE3: "-", 0xE6: "?", 0xE7: "!",
           0xE8: ".", 0xEF: "♂", 0xF5: "♀", 0xF2: ".", 0xF3: "/",
           0xF4: ",", 0x9A: "(", 0x9B: ")", 0x9C: ":", 0x9D: ";", 0x9E: "[",
           0x9F: "]", 0xBA: "é", 0xBC: "é",
           0xC0: "Ä", 0xC1: "Ö", 0xC2: "Ü",
           0xC3: "ä", 0xC4: "ö", 0xC5: "ü", 0xBE: "ß"}
for _i in range(26):
    CHARMAP[0x80 + _i] = chr(65 + _i)
    CHARMAP[0xA0 + _i] = chr(97 + _i)
for _i in range(10):
    CHARMAP[0xF6 + _i] = chr(48 + _i)

# The placeholders the engine substitutes at draw time. Same spellings the
# English extraction uses, because the catalog is read by the same code.
RAM = {0x52: "{RAM:wPlayerName}", 0x53: "{RAM:wRivalName}", 0x54: "POKé",
       0x59: "{RAM:wNameBuffer}", 0x5A: "{RAM:wNameBuffer}",
       0x5B: "PC", 0x5C: "TM", 0x5D: "TRAINER", 0x5E: "ROCKET"}


def offset(bank, addr):
    return bank * 0x4000 + (addr - 0x4000 if addr >= 0x4000 else addr)


def decode(rom, at, limit=2048):
    out = []
    for b in rom[at:at + limit]:
        if b in (0x50, 0x57, 0x58):
            return "".join(out)
        if b in RAM:
            out.append(RAM[b])
        elif b in CTRL:
            piece = CTRL[b]
            if piece:
                out.append(piece)
        else:
            out.append(CHARMAP.get(b, "{%02X}" % b))
    return "".join(out)


def lua_quote(s):
    out = (s.replace("\\", "\\\\").replace('"', '\\"')
            .replace("\n", "\\n").replace("\x0b", "\\11").replace("\x0c", "\\12"))
    return '"%s"' % out


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    de = Path(sys.argv[1]).read_bytes()
    us = Path(sys.argv[2]).read_bytes()
    mod = Path(sys.argv[3])
    repo = Path(__file__).resolve().parent.parent
    manifest = json.loads((repo / "tools" / "rom_manifest.json").read_text())
    symbols = manifest["symbols"]
    pointers = manifest["text"]["pointers"]

    # Every _XText the US build knows, by where it sits.
    by_address = {}
    for label, where in symbols.items():
        if label.startswith("_") and isinstance(where, list) and len(where) == 2:
            by_address[(where[0], where[1])] = label

    found, asm, unknown = {}, 0, 0
    for map_name, texts in pointers.items():
        header = symbols.get(map_name + "_h")
        if not header:
            continue
        bank, addr = header
        h = offset(bank, addr)
        # Same header, same address, in both cartridges -- so the table this
        # names is the same slot list on each.
        table_us = us[h + 5] | (us[h + 6] << 8)
        table_de = de[h + 5] | (de[h + 6] << 8)
        for i in range(len(texts)):
            eu = offset(bank, table_us) + i * 2
            ed = offset(bank, table_de) + i * 2
            pu = us[eu] | (us[eu + 1] << 8)
            pd = de[ed] | (de[ed + 1] << 8)
            au, ad = offset(bank, pu), offset(bank, pd)
            if us[au] != TX_FAR or de[ad] != TX_FAR:
                asm += 1
                continue
            far_us = (us[au + 3], us[au + 1] | (us[au + 2] << 8))
            label = by_address.get(far_us)
            if not label:
                unknown += 1
                continue
            far_bank = de[ad + 3]
            far = de[ad + 1] | (de[ad + 2] << 8)
            found[label] = decode(de, offset(far_bank, far))

    path = mod / "lang" / "dialogue.lua"
    text = path.read_text()
    filled = 0

    def swap(m):
        nonlocal filled
        value = found.get(m.group(1))
        # A raw {XX} means a byte this charmap does not know, and a line with a
        # hole in it is worse than the English one.
        if not value or re.search(r"\{[0-9A-F]{2}\}", value):
            return m.group(0)
        filled += 1
        return '["%s"] = %s,' % (m.group(1), lua_quote(value))

    out = re.sub(r'\["([^"]+)"\]\s*=\s*"(?:[^"\\]|\\.)*",', swap, text)
    path.write_text(out)
    print("matched %d labels through the US cartridge" % len(found))
    print("  filled            %d" % filled)
    print("  inline script     %d (not text)" % asm)
    print("  slot with no known label  %d" % unknown)


if __name__ == "__main__":
    main()
