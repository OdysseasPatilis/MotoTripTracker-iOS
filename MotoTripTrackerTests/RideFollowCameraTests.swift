import CoreLocation
import Foundation
import Testing
@testable import MotoTripTracker

struct RideFollowCameraTests {

    @Test func rideFollowCameraCruiseDistanceMatchesBaseline() {
        #expect(RideFollowCameraPolicy.cruiseDistanceMeters(speedKmh: 0) == 350)
        #expect(RideFollowCameraPolicy.cruiseDistanceMeters(speedKmh: 100) == 350 + 700)
        #expect(RideFollowCameraPolicy.cruiseDistanceMeters(speedKmh: 200) == 350 + 180 * 7)
    }

    @Test func rideFollowCameraLookAheadGrowsWithSpeedAndNav() {
        let slow = RideFollowCameraPolicy.lookAheadMeters(speedKmh: 20, isNavigating: false)
        let fast = RideFollowCameraPolicy.lookAheadMeters(speedKmh: 100, isNavigating: false)
        let fastNav = RideFollowCameraPolicy.lookAheadMeters(speedKmh: 100, isNavigating: true)
        #expect(fast > slow)
        #expect(fastNav > fast)
        let aboveDial = RideFollowCameraPolicy.lookAheadMeters(
            speedKmh: 100,
            isNavigating: true,
            keepsRiderAboveBottomChrome: true
        )
        #expect(aboveDial < fastNav)
        #expect(aboveDial > 0)
    }

    @Test func rideFollowCameraCenterUsesCourseWhenValid() {
        let rider = CLLocationCoordinate2D(latitude: 37.98, longitude: 23.72)
        let ahead = RideFollowCameraPolicy.centerCoordinate(
            rider: rider,
            courseDegrees: 0,
            speedKmh: 80,
            isNavigating: true
        )
        #expect(ahead.latitude > rider.latitude)
        #expect(abs(ahead.longitude - rider.longitude) < 0.001)

        let noCourse = RideFollowCameraPolicy.centerCoordinate(
            rider: rider,
            courseDegrees: -1,
            speedKmh: 80,
            isNavigating: true
        )
        #expect(noCourse.latitude == rider.latitude)
        #expect(noCourse.longitude == rider.longitude)
    }

    @Test func idleRecenterStaysNearTheRiderAboveTheDial() {
        let rider = CLLocationCoordinate2D(latitude: 37.98, longitude: 23.72)
        let center = RideFollowCameraPolicy.idleCenterAboveBottomDial(
            rider: rider,
            cameraDistanceMeters: 1400
        )
        let shift = CLLocation(latitude: rider.latitude, longitude: rider.longitude)
            .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
        #expect(center.latitude < rider.latitude)
        #expect(shift > 50)
        #expect(shift < 250)
    }

    @Test func rideFollowCameraZoomsNearTurnWhenNavigating() {
        let cruise = RideFollowCameraPolicy.cameraDistanceMeters(
            speedKmh: 80,
            distanceToNextManeuver: 2000,
            isNavigating: true,
            isRecalculating: false
        )
        let near = RideFollowCameraPolicy.cameraDistanceMeters(
            speedKmh: 80,
            distanceToNextManeuver: 80,
            isNavigating: true,
            isRecalculating: false
        )
        #expect(near < cruise)

        let recalculating = RideFollowCameraPolicy.cameraDistanceMeters(
            speedKmh: 80,
            distanceToNextManeuver: 80,
            isNavigating: true,
            isRecalculating: true
        )
        #expect(recalculating == cruise)
    }

    @Test func rideFollowCameraApproachWindowScalesWithSpeed() {
        let city = RideFollowCameraPolicy.approachWindowMeters(speedKmh: 40)
        let mid = RideFollowCameraPolicy.approachWindowMeters(speedKmh: 80)
        let hwy = RideFollowCameraPolicy.approachWindowMeters(speedKmh: 120)
        #expect(city >= 120 && city <= 150)
        #expect(abs(mid - 250) < 15)
        #expect(hwy >= 350 && hwy <= 400)
    }
}
