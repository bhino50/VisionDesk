import Foundation

@MainActor
func runEncoderOutputRecoveryChecks(_ runner: CheckRunner) async {
    await runner.check("Encoder callback and parsing failures trigger fallback once") {
        var recovery = EncoderOutputRecovery()
        let limit = EncoderOutputRecovery.maximumConsecutiveFailures
        for _ in 1..<limit {
            runner.expectEqual(recovery.record(usable: false), .retry, "isolated failures request repair")
        }
        runner.expectEqual(recovery.record(usable: false), .fail, "persistent failures notify the existing JPEG fallback path")
        for _ in 0..<limit {
            runner.expectEqual(recovery.record(usable: false), .ignore, "queued failures cannot repeatedly degrade the host")
        }
        runner.expectEqual(recovery.record(usable: true), .ignore, "late output cannot revive a failed encoder")
    }
    await runner.check("Usable encoder output resets consecutive callback failures") {
        var recovery = EncoderOutputRecovery()
        for _ in 0..<3 {
            for _ in 1..<EncoderOutputRecovery.maximumConsecutiveFailures {
                runner.expectEqual(recovery.record(usable: false), .retry, "a repairable run remains recoverable")
            }
            runner.expectEqual(recovery.record(usable: true), .deliver, "real output clears the run")
        }
    }
}
