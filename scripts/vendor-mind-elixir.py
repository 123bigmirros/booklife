#!/usr/bin/env python3
"""Refresh the pinned, offline Mind Elixir distribution without npm install hooks."""
import base64
import hashlib
import io
from pathlib import Path
import tarfile
import urllib.request

VERSION = "6.0.1"
URL = f"https://registry.npmjs.org/mind-elixir/-/mind-elixir-{VERSION}.tgz"
INTEGRITY = "sha512-0q7xiBedF2IN/UlZK0gW7J0SB0GI+22fx6Ryvzt+cXfbdjXsQSD6ZvSYcEic9UtP9CUe0obN2aEVI/tLb4Jbtg=="
ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "Sources/BookSlideMac/Resources/Reader/MindMap/vendor"

def main():
    with urllib.request.urlopen(URL, timeout=30) as response:
        archive = response.read(2 * 1024 * 1024)
    actual = "sha512-" + base64.b64encode(hashlib.sha512(archive).digest()).decode()
    if actual != INTEGRITY:
        raise SystemExit("Package integrity mismatch; no files were changed.")
    sources = {f"dist/{name}": name for name in ["MindElixir.js", "MindElixir.css", "i18n.js"]}
    sources["LICENSE"] = "MIND-ELIXIR-LICENSE"
    with tarfile.open(fileobj=io.BytesIO(archive)) as package:
        files = {name: package.extractfile("package/" + source).read() for source, name in sources.items()}
    TARGET.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (TARGET / name).write_bytes(data)
    (TARGET / "NOTICE.txt").write_text(
        f"Mind Elixir Core {VERSION}\nSource: https://github.com/SSShooter/mind-elixir-core\n"
        f"Package: {URL}\nIntegrity: {INTEGRITY}\nLicense: MIT (see MIND-ELIXIR-LICENSE).\n"
        "Bundled offline, unmodified upstream distribution. No runtime CDN requests.\n"
    )
    print(f"Vendored and verified Mind Elixir {VERSION}.")

if __name__ == "__main__":
    main()
