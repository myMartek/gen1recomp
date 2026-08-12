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


RAM_PH = re.compile(r"\{RAM:\w+\}")


def believable(eng, ger):
    """Whether a German line found by the SECOND pass is really this label's.

    That pass pairs by the address of the pointer SITE, and where the German
    build's code has moved, the same address holds a different site -- which
    yields a real German line that belongs to another label. Measured against
    the first pass's proven pairs: 46 of 328 came out wrong that way, and a
    wrong line is worse than an English one, because an empty entry falls back
    to English and reads correctly while a wrong one silently lies.

    So a candidate has to look like a TRANSLATION of the English at that label.
    Wording cannot be compared across languages, but these survive it:

      * the RAM placeholders, exactly -- a line that greets the player by name
        greets them by name in both, and this alone caught most of the wrong
        pairs
      * the paragraph and scroll breaks, exactly: they are the shape of the
        text box, and the German build kept them
      * POKé, which is one byte and appears where the word does
      * length, within a band -- German runs longer than English, but not
        three times longer

    On the sample that can be checked this keeps 113 and gets 3 wrong. That is
    the floor of the method: those three are the right shape and the wrong
    text, and no rule made of structure can see it.
    """
    if not ger or re.search(r"\{[0-9A-F]{2}\}", ger):
        return False
    if sorted(RAM_PH.findall(eng)) != sorted(RAM_PH.findall(ger)):
        return False
    if eng.count("\x0c") != ger.count("\x0c"):
        return False
    if eng.count("\x0b") != ger.count("\x0b"):
        return False
    if eng.count("POKé") != ger.count("POKé"):
        return False
    if not eng:
        return False
    return 0.6 <= len(ger) / len(eng) <= 2.2


def by_pointer_site(us, de, by_address, where, found):
    """Second pass: everything the map tables cannot reach.

    The first pass walks a map's text pointer table, which only ever reaches
    the texts a MAP owns -- 344 of 2582. The rest (battle text, the Pokedex,
    menus, everything a script names directly) is referenced from code, and
    code has no table to walk.

    What it does have is position. Both cartridges are the same build, so the
    TX_FAR site that names a text sits at the same ROM offset in each: read the
    far pointer there out of the German cartridge and it is the same line in
    the other language. Where the German build's code has MOVED, that is no
    longer true and the site belongs to something else -- which is what
    believable() is for.

    The first pass wins every label it filled: it followed a structure rather
    than an assumption, and where the two disagree it is the one to trust.
    """
    added = 0
    seen = set()
    for i in range(len(us) - 4):
        if us[i] != TX_FAR or de[i] != TX_FAR:
            continue
        label = by_address.get((us[i + 3], us[i + 1] | (us[i + 2] << 8)))
        if not label or label in seen or label in found:
            continue
        seen.add(label)
        eng = decode(us, offset(*where[label]))
        ger = decode(de, offset(de[i + 3], de[i + 1] | (de[i + 2] << 8)))
        if not believable(eng, ger):
            continue
        found[label] = ger
        added += 1
    return added


def dex_entry(rom, at, metric):
    """One Pokedex entry: its category, its measurements, and where its text is.

    The layout is category string, 0x50, the measurements, then the TX_FAR that
    names the description. The measurement field is the one place the two
    releases differ in SHAPE: the US build stores feet, inches and tenths of a
    pound, the German one decimetres and tenths of a kilo, which is three bytes
    where the other has four. So the far pointer is found by where it is, not
    by counting from the front.
    """
    i = at
    while i < at + 24 and rom[i] != 0x50:
        i += 1
    if i >= at + 24:
        return None
    category = "".join(CHARMAP.get(b, "?") for b in rom[at:i])
    p = i + 1
    if metric:
        height = rom[p] / 10.0
        weight = (rom[p + 1] | (rom[p + 2] << 8)) / 10.0
        q = p + 3
    else:
        height = (rom[p] * 12 + rom[p + 1]) * 0.0254
        weight = (rom[p + 2] | (rom[p + 3] << 8)) * 0.045359237
        q = p + 4
    if rom[q] != TX_FAR:
        return None
    return category, height, weight, (rom[q + 3], rom[q + 1] | (rom[q + 2] << 8))


