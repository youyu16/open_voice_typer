import Foundation
import SwiftData

/// One completed dictation, kept locally (local-first, never synced).
@Model
final class TranscriptRecord {
    var id: UUID = UUID()
    var rawText: String = ""
    var polishedText: String = ""
    var styleID: String = ""
    var source: String = Source.app.rawValue
    var createdAt: Date = Date.now
    /// Model that produced `polishedText` ("on-device", "gpt-4o-mini", …).
    var engineName: String = ""
    /// Length of the recorded audio; 0 for re-polished entries' unknown originals.
    var audioSeconds: Double = 0

    /// How long the user waited, by stage. Always recorded — the Settings
    /// toggle decides whether History *shows* them, so turning it on reveals
    /// the dictations already behind you rather than only the next one.
    ///
    /// `totalMilliseconds == 0` means unmeasured (an entry saved before this
    /// existed). Within a measured entry, `polishMilliseconds == 0` means
    /// polish was skipped, which is what the Raw template does.
    var totalMilliseconds: Int = 0
    var asrMilliseconds: Int = 0
    var polishMilliseconds: Int = 0

    enum Source: String {
        case app
        case keyboard
    }

    init(
        rawText: String,
        polishedText: String,
        styleID: String,
        source: Source,
        engineName: String = "",
        audioSeconds: Double = 0,
        totalMilliseconds: Int = 0,
        asrMilliseconds: Int = 0,
        polishMilliseconds: Int = 0
    ) {
        self.id = UUID()
        self.rawText = rawText
        self.polishedText = polishedText
        self.styleID = styleID
        self.source = source.rawValue
        self.createdAt = .now
        self.engineName = engineName
        self.audioSeconds = audioSeconds
        self.totalMilliseconds = totalMilliseconds
        self.asrMilliseconds = asrMilliseconds
        self.polishMilliseconds = polishMilliseconds
    }

    var styleName: String {
        SharedCatalog.style(id: styleID)?.name ?? styleID
    }

    /// Stage latencies, or nil when this entry was never measured.
    var latency: Latency? {
        guard totalMilliseconds > 0 else { return nil }
        return Latency(
            total: totalMilliseconds,
            asr: asrMilliseconds,
            polish: polishMilliseconds
        )
    }

    struct Latency: Equatable {
        var total: Int
        var asr: Int
        var polish: Int

        /// The stages worth showing, in the order they ran. A stage that did
        /// not run is left out rather than shown as zero — "polish 0 ms" reads
        /// like a bug, and the Raw template legitimately skips it.
        var stages: [(name: String, milliseconds: Int)] {
            var stages: [(String, Int)] = []
            if asr > 0 { stages.append(("Speech", asr)) }
            if polish > 0 { stages.append(("Polish", polish)) }
            return stages
        }

        /// Whatever the stages don't account for: writing the audio out,
        /// reading the dictionary, handing the result back to the keyboard.
        /// Shown so the parts always add up to the total the user felt.
        var otherMilliseconds: Int {
            max(0, total - asr - polish)
        }

        static func format(milliseconds: Int) -> String {
            milliseconds < 1000
                ? "\(milliseconds) ms"
                : String(format: "%.1f s", Double(milliseconds) / 1000)
        }
    }
}
