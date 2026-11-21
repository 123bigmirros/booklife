#!/usr/bin/env python3
"""Remove only regenerable simulator products and intermediates in build/."""
import argparse
import os
from pathlib import Path
import shutil


PROJECT = Path(__file__).resolve().parent.parent
BUILD = PROJECT / "build"
LOCAL_BUILD = Path.home() / "Library/Caches/AppleProjectBuilds/book-slide"


def candidates(root):
    for base, directories, _ in os.walk(root, followlinks=False):
        directories[:] = [name for name in directories if not (Path(base) / name).is_symlink()]
        if Path(base) == BUILD and "local-archive" in directories:
            directories.remove("local-archive")
        for name in list(directories):
            path = Path(base) / name
            if not name.endswith(("-iphonesimulator", "-watchsimulator")):
                continue
            parent = path.parent
            products = parent.name == "Products" and parent.parent.name == "Build"
            intermediates = (parent.parent.name == "Intermediates.noindex"
                             and parent.parent.parent.name == "Build"
                             and (parent.name.endswith(".build") or parent.name == "EagerLinkingTBDs"))
            if products or intermediates:
                directories.remove(name)
                yield path


def disk_bytes(path):
    total = 0
    for base, _, files in os.walk(path, followlinks=False):
        for name in files:
            try:
                total += (Path(base) / name).lstat().st_blocks * 512
            except FileNotFoundError:
                pass
    return total


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="delete listed products; default is preview")
    parser.add_argument("--derived-data", type=Path, help="limit cleanup to legacy build/ or the local BookSlide build cache")
    args = parser.parse_args()
    root = args.derived_data or BUILD
    if not root.is_absolute():
        root = PROJECT / root
    # Reject symlinks and traversal outside this project's generated build tree.
    allowed = (BUILD, LOCAL_BUILD)
    if (root.absolute() != root.resolve()
            or root.is_relative_to(BUILD / "local-archive")
            or not any(not base.is_symlink() and (root.resolve() == base or base in root.resolve().parents)
                       for base in allowed)):
        parser.error("cleanup must use legacy build/ or the local BookSlide cache without symlinks or '..'")
    paths = sorted(candidates(root))
    total = 0
    for path in paths:
        size = disk_bytes(path)
        if args.apply:
            shutil.rmtree(path)
        total += size
        label = path.relative_to(PROJECT) if PROJECT in path.parents else path
        print(f"{'Removed' if args.apply else 'Would remove'} {size / 1024**2:.1f} MiB  {label}")
    print(f"{'Removed' if args.apply else 'Reclaimable'}: {total / 1024**3:.2f} GiB ({len(paths)} directories)")


if __name__ == "__main__":
    main()
