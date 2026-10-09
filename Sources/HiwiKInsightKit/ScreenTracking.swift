import SwiftUI

public extension View {
    /// Records `screen.viewed` when the view appears and `screen.left` (with dwell time in seconds)
    /// when it disappears.
    /// Attach it only to standalone screens (the root view of a push / fullScreenCover / sheet).
    /// For tab roots that stay mounted and are switched by opacity, call
    /// `HiwiKInsight.screenViewed` manually where the tab changes instead.
    func trackScreen(_ screen: String, module: String, _ params: [String: String] = [:]) -> some View {
        modifier(ScreenTrackingModifier(screen: screen, module: module, params: params))
    }
}

private struct ScreenTrackingModifier: ViewModifier {
    let screen: String
    let module: String
    let params: [String: String]
    @State private var appearedAt: Date?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard appearedAt == nil else { return }
                appearedAt = Date()
                HiwiKInsight.screenViewed(screen, module: module, params)
            }
            .onDisappear {
                guard let appearedAt else { return }
                HiwiKInsight.screenLeft(screen, module: module, duration: Date().timeIntervalSince(appearedAt))
                self.appearedAt = nil
            }
    }
}
