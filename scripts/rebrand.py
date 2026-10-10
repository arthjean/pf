#!/usr/bin/env python3
"""Rename fx to pf (Paneflow Agent).

Paneflow Agent started from vercel-labs/fx. Every rename rule lives here so the
same rules apply to this repository and to fx changes ported later.

Commands:
  apply            rewrite tracked text files, .tar.gz member paths, and tracked paths in place
  check            list fx spellings outside the allowlist; exit 1 if any remain
  filter           rewrite stdin to stdout
  port FROM TO     3-way merge the fx range FROM..TO from a local fx clone
"""

import argparse
import gzip
import io
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Files that describe the fx origin, or that pf owns outright, keep their text.
SKIP_FILES = {
    "CHANGELOG.md",
    "CLAUDE.md",
    "LICENSE",
    "NOTICE",
    "UPSTREAM.md",
    "scripts/rebrand.py",
    # pf does not publish libpf, so fx's publishing workflow stays out.
    ".github/workflows/publish-libfx.yml",
    # PRDs plan pf's divergence from fx and name it on purpose.
    "tasks/prd-fx-sync-0-0-13-status.json",
    "tasks/prd-fx-sync-0-0-13.md",
    "tasks/prd-pf-distribution.md",
    "tasks/prd-windows-native-support.md",
}

# Rewrites that retarget a value instead of renaming it. They run first.
RETARGETS = [
    # Product identity sent to third parties points at the product site.
    (r"(?<=[+\" ])https://github\.com/vercel-labs/fx(?=[\"')])", "https://paneflow.dev/agent"),
    (r"You are fx, a local coding CLI assistant", "You are Paneflow Agent (pf), a local coding CLI assistant"),
    (r"You are fx, a coding agent with tool access", "You are Paneflow Agent (pf), a coding agent with tool access"),
    # pf signs macOS binaries under its own identifier.
    (r"com\.vercel\.fx", "dev.paneflow.agent"),
    # A renamed Zig package needs its own fingerprint.
    (r"\.fingerprint = 0x2ca027d00bcd652c", ".fingerprint = 0xca37af64c5d0d74e"),
    # Digests pinned over text that the rename changes.
    (r"51b79260638620ff5f046a835b16f37d50dead5156206b600d0357177edf23d7", "69ffaae21a60b322fb800934b40dcb2d982733d0b2941ce2f18e371af8a3b1a8"),
    (r"44e5ac3bfa303d0686f51387c19cb0adab415694ecf48380e3a51b130a7cf99f", "69af750994791f830db305a896b760bdd85b43a5d278c7513fc517b6a37dedf6"),
    (r"ca8b5aa265c6318fbd0604879fb2626826d9fcb83fa5d335dc0371fec7286b3f", "791976077208397ed5eb292eb6ef841b2424b5f817d2b9225367b68bad7fdfc4"),
    (r"5029829df4ea080a7c21701c0185b777d21fd42d1b79a7a957605e508f73fe03", "f4020f9dd07c6d277aa7f073ee1de9ac83b3a8946c1bc7fa3e84d768260f8bec"),
    (r"0x15, 0xa6, 0x34, 0x7e, 0xb5, 0xad, 0x37, 0xc6,", "0xf8, 0xea, 0x45, 0xb9, 0xdd, 0x40, 0x11, 0x11,"),
    (r"0x5c, 0x75, 0x59, 0xd2, 0xd0, 0xa5, 0x13, 0xb7,", "0x95, 0xb7, 0x7a, 0x27, 0x83, 0x14, 0xcc, 0x0e,"),
    (r"0x79, 0x95, 0x1f, 0xc4, 0x3a, 0x02, 0xd1, 0x73,", "0x50, 0x28, 0x88, 0x0d, 0x85, 0xf9, 0xfb, 0x51,"),
    (r"0x4c, 0x71, 0x8b, 0x0b, 0x51, 0x19, 0x58, 0x1e,", "0x99, 0xcd, 0xdd, 0x09, 0xef, 0x8c, 0x1b, 0x6e,"),
    (r"15b963713444428d1548b060b5ee883a209f7cea43ff80e0fdaa33a98b41e34e", "2fdaa8dfedca78ae42e09d63f5fa4ad59d61afd1e38e1c2bd8abf25b4fd31cf5"),
]

