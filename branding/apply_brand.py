#!/usr/bin/env python3
"""Apply the supplied DAYMARK brand assets (branding/source) to a Flutter project.

    python branding/apply_brand.py apps/client          # apply (idempotent)
    python branding/apply_brand.py apps/client --check  # verify only, change nothing

What it does to the artwork:
  * COPIES supplied PNGs byte-for-byte under the file names the app expects.
  * SCALES and PADS (never redraws or recolours) the supplied transparent symbol onto the
    108 dp canvas Android adaptive icons require, sized so every visible pixel stays inside
    the 66 dp safe zone. The adaptive background colour is read from the supplied app icon.
  * WRITES configuration only: adaptive-icon XML, colour resource, web manifest.json and the
    icon/manifest tags in web/index.html (when that file exists).

It never invents a variant. Missing variants are listed in the report.
Requires: Python 3.9+, Pillow, numpy.
"""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
RES = "android/app/src/main/res"

# (supplied file, destination relative to the Flutter project). Byte-for-byte copies.
VERBATIM = [
    # In-app logos. Names keep the stems the code already used (daymark-logo, -dark, -symbol).
    ("logo/DAYMARK-primary-light.png", "assets/brand/logo/daymark-logo.png"),
    ("logo/DAYMARK-primary-dark.png", "assets/brand/logo/daymark-logo-dark.png"),
    ("icons/DAYMARK-icon-512.png", "assets/brand/logo/daymark-symbol.png"),
    # Android legacy launcher icons (API < 26). Sizes match the densities exactly.
    ("android/ic_launcher-48.png", f"{RES}/mipmap-mdpi/ic_launcher.png"),
    ("android/ic_launcher-72.png", f"{RES}/mipmap-hdpi/ic_launcher.png"),
    ("android/ic_launcher-96.png", f"{RES}/mipmap-xhdpi/ic_launcher.png"),
    ("android/ic_launcher-144.png", f"{RES}/mipmap-xxhdpi/ic_launcher.png"),
    ("android/ic_launcher-192.png", f"{RES}/mipmap-xxxhdpi/ic_launcher.png"),
    ("android/ic_launcher-512.png", "android/app/src/main/ic_launcher-playstore.png"),
    # Web
    ("web/favicon-32.png", "web/favicon.png"),
    ("web/favicon-16.png", "web/icons/favicon-16.png"),
    ("web/favicon-32.png", "web/icons/favicon-32.png"),
    ("web/favicon-48.png", "web/icons/favicon-48.png"),
    ("web/favicon-180.png", "web/icons/apple-touch-icon.png"),
    ("web/favicon-192.png", "web/icons/Icon-192.png"),
    ("web/favicon-512.png", "web/icons/Icon-512.png"),
]

# Flutter-template icons we have no supplied replacement for (no maskable variant was supplied).
OBSOLETE_WEB_ICONS = ["Icon-maskable-192.png", "Icon-maskable-512.png"]

DENSITIES = {"mdpi": 1.0, "hdpi": 1.5, "xhdpi": 2.0, "xxhdpi": 3.0, "xxxhdpi": 4.0}
SAFE_ZONE_DP = 66  # Android guarantees this centre circle is never masked away
CANVAS_DP = 108

