import Foundation

/// A dependency-free check harness.
///
/// These checks compile the production Mac sources directly, because `CompanionModel`,
/// `InputOutput` and `DisplayCapture` live in an executable target that the package's
/// XCTest targets cannot import. The runner reports every failing expectation in a check
/// rather than stopping at the first one, and exits non-zero if anything failed.
@MainActor
final class CheckRunner {
    private var passedNames: [String] = []
    private var failures: [String] = []
    private var currentFailures: [String] = []

    func check(_ name: String, _ body: () async throws -> Void) async {
        currentFailures = []
        do {
            try await body()
        } catch {
            currentFailures.append("threw \(error)")
        }
        if currentFailures.isEmpty {
            passedNames.append(name)
            print("PASS  \(name)")
            return
        }
        for detail in currentFailures {
            failures.append("\(name): \(detail)")
            print("FAIL  \(name)")
            print("      \(detail)")
        }
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard !condition else { return }
        currentFailures.append(message())
    }

    func expectEqual<Value: Equatable>(_ actual: Value, _ expected: Value, _ label: String) {
        guard actual != expected else { return }
        currentFailures.append("\(label): expected \(expected), got \(actual)")
    }

    func expectClose(_ actual: Double, _ expected: Double, _ label: String, tolerance: Double = 0.000_001) {
        guard !(abs(actual - expected) <= tolerance) else { return }
        currentFailures.append("\(label): expected \(expected) ± \(tolerance), got \(actual)")
    }

    func finish() -> Never {
        print("")
        print("\(passedNames.count) check(s) passed, \(failures.count) failure(s)")
        for failure in failures { print("  FAILED: \(failure)") }
        exit(failures.isEmpty ? 0 : 1)
    }
}
