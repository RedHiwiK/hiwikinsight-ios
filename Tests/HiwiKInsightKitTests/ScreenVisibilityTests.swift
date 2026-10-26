import Foundation
import Testing
@testable import HiwiKInsightKit

struct ScreenVisibilityTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func appearAndDisappearRecordOnePair() {
        var visibility = ScreenVisibility()
        #expect(visibility.appear(at: start) == .viewed)
        #expect(visibility.disappear(at: start.addingTimeInterval(12)) == .left(duration: 12))
        #expect(visibility.disappear(at: start.addingTimeInterval(20)) == nil)
    }

    @Test func backgroundEndsTheStretchAndForegroundStartsANewOne() {
        var visibility = ScreenVisibility()
        _ = visibility.appear(at: start)
        #expect(visibility.setInBackground(true, at: start.addingTimeInterval(5)) == .left(duration: 5))
        // Time spent in the background is not counted.
        #expect(visibility.setInBackground(false, at: start.addingTimeInterval(3600)) == .viewed)
        #expect(visibility.disappear(at: start.addingTimeInterval(3602)) == .left(duration: 2))
    }

    @Test func inactiveContainerEndsTheStretch() {
        var visibility = ScreenVisibility()
        _ = visibility.appear(at: start)
        #expect(visibility.setActive(false, at: start.addingTimeInterval(8)) == .left(duration: 8))
        #expect(visibility.setActive(false, at: start.addingTimeInterval(9)) == nil)
        #expect(visibility.setActive(true, at: start.addingTimeInterval(60)) == .viewed)
    }

    @Test func screenInsideInactiveContainerIsNotViewedUntilActive() {
        var visibility = ScreenVisibility(isActive: false)
        #expect(visibility.appear(at: start) == nil)
        #expect(visibility.disappear(at: start.addingTimeInterval(5)) == nil)
    }

    @Test func screenAppearingInBackgroundWaitsForForeground() {
        var visibility = ScreenVisibility(isInBackground: true)
        #expect(visibility.appear(at: start) == nil)
        #expect(visibility.setInBackground(false, at: start.addingTimeInterval(2)) == .viewed)
    }

    @Test func noLeftWithoutViewed() {
        var visibility = ScreenVisibility()
        #expect(visibility.setInBackground(true, at: start) == nil)
        #expect(visibility.setActive(false, at: start) == nil)
    }
}
