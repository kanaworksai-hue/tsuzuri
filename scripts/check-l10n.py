#!/usr/bin/env python3
"""Checks that every localized string in Sources/Tsuzuri has a translation in each
table under Resources/Localization, and that the %@ placeholders match.

  python3 scripts/check-l10n.py
"""
import pathlib
import plistlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
sources = root / "Sources/Tsuzuri"
tables = root / "Resources/Localization"

# String(localized: "…") and SwiftUI Text("…") literals; \(…) interpolations become %@.
literal = r'"((?:[^"\\]|\\.)*)"'
patterns = [re.compile(r'String\(localized:\s*' + literal), re.compile(r'\bText\(' + literal)]
keys = set()
for path in sources.glob("*.swift"):
    text = path.read_text()
    for pattern in patterns:
        for match in pattern.finditer(text):
            key = re.sub(r'\\\((?:[^()]|\([^()]*\))*\)', '%@', match.group(1))
            keys.add(key.replace('\\"', '"'))

def load(path):
    xml = subprocess.run(["plutil", "-convert", "xml1", "-o", "-", str(path)],
                         check=True, capture_output=True).stdout
    return plistlib.loads(xml)

ok = True
for lproj in sorted(tables.glob("*.lproj")):
    if lproj.name == "en.lproj":
        continue  # The keys are the English text.
    table = load(lproj / "Localizable.strings")
    for key in sorted(keys - table.keys()):
        print(f"{lproj.name}: missing {key!r}"); ok = False
    for key in sorted(table.keys() - keys):
        print(f"{lproj.name}: unused {key!r}"); ok = False
    for key in sorted(keys & table.keys()):
        if key.count("%@") != table[key].count("%@"):
            print(f"{lproj.name}: placeholder mismatch {key!r}"); ok = False
print(f"{len(keys)} keys checked" if ok else "localization check failed")
sys.exit(0 if ok else 1)
