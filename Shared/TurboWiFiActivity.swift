import ActivityKit
import Foundation

struct TurboWiFiActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let confirmedAt: Date
    }
}
