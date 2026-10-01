# In-app navigation

How MotoTripTracker builds a driving route, follows it while you ride, speaks the turns, and decides you have left the road.

This is Apple MapKit navigation inside the ride screen. It is not Google Maps, and it does not have Google's road network. MapKit returns one planned polyline. The app then keeps you on that line. When you have clearly left it, MapKit is asked for a new route from where you are.

Last updated: 2026-09-30.

## What you see

Navigation lives on the live ride map, not on its own screen. The map fills the screen. On the main screen the large speedometer floats on the lower map, above destination search. While guidance is active that dial steps aside for the glance dial and the bottom bar.

1. Search for a destination (or pick a petrol station and tap Go).
2. The app shows one or more driving routes. You can pick one. Cancel clears the destination.
3. Start guidance. A full-width banner at the top shows the maneuver arrow, a large distance, and the street name (or a short maneuver such as Left) underneath. Recalculating, off route, and calculating use that same banner.
4. A back chevron returns to the route preview and keeps the destination. End Navigation, voice mute, route weather, and Apple Maps are in the options menu. Fuel range is a small pill on that same row.
5. A tick-mark speed dial (no needle) and the speed-limit sign sit on the lower map. The digits are the speed. Before Start the dial uses live GPS; once a ride is recording it uses the smoothed trip speed. "Cars +N min" appears above the dial when car traffic is meaningfully slower.
6. The bottom bar shows ride distance, average speed, and **Left** (remaining motorcycle time, such as `18 min` or `1h 30m`, not a clock ETA), plus Start, Pause, and Stop.
7. The map draws the route in a teal glow and aims the camera ahead, tightening as you approach a turn. Look-ahead is shortened while the dial covers the lower map so the arrow stays above it. The compass is hidden for the whole guidance session.
8. Voice speaks the instruction once when you get close, and again when the maneuver becomes current.
9. Arrival ends guidance, plays a success haptic, and says "You have arrived".

The ride recorder, speed limit, and fuel tracker keep running the whole time. Navigation is another consumer of the same GPS fixes.

## Files

| Piece | File |
| --- | --- |
| Phases, search, route requests, arrival, ETA | `MotoTripTracker/Services/NavigationService.swift` |
| Applying a route, step advance, off-route recalculation | `MotoTripTracker/Services/NavigationService+Guidance.swift` |
| Snap-to-route math | `MotoTripTracker/Services/NavigationRouteMath.swift` |
| "Have we actually left the road?" | `MotoTripTracker/Domain/OffRouteGate.swift` |
| Car ETA adjusted for a motorcycle | `MotoTripTracker/Domain/MotoTravelEstimator.swift` |
| Spoken prompts | `MotoTripTracker/Services/NavigationVoicePrompt.swift` |
| Destination autocomplete | `MotoTripTracker/Services/DestinationSearchCompleter.swift` |
| Recent destinations | `MotoTripTracker/Services/DestinationSearchHistory.swift` |
| Route and step models | `MotoTripTracker/Services/NavigationModels.swift` |
| GPS fan-out into navigation | `MotoTripTracker/AppContainer.swift` |
| Map polyline, glance dial placement, and follow camera | `MotoTripTracker/UI/Tracker/LiveRideMapView.swift` |
| Turn banner, back chevron, and navigation menu | `MotoTripTracker/UI/Tracker/RideMapOverlays.swift` |
| Banner distance and street-name copy | `MotoTripTracker/Services/NavigationCueFormatting.swift` |
| Glance dial, limit badge, and HUD colors | `MotoTripTracker/UI/Tracker/RideDashboardGauges.swift` |
| Bottom Dist / Avg / Left bar | `MotoTripTracker/UI/Tracker/RideControlsBar.swift` |
| Full-screen map while guiding | `MotoTripTracker/UI/Tracker/RideTrackerView.swift` |
| Camera distance while navigating | `MotoTripTracker/Utilities/RideFollowCameraPolicy.swift` |

`NavigationService` is `@Observable` and `@MainActor`. SwiftUI reads its properties and redraws. There is no separate navigation view model.

## Phases

`NavigationPhase` is `idle`, `previewing`, or `navigating`.

**Idle.** No destination. The map follows the rider as a normal ride.

**Previewing.** A destination is set and MapKit is finding routes, or routes are on screen and waiting for Start. Steps are not active yet. Voice is stopped when preview begins. If GPS arrives before a route exists, `updateOrigin` asks for routes again so the first search is not stuck on "Waiting for your location…".

