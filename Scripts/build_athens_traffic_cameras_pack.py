#!/usr/bin/env python3
"""Rebuild bundled traffic-camera packs from OpenStreetMap-derived sources.

Usage:
  python3 Scripts/build_athens_traffic_cameras_pack.py

Writes:
  MotoTripTracker/Resources/athens_traffic_cameras.json  (Greater Athens Overpass)
  MotoTripTracker/Resources/greece_traffic_cameras.json  (nationwide via speedcams.world CSV)
"""

from __future__ import annotations

import csv
import io
import json
import urllib.parse
import urllib.request
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "MotoTripTracker" / "Resources"
ATHENS_OUT = RESOURCES / "athens_traffic_cameras.json"
GREECE_OUT = RESOURCES / "greece_traffic_cameras.json"

# Greater Athens metro bbox (south, west, north, east) — same as speed-limit pack
SOUTH, WEST, NORTH, EAST = 37.82, 23.55, 38.15, 23.95

GREECE_BBOX = {"south": 34.70, "west": 19.20, "north": 41.80, "east": 29.70}
SPEEDCAMS_CSV = "https://speedcams.world/downloads/gr/gr-all.csv"

ENDPOINTS = [
    "https://lz4.overpass-api.de/api/interpreter",
    "https://z.overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass-api.de/api/interpreter",
]


def kind_from_tags(tags: dict) -> str | None:
    camera_type = (tags.get("camera:type") or "").lower()
    if camera_type in {"red_light", "traffic_signals", "signal"}:
        return "redLight"
    if camera_type in {"speed", "speed_camera", "alpr", "plate"}:
        return "speed"

    enforcement = (tags.get("enforcement") or "").lower()
    if enforcement == "traffic_signals":
        return "redLight"
    if enforcement in {"maxspeed", "speed", "speeding"}:
        return "speed"

    if tags.get("highway") == "speed_camera":
        return "speed"
    if (tags.get("device") or "").lower() == "speed_camera":
        return "speed"
    if tags.get("type") == "enforcement":
        if enforcement == "traffic_signals":
            return "redLight"
        if enforcement in {"maxspeed", "speed", "speeding"}:
            return "speed"
    return None


def fetch_overpass_elements(south: float, west: float, north: float, east: float) -> list[dict]:
    query = f"""
[out:json][timeout:180];
(
  nwr({south},{west},{north},{east})["highway"="speed_camera"];
  nwr({south},{west},{north},{east})["device"="speed_camera"];
  nwr({south},{west},{north},{east})["enforcement"="maxspeed"];
  nwr({south},{west},{north},{east})["enforcement"="speed"];
  nwr({south},{west},{north},{east})["enforcement"="traffic_signals"];
  nwr({south},{west},{north},{east})["camera:type"="speed"];
  nwr({south},{west},{north},{east})["camera:type"="speed_camera"];
  nwr({south},{west},{north},{east})["camera:type"="red_light"];
  nwr({south},{west},{north},{east})["camera:type"="traffic_signals"];
  relation({south},{west},{north},{east})["type"="enforcement"]["enforcement"="maxspeed"];
  relation({south},{west},{north},{east})["type"="enforcement"]["enforcement"="traffic_signals"];
  relation({south},{west},{north},{east})["type"="enforcement"]["enforcement"="speed"];
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


def cameras_from_elements(elements: list[dict]) -> tuple[dict[str, dict], int]:
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
    return cameras, skipped


def write_pack(
    *,
    path: Path,
    pack_id: str,
    name: str,
    version: int,
    source: str,
    bbox: dict,
    cameras: dict[str, dict],
) -> None:
    kinds = Counter(c["kind"] for c in cameras.values())
    pack = {
        "id": pack_id,
        "name": name,
        "version": version,
        "source": source,
        "bbox": bbox,
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "cameras": sorted(cameras.values(), key=lambda c: c["id"]),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(pack, separators=(",", ":")), encoding="utf-8")
    print(f"Wrote {len(pack['cameras'])} cameras {dict(kinds)} ({path.stat().st_size} bytes) → {path}")


def build_athens_pack() -> None:
    elements = fetch_overpass_elements(SOUTH, WEST, NORTH, EAST)
    cameras, skipped = cameras_from_elements(elements)
    write_pack(
        path=ATHENS_OUT,
        pack_id="athens_traffic_cameras",
        name="Greater Athens traffic cameras",
        version=2,
        source="OpenStreetMap via Overpass (expanded tags + enforcement relations)",
        bbox={"south": SOUTH, "west": WEST, "north": NORTH, "east": EAST},
        cameras=cameras,
    )
    print(f"Skipped {skipped} Athens elements without usable kind/coordinates")


def build_greece_pack() -> None:
    print(f"Downloading {SPEEDCAMS_CSV} ...", flush=True)
    req = urllib.request.Request(
        SPEEDCAMS_CSV,
        headers={"User-Agent": "MotoTripTracker/1.0 (pack-builder)", "Accept": "text/csv"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        text = resp.read().decode("utf-8")
    lines = [ln for ln in text.splitlines() if ln and not ln.startswith("#")]
    reader = csv.DictReader(io.StringIO("\n".join(lines)))
    cameras: dict[str, dict] = {}
    for row in reader:
        try:
            lat = float(row["latitude"])
            lon = float(row["longitude"])
            osm_numeric_id = row["id"].strip()
        except (KeyError, TypeError, ValueError):
            continue
        if not osm_numeric_id:
            continue
        # speedcams.world exports OSM speed-camera nodes as "fixed".
        cameras[f"osm:node/{osm_numeric_id}"] = {
            "id": f"osm:node/{osm_numeric_id}",
            "lat": lat,
            "lon": lon,
            "kind": "speed",
        }
    write_pack(
        path=GREECE_OUT,
        pack_id="greece_traffic_cameras",
        name="Greece traffic cameras",
        version=1,
        source="OpenStreetMap via speedcams.world CSV (ODbL)",
        bbox=GREECE_BBOX,
        cameras=cameras,
    )


def main() -> None:
    build_athens_pack()
    build_greece_pack()


if __name__ == "__main__":
    main()
