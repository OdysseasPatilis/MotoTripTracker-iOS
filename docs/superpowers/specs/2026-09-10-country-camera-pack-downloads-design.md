# Country Traffic-Camera Pack Downloads

**Date:** 2026-09-10  
**Status:** Approved for implementation planning  
**App:** MotoTripTracker iOS  

## Goal

While a ride is recording, automatically download a **country-level traffic-camera pack** for the country the rider is in, cache it on device, and merge it with existing bundled packs + live Overpass so camera icons and alerts work better offline and away from Greece.

## Decisions (approved)

| Topic | Choice |
| --- | --- |
| Scope | Country **traffic-camera packs** only (not offline map tiles) |
| Trigger | Automatic on ride start / country change (silent background) |
| Until pack ready | Keep Overpass + bundled packs as fill-in |
| Download source | [speedcams.world](https://speedcams.world/download) country CSV (`/{cc}/{cc}-all.csv`), OSM data under ODbL |
| UX | Small non-blocking status chip; no Settings picker in v1 |
| Refresh | Re-download when pack older than ~30 days |
| Storage | Per-country files on disk; LRU cap ~10 countries |

## Out of scope (v1)

- Offline basemap / MapKit tile downloads
- Manual country picker or Settings management UI
- Worldwide single mega-pack download
- Dedicated red-light country packs (CSV is speed-camera oriented; live Overpass still covers red-light tags where mapped)
- Hosting our own CDN / pack pipeline

## Current baseline

- Bundled `greece_traffic_cameras.json` + `athens_traffic_cameras.json`
- `TrafficCameraService` merges pack + disk Overpass cache + live Overpass; alerts while ride active
- Live Overpass uses expanded OSM tags (`highway` / `device` / `enforcement` / `camera:type` + enforcement relations)
- Pack decode path: `TrafficCameraRegionPackStore.decode`

## Design

### Behavior

1. On ride start and on location refresh while riding, resolve the rider’s **ISO 3166-1 alpha-2** country code.
2. If that country’s pack is missing or older than **30 days**, start a background download.
3. While downloading (or if download fails), continue using bundled packs + live Overpass.
4. When download succeeds, load the pack into the service’s known-camera set and persist to disk.
5. Show a short non-blocking status: “Downloading cameras for {Country}…”. Clear on success; on failure briefly show “Camera pack unavailable — using live data”, then clear.
6. Keep downloaded packs across rides. Evict least-recently-used countries when more than **~10** packs are stored.

### Country resolution

- Use `CLGeocoder` reverse geocode (or equivalent placemark) → `isoCountryCode`.
- Cache last resolved country + location; only re-resolve after moving ~**5 km** or after ~**10 minutes**.
- If geocode fails / ocean / unknown → no pack download; Overpass only.
- Border cross mid-ride → begin download for the new country; keep previous pack loaded until the new one is ready.

### Download + parse

- URL pattern: `https://speedcams.world/downloads/{cc}/{cc}-all.csv` where `{cc}` is lowercase ISO code (`it`, `de`, `gr`, …).
- Parse CSV rows (`id`, `latitude`, `longitude`, `type`, …) into `TrafficCamera` points:
  - `id`: `osm:node/{id}` (stable with existing OSM ids)
  - `kind`: `.speed` for this source (export is speed-camera oriented; `type` values like `fixed`)
- Convert to the same pack JSON shape used by bundled packs (`id`, `name`, `version`, `bbox` optional/derived, `cameras[]`).
- Write under Application Support, e.g. `CameraPacks/camera_pack_IT.json` + sidecar meta (`downloadedAt`, `countryCode`, `source`).
- **404 / unsupported country**: mark unsupported with ~**24h** cooldown; do not retry every GPS tick.
- Network / parse errors: soft-fail; Overpass continues; retry with backoff on later refresh.

### `TrafficCameraService` integration

- Extend known-camera merge order:
  1. Bundled region packs  
  2. **Downloaded country packs** (active + recently used)  
  3. Disk Overpass cache  
  4. Live Overpass results  
- Add `ensureCountryPack(for: CLLocation)` called from `refresh(for:)` while riding.
- Expose `downloadStatus` for UI:
  - `idle`
  - `downloading(countryCode: String, countryName: String?)`
  - `failed(message: String)` (short-lived)
- Greece: bundled pack remains; allow network refresh when stale (same TTL path).

### UI

- Small chip on the ride map HUD (near traffic-camera banner area).
- Non-blocking; no modal; no Settings screen in v1.

### Attribution / legal

- Data © OpenStreetMap contributors; ODbL 1.0.
- speedcams.world used as a country CSV mirror of OSM speed-camera data.
- Keep README note that coverage follows OSM and many real cameras (especially red-light) remain unmapped.

## Components

| Unit | Responsibility |
| --- | --- |
| `TrafficCameraCountryResolver` | Location → ISO country with distance/time cache |
| `TrafficCameraPackDownloader` | Fetch CSV, parse, write pack + meta, TTL / unsupported cooldown / LRU |
| `TrafficCameraService` | Orchestrate ensure-pack + merge into `allKnownCameras()` + `downloadStatus` |
| `RideTrackerView` (or map overlay) | Status chip bound to `downloadStatus` |

## Error handling

| Case | Action |
| --- | --- |
| Geocode fail | Skip download; Overpass only |
| HTTP 404 | Unsupported cooldown 24h |
| Other HTTP / timeout | Soft-fail; retry later with backoff |
| Parse error | Soft-fail; log; do not corrupt existing pack |
| Offline | Use on-disk packs; download when online |

## Testing

- CSV → `TrafficCamera` / pack decode for sample rows
- TTL: fresh pack skipped; stale pack re-fetched
- 404 → unsupported cooldown
- Merge: downloaded pack cameras appear in `nearbyCameras` within radius
- Country cache: no re-geocode within 5 km / 10 min
- LRU: 11th country evicts oldest

## Success criteria

1. Starting a ride in Italy (with network) downloads `it-all.csv` once and shows icons for pack cameras without waiting solely on Overpass.
2. Second ride in Italy within 30 days does not re-download.
3. Download failure does not break Overpass alerts.
4. Bundled Greece behavior remains intact.

## Implementation notes

- Prefer small, testable types (resolver / downloader) over growing `TrafficCameraService` further without seams.
- Do not block the main location fan-out on download completion.
- User-Agent: identify as MotoTripTracker (same spirit as Overpass requests).
