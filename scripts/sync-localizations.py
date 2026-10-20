#!/usr/bin/env python3
"""Merge the strings Xcode extracted at build time into the String Catalog.

`xcodebuild` extracts every localizable literal (Text, LocalizedStringKey,
LocalizedStringResource, String(localized:)) into `*.stringsdata` files under
its intermediates folder, but does not write them back to the source catalog
(only the Xcode IDE does). This script does that merge from the CLI:

  1. clean build into a private derived-data folder (see CLAUDE.md)
  2. python3 scripts/sync-localizations.py /tmp/dd-<name>
  3. add Turkish values to Sources/QuotaWarmer/Resources/Localizable.xcstrings
  4. python3 scripts/check-localizations.py

New keys get an English value and no `tr` entry, so the checker fails until
they are translated. Keys no longer extracted are removed. Existing
translations are never overwritten.
"""

import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CATALOG = os.path.join(HERE, "..", "Sources", "QuotaWarmer", "Resources", "Localizable.xcstrings")


def extracted_keys(derived_data):
    keys = set()
    for path in glob.glob(os.path.join(derived_data, "**", "*.stringsdata"), recursive=True):
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        for entry in data.get("tables", {}).get("Localizable", []):
            keys.add(entry["key"])
    return keys


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: sync-localizations.py <derived-data-dir>")
    keys = extracted_keys(sys.argv[1])
    if not keys:
        sys.exit("no .stringsdata found under %s; run a clean build first" % sys.argv[1])

    with open(CATALOG, encoding="utf-8") as handle:
        catalog = json.load(handle)
    strings = catalog.setdefault("strings", {})

    added = sorted(keys - set(strings))
    removed = sorted(set(strings) - keys)
    for key in added:
        strings[key] = {"localizations": {"en": {"stringUnit": {"state": "translated", "value": key}}}}
    for key in removed:
        del strings[key]

    catalog["strings"] = dict(sorted(strings.items()))
    with open(CATALOG, "w", encoding="utf-8") as handle:
        json.dump(catalog, handle, ensure_ascii=False, indent=2, sort_keys=False)
        handle.write("\n")

    print("extracted=%d added=%d removed=%d total=%d" % (len(keys), len(added), len(removed), len(strings)))


if __name__ == "__main__":
    main()
