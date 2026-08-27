import CoreLocation
import MapKit
import UIKit
import os

enum RideShareHelper {
    static func shareText(for trip: Trip) -> String {
        String(
            format: "MotoTripTracker ride — %.1f km · %@",
            trip.distanceKm,
            RideFormatters.timestampToDate(trip.startTime)
        )
    }

    static func presentShareSheet(items: [Any], from viewController: UIViewController? = nil) {
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let presenter = viewController ?? topViewController()
        guard let presenter else { return }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 1,
                height: 1
            )
        }
        presenter.present(activity, animated: true)
    }

    static func shareGPX(trip: Trip, points: [RoutePoint]) {
        let gpx = GpxExporter.build(trip: trip, points: points)
        let fileName = "ride_\(trip.id.uuidString.prefix(8)).gpx"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(String(fileName))
        do {
            try gpx.data(using: .utf8)?.write(to: url, options: .atomic)
            presentShareSheet(items: [url, shareText(for: trip)])
        } catch {
            AppLogger.app.error("GPX share failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func shareCardImage(trip: Trip, moments: RideMoments, points: [RoutePoint]) {
        let coordinates = routeCoordinates(trip: trip, points: points)
        Task { @MainActor in
            let image = await RideShareCardRenderer.render(
                trip: trip,
                moments: moments,
                coordinates: coordinates
            )
            presentShareSheet(items: [image, shareText(for: trip)])
        }
    }

    private static func routeCoordinates(trip: Trip, points: [RoutePoint]) -> [CLLocationCoordinate2D] {
        if let encoded = trip.encodedRoutePolyline, !encoded.isEmpty {
            return PolylineEncoder.decode(encoded).map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
            }
        }
        return points.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    private static func topViewController(
        base: UIViewController? = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
    ) -> UIViewController? {
        if let nav = base as? UINavigationController { return topViewController(base: nav.visibleViewController) }
        if let tab = base as? UITabBarController { return topViewController(base: tab.selectedViewController) }
        if let presented = base?.presentedViewController { return topViewController(base: presented) }
        return base
    }
}

enum RideShareCardRenderer {
    private static let width: CGFloat = 1080
    private static let height: CGFloat = 1620
    private static let mint = UIColor(red: 0, green: 229 / 255, blue: 160 / 255, alpha: 1)
    private static let blue = UIColor(red: 0, green: 180 / 255, blue: 1, alpha: 1)

    static func render(
        trip: Trip,
        moments: RideMoments,
        coordinates: [CLLocationCoordinate2D]
    ) async -> UIImage {
        let mapImage = await mapSnapshot(coordinates: coordinates, size: CGSize(width: width - 96, height: 560))

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { ctx in
            let cg = ctx.cgContext
            UIColor(red: 16 / 255, green: 16 / 255, blue: 20 / 255, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: width, height: height))

            drawText(
                "MOTOTRIPTRACKER",
                at: CGPoint(x: 48, y: 56),
                font: .systemFont(ofSize: 24, weight: .semibold),
                color: UIColor.white.withAlphaComponent(0.45)
            )
            drawText(
                trip.displayTitle,
                at: CGPoint(x: 48, y: 100),
                font: .systemFont(ofSize: 40, weight: .bold),
                color: .white,
                maxWidth: width - 96
            )
            drawText(
                RideFormatters.timestampToDate(trip.startTime),
                at: CGPoint(x: 48, y: 156),
                font: .systemFont(ofSize: 28, weight: .medium),
                color: mint
            )

            let mapRect = CGRect(x: 48, y: 220, width: width - 96, height: 560)
            let mapPath = UIBezierPath(roundedRect: mapRect, cornerRadius: 36)
            cg.saveGState()
            mapPath.addClip()
            if let mapImage {
                mapImage.draw(in: mapRect)
            } else {
                UIColor(red: 28 / 255, green: 28 / 255, blue: 34 / 255, alpha: 1).setFill()
                cg.fill(mapRect)
                drawText(
                    "No route map",
                    at: CGPoint(x: mapRect.midX - 90, y: mapRect.midY - 14),
                    font: .systemFont(ofSize: 28, weight: .medium),
                    color: UIColor.white.withAlphaComponent(0.4)
                )
            }
            cg.restoreGState()

            // Subtle border around map
            UIColor.white.withAlphaComponent(0.08).setStroke()
            mapPath.lineWidth = 2
            mapPath.stroke()

            // Distance pill on map
            let pill = String(format: "%.1f km", trip.distanceKm)
            let pillFont = UIFont.systemFont(ofSize: 24, weight: .semibold)
            let pillSize = (pill as NSString).size(withAttributes: [.font: pillFont])
            let pillRect = CGRect(
                x: mapRect.minX + 24,
                y: mapRect.maxY - 64,
                width: pillSize.width + 36,
                height: 44
            )
            UIColor.black.withAlphaComponent(0.45).setFill()
            UIBezierPath(roundedRect: pillRect, cornerRadius: 22).fill()
            drawText(
                pill,
                at: CGPoint(x: pillRect.minX + 18, y: pillRect.minY + 10),
                font: pillFont,
                color: .white
            )

            var y: CGFloat = mapRect.maxY + 48
            drawText(
                "MOMENTS",
                at: CGPoint(x: 48, y: y),
                font: .systemFont(ofSize: 22, weight: .semibold),
                color: UIColor.white.withAlphaComponent(0.45)
            )
            y += 44

            let shown = Array(moments.moments.prefix(5))
            if shown.isEmpty {
                drawText(
                    "No moments for this ride",
                    at: CGPoint(x: 48, y: y),
                    font: .systemFont(ofSize: 26, weight: .medium),
                    color: UIColor.white.withAlphaComponent(0.35)
                )
            } else {
                for moment in shown {
                    y = drawMomentCard(
                        moment,
                        in: CGRect(x: 48, y: y, width: width - 96, height: 118),
                        context: cg
                    ) + 16
                }
            }

            drawText(
                "Recorded with MotoTripTracker",
                at: CGPoint(x: 48, y: height - 64),
                font: .systemFont(ofSize: 22, weight: .regular),
                color: UIColor.white.withAlphaComponent(0.28)
            )
        }
    }

    private static func mapSnapshot(
        coordinates: [CLLocationCoordinate2D],
        size: CGSize
    ) async -> UIImage? {
        guard coordinates.count >= 2, let region = region(fitting: coordinates) else {
            return nil
        }

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.scale = 3
        options.mapType = .standard
        options.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: .muted)
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
        options.traitCollection = darkTraits.modifyingTraits { mutable in
            mutable.displayScale = 3
        }

        do {
            let snapshot = try await MKMapSnapshotter(options: options).start()
            return drawRoute(on: snapshot, coordinates: coordinates)
        } catch {
            AppLogger.app.error("Share map snapshot failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func drawRoute(
        on snapshot: MKMapSnapshotter.Snapshot,
        coordinates: [CLLocationCoordinate2D]
    ) -> UIImage {
        let image = snapshot.image
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { context in
            image.draw(at: .zero)

            let points = coordinates.map { snapshot.point(for: $0) }
            guard points.count >= 2 else { return }

            let path = UIBezierPath()
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }

            context.cgContext.setLineCap(.round)
            context.cgContext.setLineJoin(.round)

            // Soft under-stroke
            UIColor.black.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 10
            path.stroke()

            // Brand route stroke
            let colors = [mint.cgColor, blue.cgColor] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) {
                context.cgContext.saveGState()
                context.cgContext.addPath(path.cgPath)
                context.cgContext.setLineWidth(6)
                context.cgContext.replacePathWithStrokedPath()
                context.cgContext.clip()
                let bounds = path.bounds.insetBy(dx: -8, dy: -8)
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: bounds.minX, y: bounds.midY),
                    end: CGPoint(x: bounds.maxX, y: bounds.midY),
                    options: []
                )
                context.cgContext.restoreGState()
            } else {
                mint.setStroke()
                path.lineWidth = 6
                path.stroke()
            }

            // Start / end dots
            if let start = points.first {
                drawEndpoint(at: start, color: mint, in: context.cgContext)
            }
            if let end = points.last {
                drawEndpoint(at: end, color: UIColor(red: 226 / 255, green: 75 / 255, blue: 74 / 255, alpha: 1), in: context.cgContext)
            }
        }
    }

    private static func drawEndpoint(at point: CGPoint, color: UIColor, in cg: CGContext) {
        let outer = CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)
        UIColor(red: 16 / 255, green: 16 / 255, blue: 20 / 255, alpha: 1).setFill()
        cg.fillEllipse(in: outer)
        color.setFill()
        cg.fillEllipse(in: outer.insetBy(dx: 3, dy: 3))
    }

    @discardableResult
    private static func drawMomentCard(
        _ moment: RideMoment,
        in rect: CGRect,
        context cg: CGContext
    ) -> CGFloat {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 24)
        UIColor.white.withAlphaComponent(0.06).setFill()
        path.fill()

        drawText(
            moment.title,
            at: CGPoint(x: rect.minX + 28, y: rect.minY + 22),
            font: .systemFont(ofSize: 22, weight: .semibold),
            color: UIColor.white.withAlphaComponent(0.55),
            maxWidth: rect.width * 0.55
        )
        drawText(
            moment.value,
            at: CGPoint(x: rect.minX + 28, y: rect.minY + 52),
            font: .systemFont(ofSize: 34, weight: .bold),
            color: mint,
            maxWidth: rect.width - 56
        )
        drawText(
            moment.detail,
            at: CGPoint(x: rect.minX + 28, y: rect.minY + 92),
            font: .systemFont(ofSize: 20, weight: .regular),
            color: UIColor.white.withAlphaComponent(0.4),
            maxWidth: rect.width - 56
        )
        return rect.maxY
    }

    private static func region(fitting coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coordinates.isEmpty else { return nil }
        var minLat = coordinates[0].latitude
        var maxLat = coordinates[0].latitude
        var minLng = coordinates[0].longitude
        var maxLng = coordinates[0].longitude
        for c in coordinates {
            minLat = min(minLat, c.latitude)
            maxLat = max(maxLat, c.latitude)
            minLng = min(minLng, c.longitude)
            maxLng = max(maxLng, c.longitude)
        }
        let latDelta = max((maxLat - minLat) * 1.5, 0.012)
        let lngDelta = max((maxLng - minLng) * 1.5, 0.012)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLng + maxLng) / 2
            ),
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lngDelta)
        )
    }

    private static func drawText(
        _ text: String,
        at point: CGPoint,
        font: UIFont,
        color: UIColor,
        maxWidth: CGFloat? = nil
    ) {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        if let maxWidth {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            attrs[.paragraphStyle] = paragraph
            let rect = CGRect(x: point.x, y: point.y, width: maxWidth, height: font.lineHeight + 8)
            (text as NSString).draw(in: rect, withAttributes: attrs)
        } else {
            (text as NSString).draw(at: point, withAttributes: attrs)
        }
    }
}
