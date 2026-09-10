# Country Traffic-Camera Pack Downloads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-download country traffic-camera packs from speedcams.world when the rider’s country is known, cache them on disk, and merge them into `TrafficCameraService` with a small HUD status chip.

**Architecture:** `TrafficCameraCountryResolver` reverse-geocodes ISO country with distance/time cache. `TrafficCameraPackDownloader` fetches `{cc}-all.csv`, parses to pack JSON, persists under Application Support with TTL/LRU/unsupported cooldown. `TrafficCameraService` calls `ensureCountryPack` during ride refresh, merges downloaded packs into `allKnownCameras()`, and exposes `downloadStatus` for a non-blocking chip in `RideTrackerView`.

**Tech Stack:** Swift / SwiftUI, CoreLocation (`CLGeocoder`), URLSession, existing `TrafficCamera` / `TrafficCameraRegionPack` types, XCTest / Swift Testing.

## Global Constraints

- Scope: country traffic-camera packs only (not offline map tiles)
- Trigger: automatic on ride start / country change
- Until pack ready: keep Overpass + bundled packs
- Source: `https://speedcams.world/downloads/{cc}/{cc}-all.csv` (lowercase ISO), OSM/ODbL
- UX: non-blocking status chip; no Settings picker in v1
- Pack TTL: ~30 days; unsupported 404 cooldown: ~24h; LRU: ~10 countries
- Do not block location fan-out on download completion
- User-Agent: identify as MotoTripTracker

---

## File map

| File | Responsibility |
| --- | --- |
| `MotoTripTracker/Services/TrafficCameraCountryResolver.swift` | Location → ISO country + cache |
| `MotoTripTracker/Services/TrafficCameraPackDownloader.swift` | CSV fetch/parse, disk pack store, TTL/LRU/cooldown |
| `MotoTripTracker/Services/TrafficCameraService.swift` | Orchestrate ensure-pack, merge downloaded packs, `downloadStatus` |
| `MotoTripTracker/Domain/TrafficCamera.swift` | Optional: `TrafficCameraPackDownloadStatus` enum if kept with domain |
| `MotoTripTracker/UI/Tracker/RideTrackerView.swift` | Status chip |
| `MotoTripTrackerTests/MotoTripTrackerTests.swift` | Unit tests for CSV parse, TTL, cooldown, merge helpers |
| `README.md` | One-line note on auto country packs |

---

### Task 1: CSV parse + pack write helpers (pure)

**Files:**
- Create: `MotoTripTracker/Services/TrafficCameraPackDownloader.swift` (parse/encode helpers first; network later in same file)
- Test: `MotoTripTrackerTests/MotoTripTrackerTests.swift`

**Interfaces:**
- Produces:
  - `TrafficCameraPackDownloader.parseCSV(_ text: String, countryCode: String) -> TrafficCameraRegionPack`
  - Cameras use `id: "osm:node/{id}"`, `kind: .speed`
  - Pack `id`: `"country_{CC}"`, `name`: `"Country {CC} traffic cameras"`

- [ ] **Step 1: Write failing tests**

```swift
@Test func trafficCameraParsesSpeedcamsCSV() throws {
    let csv = """
    # comment
    id,latitude,longitude,type,maxspeed,unit,country_code,region
    123,37.97,23.72,fixed,50,kmh,GR,
    456,38.0,23.8,fixed,,,GR,
    """
    let pack = try TrafficCameraPackDownloader.parseCSV(csv, countryCode: "GR")
    #expect(pack.cameras.count == 2)
    #expect(pack.cameras[0].id == "osm:node/123")
    #expect(pack.cameras[0].kind == .speed)
    #expect(pack.cameras[0].latitude == 37.97)
    #expect(pack.id == "country_GR")
}

@Test func trafficCameraCSVSkipsBadRows() throws {
    let csv = """
    id,latitude,longitude,type,maxspeed,unit,country_code,region
    bad,x,y,fixed,,,GR,
    789,40.5,22.9,fixed,,,GR,
    """
    let pack = try TrafficCameraPackDownloader.parseCSV(csv, countryCode: "GR")
    #expect(pack.cameras.count == 1)
    #expect(pack.cameras[0].id == "osm:node/789")
}
```

