import ApplicationServices
import Foundation

/// Measures only the expensive preflight portion of the real input path. It neither grants
/// permission nor posts an event. AX trust is forced true only to isolate that portion.
@main
struct PermissionLatency {
    static func samples(count: Int, action: () -> Void) -> [Double] {
        (0..<count).map { _ in
            let start = ProcessInfo.processInfo.systemUptime
            action()
            return (ProcessInfo.processInfo.systemUptime - start) * 1_000
        }
    }

    static func summary(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        return ["totalMilliseconds": values.reduce(0, +),
                "medianMilliseconds": sorted[sorted.count / 2],
                "p95Milliseconds": sorted[Int(Double(sorted.count - 1) * 0.95)]]
    }

    static func main() throws {
        let eventCount = 100
        let baseline = samples(count: eventCount) {
            _ = CGPreflightPostEventAccess()
            _ = CGPreflightPostEventAccess()
        }
        var queries = 0
        var cache = InputPermissionCache(isTrusted: { true }, canPostEvents: {
            queries += 1
            return CGPreflightPostEventAccess()
        })
        let cached = samples(count: eventCount) {
            _ = cache.isAllowed()
            _ = cache.isAllowed()
        }
        let report: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "eventsPerBurst": eventCount,
            "baselinePreflightQueries": eventCount * 2,
            "cachedPreflightQueries": queries,
            "baselinePermissionPortion": summary(baseline),
            "cachedPermissionPortion": summary(cached),
            "postedInputEvents": false,
            "forcedAXTrustForIsolatedPreflightComparison": true,
            "physicalHeadsetLatencyMeasured": false
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
