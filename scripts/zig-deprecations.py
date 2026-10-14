#!/usr/bin/env python3
"""Count uses of the standard library names that Zig 0.17 deprecates.

Matches code only: string literals, multiline strings, and comments are
skipped, and file-local aliases such as `const mem = std.mem;` or
`const native = @import("builtin");` are resolved. `src/core/upgrade/` is
counted on its own line because distribution code changes only with
Arthur's approval. Exits 1 when any site remains outside it.

usage: python3 scripts/zig-deprecations.py [PATH ...]
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PATHS = ["src", "benchmarks", "build.zig"]
STOP_ZONE = "src/core/upgrade/"

PATTERNS = [
    ("std.fmt.allocPrint", r"\bstd\.fmt\.allocPrint(?:Sentinel)?\b"),
    ("std.fmt.bufPrint", r"\bstd\.fmt\.bufPrint(?:Sentinel)?\b"),
    ("std.mem.indexOf family", r"\bstd\.mem\.(?:indexOf|lastIndexOf)\w*\b"),
    ("std.fs.path.resolve and relative", r"\bstd\.fs\.path\.(?:resolve|relative)\b"),
    ("std.fs.path", r"\bstd\.fs\.path\b(?!\.(?:resolve|relative)\b)"),
    ("std.fs.max_path_bytes", r"\bstd\.fs\.max_path_bytes\b"),
    ("builtin.os and builtin.cpu", r"(?:\bBUILTIN|@import\(\"builtin\"\))\.(?:os|cpu)\b"),
    ("std.builtin", r"\bstd\.builtin\b"),
    (
        "Unmanaged and BitSet aliases",
        r"\bstd\.(?:ArrayListUnmanaged|ArrayListAlignedUnmanaged|ArrayHashMapUnmanaged|"
        r"AutoArrayHashMapUnmanaged|StringArrayHashMapUnmanaged|DynamicBitSetUnmanaged|"
        r"DynamicBitSet|StaticBitSet)\b",
    ),
    ("@intFromEnum", r"@intFromEnum\b"),
    ("@enumFromInt", r"@enumFromInt\b"),
    ("std.mem.copyForwards and copyBackwards", r"\bstd\.mem\.copy(?:Forwards|Backwards)\b"),
]

MASK = re.compile(r'//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'')
NAMESPACE_ALIAS = re.compile(r"\b(?:pub\s+)?const\s+(\w+)\s*=\s*(std\.(?:mem|fmt|fs|fs\.path))\s*;")
BUILTIN_ALIAS = re.compile(r"\b(?:pub\s+)?const\s+(\w+)\s*=\s*@import\(\"builtin\"\)\s*;")


def code_only(text):
    """Blank out comments and strings, keeping `@import("builtin")` visible."""

    def blank(match):
        token = match.group(0)
        return token if token == '"builtin"' else " " * len(token)

    return MASK.sub(blank, text)


def resolve_aliases(code):
    for match in NAMESPACE_ALIAS.finditer(code):
        alias, target = match.groups()
        code = re.sub(rf"(?<![\w.]){alias}\.", f"{target}.", code)
    for match in BUILTIN_ALIAS.finditer(code):
        code = re.sub(rf"(?<![\w.]){match.group(1)}\.(os|cpu)\b", r"BUILTIN.\1", code)
    return code


def zig_files(paths):
    listed = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "--", *paths],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    return [path for path in listed if path.endswith(".zig") and (ROOT / path).is_file()]


def main():
    paths = sys.argv[1:] or DEFAULT_PATHS
    counts = {name: [0, 0] for name, _ in PATTERNS}
    for path in zig_files(paths):
        original = (ROOT / path).read_text(encoding="utf-8")
        code = resolve_aliases(code_only(original))
        column = 1 if path.startswith(STOP_ZONE) else 0
        for name, pattern in PATTERNS:
            counts[name][column] += len(re.findall(pattern, code))
    width = max(len(name) for name, _ in PATTERNS)
    print(f"{'pattern':<{width}}  {'sites':>6}  {STOP_ZONE}")
    for name, (sites, stop_zone) in counts.items():
        print(f"{name:<{width}}  {sites:>6}  {stop_zone}")
    total = sum(sites for sites, _ in counts.values())
    stop_total = sum(stop for _, stop in counts.values())
    print(f"{'total':<{width}}  {total:>6}  {stop_total}")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