**Navigating.** Start was confirmed. Every accepted GPS fix updates remaining distance, the current maneuver, off-route state, and arrival. Preview alternates are no longer requested. The back chevron calls `returnToPreview`, which stops voice, drops the in-progress timing, and returns to `previewing` with the destination and any already loaded route choices kept. If those choices are gone, it asks MapKit for routes again. End Navigation calls `clear` and drops the destination.

`routeRequestGeneration` increments whenever a new search starts or navigation is cleared. A MapKit response is ignored if a newer request has already been issued, or if the phase changed while the request was in flight (for example you cancelled during the fetch).

## Choosing a destination

`DestinationSearchCompleter` wraps `MKLocalSearchCompleter`. `NavigationService.searchQuery` and `searchResults` forward to it. The completer is warmed up at first interaction so the sheet is not cold.

Picking a completion resolves it to a coordinate, then `beginPreview`:

- Saves the place in `DestinationSearchHistory` (newest first, capped, nearby duplicates move to the top).
- Stores the destination name and coordinate.
- Clears any previous route, steps, and voice.
- Sets the phase to `previewing`.
- Calls `computeRoute(isRecalculation: false, requestAlternates: true)`.

`setDestination` is the same path. Petrol "Go" uses it.

## Asking MapKit for a route

`computeRoute` builds an `MKDirections.Request`:

- Source is the latest GPS origin. Destination is the pinned coordinate.
- Transport type is **automobile**. There is no motorcycle routing profile in MapKit. The motorcycle adjustment is applied afterwards to the travel time only.
- `departureDate` is now, so the car ETA is traffic-aware when Apple has traffic.
- Alternate routes are requested only for the first preview, not for a recalculation.

On success during preview, every `MKRoute` becomes a `NavRouteOption`: polyline vertices, MapKit distance, car time, motorcycle time, and `NavStep`s. The first option is selected. `applyPreviewSelection` draws that polyline and sets remaining distance and ETA, but it does **not** install turn-by-turn steps yet. Steps start only when you confirm.

On success during an active navigation (a recalculation), only the first route is kept. `applyRoute` replaces the polyline, steps, and match state, and clears the off-route latch.

Each MapKit step with non-empty instruction text becomes a `NavStep`: the spoken sentence, the step's own length, and the coordinate at the end of that step. Empty steps are dropped.

If MapKit returns nothing during preview, the chip shows "Couldn't find a driving route."

## Motorcycle ETA

MapKit's `expectedTravelTime` is a car estimate. `MotoTravelEstimator` turns it into a bike estimate:

- Free-flow baseline assumes about 50 km/h, and is never under 45 seconds.
- Traffic delay is car time minus that baseline, floored at zero.
- A filter benefit (default 0.45, clamped between 0.15 and 0.75) throws away part of that delay, because a bike can filter.
- Motorcycle time is baseline plus the delay that remains, and is never under 30 seconds.

The benefit is stored in `UserDefaults` under `moto_nav_filter_benefit`. After a guided ride of at least 45 seconds, `learn` blends the stored benefit with what you actually did (72% old, 28% observed), and only when the car delay was more than 30 seconds. The result is `lastTimingResult`, shown briefly on the HUD.

While guiding, remaining ETA is the motorcycle time scaled by the fraction of route distance still ahead. It is not a fresh MapKit request on every fix.

If the car time is at least 90 seconds slower than the motorcycle time, the chip adds "Cars +N min".

When a route is applied, `onRouteApplied` asks `RouteWeatherService` to load weather along the polyline. Clearing navigation clears that weather. During the ride, weather also refreshes for the part of the route still ahead.

## One GPS fix

`LocationService` calls `AppContainer`, which calls:

```text
navigationService.updateOrigin(
    coordinate,
    horizontalAccuracy,
    course,
    speed,
    timestamp
)
```

`updateOrigin` always stores the coordinate as the next route origin and moves the search completer's region.

