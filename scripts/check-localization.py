#!/usr/bin/env python3
"""Check owned source text, translation keys, and catalog placeholders."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HAN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\U00020000-\U0003134f]")
PLACEHOLDER = re.compile(r"\{\d+\}")
# Simplified Chinese follows mainland usage. Escaped so this file holds no CJK text: Traditional "zhi" (log),
# "trade" for transaction, Taiwanese "file", "original file", "support", "information", "sign out", "disk",
# "interface" and "view".
ZH_HANS_AVOID = ["\u8a8c", "\u4ea4\u6613", "\u6863\u6848", "\u539f\u6863", "\u652f\u63f4", "\u8d44\u8baf",
                 "\u767b\u51fa", "\u78c1\u789f", "\u4ecb\u9762", "\u68c0\u89c6"]
LOOKUP = re.compile(r'\b(?:L10n\.)?(?:tr|text)\("((?:[^"\\]|\\.)*)"')
errors = []
catalogs = {}
for path in (ROOT / "Sources/SwitchCore/Localizations").glob("*.json"):
    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                errors.append(f"{path.name}: duplicate key {key!r}")
            result[key] = value
        return result
    catalogs[path.stem] = json.loads(path.read_text(), object_pairs_hook=unique_pairs)
english = catalogs["en"]
for language, catalog in catalogs.items():
    if catalog.keys() != english.keys():
        errors.append(f"{language}: catalog keys differ from English")
    for key, value in catalog.items():
        if not key.isascii():
            # Typography is allowed; translated words belong only in values.
            if HAN.search(key):
                errors.append(f"{language}: non-English key {key!r}")
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{language}: empty or invalid value for {key!r}")
        elif sorted(PLACEHOLDER.findall(value)) != sorted(PLACEHOLDER.findall(english.get(key, ""))):
            errors.append(f"{language}: mismatched placeholders for {key!r}")
        elif language == "zh-Hans" and any(term in value for term in ZH_HANS_AVOID):
            errors.append(f"zh-Hans: Taiwanese or Traditional wording for {key!r}")
count = 0
for folder in ("Sources", "Tests", "scripts"):
    for path in (ROOT / folder).rglob("*"):
        if path.suffix not in (".swift", ".py", ".sh"):
            continue
        source = path.read_text()
        for number, line in enumerate(source.splitlines(), 1):
            if HAN.search(line):
                errors.append(f"{path.relative_to(ROOT)}:{number}: hardcoded CJK text")
        if folder == "Sources" and path.suffix == ".swift":
            for match in LOOKUP.finditer(source):
                key = json.loads('"' + match[1] + '"')
                count += 1
                if key not in english:
                    errors.append(f"{path.relative_to(ROOT)}: missing translation key {key!r}")
if errors:
    raise SystemExit("\n".join(errors))
print(f"Localization checks passed: {len(catalogs)} catalogs, {len(english)} keys, {count} literal lookups.")
