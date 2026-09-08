#!/usr/bin/env python3
"""Normalise the given trees to the resting format the pre-commit hooks want.

The vendored files sit at the chart root now, not under charts/, so the
trailing-whitespace and end-of-file-fixer hooks no longer skip them. Without
this step the tree flips between two resting formats: `make sync` writes the
upstream form, the hooks rewrite it, and the next sync reverts the rewrite. The
generated patch files under diffs/ are normalised for the same reason; nothing
applies them, so trailing whitespace in their context lines does not matter.
"""

import pathlib
import sys


def normalise(text: str) -> str:
    fixed = "".join(line.rstrip() + "\n" for line in text.splitlines()).rstrip("\n")
    return fixed + "\n" if fixed else fixed


def main(roots: list[str]) -> int:
    for root in roots:
        for path in sorted(pathlib.Path(root).rglob("*")):
            if not path.is_file():
                continue
            text = path.read_text(encoding="utf-8")
            fixed = normalise(text)
            if fixed != text:
                path.write_text(fixed, encoding="utf-8")
                print(f"normalised {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["vendor"]))
