#!/usr/bin/env python3
"""Compare the model catalogs with the providers' published pricing.

Catalogs live in Sources/QuotaWarmer/Resources/<tool>-models.json. Each is
bundled in the app and fetched from `main` by installed copies, so fixing it
here updates every user within a day, without a release. Each catalog's
`upstream` block names its pricing page and parser:

  anthropic  Claude pricing page, "## Model pricing" table (every row required)
  openai     OpenAI pricing page, "### Standard pricing data" table; rows are
             required only when they match `upstream.include`

Usage:
  scripts/check-model-catalog.py                 # report drift for all tools
  scripts/check-model-catalog.py --tool codex    # one tool
  scripts/check-model-catalog.py --fix           # add new models / correct
                                                 # prices, bump revision
  scripts/check-model-catalog.py --tool claude --pricing-file pricing.md

Exit codes: 0 in sync, 1 drift found (or fixed), 2 a pricing page unreadable.
Warm-up model lists are never edited automatically: a cheaper candidate is
reported, and a human decides which `--model` value to ship (per-warm-up cost
can differ from per-token price).
"""

import argparse
import json
import re
import sys
import urllib.request
from datetime import date
from pathlib import Path

RESOURCES = Path(__file__).resolve().parent.parent / "Sources/QuotaWarmer/Resources"
TOOLS = ["claude", "codex"]
PRICE_FIELDS = ["input", "cacheWrite5m", "cacheWrite1h", "cacheRead", "output"]
MODEL_KEY_ORDER = ["id", "name", "aliases", "match"] + PRICE_FIELDS


