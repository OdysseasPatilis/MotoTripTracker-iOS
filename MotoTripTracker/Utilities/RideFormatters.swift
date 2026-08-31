import Foundation

enum RideFormatters {
    static func secondsToTime(_ totalSeconds: Int64) -> String {
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func timestampToDate(_ timeInterval: TimeInterval) -> String {
        guard timeInterval > 0 else { return "--" }
        let date = Date(timeIntervalSince1970: timeInterval)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, yyyy - HH:mm"
        return formatter.string(from: date)
    }

    /// Clock time only — used under day section headers in History.
    static func timestampToTime(_ timeInterval: TimeInterval) -> String {
        guard timeInterval > 0 else { return "--" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timeInterval))
    }

    static func currentClock() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }
}
