import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct GaEmulatorActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: Int
        var memoryMB: Double?
        var cpuPercent: Double?
        var tabs: Int
        var updatedAt: Date
    }
    var appName: String
}
