#!/usr/bin/env python3
"""Emit unchecked plan.md action items as TSV lines: fingerprint<TAB>type<TAB>text.

- Only `- [ ]` / `* [ ]` checklist lines are considered; `- [x]` are ignored.
- A leading `(type)` token is extracted when it is a known type.
- The nearest preceding `#`..`######` heading is prepended as `Heading :: text`.
- The fingerprint is a 12-char sha1 of the whitespace-normalised, lower-cased
  full text, so cosmetic edits do not cause a re-slice.
"""
from __future__ import annotations

import hashlib
import re
import sys

KNOWN_TYPES = {"feature", "bug", "bugfix", "fix", "refactor", "docs", "chore", "spike", "question"}
TYPE_ALIAS = {"bugfix": "bug", "fix": "bug"}

HEADING_RE = re.compile(r"^#{1,6}\s+(.*\S)\s*$")
ITEM_RE = re.compile(r"^\s*[-*]\s+\[(?P<mark>[ xX])\]\s+(?P<text>.+?)\s*$")
TYPE_RE = re.compile(r"^\((?P<type>[A-Za-z]+)\)\s*(?P<rest>.+)$")


def fingerprint(text: str) -> str:
    norm = re.sub(r"\s+", " ", text.strip().lower())
    return hashlib.sha1(norm.encode("utf-8")).hexdigest()[:12]


def parse(path: str):
    heading = ""
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            hm = HEADING_RE.match(raw.rstrip("\n"))
            if hm:
                heading = hm.group(1).strip()
                continue
            im = ITEM_RE.match(raw)
            if not im or im.group("mark").lower() == "x":
                continue
            text = im.group("text").strip()
            typ = ""
            tm = TYPE_RE.match(text)
            if tm and tm.group("type").lower() in KNOWN_TYPES:
                key = tm.group("type").lower()
                typ = TYPE_ALIAS.get(key, key)
                text = tm.group("rest").strip()
            full = f"{heading} :: {text}" if heading else text
            yield fingerprint(full), typ, full


def main(argv):
    if len(argv) != 2:
        sys.exit("usage: parse_plan.py <plan.md>")
    for fp, typ, full in parse(argv[1]):
        print(f"{fp}\t{typ}\t{full}")


if __name__ == "__main__":
    main(sys.argv)
