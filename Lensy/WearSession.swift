import Foundation
import SwiftData

@Model
final class WearSession {
    var startedAt: Date = Date()
    var endedAt: Date? = nil
    var note: String = ""

    init(startedAt: Date = .now) {
        self.startedAt = startedAt
    }

    var duration: TimeInterval {
        (endedAt ?? .now).timeIntervalSince(startedAt)
    }
}
