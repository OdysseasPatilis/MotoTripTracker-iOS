#!/usr/bin/env python3
"""Rebuild the bundled Greater Athens traffic-camera pack from OpenStreetMap.

Usage:
  python3 Scripts/build_athens_traffic_cameras_pack.py

Writes:
  MotoTripTracker/Resources/athens_traffic_cameras.json
"""

from __future__ import annotations

import json
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "MotoTripTracker" / "Resources" / "athens_traffic_cameras.json"

# Greater Athens metro bbox (south, west, north, east) — same as speed-limit pack
SOUTH, WEST, NORTH, EAST = 37.82, 23.55, 38.15, 23.95

ENDPOINTS = [
    "https://lz4.overpass-api.de/api/interpreter",
    "https://z.overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass-api.de/api/interpreter",
]


def kind_from_tags(tags: dict) -> str | None:
    if tags.get("highway") == "speed_camera":
        return "speed"
    enforcement = tags.get("enforcement")
    if enforcement == "maxspeed":
        return "speed"
    if enforcement == "traffic_signals":
        return "redLight"
    return None


def fetch_elements() -> list[dict]:
    query = f"""
[out:json][timeout:180];
(
  node({SOUTH},{WEST},{NORTH},{EAST})["highway"="speed_camera"];
  way({SOUTH},{WEST},{NORTH},{EAST})["highway"="speed_camera"];
  node({SOUTH},{WEST},{NORTH},{EAST})["enforcement"="maxspeed"];
  way({SOUTH},{WEST},{NORTH},{EAST})["enforcement"="maxspeed"];
  node({SOUTH},{WEST},{NORTH},{EAST})["enforcement"="traffic_signals"];
  way({SOUTH},{WEST},{NORTH},{EAST})["enforcement"="traffic_signals"];
);
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
    cameras: dict[str, dict] = {}
    skipped = 0
    for element in elements:
        tags = element.get("tags") or {}
        kind = kind_from_tags(tags)
        if not kind:
            skipped += 1
            continue
        lat = element.get("lat")
        lon = element.get("lon")
        center = element.get("center") or {}
        if lat is None:
            lat = center.get("lat")
        if lon is None:
            lon = center.get("lon")
        if lat is None or lon is None:
            skipped += 1
            continue
        osm_id = f"osm:{element.get('type', 'node')}/{element['id']}"
        cameras[osm_id] = {
            "id": osm_id,
            "lat": float(lat),
            "lon": float(lon),
            "kind": kind,
        }

    pack = {
        "id": "athens_traffic_cameras",
        "name": "Greater Athens traffic cameras",
        "version": 1,
        "source": "OpenStreetMap speed/red-light cameras via Overpass",
        "bbox": {"south": SOUTH, "west": WEST, "north": NORTH, "east": EAST},
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "cameras": sorted(cameras.values(), key=lambda c: c["id"]),
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(pack, separators=(",", ":")), encoding="utf-8")
    print(f"Wrote {len(pack['cameras'])} cameras ({OUT.stat().st_size} bytes) → {OUT}")
    print(f"Skipped {skipped} elements without usable kind/coordinates")


if __name__ == "__main__":
    main()