def by_dex_measurements(us, de, symbols, by_address, found):
    """Third pass: the Pokedex, paired on how big each Pokemon is.

    The dex has a real pointer table -- PokedexEntryPointers -- and a table is
    exactly what the first pass trusts. This one cannot be trusted that way:
    the German build REORDERED it. Slot 1 is Rhydon in the US cartridge
    ("DRILL") and something else entirely in the German one, so pairing slot to
    slot would give every Pokemon another one's entry.

    What does not move between languages is how tall and how heavy each one is.
    The German build stores those metrically and the US build imperially, but
    they describe the same animal, so converting one gives the other back to
    within rounding -- and height with weight is close enough to a fingerprint
    that 149 of 151 fall out uniquely.

    Not looked up one at a time, though: singly, 66 of them have more than one
    candidate inside any sensible tolerance. It is an ASSIGNMENT -- every US
    entry gets exactly one German entry and no German entry is used twice --
    so it is solved by repeatedly taking the pairs that are each other's
    closest match. That leaves 149 paired and no German entry spare.

    The category strings are not used to decide anything, only to check: the
    six widest-apart pairs it produces are Zubat/FLEDERMAUS, Clefairy/FEE,
    Sandshrew/MAUS, Wigglytuff/BALLON, Dragonair/DRACHE and Exeggcute/EI.
    """
    place = symbols.get("PokedexEntryPointers")
    if not place:
        return 0
    bank, addr = place
    base = offset(bank, addr)

    ours = {}
    for n in range(1, 191):          # internal index, which is not the dex number
        e = base + (n - 1) * 2
        if e + 1 >= len(us):
            break
        pu = us[e] | (us[e + 1] << 8)
        if 0x4000 <= pu < 0x8000:
            got = dex_entry(us, offset(bank, pu), False)
            if got:
                ours[n] = got

    # The GERMAN entries are found by SWEEPING the bank rather than by walking
    # that release's table, which is reordered and, for its last two slots,
    # holds addresses outside the bank entirely -- Rhydon's and Kangaskhan's
    # entries are in there, the table simply does not lead to them. The
    # entries have a shape of their own (a name, a terminator, three bytes of
    # measurements, then the TX_FAR that names the text), and that shape is
    # what this looks for. Order does not matter: the pairing is by size.
    theirs, seen_at = {}, 0
    for at in range(bank * 0x4000, (bank + 1) * 0x4000 - 8):
        if de[at] != 0x50 or de[at + 4] != TX_FAR:
            continue
        far = (de[at + 7], de[at + 5] | (de[at + 6] << 8))
        if not (0x4000 <= far[1] < 0x8000):
            continue
        height = de[at + 1] / 10.0
        weight = (de[at + 2] | (de[at + 3] << 8)) / 10.0
        if not (0.1 <= height <= 25.0 and 0.1 <= weight <= 1000.0):
            continue
        seen_at += 1
        theirs[seen_at] = ("", height, weight, far)

    def apart(u, d):
        return abs(u[1] - d[1]) / 0.1 + abs(u[2] - d[2]) / max(1.0, u[2] * 0.05)

    free_u, free_d, paired = set(ours), set(theirs), {}
    while free_u and free_d:
        closest_u = {n: min(free_d, key=lambda k: apart(ours[n], theirs[k]))
                     for n in free_u}
        closest_d = {k: min(free_u, key=lambda n: apart(ours[n], theirs[k]))
                     for k in free_d}
        mutual = [(n, k) for n, k in closest_u.items() if closest_d.get(k) == n]
        if not mutual:
            break
        for n, k in mutual:
            paired[n] = k
            free_u.discard(n)
            free_d.discard(k)

    added = 0
    for n, k in paired.items():
        label = by_address.get(ours[n][3])
        if not label or label in found:
            continue
        found[label] = decode(de, offset(*theirs[k][3]))
        added += 1
    return added



# ------------------------------------------------------------------ pass four
#
# Aligning the two cartridges' texts, which is what finally reaches the ones no
# table names.
#
# The texts of a bank lie one after another in both releases, in the same
# order -- checked: of the ten banks holding two or more proven pairs, nine
# keep it. So between two pairs we already trust, the German texts in between
# ARE the English ones in between, and the only question is which is which
# when the counts differ, because one release inlined a line the other did not.
#
# That is a sequence alignment, so it is done as one (Needleman-Wunsch) rather
# than by counting. The score asks the same structural questions believable()
# does -- placeholders, box breaks, POKe, length -- and a gap costs enough that
# dropping a text is only worth it when the alternative is worse.
#
# Measured by holding back every second anchor and predicting it: 164 of 165
# land exactly where the cartridge says they do. That is a real measurement of
# this pass rather than of the anchors, because a held-back anchor is not a
# boundary and gets no say in its own answer.

GAP = -3


def similarity(eng, ger):
    if not ger:
        return -4
    s = 3 if sorted(RAM_PH.findall(eng)) == sorted(RAM_PH.findall(ger)) else -4
    s += 2 if eng.count("\x0c") == ger.count("\x0c") else -2
    s += 1 if eng.count("\x0b") == ger.count("\x0b") else -1
    s += 1 if eng.count("POK\u00e9") == ger.count("POK\u00e9") else -2
    if eng:
        ratio = len(ger) / len(eng)
        s += 2 if 0.7 <= ratio <= 1.9 else (1 if 0.5 <= ratio <= 2.6 else -2)
    if re.search(r"\{[0-9A-F]{2}\}", ger):
        s -= 3
    return s


