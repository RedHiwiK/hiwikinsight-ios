import Foundation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

enum DeviceInfo {
    /// Static attributes that are known at launch.
    @MainActor
    static func staticContext() -> [String: String] {
        var ctx: [String: String] = [:]
        let info = Bundle.main.infoDictionary
        ctx["app_version"] = info?["CFBundleShortVersionString"] as? String
        ctx["build"] = info?["CFBundleVersion"] as? String
        #if canImport(UIKit)
        ctx["os"] = UIDevice.current.systemName
        ctx["os_version"] = UIDevice.current.systemVersion
        #else
        ctx["os"] = "macOS"
        ctx["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        ctx["device"] = modelIdentifier()
        ctx["locale"] = Locale.current.identifier
        ctx["language"] = Locale.preferredLanguages.first
        ctx["region"] = Locale.current.region?.identifier
        ctx["env"] = fallbackEnvironment()
        return ctx.compactMapValues { $0 }
    }

    /// Attributes that may change at any time (appearance, Dynamic Type size). Refreshed on every return to the foreground.
    @MainActor
    static func dynamicContext() -> [String: String] {
        #if canImport(UIKit)
        let traits = UIScreen.main.traitCollection
        return [
            "appearance": traits.userInterfaceStyle == .dark ? "dark" : "light",
            "text_size": textSize(traits.preferredContentSizeCategory),
        ]
        #else
        return [:]
        #endif
    }

    struct AppTransactionResult: Sendable {
        var env: String?
        var originalDownload: Date?
        /// ok / unverified / skipped / timeout / error: <reason>; sent with app.installed to aid troubleshooting.
        var status: String
    }

    /// Environment and original download date from AppTransaction; if unavailable the environment
    /// keeps its fallback value. Without a network, or on a simulator without a StoreKit configuration,
    /// `AppTransaction.shared` may never return, so give up after a timeout to avoid holding
    /// `app.installed` forever.
    static func appTransaction(timeout: TimeInterval = 10) async -> AppTransactionResult {
        await withTimeout(timeout, fallback: AppTransactionResult(status: "timeout")) { await loadAppTransaction() }
    }

    /// On failure, retry once after 2 seconds: StoreKit may not be ready yet on first launch
    /// (observed failing immediately on first launch on real devices).
    private static func loadAppTransaction() async -> AppTransactionResult {
        var result = await loadAppTransactionOnce()
        if result.originalDownload == nil, result.status.hasPrefix("error") {
            try? await Task.sleep(for: .seconds(2))
            let retry = await loadAppTransactionOnce()
            result = retry.originalDownload != nil ? retry : AppTransactionResult(status: result.status + " | retry " + retry.status)
        }
        return result
    }

    private static func loadAppTransactionOnce() async -> AppTransactionResult {
        // Simulator and Debug builds installed from Xcode have no app transaction, and
        // AppTransaction.shared would prompt "Sign in with Apple Account". Those installs are the
        // xcode environment anyway, so skip them.
        // Do not decide based on whether a receipt file exists: on newer OS versions App Store /
        // TestFlight installs do not always have a receipt file, which would lose the original
        // download date and count every upgrading existing user as new (observed in production).
        if skipsAppTransaction { return AppTransactionResult(status: "skipped") }
        let result: VerificationResult<AppTransaction>
        do {
            result = try await AppTransaction.shared
        } catch {
            return AppTransactionResult(status: "error: " + String(describing: error))
        }
        let tx: AppTransaction
        let status: String
        switch result {
        case .verified(let t): tx = t; status = "ok"
        case .unverified(let t, let e): tx = t; status = "unverified: " + String(describing: e)
        }
        let env: String
        switch tx.environment {
        case .production: env = "production"
        case .sandbox: env = "sandbox"
        case .xcode: env = "xcode"
        default: env = tx.environment.rawValue.lowercased()
        }
        return AppTransactionResult(env: env, originalDownload: tx.originalPurchaseDate, status: status)
    }

    static func storefront(timeout: TimeInterval = 10) async -> String? {
        await withTimeout(timeout, fallback: nil) { await Storefront.current?.countryCode }
    }

    /// Returns `fallback` on timeout. Does not use a TaskGroup: a group waits for all child tasks
    /// before returning, and these StoreKit calls do not necessarily honor cancellation.
    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        fallback: T,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T {
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            Task {
                let value = await operation()
                if once.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() { continuation.resume(returning: fallback) }
            }
        }
    }

    private static var skipsAppTransaction: Bool {
        #if targetEnvironment(simulator) || DEBUG
        return true
        #else
        return false
        #endif
    }

    private static func fallbackEnvironment() -> String {
        #if targetEnvironment(simulator) || DEBUG
        return "xcode"
        #else
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" { return "sandbox" }
        return "production"
        #endif
    }

    private static func modelIdentifier() -> String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    #if canImport(UIKit)
    private static func textSize(_ c: UIContentSizeCategory) -> String {
        switch c {
        case .extraSmall: return "XS"
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        case .extraLarge: return "XL"
        case .extraExtraLarge: return "XXL"
        case .extraExtraExtraLarge: return "XXXL"
        default: return c.isAccessibilityCategory ? "A11Y" : "L"
        }
    }
    #endif
}

/// Ensures a continuation is resumed only once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}
