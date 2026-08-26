import SwiftUI
import UIKit
import os

enum RideShareHelper {
    static func shareText(for trip: Trip) -> String {
        String(
            format: "MotoTripTracker ride — %.1f km · max %d km/h · %@",
            trip.distanceKm,
            Int(trip.maxSpeed),
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

    static func shareCardImage(trip: Trip, moments: RideMoments) {
        let image = RideShareCardRenderer.render(trip: trip, moments: moments)
        presentShareSheet(items: [image, shareText(for: trip)])
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
    static func render(trip: Trip, moments: RideMoments) -> UIImage {
        let size = CGSize(width: 1080, height: 1350)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            UIColor(red: 10 / 255, green: 10 / 255, blue: 15 / 255, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            let hero = CGRect(x: 48, y: 64, width: size.width - 96, height: 216)
            let colors = [UIColor(red: 91 / 255, green: 95 / 255, blue: 239 / 255, alpha: 1).cgColor,
                          UIColor(red: 124 / 255, green: 77 / 255, blue: 255 / 255, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.saveGState()
                let path = UIBezierPath(roundedRect: hero, cornerRadius: 48)
                path.addClip()
                cg.drawLinearGradient(
                    gradient,
                    start: hero.origin,
                    end: CGPoint(x: hero.maxX, y: hero.maxY),
                    options: []
                )
                cg.restoreGState()
            }

            drawText(
                "MOTOTRIPTRACKER",
                at: CGPoint(x: 88, y: 110),
                font: .systemFont(ofSize: 28, weight: .medium),
                color: UIColor.white.withAlphaComponent(0.7)
            )
            drawText(
                RideFormatters.timestampToDate(trip.startTime),
                at: CGPoint(x: 88, y: 170),
                font: .systemFont(ofSize: 44, weight: .bold),
                color: UIColor(red: 94 / 255, green: 255 / 255, blue: 200 / 255, alpha: 1)
            )

            let stats: [(String, String, String)] = [
                ("DISTANCE", String(format: "%.1f", trip.distanceKm), "km"),
                ("MAX SPEED", "\(Int(trip.maxSpeed))", "km/h"),
                ("AVG SPEED", "\(Int(trip.avgSpeed))", "km/h"),
                ("MOVING", RideFormatters.secondsToTime(trip.movingTime), ""),
                ("ELEVATION", "+\(Int(trip.elevationGain))", "m"),
                ("MAX G", String(format: "%.2f", trip.maxGForce), "G")
            ]

            var y: CGFloat = 340
            for row in stride(from: 0, to: stats.count, by: 2) {
                var x: CGFloat = 48
                let tileW = (size.width - 96 - 24) / 2
                for col in 0..<2 where row + col < stats.count {
                    let item = stats[row + col]
                    drawStatTile(
                        in: CGRect(x: x, y: y, width: tileW, height: 170),
                        label: item.0,
                        value: item.1,
                        unit: item.2
                    )
                    x += tileW + 24
                }
                y += 194
            }

            y += 20
            drawText(
                "RIDE MOMENTS",
                at: CGPoint(x: 48, y: y),
                font: .systemFont(ofSize: 22, weight: .semibold),
                color: UIColor.white.withAlphaComponent(0.55)
            )
            y += 50
            for moment in moments.moments.prefix(4) {
                drawText(
                    "\(moment.title): \(moment.value)",
                    at: CGPoint(x: 48, y: y),
                    font: .systemFont(ofSize: 28, weight: .medium),
                    color: .white
                )
                y += 48
            }
        }
    }

    private static func drawStatTile(in rect: CGRect, label: String, value: String, unit: String) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 28)
        UIColor.white.withAlphaComponent(0.06).setFill()
        path.fill()
        drawText(
            label,
            at: CGPoint(x: rect.minX + 28, y: rect.minY + 28),
            font: .systemFont(ofSize: 20, weight: .medium),
            color: UIColor.white.withAlphaComponent(0.45)
        )
        drawText(
            value,
            at: CGPoint(x: rect.minX + 28, y: rect.minY + 70),
            font: .systemFont(ofSize: 48, weight: .bold),
            color: .white
        )
        if !unit.isEmpty {
            drawText(
                unit,
                at: CGPoint(x: rect.minX + 28, y: rect.minY + 128),
                font: .systemFont(ofSize: 20, weight: .regular),
                color: UIColor.white.withAlphaComponent(0.45)
            )
        }
    }

    private static func drawText(_ text: String, at point: CGPoint, font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        (text as NSString).draw(at: point, withAttributes: attrs)
    }
}
