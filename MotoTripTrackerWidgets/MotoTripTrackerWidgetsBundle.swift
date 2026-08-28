import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MotoTripTrackerWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RideLiveActivityWidget()
        LastRideWidget()
        WeekStatsWidget()
    }
}