- [ ] **Step 2: Run tests — expect fail** (type missing)

Run: `xcodebuild -scheme MotoTripTracker -destination 'generic/platform=iOS' build-for-testing` then test filtered, or build and compile-check. Expected: compile error / missing `TrafficCameraPackDownloader`.

- [ ] **Step 3: Implement parseCSV**

In `TrafficCameraPackDownloader.swift`:

```swift
import CoreLocation
import Foundation

enum TrafficCameraPackDownloaderError: Error {
    case emptyCSV
    case missingHeader
}

enum TrafficCameraPackDownloader {
    static func parseCSV(_ text: String, countryCode: String) throws -> TrafficCameraRegionPack {
        let cc = countryCode.uppercased()
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard let headerLine = lines.first else { throw TrafficCameraPackDownloaderError.emptyCSV }
        let headers = parseCSVLine(headerLine).map { $0.lowercased() }
        guard let idIdx = headers.firstIndex(of: "id"),
              let latIdx = headers.firstIndex(of: "latitude"),
              let lonIdx = headers.firstIndex(of: "longitude")
        else { throw TrafficCameraPackDownloaderError.missingHeader }

        var cameras: [TrafficCamera] = []
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for line in lines.dropFirst() {
            let cols = parseCSVLine(line)
            guard cols.count > max(idIdx, latIdx, lonIdx),
                  let lat = Double(cols[latIdx]), let lon = Double(cols[lonIdx]),
                  lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180
            else { continue }
            let rawID = cols[idIdx].trimmingCharacters(in: .whitespaces)
            guard !rawID.isEmpty else { continue }
            cameras.append(TrafficCamera(id: "osm:node/\(rawID)", latitude: lat, longitude: lon, kind: .speed))
            minLat = min(minLat, lat); maxLat = max(maxLat, lat)
            minLon = min(minLon, lon); maxLon = max(maxLon, lon)
        }
        if cameras.isEmpty {
            minLat = 0; maxLat = 0; minLon = 0; maxLon = 0
        }
        return TrafficCameraRegionPack(
            id: "country_\(cc)",
            name: "Country \(cc) traffic cameras",
            version: 1,
            south: minLat, west: minLon, north: maxLat, east: maxLon,
            cameras: cameras
        )
    }

    /// Minimal CSV split (no quoted commas expected in speedcams.world export).
    static func parseCSVLine(_ line: String) -> [String] {
        line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }
}
```

Note: `TrafficCameraRegionPack` memberwise init must be accessible — if only via `decode`, add an internal/public memberwise initializer on the struct.

- [ ] **Step 4: Run tests — expect pass**

- [ ] **Step 5: Commit**

```bash
git add MotoTripTracker/Services/TrafficCameraPackDownloader.swift MotoTripTracker/Services/TrafficCameraRegionPack.swift MotoTripTrackerTests/MotoTripTrackerTests.swift
git commit -m "feat: parse speedcams.world CSV into country camera packs"
```

---

### Task 2: Disk store — TTL, unsupported cooldown, LRU

**Files:**
- Modify: `MotoTripTracker/Services/TrafficCameraPackDownloader.swift`
- Test: `MotoTripTrackerTests/MotoTripTrackerTests.swift`

**Interfaces:**
- Produces:
  - `TrafficCameraPackStore` (or methods on downloader) with:
    - `loadPack(countryCode:) -> (pack: TrafficCameraRegionPack, downloadedAt: Date)?`
    - `savePack(_:countryCode:downloadedAt:)`
    - `isFresh(downloadedAt:now:ttl:) -> Bool` (ttl default 30 days)
    - `markUnsupported(countryCode:at:)` / `isUnsupported(countryCode:now:cooldown:) -> Bool` (24h)
    - `touch(countryCode:)` + `evictIfNeeded(maxCountries: 10)`
  - Directory: Application Support `/CameraPacks/`
  - Files: `camera_pack_{CC}.json`, `camera_pack_meta.json` (dictionary of country → meta)

Meta JSON shape:

```json
{
  "IT": { "downloadedAt": "2026-09-10T12:00:00Z", "lastUsedAt": "2026-09-10T12:00:00Z", "unsupportedUntil": null },
  "XX": { "downloadedAt": null, "lastUsedAt": null, "unsupportedUntil": "2026-09-11T12:00:00Z" }
}
```

