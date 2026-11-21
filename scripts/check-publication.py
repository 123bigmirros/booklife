#!/usr/bin/env python3
"""Check public source files without printing secret values; optionally export them.

Uses Git's own ignore parser, even before this directory is a Git repository.
Tracked files are also checked: adding a file to .gitignore does not untrack it.
This is a release guard, not a complete secret detector or a history audit.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PATTERNS = {
    "private key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    "API key": re.compile(r"\bsk-[A-Za-z0-9_-]{20,}"),
    "GitHub token": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})"),
    "AWS access key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "credential assignment": re.compile(r'''(?i)(?:api[_-]?key|access[_-]?token|client[_-]?secret|password)\s*[=:]\s*["']([A-Za-z0-9_+/=-]{20,})["']'''),
    "personal home path": re.compile(r"/" r"Users/(?!Shared(?:/|\b)|<)[^/\s`\"']+"),
    "physical device identifier": re.compile(r"\b0000[0-9A-F]{4}-[0-9A-F]{16}\b", re.I),
}
PUBLIC_MEDIA = {
    "Sources/BookSlideMac/Resources/Reader/QuietHours.epub",
    "Sources/BookSlideMac/Resources/Reader/ReadingSerif.woff2",
    "docs/media/booklife-ipad-intro.mp4",
}
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".icns"}


def git(*args, git_dir=None, check=True):
    command = ["git", "-c", "core.excludesFile=/dev/null"]
    if git_dir is not None:
        command += ["--git-dir=" + str(git_dir), "--work-tree=" + str(ROOT)]
    result = subprocess.run(command + list(args), cwd=ROOT, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=check)
    return result


def public_files():
    # A fresh index avoids workstation-global and .git/info/exclude rules silently
    # removing required files from a release. Only repository .gitignore rules apply.
    with tempfile.TemporaryDirectory(prefix="bookslide-publication-") as folder:
        git("init", "--bare", "--quiet", folder)
        names = git("ls-files", "--others", "--exclude-standard", "-z", git_dir=folder).stdout
        files = {os.fsdecode(name) for name in names.split(b"\0") if name}
        # Check tracked files in an existing repository, including ignored ones.
        tracked = git("ls-files", "--cached", "-z", check=False)
        if tracked.returncode == 0:
            tracked_names = {os.fsdecode(name) for name in tracked.stdout.split(b"\0") if name}
            # check-ignore needs NUL-delimited stdin rather than command arguments.
            result = subprocess.run(
                ["git", "-c", "core.excludesFile=/dev/null", "--git-dir=" + folder,
                 "--work-tree=" + str(ROOT), "check-ignore", "--no-index", "--stdin", "-z"],
                input=b"\0".join(os.fsencode(n) for n in sorted(tracked_names)) + b"\0" if tracked_names else b"",
                cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
            if result.returncode not in (0, 1):
                raise RuntimeError("Unable to check tracked files against .gitignore")
            ignored_tracked = {os.fsdecode(n) for n in result.stdout.split(b"\0") if n}
            files |= tracked_names
        else:
            ignored_tracked = set()
    return sorted(files), ignored_tracked, tracked.returncode == 0


def inspect_files(names, ignored_tracked):
    problems = []
    for name in names:
        path = ROOT / name
        if name in ignored_tracked:
            problems.append((name, "tracked file is excluded by .gitignore; untrack before publishing"))
        if path.is_symlink():
            problems.append((name, "symlink requires manual review"))
            continue
        if not path.is_file():
            problems.append((name, "missing or non-regular source file"))
            continue
        if path.stat().st_size > 20 * 1024 * 1024:
            problems.append((name, "file exceeds the 20 MiB source distribution limit"))
            continue
        data = path.read_bytes()
        if name in PUBLIC_MEDIA:
            continue
        if path.suffix.lower() in IMAGE_EXTENSIONS:
            if not name.startswith(("Assets/", "docs/images/")):
                problems.append((name, "unexpected image outside public assets or documentation"))
            continue
        try:
            content = data.decode("utf-8")
        except UnicodeDecodeError:
            problems.append((name, "unexpected binary file"))
            continue
        if b"\0" in data:
            problems.append((name, "unexpected binary file"))
            continue
        for label, pattern in PATTERNS.items():
            for match in pattern.finditer(content):
                line = content.count("\n", 0, match.start()) + 1
                problems.append((f"{name}:{line}", label + " (value redacted)"))
    for required in ("README.md", "LICENSE", "SECURITY.md", "CONTRIBUTING.md", "THIRD_PARTY_NOTICES.md"):
        if required not in names:
            problems.append((required, "required public document missing"))
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--export", type=Path, metavar="NEW_DIRECTORY",
                        help="Copy checked files into a new directory; never copy the whole workspace")
    args = parser.parse_args()
    names, ignored_tracked, has_git = public_files()
    problems = inspect_files(names, ignored_tracked)
    if problems:
        for name, problem in problems:
            print(f"FAIL {name}: {problem}")
        print(f"Publication blocked: {len(problems)} finding(s). No export created.")
        return 1
    print(f"PASS: {len(names)} public files checked; no configured secret patterns found.")
    print("History: not checked." if has_git else "No Git repository: tracked files and history could not be audited.")
    if args.export:
        destination = args.export.resolve()
        if destination == ROOT or destination in ROOT.parents or destination.exists():
            parser.error("Export destination must be a new directory, never the project or its parent")
        # Prevent recursive/self-inclusion if the destination sits in this tree.
        if destination.is_relative_to(ROOT) and not destination.is_relative_to(ROOT / "build"):
            parser.error("Use a new directory under build/ or outside the project")
        destination.mkdir(parents=True)
        try:
            for name in names:
                target = destination / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / name, target, follow_symlinks=False)
        except Exception:
            shutil.rmtree(destination)
            raise
        print(f"Exported {len(names)} files to {destination}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Publication check failed: {type(error).__name__}", file=sys.stderr)
        sys.exit(1)
