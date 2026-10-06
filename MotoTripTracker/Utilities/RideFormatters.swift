import Foundation

nonisolated enum RideFormatters {
    private static let dateStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, yyyy - HH:mm"
        return formatter
    }()

    private static let clockTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayHeadingFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter
    }()

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
        return dateStamp.string(from: Date(timeIntervalSince1970: timeInterval))
    }

    /// Clock time only — used under day section headers in History.
    static func timestampToTime(_ timeInterval: TimeInterval) -> String {
        guard timeInterval > 0 else { return "--" }
        return clockTime.string(from: Date(timeIntervalSince1970: timeInterval))
    }

    static func dayHeading(_ date: Date, calendar: Calendar) -> String {
        dayHeadingFormatter.calendar = calendar
        dayHeadingFormatter.timeZone = calendar.timeZone
        dayHeadingFormatter.locale = calendar.locale ?? .current
        return dayHeadingFormatter.string(from: date)
    }

    static func currentClock() -> String {
        clockTime.string(from: Date())
    }
}
