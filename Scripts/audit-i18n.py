#!/usr/bin/env python3
import argparse
import collections
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCOPES = {
    "app": ROOT / "Sources" / "ConductorApp",
    "core": ROOT / "Sources" / "ConductorCore",
}

TECHNICAL_LITERALS = {
    "Agent",
    "API",
    "CLI",
    "Core 7-day",
    "Core Monthly",
    "Daily Routines",
    "Deployment",
    "Mission Control",
    "OAuth",
    "OAuth / auth.json",
    "Quota URL",
    "SKILL.md",
    "skills.sh",
    "Token",
}

VISIBLE_LITERAL_ALLOWLIST = {
    "≈",
    "skills.sh",
    "https://github.com/org/repo.git",
    "branch / tag / sha",
}


def swift_files(scope_path):
    return sorted(scope_path.rglob("*.swift"))


def parse_strings(path):
    if not path.exists():
        return {}, []
    text = path.read_text(encoding="utf-8", errors="ignore")
    entries = {}
    order = []
    pattern = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)
    for match in pattern.finditer(text):
        key = match.group(1)
        entries[key] = match.group(2)
        order.append(key)
    return entries, order


def l_keys(scope_path):
    found = collections.defaultdict(list)
    pattern = re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)*)"')
    for path in swift_files(scope_path):
        text = path.read_text(encoding="utf-8", errors="ignore")
        for match in pattern.finditer(text):
            key = match.group(1)
            line = text.count("\n", 0, match.start()) + 1
            found[key].append((path, line))
    return found


def looks_like_english_key(key):
    if key in TECHNICAL_LITERALS:
        return False
    if not re.match(r"^[A-Za-z][A-Za-z0-9 /._()%-]*$", key):
        return False
    # Single acronyms or product-ish constants are usually intentional.
    if re.fullmatch(r"[A-Z0-9 /._()-]+", key):
        return False
    return True


def likely_visible_bare_strings(scope_path):
    call_pattern = re.compile(
        r'\b(?:Text|Button|Label|Toggle|Picker|TextField|SecureField)\(\s*"((?:[^"\\]|\\.)*)"|'
        r'\.help\(\s*"((?:[^"\\]|\\.)*)"|'
        r'\.accessibilityLabel\(\s*"((?:[^"\\]|\\.)*)"'
    )
    ignores = [
        re.compile(r"^\s*$"),
        re.compile(r"^[0-9%@$#{}()_ ./:\-+<>~=|]+$"),
        re.compile(r"^[A-Z][A-Za-z0-9 ._/\-+]*$"),
    ]
    out = []
    for path in swift_files(scope_path):
        text = path.read_text(encoding="utf-8", errors="ignore")
        for match in call_pattern.finditer(text):
            literal = next(group for group in match.groups() if group is not None)
            if literal in VISIBLE_LITERAL_ALLOWLIST:
                continue
            if any(regex.match(literal) for regex in ignores):
                continue
            if "\\(" in literal:
                # Interpolated counts and metrics are often generated labels; keep this audit low-noise.
                continue
            line = text.count("\n", 0, match.start()) + 1
            out.append((path, line, literal))
    return out


def rel(path):
    return str(path.relative_to(ROOT))


def print_bucket(title, items, limit):
    print(f"\n{title}: {len(items)}")
    for item in items[:limit]:
        print(f"  {item}")
    if len(items) > limit:
        print(f"  ... {len(items) - limit} more")


def main():
    parser = argparse.ArgumentParser(description="Audit Conductor localization coverage.")
    parser.add_argument("--strict", action="store_true", help="Exit non-zero when issues are found.")
    parser.add_argument("--limit", type=int, default=80, help="Maximum examples per bucket.")
    args = parser.parse_args()

    total_issues = 0
    for name, scope_path in SCOPES.items():
        entries, order = parse_strings(scope_path / "Resources" / "en.lproj" / "Localizable.strings")
        used = l_keys(scope_path)
        missing = sorted(key for key in used if key not in entries)
        duplicates = sorted(key for key, count in collections.Counter(order).items() if count > 1)
        english_keys = sorted(key for key in used if looks_like_english_key(key))
        bare = likely_visible_bare_strings(scope_path)

        total_issues += len(missing) + len(duplicates) + len(english_keys) + len(bare)

        print(f"\n== {name} ==")
        print(f"L keys: {len(used)} unique")
        print(f"en strings: {len(entries)} unique")
        print_bucket("Missing en translations", missing, args.limit)
        print_bucket("Duplicate en keys", duplicates, args.limit)
        print_bucket("English-looking L keys", english_keys, args.limit)

        bare_lines = [f"{rel(path)}:{line}: {literal}" for path, line, literal in bare]
        print_bucket("Likely bare visible strings", bare_lines, args.limit)

    if args.strict and total_issues:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
