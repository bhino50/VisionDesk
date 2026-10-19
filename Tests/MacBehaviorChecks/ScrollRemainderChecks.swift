import Foundation

@MainActor
func runScrollRemainderChecks(_ runner: CheckRunner) async {
    await runner.check("Small scroll deltas accumulate rather than disappear") {
        var scroll = ScrollRemainder()
        var totalX = 0, totalY = 0
        for _ in 0..<100 {
            let delta = scroll.take(x: 0.1, y: -0.1)
            totalX += Int(delta.x); totalY += Int(delta.y)
        }
        runner.expectEqual(totalX, 10, "horizontal pixel sum")
        runner.expectEqual(totalY, -10, "vertical pixel sum")
    }
    await runner.check("Scroll direction changes preserve the net displacement") {
        var scroll = ScrollRemainder()
        let first = scroll.take(x: 0.4, y: 0.6)
        let reverse = scroll.take(x: -0.4, y: -0.6)
        runner.expectEqual(first.x + reverse.x, 0, "horizontal reversal")
        runner.expectEqual(first.y + reverse.y, 0, "vertical reversal")
    }
    await runner.check("Nonfinite and saturated scroll deltas leave no large backlog") {
        var scroll = ScrollRemainder()
        let invalid = scroll.take(x: .nan, y: .infinity)
        runner.expectEqual(invalid.x, 0, "NaN")
        runner.expectEqual(invalid.y, 0, "infinity")
        let saturated = scroll.take(x: 1e100, y: -1e100)
        runner.expectEqual(saturated.x, 2_000, "upper bound")
        runner.expectEqual(saturated.y, -2_000, "lower bound")
        let next = scroll.take(x: 0, y: 0)
        runner.expectEqual(next.x, 0, "no horizontal stored overflow")
        runner.expectEqual(next.y, 0, "no vertical stored overflow")
    }
}