Then it drops the fix for guidance purposes when accuracy is negative (Core Location's "invalid") or worse than 100 m. Those fixes are not a position on a road. Fixes between 0 and 100 m are used. A coarse but still usable fix is not thrown away; the off-route test below gets stricter as accuracy gets worse.

If there is no route yet, it stops after updating the origin.

If there is a route, it snaps the fix onto the polyline (`recomputeRemaining`). Remaining distance and ETA update in preview and while navigating.

Only while `phase == .navigating` does it then:

1. Advance the current maneuver if you are within 35 m along the route of its end.
2. Ask `OffRouteGate` whether this is a real departure.
3. Check arrival.

## Snapping onto the route

`NavigationRouteMath.progress` does this. It does not pick the nearest corner of the polyline. It projects the fix onto each segment (the straight piece between two vertices) and keeps the best one.

For each candidate segment it computes:

- **Cross-track distance.** How far the fix is from the segment, perpendicular to it, clamped so the foot of the perpendicular stays on the segment.
- **Along-route distance.** Metres from the start of the route to that foot. Segment lengths use `CLLocation` distance. The fraction along a segment uses a local flat projection (111320 m per degree of latitude, tightened by cosine for longitude).
- **Segment bearing.** Degrees clockwise from north.
- **Score.** Cross-track, plus a heading penalty when course is valid and speed is at least 3 m/s. Every 90° of disagreement with the segment adds 50 m to the score. A road you are facing beats a nearer road you are facing away from. Below 3 m/s, course is ignored because it is noisy when you are stopped. Course `-1` means Core Location has no heading, and the penalty is skipped.

The search is local on purpose. From the last matched vertex it looks about **300 m back** and **4 km forward** along the polyline. A loop or a later part of the route that passes near your start cannot steal the match just because a vertex over there is geographically close.

If that local match is more than 80 m off the line, the matcher tries the whole route once. It accepts the global match only when that match is within 35 m of the line and at least 40 m better than the local one. That is how a GPS gap can rejoin the route several kilometres ahead without a random nearby bend winning.

The stored anchor (`matchedRouteIndex`) moves to the next vertex once you are past 85% of the current segment, so the window walks forward with you.

`nearestRouteDistance` on the service is this cross-track distance, not "distance to the nearest vertex". `distanceRemaining` is total polyline length minus `alongRoute`.

### Distance to the next turn

`advanceStepIfNeeded` does not use straight-line distance to the maneuver pin. A pin around a corner is closer as the crow flies than the road you still have to ride, and a sideways GPS jump can look close to a junction you have not reached.

It projects the step's end coordinate onto the route **ahead of** the current match (`alongRoute`, which gives up if the point is more than 40 m off the line). Distance to the maneuver is that along-route position minus your along-route position.

When that distance is 35 m or less, and a later step exists, the step index advances. Each new step is announced once. A light haptic fires. The approach prompt is separate: the first time the along-route distance is 250 m or less, voice says "In {distance}, {instruction}". `approachedStepID` and `announcedStepID` stop those lines repeating for the same step.

If the step end cannot be placed on the polyline, the app falls back to straight-line distance for that one maneuver.

The on-screen banner does not print the full MapKit sentence. `NavigationCueFormatting` keeps the distance large and puts a short label under it: the street after "onto", "on", or "toward" when the instruction names one, otherwise a one-word maneuver (Left, U-turn, Destination). Off route and recalculating replace that pair with a single line.

`guidanceSummary` is the longer line used by the Live Activity, not the banner:

- "Recalculating…" while a replacement route is in flight.
- "Off route — recalculating" once a departure has been accepted and the new route is not back yet.
- Otherwise `"{distance} · {instruction}"`.

## Leaving the route

`OffRouteGate` does not reroute on a single far fix, and it does not use a timer.

A fix counts as diverging only when cross-track exceeds a limit that depends on heading and accuracy:

- Heading is "known" when course is ≥ 0 and speed is at least 3 m/s.
- If heading is unknown, or within 40° of the matched segment, you are treated as still aimed along the road. The limit is the larger of **40 m** and **accuracy + 15 m**. Sideways jitter with the right heading stays on the route.
- If heading differs by more than 40°, the limit is the larger of **25 m** and **half the accuracy plus 12 m**. A real turn counts sooner than a parallel wobble.
- Negative accuracy is treated as 30 m for this test.

While diverging, distance traveled is added from fix to fix. Recalculation commits after **50 m** of that travel.

Travel is not counted when:

- Speed is known and below 1.5 m/s. A parked bike's GPS wander is not a wrong turn.
- The jump is longer than 120 m, or the implied speed is over 70 m/s (about 250 km/h). One teleported fix cannot fill the 50 m budget.

Coming back inside the limit zeroes the budget. The next departure starts over.

A committed departure sets `isOffRoute`, and if 12 seconds have passed since the last recalculation, calls `computeRoute(isRecalculation: true)`. The 12 second cooldown stops a string of bad fixes from stacking route requests. `isRecalculating` blocks another request until this one finishes. Applying the new route resets the gate and the match anchor.

`isOffRoute` clears again when a later fix is not diverging. The banner does not appear for the samples that are still only accumulating the 50 m.

### What this cannot see

Google snaps the puck to the nearest road in the whole network, then decides whether that road is the planned one. This app only has the planned polyline. A frontage road that stays close to the route and points the same way still looks "on route" until cross-track exceeds the aligned limit. After that, MapKit builds a new automobile route from the live origin. That new route is the recovery, not a second hidden road graph inside the app.

## Arrival

Arrival is stricter than "the pin looks nearby", so riding past the destination on a parallel road does not end the trip.

All of these have to be true:

- Straight-line distance to the destination pin is ≤ 45 m.
- And either remaining route distance is ≤ 120 m, or you are already on the last step.

That condition has to hold for **2.5 seconds**. A single bounce onto the pin does not finish guidance.

`completeArrival` records timing (if the guided ride lasted at least 45 seconds), clears the route, plays a success haptic, and speaks "You have arrived" after clear so the speech is not cut off by `voice.stop()`.

## Voice

`NavigationVoicePrompt` uses `AVSpeechSynthesizer`. It is on by default (`moto_nav_voice_enabled`). MapKit instructions are English, so speech stays on an English voice: enhanced or premium `en-*` if the device has one, otherwise `en-US`, then `en-GB`. A new prompt interrupts the one still playing. Rate is slightly under the system default.

Turning voice off stops speech immediately. Starting a new preview also stops speech so an old instruction does not talk over the next route.

## Map and camera

`LiveRideMapView` draws `routeCoordinates` whenever a route exists and you are not in an empty preview. While navigating, that line is a teal glow instead of the idle route blue. The follow camera uses `RideFollowCameraPolicy`. While navigating, look-ahead is 1.2× the normal ride look-ahead, then 0.62× of that while the glance dial is on screen, so the rider stays above the instrument. As `distanceToNextManeuver` falls inside the approach window the camera pulls in toward the turn (down to about 55% of cruise distance, never closer than 220 m).

The blue user dot is still the device location from MapKit. Guidance numbers use the snapped point on the polyline. Those two are not forced to be the same pixel.

## Numbers in one place

| Rule | Value |
| --- | --- |
| Ignore fix for guidance | accuracy &lt; 0 or &gt; 100 m |
| Match window behind / ahead | 300 m / 4 km along the polyline |
| Heading penalty | 50 m of score per 90° of disagreement, only if speed ≥ 3 m/s |
| Use a far-away match on the same route | local cross-track &gt; 80 m, global ≤ 35 m, and at least 40 m better |
| Advance match anchor | past 85% of the current segment |
| Step end must lie on the line | within 40 m |
| Advance to the next step | ≤ 35 m along the route |
| Speak the approach prompt | ≤ 250 m along the route, once per step |
| Still "on route" when heading matches | cross-track ≤ max(40 m, accuracy + 15 m) |
| Heading counts as matching | within 40° |
| Off route when heading differs | cross-track &gt; max(25 m, 0.5 × accuracy + 12 m) |
| Commit a recalculation | 50 m traveled while diverging |
| Ignore stopped drift | speed known and &lt; 1.5 m/s |
| Ignore a teleported step | &gt; 120 m, or implied speed &gt; 70 m/s |
| Recalculation cooldown | 12 s |
| Arrive | ≤ 45 m from the pin, and (≤ 120 m route left or last step), for 2.5 s |
| Motorcycle free-flow pace | 50 km/h, baseline at least 45 s |
| Default filter benefit | 0.45 of car traffic delay |

## Tests

- `MotoTripTrackerTests/NavigationRouteMathTests.swift` — remaining distance at the start, end, and beside the middle of a segment; a nearer opposite-direction road does not steal the match; step advance thresholds; arrival rules.
- `MotoTripTrackerTests/GpsStreetMatchTests.swift` — one off-route sample does not recalculate; traveling off with a different heading does; same-heading lateral jitter does not; stopped drift does not; returning to the route cancels a pending departure.
- `MotoTripTrackerTests/DestinationAndNavTests.swift` — destination history, the motorcycle ETA estimator, banner copy ("120 m Ermou", short maneuvers, remaining-time labels), and returning from guidance to the route preview without clearing the destination.
- `MotoTripTrackerTests/RideFollowCameraTests.swift` — look-ahead grows with speed and navigation, and shortens again while the glance dial covers the lower map.
