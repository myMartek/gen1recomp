#!/usr/bin/env python3
"""Menu labels for a translation, read out of a German Gen 1 cartridge.

The labels the engine writes itself -- SAVE, OPTION, CANCEL, SWITCH -- are
keyed by their English source in lang/strings.lua, and were left empty because
they are short words nobody wanted to guess at. The cartridge knows them.

HOW A LABEL IS PAIRED, and what this deliberately does NOT do:

A generic search does not work here, and the failed attempts are worth naming
so nobody repeats them. Menu labels are not behind a pointer table the way map
dialogue is (see de_text_from_rom.py), so there is nothing to follow. Searching
for a two-byte pointer to a string finds coincidences -- a bank is full of byte
pairs, and the unique ones are unique by accident. Pairing "the block at the
same file offset" holds early in a bank and stops holding once German's longer
lines have pushed everything along.

What does hold is that both cartridges are the same build: a menu is the same
list of items in the same order in each. So each block below is named by an
anchor or an address VERIFIED by decoding both dumps side by side, its items
are read out in order, and the nth German item is the nth English one. Two
checks keep it honest -- the blocks must yield the same number of items, and no
German item may contain a byte the character set does not know.

Anchors are searched with each dump's OWN character set. The German one moves
é and adds the umlauts, so American bytes find nothing in it and that looks
exactly like "the word is not in there", which is the wrong conclusion.

Output is cartridge content: it goes to a file the port gitignores and the
private wrapper carries. Run it locally, against your own dumps.

    python3 tools/de_menus_from_rom.py \\
        --us "Pokemon - Red Version (USA, Europe).gb" \\
        --de "Pokemon - Rote Edition (Germany) (SGB Enhanced).gb" \\
        --out ../translations/deutsch/lang/strings_rom.lua
"""
import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from de_names_from_rom import CHARMAP as _DE_CHARS     # noqa: E402

# "POKé" is ONE byte in both cartridges -- a macro the font expands -- and the
# German character table above does not list it, because names never contain
# it. Menu labels do, and without this the whole START menu decodes as an
# undecodable byte followed by "DEX".
DE_CHARS = dict(_DE_CHARS)
DE_CHARS[0x54] = "POKé"

TERMINATOR = 0x50

# The blocks, each verified by decoding both dumps side by side.
#
#   anchor    a word that survives translation unchanged; the block starts at
#             the string it begins. anchor_de gives the German spelling where
#             the word does change but the block is still identifiable.
#   at        an address instead, where no word survives. Both dumps agree on
#             it, and the item count is what proves they do.
#   count     how many terminated strings the block spans.
#   split     "lines" for a block written as one text with newlines in it,
#             "columns" for a single line with runs of spaces between items.
# Addresses, not searches. Every one of them was read out of both dumps and
# checked against its neighbours; a word search cannot stand in for that,
# because most of these words occur several times and the occurrence that is
# the menu is not distinguishable from the ones that are not.
BLOCKS = [
    # The START menu: seven strings in a row, five of them the same word in
    # German (POKéDEX POKéMON ITEM SAVE RESET EXIT OPTION).
    dict(us=0x718F, de=0x71AF, count=7, split="lines"),
    # The title screen, then the link menu under it: two texts of three lines.
    dict(us=0x5D7E, de=0x5D98, count=2, split="lines"),
    # The party menu header, one line with its two choices spaced apart.
    dict(us=0x571F, de=0x572F, count=1, split="columns"),
    # SWITCH / STATS / CANCEL, the party and item submenu.
    dict(us=0x7489, de=0x748D, count=1, split="lines"),
]

# What may be published as a pairing. Anything not on this list is not a menu
# label; anything identical in German is dropped at the end rather than written
# as a line that changes nothing.
WANTED = {
    "POKéDEX", "POKéMON", "ITEM", "SAVE", "OPTION", "EXIT", "QUIT", "RESET",
    "CONTINUE", "NEW GAME", "CANCEL", "SWITCH", "STATS", "TRADE",
    "TRADE CENTER", "COLOSSEUM",
}


def us_charmap(manifest):
    return {int(k): v for k, v in json.load(open(manifest))["charmap"].items()}


