#!/usr/bin/env python3
"""Package the approved master artwork into reproducible Xcode icon assets."""
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
INFO = {"author": "xcode", "version": 1}

def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")

def resize(source, destination, pixels):
    subprocess.run(["sips", "-z", str(pixels), str(pixels), str(source),
                    "--out", str(destination)], check=True, capture_output=True)

for platform in ("Phone", "Watch", "Mac"):
    catalog = ROOT / "Assets" / f"{platform}.xcassets"
    icon = catalog / "AppIcon.appiconset"
    icon.mkdir(parents=True, exist_ok=True)
    write_json(catalog / "Contents.json", {"info": INFO})
    images = []
    if platform == "Mac":
        source = ROOT / "Assets/Brand/BookSlide-mac-master.png"
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                name = f"icon-{size}@{scale}x.png"
                resize(source, icon / name, size * scale)
                images.append({"idiom": "mac", "size": f"{size}x{size}",
                               "scale": f"{scale}x", "filename": name})
    else:
        resize(ROOT / "Assets/Brand/BookSlide-master.png", icon / "icon-1024.png", 1024)
        images.append({"idiom": "universal", "platform": "ios" if platform == "Phone" else "watchos",
                       "size": "1024x1024", "filename": "icon-1024.png"})
    write_json(icon / "Contents.json", {"images": images, "info": INFO})
print("Generated Phone, Watch and Mac AppIcon catalogs")