- [ ] **Step 1: Write failing tests** using a temp directory injected into the store

```swift
@Test func trafficCameraPackStoreTTLAndUnsupported() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = TrafficCameraPackStore(directory: dir)
    let pack = try TrafficCameraPackDownloader.parseCSV(
        "id,latitude,longitude,type,maxspeed,unit,country_code,region\n1,1,1,fixed,,,IT,\n",
        countryCode: "IT"
    )
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    store.save(pack: pack, countryCode: "IT", downloadedAt: t0)
    #expect(store.isFresh(countryCode: "IT", now: t0.addingTimeInterval(10), ttl: 30 * 24 * 3600))
    #expect(!store.isFresh(countryCode: "IT", now: t0.addingTimeInterval(31 * 24 * 3600), ttl: 30 * 24 * 3600))
    store.markUnsupported(countryCode: "XX", at: t0, cooldown: 24 * 3600)
    #expect(store.isUnsupported(countryCode: "XX", now: t0.addingTimeInterval(3600)))
    #expect(!store.isUnsupported(countryCode: "XX", now: t0.addingTimeInterval(25 * 3600)))
}
```

- [ ] **Step 2: Implement `TrafficCameraPackStore`** with injectable `directory: URL`

- [ ] **Step 3: Tests pass + commit**

```bash
git commit -m "feat: persist country camera packs with TTL and LRU metadata"
```

---

### Task 3: Network download

**Files:**
- Modify: `MotoTripTracker/Services/TrafficCameraPackDownloader.swift`

**Interfaces:**
- Produces:
  - `actor TrafficCameraPackDownloader` or `@MainActor` class method:
    `func download(countryCode: String, session: URLSession) async throws -> TrafficCameraRegionPack`
  - URL: `https://speedcams.world/downloads/{cc}/{cc}-all.csv` (`cc` lowercase)
  - On HTTP 404: throw `unsupportedCountry`
  - User-Agent: `MotoTripTracker/1.0 (iOS; motorcycle trip tracker)`

- [ ] **Step 1: Implement download + map 404 → unsupported**

```swift
static func csvURL(countryCode: String) -> URL {
    let cc = countryCode.lowercased()
    return URL(string: "https://speedcams.world/downloads/\(cc)/\(cc)-all.csv")!
}
```

- [ ] **Step 2: Unit-test URL builder + 404 error mapping with a mock `URLProtocol` if already used in project; otherwise test URL builder + treat integration as manual**

- [ ] **Step 3: Commit**

```bash
git commit -m "feat: download country camera CSV from speedcams.world"
```

---

### Task 4: Country resolver

**Files:**
- Create: `MotoTripTracker/Services/TrafficCameraCountryResolver.swift`
- Test: `MotoTripTrackerTests/MotoTripTrackerTests.swift` (cache logic with injected last result)

**Interfaces:**
- Produces:
  - `@MainActor final class TrafficCameraCountryResolver`
  - `func resolve(location: CLLocation) async -> String?` // ISO alpha-2 uppercased
  - Cache: skip geocode if same country candidate within 5 km and 10 minutes
  - Uses `CLGeocoder.reverseGeocodeLocation`

For testability, extract pure helper:

```swift
static func shouldRefresh(
    lastLocation: CLLocation?,
    lastResolvedAt: Date?,
    newLocation: CLLocation,
    now: Date,
    minDistanceMeters: CLLocationDistance = 5_000,
    minInterval: TimeInterval = 600
) -> Bool
```

- [ ] **Step 1: Test `shouldRefresh`**

```swift
@Test func trafficCameraCountryResolverRefreshGate() {
    let a = CLLocation(latitude: 37.97, longitude: 23.72)
    let near = CLLocation(latitude: 37.971, longitude: 23.721)
    let far = CLLocation(latitude: 38.2, longitude: 23.9)
    let t0 = Date(timeIntervalSince1970: 0)
    #expect(!TrafficCameraCountryResolver.shouldRefresh(lastLocation: a, lastResolvedAt: t0, newLocation: near, now: t0.addingTimeInterval(60)))
    #expect(TrafficCameraCountryResolver.shouldRefresh(lastLocation: a, lastResolvedAt: t0, newLocation: far, now: t0.addingTimeInterval(60)))
    #expect(TrafficCameraCountryResolver.shouldRefresh(lastLocation: a, lastResolvedAt: t0, newLocation: near, now: t0.addingTimeInterval(601)))
}
```