# Spans that must stay fx. They are masked before the rename rules run.
PROTECTED = [
    # Upstream attribution and fixtures that parse real repository URLs.
    r"(?:https?://github\.com/|git@github\.com:|git\+https://github\.com/)?vercel-labs/fx\b(?:\.git)?",
    # The Slack bridge runs on fx.sh with fx's Slack app.
    r"\"https://fx\.sh\"",
    r"https://fx\.sh/api/slack/[^\s\"'`)]*",
    # Attribution that names fx on purpose.
    r"\[fx\](?=\(https://github\.com/vercel-labs/fx\))",
    r"the fx Slack app",
    r"fx Client ID",
    # Repository names parsed from those fixtures.
    r"\"fx\", [A-Za-z_.?]*repo_name\)",
    # Package lock integrity hashes.
    r"sha(?:1|256|384|512)-[A-Za-z0-9+/]+=*",
]
PROTECTED_RE = re.compile("|".join(f"(?:{p})" for p in PROTECTED))
SLACK_LINE_RE = re.compile(r"(?i)slack")
FX_SH_RE = re.compile(r"fx\.sh")

RULES = [
    # The styled wordmark keeps its width and byte length.
    (r"\U0001D487x", "\U0001D491f"),
    (r"https://releases\.fx\.sh", "https://releases.paneflow.dev/agent"),
    (r"releases\.fx\.sh", "releases.paneflow.dev/agent"),
    (r"https?://fx\.sh", "https://paneflow.dev/agent"),
    (r"(?<![A-Za-z0-9.-])fx\.sh(?![A-Za-z0-9])", "paneflow.dev/agent"),
    # The article follows the name: "an fx session" becomes "a pf session",
    # and "an FX_FAST toggle" becomes "a PF_FAST toggle".
    (r"\b([Aa])n fx(?![A-Za-z0-9])", r"\1 pf"),
    (r"\b([Aa])n FX(?![A-Za-z0-9])", r"\1 PF"),
    (r"libfx", "libpf"),
    (r"LIBFX", "LIBPF"),
    (r"Libfx", "Libpf"),
    (r"fxtape", "pftape"),
    (r"FXSNAP", "PFSNAP"),
    (r"fxsnap", "pfsnap"),
    # Fixture names and shell aliases such as fxbig, fxll, or fxb_a.
    (r"(?<![A-Za-z0-9])fx(?=(?:a|big|small|late|grid|ll)\b|b_[af])", "pf"),
    (r"'f', 'x'", "'p', 'f'"),
    (r"(?<![A-Z])Fx(?![a-z])", "Pf"),
    # Escapes such as \n, \000, \x00, or a CSI sequence glue a letter to the name.
    (r"(\\[ntr]|\\[0-7]{1,3}|\\x[0-9a-fA-F]{2}|\[[0-9;]*[A-Za-z])fx(?![A-Za-z0-9])", r"\1pf"),
    (r"(\\[ntr]|\\[0-7]{1,3}|\\x[0-9a-fA-F]{2}|\[[0-9;]*[A-Za-z])FX(?![A-Za-z0-9])", r"\1PF"),
    (r"(?<![A-Za-z0-9])FX(?![A-Za-z0-9])", "PF"),
    (r"(?<![A-Za-z0-9])fx(?![A-Za-z0-9])", "pf"),
    # lowerCamel identifiers such as fxSdkApiVersion or __fxCoreTest.
    (r"(?<![A-Za-z0-9])fx(?=[A-Z])", "pf"),
]
RETARGETS = [(re.compile(p), r) for p, r in RETARGETS]
RULES = [(re.compile(p), r) for p, r in RULES]