def fetch(url, path):
    if path:
        return Path(path).read_text(encoding="utf-8")
    request = urllib.request.Request(url, headers={"User-Agent": "quota-warmer-catalog-check"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read().decode("utf-8")


def parse_price(cell):
    """`$12.50 / MTok<sup>1</sup>` -> 12.5; `-` -> None."""
    match = re.search(r"\$([0-9]+(?:\.[0-9]+)?)", cell)
    return float(match.group(1)) if match else None


def table_rows(markdown, heading):
    try:
        section = markdown.split(heading, 1)[1]
    except IndexError:
        raise ValueError(f"{heading!r} not found")
    rows = []
    started = False
    for line in section.splitlines():
        if line.startswith("#"):
            break
        if not line.startswith("|"):
            if started:
                break
            continue
        started = True
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if cells[0].lower() == "model" or set(cells[0]) <= set("-: "):
            continue
        rows.append(cells)
    if not rows:
        raise ValueError(f"no rows under {heading!r}")
    return rows


def clean_name(cell):
    """Drop footnotes (`<sup>1</sup>`), tags, and "(retired …)" style notes."""
    name = re.sub(r"<sup>.*?</sup>|<[^>]+>", "", cell)
    return re.sub(r"\s*\(.*$", "", name).strip()


def parse_anthropic(markdown, upstream):
    rows = []
    for cells in table_rows(markdown, "## Model pricing"):
        if len(cells) < 6 or not cells[0].startswith("Claude"):
            continue
        name = clean_name(cells[0])
        lowered = cells[0].lower()
        status = "retired" if "retired" in lowered else "limited" if ("limited" in lowered or "glasswing" in lowered) else "available"
        model_id = re.sub(r"[\s._]+", "-", name.lower().removeprefix("claude ").strip())
        prices = dict(zip(PRICE_FIELDS, (parse_price(cell) for cell in cells[1:6])))
        if None in prices.values():
            raise ValueError(f"missing price in row {cells}")
        rows.append({"id": model_id, "name": name, "status": status, "prices": prices})
    return rows


def parse_openai(markdown, upstream):
    """Columns: model, short input, short cached input, short cache writes,
    short output, then the long-context equivalents. A `-` cached or cache-write
    price means no discount, so it falls back to the input price."""
    include = re.compile(upstream.get("include") or ".*")
    rows = []
    for cells in table_rows(markdown, "### Standard pricing data"):
        if len(cells) < 5:
            continue
        name = clean_name(cells[0])
        if not include.search(name):
            continue
        base_input, cached, cache_write, output = (parse_price(cell) for cell in cells[1:5])
        if base_input is None or output is None:
            raise ValueError(f"missing price in row {cells}")
        write = cache_write if cache_write is not None else base_input
        prices = {
            "input": base_input,
            "cacheWrite5m": write,
            "cacheWrite1h": write,
            "cacheRead": cached if cached is not None else base_input,
            "output": output,
        }
        rows.append({"id": name, "name": name, "status": "available", "prices": prices})
    return rows


PARSERS = {"anthropic": parse_anthropic, "openai": parse_openai}


def number(value):
    return int(value) if float(value).is_integer() else value


def write_catalog(catalog, path):
    """Canonical layout: nested objects one key per line, one model per line."""
    lines = ["{"]
    items = [(key, value) for key, value in catalog.items() if key != "models"]
    for key, value in items:
        if isinstance(value, dict):
            inner = ",\n".join(f"    {json.dumps(k)}: {json.dumps(v)}" for k, v in value.items())
            lines.append(f"  {json.dumps(key)}: {{\n{inner}\n  }},")
        else:
            lines.append(f"  {json.dumps(key)}: {json.dumps(value)},")
    model_lines = []
    for model in catalog["models"]:
        ordered = {key: model[key] for key in MODEL_KEY_ORDER if key in model}
        ordered.update({key: value for key, value in model.items() if key not in ordered})
        parts = [f"{json.dumps(key)}: {json.dumps(number(value) if key in PRICE_FIELDS else value)}"
                 for key, value in ordered.items()]
        model_lines.append("    { " + ", ".join(parts) + " }")
    lines.append('  "models": [')
    lines.append(",\n".join(model_lines))
    lines.append("  ]")
    lines.append("}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def normalize(model_id):
    return re.sub(r"[._\s]+", "-", model_id.lower())


def compare(catalog, rows):
    by_id = {normalize(model["id"]): model for model in catalog["models"]}
    findings = []
    for row in rows:
        model = by_id.get(normalize(row["id"]))
        if model is None:
            findings.append(("new", row, None))
            continue
        changed = {field: (model[field], row["prices"][field])
                   for field in PRICE_FIELDS if abs(float(model[field]) - row["prices"][field]) > 1e-9}
        if changed:
            findings.append(("price", row, changed))

    notes = []
    upstream = catalog.get("upstream", {})
    among = re.compile(upstream.get("cheapestAmong") or ".*")
    candidates = [row for row in rows if row["status"] == "available" and among.search(row["id"])]
    declared = catalog["warmup"].get("cheapestModel")
    if candidates:
        cheapest = min(candidates, key=lambda row: (row["prices"]["input"] + row["prices"]["output"], row["prices"]["input"]))
        if normalize(cheapest["id"]) != normalize(declared or ""):
            notes.append(
                f"A cheaper warm-up candidate is published: **{cheapest['name']}** (`{cheapest['id']}`, "
                f"${number(cheapest['prices']['input'])} in / ${number(cheapest['prices']['output'])} out per MTok); "
                f"the catalog's `warmup.cheapestModel` is `{declared}`. Measure one warm-up with it (per-warm-up cost "
                f"includes the CLI's own prompt), then update `warmup.models` / `warmup.cheapestModel` and bump `revision`."
            )
    retired = {normalize(row["id"]) for row in rows if row["status"] == "retired"}
    for model in catalog["warmup"]["models"]:
        entry = next((m for m in catalog["models"] if normalize(m["id"]) == normalize(model)), None)
        if entry and normalize(entry["id"]) in retired:
            notes.append(f"Warm-up model `{model}` is marked retired on the pricing page.")
    return findings, notes


def report(tool, url, findings, notes, fixed):
    out = [f"## {tool}: model catalog drift", "", f"Source: {url}", ""]
    new = [f for f in findings if f[0] == "new"]
    changed = [f for f in findings if f[0] == "price"]
    if new:
        out.append("### New models")
        for _, row, _ in new:
            prices = ", ".join(f"{k} ${number(v)}" for k, v in row["prices"].items())
            out.append(f"- **{row['name']}** (`{row['id']}`, {row['status']}): {prices}")
        out.append("")
    if changed:
        out.append("### Price changes")
        for _, row, diff in changed:
            detail = ", ".join(f"{field} ${number(old)} → ${number(value)}" for field, (old, value) in diff.items())
            out.append(f"- **{row['name']}** (`{row['id']}`): {detail}")
        out.append("")
    if notes:
        out.append("### Warm-up model")
        out.extend(f"- {note}" for note in notes)
        out.append("")
    if fixed:
        out.append("Applied to the catalog with a bumped `revision`. Review, run the regression test, and commit.")
    else:
        out.append(f"Fix: `scripts/check-model-catalog.py --tool {tool} --fix`, review the diff, run the quota "
                   "regression test, and push to `main`. Installed apps adopt the higher `revision` within a day.")
    return "\n".join(out)


def check(tool, fix, pricing_file, catalog_path):
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    upstream = catalog.get("upstream") or {}
    url = upstream.get("url")
    parser = PARSERS.get(upstream.get("format"))
    if not url or not parser:
        print(f"{tool}: catalog has no usable `upstream` block")
        return 2
    try:
        rows = parser(fetch(url, pricing_file), upstream)
    except Exception as error:  # network, HTML instead of markdown, table format change
        print(f"{tool}: could not read the pricing table at {url}: {error}")
        return 2

    findings, notes = compare(catalog, rows)
    if not findings and not notes:
        print(f"{tool}: catalog revision {catalog['revision']} matches {len(rows)} published models.")
        return 0

    fixed = False
    if fix and findings:
        by_id = {normalize(model["id"]): model for model in catalog["models"]}
        for kind, row, _ in findings:
            if kind == "new":
                entry = {"id": row["id"], **({"name": row["name"]} if row["name"] != row["id"] else {})}
                # New OpenAI families are usually matched with dated suffixes.
                if upstream.get("format") == "openai" and catalog.get("defaultMatch") == "exact":
                    entry["match"] = "prefix"
                catalog["models"].append({**entry, **row["prices"]})
            else:
                by_id[normalize(row["id"])].update(row["prices"])
        catalog["revision"] = int(catalog["revision"]) + 1
        catalog["updatedAt"] = date.today().isoformat()
        write_catalog(catalog, catalog_path)
        fixed = True

    print(report(tool, url, findings, notes, fixed))
    print()
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tool", choices=TOOLS, help="check one tool (default: all)")
    parser.add_argument("--fix", action="store_true", help="update prices and add new models in the catalog")
    parser.add_argument("--pricing-file", help="read the pricing markdown from a file (requires --tool)")
    parser.add_argument("--catalog", help="catalog JSON path (requires --tool)")
    args = parser.parse_args()
    if (args.pricing_file or args.catalog) and not args.tool:
        parser.error("--pricing-file/--catalog need --tool")

    status = 0
    for tool in [args.tool] if args.tool else TOOLS:
        path = Path(args.catalog) if args.catalog else RESOURCES / f"{tool}-models.json"
        status = max(status, check(tool, args.fix, args.pricing_file, path))
    return status


if __name__ == "__main__":
    sys.exit(main())