- [ ] **Step 2: Implement resolver + commit**

```bash
git commit -m "feat: resolve ride country for camera pack downloads"
```

---

### Task 5: Wire into `TrafficCameraService`

**Files:**
- Modify: `MotoTripTracker/Services/TrafficCameraService.swift`
- Modify: `MotoTripTracker/Domain/TrafficCamera.swift` (add status enum) OR keep enum in service file

**Interfaces:**
- Produces:
  - `enum TrafficCameraPackDownloadStatus: Equatable { case idle; case downloading(countryCode: String, countryName: String?); case failed(message: String) }`
  - `private(set) var downloadStatus`
  - `private var downloadedPacksByCountry: [String: TrafficCameraRegionPack]`
  - `allKnownCameras()` includes `downloadedPacksByCountry.values`
  - `ensureCountryPack(for location: CLLocation)` from `refresh(for:)`
  - Load all on-disk packs at init (or lazy load active country + keep others in store for merge of active set)

Flow in `ensureCountryPack`:

1. Resolve country (async Task; do not block `publishNearby`)
2. If unsupported → return
3. If fresh on disk → load into `downloadedPacksByCountry`, `touch`, `publishNearby`
4. Else if not already downloading → set status downloading, download, save, load, status idle; on 404 mark unsupported; on other error set failed then clear after ~4s

- [ ] **Step 1: Implement merge + ensureCountryPack**

- [ ] **Step 2: Manual / unit smoke: after injecting a pack into `downloadedPacksByCountry`, `publishNearby` returns those cameras**

- [ ] **Step 3: Commit**

```bash
git commit -m "feat: auto-ensure country camera packs while riding"
```

---

### Task 6: HUD status chip + README

**Files:**
- Modify: `MotoTripTracker/UI/Tracker/RideTrackerView.swift` (top HUD stack near camera banner)
- Modify: `README.md`

**Interfaces:**
- Consumes: `app.trafficCameraService.downloadStatus`

- [ ] **Step 1: Add chip**

```swift
if case let .downloading(code, name) = app.trafficCameraService.downloadStatus {
    Text("Downloading cameras for \(name ?? code)…")
    // caption style, material capsule — match existing banners
}
if case let .failed(message) = app.trafficCameraService.downloadStatus {
    Text(message)
}
```

- [ ] **Step 2: README one liner under traffic cameras**

- [ ] **Step 3: Commit**

```bash
git commit -m "feat: show country camera pack download status on ride HUD"
```

---

### Task 7: Docs + verification

**Files:**
- Optionally update `docs/superpowers/specs/2026-09-10-country-camera-pack-downloads-design.md` status if needed (no change required)
- Commit any leftover coverage-expansion files only if already part of working tree and needed for packs (`greece_traffic_cameras.json`) — prefer separate commit: `feat: expand traffic camera OSM coverage and Greece pack`

- [ ] **Step 1: Build** `xcodebuild -scheme MotoTripTracker -destination 'generic/platform=iOS' build`

- [ ] **Step 2: Run camera-related unit tests**

- [ ] **Step 3: Manual checklist**
  1. Ride in GR with network — no forced re-download if bundled/fresh; icons still work
  2. Simulate/IT pack: status chip appears once, cameras from pack show within 3 km
  3. Airplane mode — no crash; Overpass/bundled still used
  4. Kill network mid-download — failed chip then idle; Overpass continues

---

## Spec coverage check

| Spec item | Task |
| --- | --- |
| Auto download on ride/country | 4, 5 |
| Overpass until ready | 5 (existing Overpass unchanged) |
| speedcams.world CSV | 1, 3 |
| Status chip | 6 |
| 30-day TTL / 10 LRU / 24h unsupported | 2 |
| Soft-fail | 5 |
| Greece bundled intact | 5 |
| Tests | 1, 2, 4 |

## Placeholder scan

None intentional — URL, paths, types, and test code are concrete.
