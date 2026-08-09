#!/usr/bin/env python3
"""Fill a translation mod's name catalogs from a German Gen 1 cartridge.

The names in a German Red are the same tables at the same addresses as the
American one -- the cartridge is the same build with different text -- so this
reads them where the English extractor reads its own and joins them onto the
project's ids by INTERNAL INDEX, which is the one thing both cartridges agree
on. Nothing is matched by name, so nothing depends on a translation being
guessable from the English.

The output is ROM content and belongs beside the player's own cartridge, not
in a repository: run it locally, against your own dump. It writes only the
catalogs it can fill and leaves every other key untouched, so a partial run
degrades to English exactly as an untranslated key does.

    python3 tools/de_names_from_rom.py path/to/rot_de.gb mods/deutsch
"""
import re
import subprocess
import sys
from pathlib import Path

# Where the tables sit. Same in every Gen 1 build of Red: the German release
# relocates none of them.
SPECIES = (0x1C21E, 10)     # fixed stride, 190 entries, indexed 1..190
MOVES = 0xB0000             # 0x50-terminated, in index order
ITEMS = 0x472D             # MEISTERBALL first; the US base is two bytes earlier
TRAINERS = 0x27EC3    # TEENAGER..SIEGFRIED, 47 classes

# The character set. Letters and digits are positional; the rest is a lookup,
# and the three umlauts are what makes this a German cartridge rather than an
# American one with different words in it.
CHARMAP = {0x7F: " ", 0x4E: "\n", 0xE0: "'", 0xE1: "PK", 0xE2: "MN", 0xE3: "-",
           0xE6: "?", 0xE7: "!", 0xE8: ".", 0xEF: "\u2642", 0xF5: "\u2640",
           0xF2: ".", 0xF3: "/", 0xF4: ",", 0x9A: "(", 0x9B: ")", 0x9C: ":",
           0x9D: ";", 0x9E: "[", 0x9F: "]", 0xBC: "\u00e9",
           0xC0: "\u00c4", 0xC1: "\u00d6", 0xC2: "\u00dc",
           0xD0: "\u00e4", 0xD1: "\u00f6", 0xD2: "\u00fc"}
for _i in range(26):
    CHARMAP[0x80 + _i] = chr(65 + _i)
    CHARMAP[0xA0 + _i] = chr(97 + _i)
for _i in range(10):
    CHARMAP[0xF6 + _i] = chr(48 + _i)


def decode(raw):
    """Bytes up to the terminator, as text. Unknown bytes are kept visible as
    {XX} rather than dropped -- a name with a hole in it should look wrong."""
    out = []
    for b in raw:
        if b == 0x50:
            break
        out.append(CHARMAP.get(b, "{%02X}" % b))
    return "".join(out)


def fixed_table(rom, base, stride, count):
    return {i + 1: decode(rom[base + i * stride: base + (i + 1) * stride])
            for i in range(count)}


def terminated_table(rom, base, count):
    """0x50-terminated strings back to back, numbered from 1."""
    out, at = {}, base
    for i in range(1, count + 1):
        end = rom.index(0x50, at)
        out[i] = decode(rom[at:end])
        at = end + 1
    return out


def lua_table(path):
    """A generated data table, read by the interpreter that understands it."""
    script = (
        'local t = assert(loadfile(%r))()\n'
        'for k, v in pairs(t) do\n'
        '  if type(v) == "table" and v.index then\n'
        '    io.write(k, "\\t", tostring(v.index), "\\n")\n'
        '  end\n'
        'end\n' % str(path)
    )
    text = subprocess.run(["luajit", "-e", script], capture_output=True,
                          text=True, check=True).stdout
    return {line.split("\t")[0]: int(line.split("\t")[1])
            for line in text.splitlines() if "\t" in line}


def write_catalog(path, title, values):
    """Rewrite a catalog in place, keeping its keys and its order.

    Only the values change: modkit --refresh reconciles against these keys, so
    losing one would park a translation that is not actually orphaned.
    """
    text = path.read_text()
    filled = 0

    def swap(m):
        nonlocal filled
        key = m.group(1)
        value = values.get(key)
        if not value:
            return m.group(0)
        filled += 1
        return '["%s"] = %s,' % (key, lua_quote(value))

    out = re.sub(r'\["([^"]+)"\]\s*=\s*"(?:[^"\\]|\\.)*",', swap, text)
    path.write_text(out)
    print("  %-18s %3d / %d" % (title, filled, out.count("[\"")))


def lua_quote(s):
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    rom = Path(sys.argv[1]).read_bytes()
    mod = Path(sys.argv[2])
    if len(rom) != 1024 * 1024:
        sys.exit("expected a 1 MiB cartridge dump, got %d bytes" % len(rom))

    repo = Path(__file__).resolve().parent.parent
    data = repo / "data" / "generated"
    if not (data / "pokemon.lua").exists():
        sys.exit("no data/generated: import the English ROM first, so there "
                 "are ids to attach these names to")

    print("reading %s" % sys.argv[1])
    species = fixed_table(rom, SPECIES[0], SPECIES[1], 190)
    moves = terminated_table(rom, MOVES, 165)
    items = terminated_table(rom, ITEMS, 100)
    trainers = terminated_table(rom, TRAINERS, 47)

    by_index = {
        "species_names.lua": (lua_table(data / "pokemon.lua"), species, "species"),
        "move_names.lua": (lua_table(data / "moves.lua"), moves, "moves"),
        "item_names.lua": (lua_table(data / "items.lua"), items, "items"),
    }
    for filename, (ids, table, title) in by_index.items():
        values = {key: table[i] for key, i in ids.items() if i in table}
        write_catalog(mod / "lang" / filename, title, values)

    # TRAINERS ARE NOT DONE HERE, and the reason is worth writing down.
    # lang/trainer_names.lua is keyed by class id in ALPHABETICAL order, and
    # the cartridge lists its classes in battle order; matching one against
    # the other by position turns a bug catcher into a mechanic. The table is
    # at 0x27EC3 and reads cleanly -- what is missing is the id-to-index
    # mapping this project does not store for trainers, the way it does for
    # species, moves and items.


if __name__ == "__main__":
    main()
