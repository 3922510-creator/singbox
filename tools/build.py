#!/usr/bin/env python3
"""Build the self-contained script served by the existing installer. No runtime imports."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PARTS = ("header", "core", "nodes", "argo", "warp", "system-tools", "menus")


def build():
    return "\n\n".join((ROOT / "src" / f"{part}.sh").read_text().rstrip() for part in PARTS) + "\n"


if __name__ == "__main__":
    (ROOT / "singbox.sh").write_text(build())
