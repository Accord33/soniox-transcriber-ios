import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case recording
            case interrupted
            case reconnecting
            case finishing
        }

        var startedAt: Date
        var status: String
        var phase: Phase
    }

    var title: String
}