# Internal fx spellings that `check` accepts: binary format magics, test
# labels, and temp prefixes.
ALLOWED = [
    r"FX(?:CP|RPLY\d+|REL[HP]\d+|TE|TH|TP)\b",
    r"FX\d\d",
    r"FXC-?\d*",
    r"\bAFX\b",
    r"FXWASMLIVE",
    r"RIFFxxxx",
    r"fxc\d+",
    r"fxop:",
    r"fxp-tmux-",
    r"fxrl-",
    r"\.fxtp\b",
    r"_rfx\b",
    r"\\xffx",
    r"\\nFX\d",
]
ALLOWED_RE = re.compile("|".join(f"(?:{p})" for p in ALLOWED))
FX_ANY_RE = re.compile(r"(?i)fx|\U0001D487")


def mask(line, keep):
    """Replace protected spans with NUL-delimited indexes into `keep`."""

    def stash(match):
        keep.append(match.group(0))
        return f"\0{len(keep) - 1}\0"

    line = PROTECTED_RE.sub(stash, line)
    if SLACK_LINE_RE.search(line):
        line = FX_SH_RE.sub(stash, line)
    return line


def unmask(line, keep):
    return re.sub(r"\0(\d+)\0", lambda m: keep[int(m.group(1))], line)


def rename_text(text):
    out = []
    for line in text.splitlines(keepends=True):
        for pattern, replacement in RETARGETS:
            line = pattern.sub(replacement, line)
        keep = []
        line = mask(line, keep)
        for pattern, replacement in RULES:
            line = pattern.sub(replacement, line)
        out.append(unmask(line, keep))
    return "".join(out)


def rename_path(path):
    return "/".join(rename_text(part) for part in path.split("/"))


def rename_binary(path, data):
    """Rename member paths inside .tar.gz fixtures; return other binary data unchanged."""
    if not path.endswith(".tar.gz"):
        return data
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as src:
        members = src.getmembers()
        if all(rename_path(m.name) == m.name for m in members):
            return data
        out = io.BytesIO()
        with gzip.GzipFile(filename="", mode="wb", fileobj=out, mtime=0) as gz, tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as dst:
            for member in members:
                content = src.extractfile(member) if member.isfile() else None
                member.name = rename_path(member.name)
                dst.addfile(member, content)
    return out.getvalue()


def decode(data):
    """Return text for UTF-8 files, or None for binary data."""
    if data is None or b"\0" in data[:8192]:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def git(*args, cwd=ROOT, check=True):
    return subprocess.run(["git", *args], cwd=cwd, check=check, capture_output=True).stdout


def tracked_files():
    return [p for p in git("ls-files", "-z").decode().split("\0") if p]


def worktree_files():
    """Tracked and untracked files, without ignored ones."""
    listed = git("ls-files", "-z", "--cached", "--others", "--exclude-standard").decode().split("\0")
    return list(dict.fromkeys(p for p in listed if p))


def cmd_apply(_args):
    changed = moved = 0
    for path in tracked_files():
        file = ROOT / path
        if path not in SKIP_FILES and not file.is_symlink():
            data = file.read_bytes()
            text = decode(data)
            if text is not None:
                renamed = rename_text(text)
                if renamed != text:
                    file.write_text(renamed, encoding="utf-8")
                    changed += 1
            elif (renamed := rename_binary(path, data)) != data:
                file.write_bytes(renamed)
                changed += 1
        target = rename_path(path)
        if target != path:
            (ROOT / target).parent.mkdir(parents=True, exist_ok=True)
            git("mv", path, target)
            moved += 1
    print(f"rewrote {changed} files, moved {moved} paths")


def cmd_check(_args):
    hits = 0
    for path in worktree_files():
        file = ROOT / path
        # A tracked file can be missing from the worktree while a conflict is resolved.
        if path in SKIP_FILES or file.is_symlink() or not file.is_file():
            continue
        text = decode(file.read_bytes())
        if text is None:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            visible = ALLOWED_RE.sub("", unmask_all(line))
            if FX_ANY_RE.search(visible):
                hits += 1
                print(f"{path}:{number}: {line.strip()[:160]}")
    if hits:
        print(f"{hits} unexpected fx spellings", file=sys.stderr)
        return 1
    return 0