NOT_SUPPLIED = [
    "Vector (SVG) logo or symbol: the guideline sheet mentions 'SVG / PNG' but only PNG was supplied",
    "Compact horizontal logo and stacked logo as files (they appear only on the guideline sheet)",
    "Monochrome logo, so no Android 13 themed-icon layer (omitted, not invented)",
    "Dark-background standalone symbol (the supplied transparent symbol loses its tile on dark surfaces)",
    "Inverted/dark app icon shown on the guideline sheet",
    "Maskable PWA icons (supplied web icons are full-bleed, so none are declared as maskable)",
    "Round Android launcher icons (optional; Android masks the adaptive icon itself)",
    "favicon.ico",
    "Transparent-background versions of the primary logos (both are opaque with a baked-in background)",
]


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def adaptive_foreground(sym: Image.Image) -> tuple[float, dict]:
    """Return the symbol size in dp and the per-density canvases (symbol centred, transparent)."""
    a = np.asarray(sym.getchannel("A"))
    ys, xs = np.nonzero(a >= 8)
    c = (sym.width - 1) / 2
    r_px = float(np.sqrt((xs - c) ** 2 + (ys - c) ** 2).max()) + 1.0
    sym_dp = sym.width * (SAFE_ZONE_DP / 2) / r_px  # farthest visible pixel lands on the 66 dp circle
    out = {}
    for name, d in DENSITIES.items():
        size, side = round(CANVAS_DP * d), int(sym_dp * d)  # int() rounds down: stays inside
        canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        scaled = sym.resize((side, side), Image.LANCZOS)
        canvas.alpha_composite(scaled, ((size - side) // 2, (size - side) // 2))
        out[name] = canvas
    return sym_dp, out


HEAD_MARK = "<!-- DAYMARK branding -->"
HEAD_BLOCK = f"""  {HEAD_MARK}
  <link rel="icon" type="image/png" href="favicon.png">
  <link rel="icon" type="image/png" sizes="16x16" href="icons/favicon-16.png">
  <link rel="icon" type="image/png" sizes="32x32" href="icons/favicon-32.png">
  <link rel="icon" type="image/png" sizes="48x48" href="icons/favicon-48.png">
  <link rel="apple-touch-icon" sizes="180x180" href="icons/apple-touch-icon.png">
  <link rel="manifest" href="manifest.json">
  <meta name="theme-color" content="{{THEME}}">
  <!-- /DAYMARK branding -->
"""


def patch_index(html: str, theme: str) -> str:
    html = re.sub(rf"[ \t]*{re.escape(HEAD_MARK)}.*?<!-- /DAYMARK branding -->\n?", "", html, flags=re.S)
    for pat in (r'<link[^>]+rel=["\'](?:shortcut )?icon["\'][^>]*>',
                r'<link[^>]+rel=["\']apple-touch-icon["\'][^>]*>',
                r'<link[^>]+rel=["\']manifest["\'][^>]*>',
                r'<meta[^>]+name=["\']theme-color["\'][^>]*>'):
        html = re.sub(r"[ \t]*" + pat + r"[ \t]*\n?", "", html, flags=re.I)
    if "</head>" not in html:
        raise ValueError("index.html has no </head>")
    return html.replace("</head>", HEAD_BLOCK.replace("{THEME}", theme) + "</head>", 1)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("project", type=Path, help="Flutter project directory (contains pubspec.yaml)")
    ap.add_argument("--source", type=Path, default=HERE / "source")
    ap.add_argument("--check", action="store_true", help="verify only; change nothing")
    args = ap.parse_args()
    src, proj = args.source, args.project

    missing = [s for s, _ in VERBATIM if not (src / s).exists()] + \
              [s for s in ("icons/DAYMARK-icon-transparent-1024.png", "icons/DAYMARK-app-icon-1024.png",
                           "web/site.webmanifest") if not (src / s).exists()]
    if missing:
        print("ERROR: supplied files not found:", *missing, sep="\n  ")
        return 2

    problems = []

    def write_bytes(dst_rel: str, data: bytes):
        dst = proj / dst_rel
        if args.check:
            if not dst.exists() or dst.read_bytes() != data:
                problems.append(f"out of date: {dst_rel}")
            return
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(data)

    # 1. Verbatim copies
    for s, d in VERBATIM:
        write_bytes(d, (src / s).read_bytes())
    print(f"copied byte-for-byte: {len(VERBATIM)} files")

    # 2. Android adaptive icon (derived by scaling/padding only)
    sym = Image.open(src / "icons/DAYMARK-icon-transparent-1024.png").convert("RGBA")
    sym_dp, layers = adaptive_foreground(sym)
    bg = "#%02X%02X%02X" % Image.open(src / "icons/DAYMARK-app-icon-1024.png").convert("RGB").getpixel((2, 2))
    import io
    for name, img in layers.items():
        buf = io.BytesIO()
        img.save(buf, "PNG", optimize=True)
        write_bytes(f"{RES}/mipmap-{name}/ic_launcher_foreground.png", buf.getvalue())
    write_bytes(f"{RES}/mipmap-anydpi-v26/ic_launcher.xml", (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '</adaptive-icon>\n').encode())
    write_bytes(f"{RES}/values/ic_launcher_background.xml", (
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        f'    <color name="ic_launcher_background">{bg}</color>\n</resources>\n').encode())
    print(f"adaptive icon: symbol {sym_dp:.1f} dp inside a {CANVAS_DP} dp canvas "
          f"({sym_dp / CANVAS_DP:.0%}); background {bg} (sampled from the supplied app icon)")

    # 3. Web manifest: supplied values, relative paths, start_url added for installability
    sup = json.loads((src / "web/site.webmanifest").read_text())
    manifest = {
        "name": sup["name"], "short_name": sup["short_name"], "description": sup["description"],
        "start_url": ".", "display": sup["display"],
        "background_color": sup["background_color"], "theme_color": sup["theme_color"],
        "icons": [
            {"src": "icons/Icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any"},
            {"src": "icons/Icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any"},
        ],
    }
    write_bytes("web/manifest.json", (json.dumps(manifest, indent=2) + "\n").encode())

    # 4. index.html (only if the project already has one)
    idx = proj / "web/index.html"
    if idx.exists():
        new = patch_index(idx.read_text(encoding="utf-8"), sup["theme_color"])
        if args.check:
            if new != idx.read_text(encoding="utf-8"):
                problems.append("out of date: web/index.html")
        else:
            idx.write_text(new, encoding="utf-8")
        print("patched web/index.html")
    else:
        print("web/index.html not found: skipped (run `flutter create --platforms=web,android .` first,"
              " then re-run this script)")

    # 4b. Prune obsolete default icons that no longer have a supplied replacement.
    #     Only exact known Flutter-template names, and only if nothing in web/ references them.
    for name in OBSOLETE_WEB_ICONS:
        f = proj / "web/icons" / name
        if not f.exists():
            continue
        refs = [t.relative_to(proj).as_posix() for t in (proj / "web").rglob("*")
                if t.is_file() and t.suffix in {".html", ".json", ".js", ".webmanifest"}
                and name in t.read_text(encoding="utf-8", errors="ignore")]
        if refs:
            problems.append(f"web/icons/{name} is still referenced by {refs}; not removed")
        elif args.check:
            problems.append(f"obsolete (unreferenced) default icon present: web/icons/{name}")
        else:
            f.unlink()
            print(f"removed obsolete, unreferenced default icon: web/icons/{name}")

    # 5. Integrity: every file referenced by the configs exists
    for ref in ["web/icons/Icon-192.png", "web/icons/Icon-512.png", "web/favicon.png",
                "web/icons/apple-touch-icon.png", f"{RES}/mipmap-xxxhdpi/ic_launcher_foreground.png"]:
        if not (proj / ref).exists() and not args.check:
            problems.append(f"missing after apply: {ref}")
    if args.check:
        for s, d in VERBATIM:
            if (proj / d).exists() and sha(proj / d) != sha(src / s):
                problems.append(f"checksum differs from supplied file: {d}")

    print("\nNOT SUPPLIED (reported, not invented):", *NOT_SUPPLIED, sep="\n  - ")
    if problems:
        print("\nPROBLEMS:", *problems, sep="\n  ")
        return 1
    print("\nOK" + (" (check only)" if args.check else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
