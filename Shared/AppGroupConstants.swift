import Foundation

/// Identifiers shared between the main app and the keyboard extension.
enum AppGroup {
    static let identifier = "group.com.shuaiwang.openvoicetyper"

    /// Opened once per process. Both of these look like cheap accessors and
    /// are not: `UserDefaults(suiteName:)` re-opens the suite and
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` asks the
    /// sandbox daemon where the container lives. The bridge touches them
    /// several times a second while a dictation runs (level updates from the
    /// app, the keyboard's poll timer, every catalog and settings read), so
    /// they are resolved once and shared.
    /// `nonisolated(unsafe)` because `UserDefaults` predates `Sendable` but is
    /// documented as thread-safe, which is exactly how the bridge uses it
    /// (audio thread levels, main-actor reads, background pipeline writes).
    nonisolated(unsafe) static let defaults: UserDefaults? = UserDefaults(suiteName: identifier)

    static let containerURL: URL? =
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
}
