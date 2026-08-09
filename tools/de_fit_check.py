#!/usr/bin/env python3
"""Report every translated line that will not fit the text box.

The box is 18 glyphs wide and the engine does not wrap: a break that is not in
the string is a line that runs off the edge. German is longer than English, so
a translation that reads well can still overflow, and the only honest way to
know is to measure every line instead of spot-checking a few.

Counts GLYPHS, not bytes. "ä" is one column and two bytes, and counting bytes
is the bug this project already fixed once in its own layout code.

Placeholders are measured at their worst case rather than at the width of the
marker: %s can be a ten-character nickname, %d a three-digit number. A line
that fits only while the name is short is a line that breaks for somebody.

    python3 tools/de_fit_check.py mods/deutsch
"""
import re
import sys
from pathlib import Path

WIDTH = 18
WORST = {"%s": 10, "%d": 3, "{PLAYER}": 10, "{RIVAL}": 10}


def glyphs(line):
    for marker, cost in WORST.items():
        line = line.replace(marker, "x" * cost)
    # anything else in braces is a runtime substitution of unknown length;
    # a name is the longest thing that lands in one
    line = re.sub(r"\{[^}]*\}", "x" * 10, line)
    return len(line)


def main():
    mod = Path(sys.argv[1] if len(sys.argv) > 1 else "mods/deutsch")
    bad = 0
    for name in ("strings", "dialogue", "species_names", "move_names",
                 "item_names", "trainer_names"):
        path = mod / "lang" / (name + ".lua")
        if not path.exists():
            continue
        text = path.read_text()
        for _key, value in re.findall(
                r'\["((?:[^"\\]|\\.)*)"\]\s*=\s*"((?:[^"\\]|\\.)*)",', text):
            if not value:
                continue
            # Only the escapes Lua wrote, and NOT through unicode_escape:
            # that decodes the UTF-8 bytes as Latin-1 and turns every ä into
            # two glyphs, which is the very miscount this check exists to
            # catch.
            raw = (value.replace("\\n", "\n").replace("\\11", "\v")
                        .replace("\\12", "\f"))
            for line in re.split(r"[\n\v\f]", raw):
                width = glyphs(line)
                if width > WIDTH:
                    bad += 1
                    print("%-14s %2d  %s" % (name, width, line[:56]))
    print()
    print("%d lines wider than %d glyphs" % (bad, WIDTH))


if __name__ == "__main__":
    main()
