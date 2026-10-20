import DeskTransport
import Foundation

/// Explicit diagnostic using a disposable namespace. Never reads or replaces real pairing.
enum PairingStoreCheck {
    static func run() {
        let store = PairingKeyStore(service: "org.visiondesk.diagnostic." + UUID().uuidString)
        let account = "disposable-roundtrip"
        var report: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()),
                                   "saved": false, "matched": false, "deleted": false]
        do {
            let key = PairingKey.generate()
            try store.save(key, account: account)
            report["saved"] = true
            report["matched"] = try store.load(account: account)?.displayValue == key.displayValue
        } catch {
            report["operationError"] = error.localizedDescription
        }
        do {
            try store.delete(account: account)
            report["deleted"] = true
        } catch {
            report["cleanupError"] = error.localizedDescription
        }
        report["passed"] = report["saved"] as? Bool == true
            && report["matched"] as? Bool == true && report["deleted"] as? Bool == true
        let destination = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("pairing-store-check.json")
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: destination, options: .atomic)
        } catch {
            NSLog("VisionDesk could not write the disposable pairing-store diagnostic report.")
        }
    }
}
