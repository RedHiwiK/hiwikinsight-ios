import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public extension View {
    /// Records `screen.viewed` when the view appears and `screen.left` (with dwell time in seconds)
    /// when it disappears.
    /// Attach it only to standalone screens (the root view of a push / fullScreenCover / sheet).
    /// For tab roots that stay mounted and are switched by opacity, call
    /// `HiwiKInsight.screenViewed` manually where the tab changes instead.
    ///
    /// The screen also counts as left while the app is in the background and while an enclosing
    /// `screenTrackingActive(false)` is in effect (for example, a pushed screen inside a tab that is
    /// not selected); it is recorded as viewed again once it becomes visible.
    func trackScreen(_ screen: String, module: String, _ params: [String: String] = [:]) -> some View {
        modifier(ScreenTrackingModifier(screen: screen, module: module, params: params))
    }

    /// Marks whether the screens inside this view are visible to the user.
    /// Apply it to containers that stay mounted while hidden, such as each tab of a tab bar that
    /// switches tabs by opacity: pass `false` for tabs that are not selected, so `trackScreen`
    /// screens inside them record `screen.left` when the tab is switched away.
    func screenTrackingActive(_ isActive: Bool) -> some View {
        environment(\.hiwikScreenTrackingActive, isActive)
    }
}

extension EnvironmentValues {
    @Entry var hiwikScreenTrackingActive: Bool = true
}

/// Decides when a tracked screen counts as viewed or left. A screen is visible while it is mounted,
/// its container is active and the app is not in the background; each visible stretch is one
/// `screen.viewed` / `screen.left` pair. Kept free of SwiftUI so the rules can be unit tested.
struct ScreenVisibility {
    enum Transition: Equatable {
        case viewed
        case left(duration: TimeInterval)
    }

    private var isMounted = false
    private var isActive: Bool
    private var isInBackground: Bool
    /// Start of the current visible stretch; nil when no `screen.viewed` is open.
    private var viewedAt: Date?

    init(isActive: Bool = true, isInBackground: Bool = false) {
        self.isActive = isActive
        self.isInBackground = isInBackground
    }

    mutating func appear(at now: Date) -> Transition? {
        isMounted = true
        return update(at: now)
    }

    mutating func disappear(at now: Date) -> Transition? {
        isMounted = false
        return update(at: now)
    }

    mutating func setActive(_ active: Bool, at now: Date) -> Transition? {
        isActive = active
        return update(at: now)
    }

    mutating func setInBackground(_ background: Bool, at now: Date) -> Transition? {
        isInBackground = background
        return update(at: now)
    }

    private mutating func update(at now: Date) -> Transition? {
        let isVisible = isMounted && isActive && !isInBackground
        if isVisible, viewedAt == nil {
            viewedAt = now
            return .viewed
        }
        if !isVisible, let start = viewedAt {
            viewedAt = nil
            return .left(duration: now.timeIntervalSince(start))
        }
        return nil
    }
}

private struct ScreenTrackingModifier: ViewModifier {
    let screen: String
    let module: String
    let params: [String: String]
    @Environment(\.hiwikScreenTrackingActive) private var isActive
    @State private var visibility = ScreenVisibility()

    func body(content: Content) -> some View {
        content
            .onAppear {
                _ = visibility.setActive(isActive, at: Date())
                #if canImport(UIKit)
                _ = visibility.setInBackground(UIApplication.shared.applicationState == .background, at: Date())
                #endif
                record(visibility.appear(at: Date()))
            }
            .onDisappear {
                record(visibility.disappear(at: Date()))
            }
            .onChange(of: isActive) { _, active in
                record(visibility.setActive(active, at: Date()))
            }
        #if canImport(UIKit)
            // UIApplication notifications rather than scenePhase: the SDK opens the session on
            // didBecomeActive, and scenePhase turns active before it, so the view would land outside the session.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                record(visibility.setInBackground(false, at: Date()))
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                record(visibility.setInBackground(true, at: Date()))
            }
        #endif
    }

    private func record(_ transition: ScreenVisibility.Transition?) {
        switch transition {
        case .viewed:
            HiwiKInsight.screenViewed(screen, module: module, params)
        case .left(let duration):
            HiwiKInsight.screenLeft(screen, module: module, duration: duration)
        case nil:
            break
        }
    }
}
