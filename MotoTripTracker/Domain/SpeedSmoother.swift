import Foundation

final class SpeedSmoother: @unchecked Sendable {
    private let windowSize: Int
    private var speedBuffer: [Double] = []

    init(windowSize: Int = 3) {
        self.windowSize = max(1, windowSize)
    }

    func smoothedSpeedKmh(fromSpeedMps speedMps: Double) -> Double {
        let speedKmh = speedMps * 3.6
        speedBuffer.append(speedKmh)
        if speedBuffer.count > windowSize {
            speedBuffer.removeFirst(speedBuffer.count - windowSize)
        }
        let average = speedBuffer.reduce(0, +) / Double(speedBuffer.count)
        return average.rounded()
    }

    func reset() {
        speedBuffer.removeAll(keepingCapacity: true)
    }
}