def unmask_all(line):
    """Drop protected spans so only unexpected fx spellings remain."""
    return re.sub(r"\0\d+\0", "", mask(line, []))


def cmd_filter(_args):
    sys.stdout.write(rename_text(sys.stdin.read()))


def cmd_port(args):
    upstream = Path(args.upstream).resolve()
    if not upstream.is_dir():
        sys.exit(f"rebrand.py port: no fx clone at {upstream}; clone fx there or pass --upstream")
    # Fail before writing anything when the clone lacks FROM or TO.
    diff = ["diff", "--name-status", "--no-renames", args.start, args.end]
    listed = subprocess.run(["git", *diff], cwd=upstream, capture_output=True)
    if listed.returncode:
        sys.exit(f"rebrand.py port: `git {' '.join(diff)}` failed in {upstream}: {listed.stderr.decode().strip()}")
    names = listed.stdout.decode()
    conflicts = []
    for entry in names.splitlines():
        status, path = entry.split("\t", 1)
        if path in SKIP_FILES:
            print(f"skip   {path}")
            continue
        dest = ROOT / rename_path(path)
        old = None if status == "A" else git("show", f"{args.start}:{path}", cwd=upstream)
        new = None if status == "D" else git("show", f"{args.end}:{path}", cwd=upstream)
        old_text, new_text = decode(old), decode(new)
        binary = (old is not None and old_text is None) or (new is not None and new_text is None)
        if status == "D":
            current = dest.read_bytes() if dest.exists() else None
            expected = rename_binary(path, old) if binary else rename_text(old_text).encode()
            if current is None:
                continue
            if current == expected:
                git("rm", "--quiet", str(dest.relative_to(ROOT)))
                print(f"delete {dest.relative_to(ROOT)}")
            else:
                conflicts.append(f"{dest.relative_to(ROOT)}: deleted upstream but changed in pf")
            continue
        payload = rename_binary(path, new) if binary else rename_text(new_text).encode()
        if status == "A" or not dest.exists():
            if dest.exists() and dest.read_bytes() != payload:
                conflicts.append(f"{dest.relative_to(ROOT)}: added upstream but already exists in pf")
                continue
            if status != "A":
                conflicts.append(f"{dest.relative_to(ROOT)}: changed upstream but missing in pf")
                continue
            mode = git("ls-tree", args.end, "--", path, cwd=upstream).split(b" ", 1)[0]
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(payload)
            dest.chmod(0o755 if mode == b"100755" else 0o644)
            git("add", str(dest.relative_to(ROOT)))
            print(f"add    {dest.relative_to(ROOT)}")
            continue
        if binary:
            conflicts.append(f"{dest.relative_to(ROOT)}: binary file changed upstream")
            continue
        with tempfile.TemporaryDirectory() as tmp:
            base, theirs = Path(tmp, "base"), Path(tmp, "theirs")
            base.write_text(rename_text(old_text), encoding="utf-8")
            theirs.write_text(rename_text(new_text), encoding="utf-8")
            merge = subprocess.run(
                ["git", "merge-file", "-L", "pf", "-L", f"fx {args.start}", "-L", f"fx {args.end}", str(dest), str(base), str(theirs)],
                cwd=ROOT,
            )
        if merge.returncode:
            conflicts.append(f"{dest.relative_to(ROOT)}: {merge.returncode} conflict(s)")
        print(f"merge  {dest.relative_to(ROOT)}")
    for conflict in conflicts:
        print(f"CONFLICT {conflict}", file=sys.stderr)
    return 1 if conflicts else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("apply").set_defaults(run=cmd_apply)
    commands.add_parser("check").set_defaults(run=cmd_check)
    commands.add_parser("filter").set_defaults(run=cmd_filter)
    port = commands.add_parser("port")
    port.add_argument("start", metavar="FROM")
    port.add_argument("end", metavar="TO")
    port.add_argument("--upstream", default=str(ROOT.parent / "fx"), help="local fx clone (default: ../fx)")
    port.set_defaults(run=cmd_port)
    args = parser.parse_args()
    sys.exit(args.run(args) or 0)


if __name__ == "__main__":
    main()
