#!/usr/bin/env python3
"""Rebuild the bundled Greater Athens speed-limit grid from OpenStreetMap.

Usage:
  python3 Scripts/build_athens_speed_limit_pack.py

Writes:
  MotoTripTracker/Resources/athens_speed_limits.json
"""

from __future__ import annotations

import json
import math
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "MotoTripTracker" / "Resources" / "athens_speed_limits.json"

# Greater Athens metro bbox (south, west, north, east)
SOUTH, WEST, NORTH, EAST = 37.82, 23.55, 38.15, 23.95
GRID_SCALE = 500.0

HIGHWAY_PRIORITY = {
    "motorway": 100,
    "motorway_link": 95,
    "trunk": 90,
    "trunk_link": 85,
    "primary": 80,
    "primary_link": 75,
    "secondary": 70,
    "secondary_link": 65,
    "tertiary": 60,
    "tertiary_link": 55,
    "unclassified": 40,
    "residential": 35,
    "living_street": 30,
    "service": 20,
}

IMPLICIT = {
    "gr:urban": 50,
    "gr:rural": 90,
    "gr:trunk": 110,
    "gr:motorway": 130,
    "gr:living_street": 20,
    "urban": 50,
    "rural": 90,
    "trunk": 110,
    "motorway": 130,
    "living_street": 20,
    "walk": 5,
}

ENDPOINTS = [
    "https://lz4.overpass-api.de/api/interpreter",
    "https://z.overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass-api.de/api/interpreter",
]


def parse_kmh(raw: str) -> int | None:
    value = raw.strip().lower()
    if not value or value in ("signals", "variable", "none"):
        return None
    if value in IMPLICIT:
        parsed = IMPLICIT[value]
        return parsed if parsed > 0 else None
    if "mph" in value:
        digits = "".join(c for c in value if c.isdigit() or c == ".")
        try:
            return int(round(float(digits) * 1.60934))
        except ValueError:
            return None
    digits = "".join(
        c for c in value.replace("km/h", "").replace("kph", "") if c.isdigit()
    )
    if digits:
        n = int(digits)
        return n if n > 0 else None
    return None


def fetch_elements() -> list[dict]:
    query = f"""
[out:json][timeout:180];
way({SOUTH},{WEST},{NORTH},{EAST})["highway"]["maxspeed"];
out center tags;
"""
    body = urllib.parse.urlencode({"data": query}).encode()
    last_err: Exception | None = None
    for endpoint in ENDPOINTS:
        try:
            print(f"Querying {endpoint} ...", flush=True)
            req = urllib.request.Request(
                endpoint,
                data=body,
                method="POST",
                headers={
                    "Content-Type": "application/x-www-form-urlencoded",
                    "User-Agent": "MotoTripTracker/1.0 (pack-builder)",
                    "Accept": "application/json",
                },
            )
            with urllib.request.urlopen(req, timeout=200) as resp:
                payload = json.load(resp)
            elements = payload.get("elements", [])
            print(f"OK elements={len(elements)}", flush=True)
            return elements
        except Exception as exc:  # noqa: BLE001 - try next mirror
            last_err = exc
            print(f"Failed {endpoint}: {exc}", flush=True)
    raise SystemExit(f"All Overpass mirrors failed: {last_err}")


def main() -> None:
    elements = fetch_elements()
    cells: dict[str, tuple[int, int]] = {}
    skipped = 0
    for element in elements:
        tags = element.get("tags") or {}
        center = element.get("center")
        if not center:
            skipped += 1
            continue
        kmh = parse_kmh(tags.get("maxspeed", ""))
        if not kmh or kmh < 5 or kmh > 200:
            skipped += 1
            continue
        lat = center["lat"]
        lon = center["lon"]
        key = f"{int(math.trunc(lat * GRID_SCALE))}_{int(math.trunc(lon * GRID_SCALE))}"
        priority = HIGHWAY_PRIORITY.get(tags.get("highway", ""), 1)
        previous = cells.get(key)
        if previous is None or priority >= previous[0]:
            cells[key] = (priority, kmh)

    pack = {
        "id": "athens",
        "name": "Greater Athens",
        "version": 1,
        "source": "OpenStreetMap maxspeed via Overpass",
        "gridScale": GRID_SCALE,
        "bbox": {"south": SOUTH, "west": WEST, "north": NORTH, "east": EAST},
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "cells": {key: value for key, (_, value) in cells.items()},
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(pack, separators=(",", ":")), encoding="utf-8")
    print(f"Wrote {len(pack['cells'])} cells ({OUT.stat().st_size} bytes) → {OUT}")
    print(f"Skipped {skipped} ways without usable center/maxspeed")


if __name__ == "__main__":
    main()