def encoder(chars):
    inv = {}
    for code, ch in chars.items():
        inv.setdefault(ch, code)
    return lambda text: bytes(inv[c] for c in text)


def decode(rom, at, chars, limit=200):
    out = []
    for i in range(at, min(at + limit, len(rom))):
        if rom[i] == TERMINATOR:
            break
        out.append(chars.get(rom[i], "{%02X}" % rom[i]))
    return "".join(out)


def block_start(rom, hit):
    at = hit
    while at > 0 and rom[at - 1] != TERMINATOR:
        at -= 1
    return at


def find_block(rom, chars, spec, german):
    key = "de" if german else "us"
    if key in spec:
        return spec[key]
    if "at" in spec:
        return spec["at"]
    word = spec["anchor_de"] if german and spec.get("anchor_de") else spec["anchor"]
    try:
        needle = encoder(chars)(word)
    except KeyError:
        return None
    hits, at = [], rom.find(needle)
    while at != -1:
        if at > 0 and rom[at - 1] in (TERMINATOR, 0x4E):
            hits.append(at)
        at = rom.find(needle, at + 1)
    if len(hits) != 1:
        return None
    return block_start(rom, hits[0])


def items(rom, chars, spec, at):
    out, i = [], at
    for _ in range(spec["count"]):
        text = decode(rom, i, chars)
        if spec["split"] == "columns":
            out.extend(p for p in re.split(r"\s{2,}", text.strip()) if p)
        else:
            out.extend(text.split("\n"))
        while i < len(rom) and rom[i] != TERMINATOR:
            i += 1
        i += 1
    return [s.strip() for s in out]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--us", required=True)
    ap.add_argument("--de", required=True)
    ap.add_argument("--manifest",
                    default=str(Path(__file__).parent / "rom_manifest.json"))
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    us = Path(args.us).read_bytes()
    de = Path(args.de).read_bytes()
    us_chars = us_charmap(args.manifest)

    pairs, notes = {}, []
    for spec in BLOCKS:
        name = spec.get("anchor") or hex(spec.get("at", 0))
        a_us = find_block(us, us_chars, spec, german=False)
        a_de = find_block(de, DE_CHARS, spec, german=True)
        if a_us is None or a_de is None:
            notes.append("%s: block not located" % name)
            continue
        english = items(us, us_chars, spec, a_us)
        german = items(de, DE_CHARS, spec, a_de)
        if len(english) != len(german):
            notes.append("%s: %d English items, %d German -- not the same block"
                         % (name, len(english), len(german)))
            continue
        if any("{" in g for g in german):
            notes.append("%s: undecodable byte in the German block" % name)
            continue
        for english_item, german_item in zip(english, german):
            if english_item in WANTED and english_item != german_item:
                pairs[english_item] = german_item
        notes.append("%s: %d items paired (US %s / DE %s)"
                     % (name, len(english), hex(a_us), hex(a_de)))

    # The port renamed one label: the cartridge's EXIT closes the start menu,
    # and this engine's QUIT returns to the title from it. Same word on the
    # same row, so the German is the same -- said here rather than in the
    # catalog, where it would look like a second reading of the cartridge.
    if "EXIT" in pairs:
        pairs.setdefault("QUIT", pairs["EXIT"])

    lines = [
        "-- Menu labels, read out of a German cartridge by",
        "-- tools/de_menus_from_rom.py. Do not edit by hand: the next run",
        "-- overwrites it, and the cartridge is the authority anyway.",
        "--",
        "-- Cartridge content: this file belongs in the private wrapper, never",
        "-- in the public port. See translations/README.md.",
        "return {",
    ]
    # Lua quoting, not JSON: LuaJIT has no \u escape, so json.dumps would
    # write ZUR\u00dcCK and the game would print it literally.
    def lua(text):
        return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'

    for key in sorted(pairs):
        lines.append("  [%s] = %s," % (lua(key), lua(pairs[key])))
    lines.append("}")
    Path(args.out).write_text("\n".join(lines) + "\n", encoding="utf-8")

    print("%d labels -> %s" % (len(pairs), args.out))
    for key in sorted(pairs):
        print("  %-14s %s" % (key, pairs[key]))
    print()
    for note in notes:
        print("  " + note)


if __name__ == "__main__":
    main()
