import Foundation
import os

struct UploadTripPayload: Encodable, Sendable {
    struct RoutePointPayload: Encodable, Sendable {
        let id: String
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let speedMps: Double
        let timestampMs: Int64
        let waypointType: String?
        let isWaypoint: Bool
        let waypointTitle: String
        let waypointSubtitle: String
    }

    let clientTripId: String
    let userId: String
    let startTimeMs: Int64
    let endTimeMs: Int64
    let distanceMeters: Double
    let movingTime: Int64
    let stoppedTime: Int64
    let maxSpeed: Double
    let maxGForce: Double
    let maxLateralGForce: Double
    let elevationGain: Double
    let avgSpeed: Double
    let cornerCount: Int
    let twistinessScore: Double
    let encodedRoutePolyline: String?
    let title: String?
    let visibility: String
    let routePoints: [RoutePointPayload]
}

enum TripCloudUploader {
    private static let kmhToMps = 3.6

    static func makePayload(trip: Trip, points: [RoutePoint]) -> UploadTripPayload {
        UploadTripPayload(
            clientTripId: trip.id.uuidString,
            userId: BackendUserIdStore.getOrCreate(),
            startTimeMs: Int64(trip.startTime * 1000),
            endTimeMs: Int64(trip.endTime * 1000),
            distanceMeters: trip.distanceMeters,
            movingTime: trip.movingTime,
            stoppedTime: trip.stoppedTime,
            maxSpeed: trip.maxSpeed / kmhToMps,
            maxGForce: trip.maxGForce,
            maxLateralGForce: trip.maxLateralGForce,
            elevationGain: trip.elevationGain,
            avgSpeed: trip.avgSpeed / kmhToMps,
            cornerCount: trip.cornerCount,
            twistinessScore: trip.twistinessScore,
            encodedRoutePolyline: trip.encodedRoutePolyline,
            title: trip.title,
            visibility: "PRIVATE",
            routePoints: points.map { point in
                UploadTripPayload.RoutePointPayload(
                    id: point.id.uuidString,
                    latitude: point.latitude,
                    longitude: point.longitude,
                    altitude: point.altitude,
                    speedMps: point.speedMps,
                    timestampMs: Int64(point.timestamp * 1000),
                    waypointType: point.waypointType,
                    isWaypoint: point.isWaypoint,
                    waypointTitle: point.waypointTitle,
                    waypointSubtitle: point.waypointSubtitle
                )
            }
        )
    }

    static func enqueueUpload(payload: UploadTripPayload) {
        guard BackendSettings.isEnabled else {
            AppLogger.app.debug("Cloud upload skipped — backendBaseURL not set")
            return
        }

        Task.detached(priority: .utility) {
            await runUpload(payload)
        }
    }

    static func uploadNow(payload: UploadTripPayload) async throws {
        guard BackendSettings.isEnabled else {
            throw UploadError.backendDisabled
        }
        try await upload(payload)
        AppLogger.app.notice("Cloud upload ok trip id=\(payload.clientTripId.prefix(8), privacy: .public)")
    }

    private static func runUpload(_ payload: UploadTripPayload) async {
        do {
            try await upload(payload)
            AppLogger.app.notice("Cloud upload ok trip id=\(payload.clientTripId.prefix(8), privacy: .public)")
        } catch {
            AppLogger.app.error("Cloud upload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    enum UploadError: LocalizedError {
        case backendDisabled
        case tripNotFound

        var errorDescription: String? {
            switch self {
            case .backendDisabled:
                "Backend URL not configured"
            case .tripNotFound:
                "Trip not found"
            }
        }
    }

    private static func upload(_ payload: UploadTripPayload) async throws {
        guard let url = URL(string: "\(BackendSettings.baseURL)/v1/trips/upload") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 60

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