def align(english, german):
    """Needleman-Wunsch over two lists of (key, text). Returns matched keys."""
    n, m = len(english), len(german)
    grid = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(1, n + 1):
        grid[i][0] = grid[i - 1][0] + GAP
    for j in range(1, m + 1):
        grid[0][j] = grid[0][j - 1] + GAP
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            grid[i][j] = max(grid[i - 1][j - 1] + similarity(english[i - 1][1],
                                                             german[j - 1][1]),
                             grid[i - 1][j] + GAP, grid[i][j - 1] + GAP)
    out, i, j = [], n, m
    while i > 0 and j > 0:
        diag = grid[i - 1][j - 1] + similarity(english[i - 1][1], german[j - 1][1])
        if grid[i][j] == diag:
            out.append((english[i - 1][0], german[j - 1][0]))
            i -= 1
            j -= 1
        elif grid[i][j] == grid[i - 1][j] + GAP:
            i -= 1
        else:
            j -= 1
    return out[::-1]


def text_runs(rom, start, stop):
    """Where each text begins between two offsets: they are laid end to end."""
    out, i = [], start
    while i < stop:
        out.append(i)
        j = i + (1 if rom[i] == 0x00 else 0)
        while j < stop and rom[j] not in (0x50, 0x57, 0x58):
            j += 1
        if j >= stop:
            break
        i = j + 1
    return out


def by_alignment(us, de, where, anchors, found):
    """Fourth pass: everything between two proven pairs, aligned."""
    in_bank = {}
    for label, (bank, addr) in where.items():
        in_bank.setdefault(bank, []).append((addr, label))
    for bank in in_bank:
        in_bank[bank].sort()

    added = 0
    for bank, labels in sorted(in_bank.items()):
        posts = sorted((where[l][1], anchors[l], l) for l in anchors
                       if where[l][0] == bank and anchors[l] // 0x4000 == bank)
        if not posts:
            continue
        # THE ENDS OF THE FENCE, which is where a third of the misses were.
        #
        # Aligning only BETWEEN posts leaves whatever stands before the first
        # and after the last untouched. Both ends are known without a search:
        # every one of the twelve text banks begins its texts AT the bank
        # boundary, in both releases -- bank 40 opens with Koga's parting
        # advice in each -- so the head boundary is the boundary itself.
        #
        # This used to walk backwards over one terminator per English text
        # ahead of the first post. That is fragile where it matters most: bank
        # 40 holds 206 texts and only 9 posts, all of them at the far end, so
        # the walk had to step back 159 times without a single misstep. It did
        # not, and the whole Fuchsia gym came out empty.
        ahead = [a for a, _ in in_bank[bank] if a < posts[0][0]]
        if ahead:
            posts.insert(0, (min(ahead) - 1, bank * 0x4000, None))
        posts.append((0x8000, (bank + 1) * 0x4000, None))
        for k in range(len(posts) - 1):
            ua0, da0, _ = posts[k]
            ua1, da1, _ = posts[k + 1]
            if da1 <= da0:
                continue
            english = [(l, decode(us, offset(bank, a)))
                       for a, l in in_bank[bank] if ua0 < a < ua1]
            # The first run in a stretch is the POST itself and is already
            # paired -- except at a bank boundary, where the post is the
            # boundary rather than a text, and the first run is the bank's
            # first text. Dropping it there would lose one text per bank, and
            # in bank 40 that text is the one the whole gym hangs off.
            runs = text_runs(de, da0, da1)
            if da0 != bank * 0x4000:
                runs = runs[1:]
            german = [(o, decode(de, o)) for o in runs]
            if not english or not german:
                continue
            # The grid is n*m cells. This was 20000 and that was far too shy:
            # it skipped whole segments and left 439 texts to the guessier pass
            # behind it, to save a second of arithmetic. At this ceiling
            # nothing in either cartridge is skipped at all.
            if len(english) * len(german) > 400000:
                continue
            for label, at in align(english, german):
                if label in found:
                    continue
                found[label] = decode(de, at)
                added += 1
    return added


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
    at = {}
    for label, place in symbols.items():
        if label.startswith("_") and isinstance(place, list) and len(place) == 2:
            by_address[(place[0], place[1])] = label
            at[label] = (place[0], place[1])

    found, asm, unknown = {}, 0, 0
    # where each PROVEN pair's German text sits: the posts the
    # alignment pass runs its fence between
    anchors = {}
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
            anchors[label] = offset(far_bank, far)
            found[label] = decode(de, anchors[label])

    through_tables = len(found)
    # Before the site pass, because it is the stronger claim: a pairing
    # this one makes is one the guessier pass never gets asked about.
    through_dex = by_dex_measurements(us, de, symbols, by_address, found)
    through_align = by_alignment(us, de, at, anchors, found)
    through_sites = by_pointer_site(us, de, by_address, at, found)

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
    print("  through map tables        %d" % through_tables)
    print("  through dex measurements  %d" % through_dex)
    print("  through alignment         %d" % through_align)
    print("  through pointer sites     %d (structure-checked)" % through_sites)
    print("  filled                    %d" % filled)
    print("  inline script             %d (not text)" % asm)
    print("  slot with no known label  %d" % unknown)


if __name__ == "__main__":
    main()
