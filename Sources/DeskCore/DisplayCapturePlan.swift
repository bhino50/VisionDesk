import Foundation

/// Reconciles macOS's physical inventory with ScreenCaptureKit before any stream starts.
/// A dock may enumerate its screens before capture is ready; never advertise a partial set.
public enum DisplayCapturePlan {
    /// Bound capture independently of the number of connected screens. Preserve the
    /// main-first inventory order and any explicit selection made by the owner.
    public static func select(inventory: [DisplayInfo], preferredIDs: Set<UInt32>? = nil) -> [DisplayInfo] {
        var seen = Set<UInt32>()
        return Array(inventory.filter {
            $0.isValid && seen.insert($0.id).inserted && (preferredIDs?.contains($0.id) ?? true)
        }.prefix(DeskMessage.maximumSharedDisplays))
    }

    /// Match a saved physical identity to today's runtime ID. Missing or duplicate
    /// identities are unavailable; they must never select another connected screen.
    public static func resolve(identities: Set<String>, current: [UInt32: String]) -> Set<UInt32> {
        let grouped = Dictionary(grouping: current.keys, by: { current[$0]! })
        return Set(identities.compactMap { identity in
            guard let matches = grouped[identity], matches.count == 1 else { return nil }
            return matches[0]
        })
    }

    public static func validate(inventory: [DisplayInfo], capturableIDs: Set<UInt32>) throws {
        guard !inventory.isEmpty else { throw Unavailable(displays: []) }
        let missing = inventory.filter { !capturableIDs.contains($0.id) }
        guard missing.isEmpty else { throw Unavailable(displays: missing) }
    }

    public struct Unavailable: LocalizedError, Equatable, Sendable {
        public let displays: [DisplayInfo]

        public var errorDescription: String? {
            guard !displays.isEmpty else { return "No connected displays are ready for capture. Check the dock and displays." }
            let names = displays.map { "\($0.name) (ID \($0.id))" }.joined(separator: ", ")
            return "Waiting for ScreenCaptureKit to make all connected displays available: \(names). Check the dock and Screen Recording access."
        }
    }
}
