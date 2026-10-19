import DeskTransport
import CoreGraphics
import DeskCore
import Foundation

/// Input translation on the Mac side. These checks only call pure helpers and injected fakes,
/// so no Quartz event is ever posted and the Accessibility permission is never requested.
@MainActor
func runInputMappingChecks(_ runner: CheckRunner) async {
    await runner.check("Text chunks never split a surrogate pair") {
        let emoji = String(repeating: "🙂", count: 30) // 60 UTF-16 units, 2 per scalar
        let chunks = InputOutput.textChunks(emoji)

        runner.expect(!chunks.isEmpty, "a non-empty string must produce chunks")
        for (index, chunk) in chunks.enumerated() {
            runner.expect(!chunk.isEmpty, "chunk \(index) must not be empty")
            runner.expect(
                chunk.count <= InputOutput.maximumTextChunkUnits,
                "chunk \(index) length \(chunk.count) exceeds the unit bound"
            )
            runner.expect(
                !(0xDC00...0xDFFF).contains(chunk[0]),
                "chunk \(index) must not start with a low surrogate"
            )
            runner.expect(
                !(0xD800...0xDBFF).contains(chunk[chunk.count - 1]),
                "chunk \(index) must not end with a high surrogate"
            )
            let decoded = String(decoding: chunk, as: UTF16.self)
            runner.expect(
                !decoded.unicodeScalars.contains { $0.value == 0xFFFD },
                "chunk \(index) must decode without a replacement character"
            )
        }
        runner.expectEqual(
            String(decoding: chunks.flatMap { $0 }, as: UTF16.self),
            emoji,
            "chunks must reassemble into the original text"
        )
    }

    await runner.check("Chunking backs off one unit when a pair straddles the boundary") {
        let text = String(repeating: "a", count: InputOutput.maximumTextChunkUnits - 1) + "🙂"
        let chunks = InputOutput.textChunks(text)

        let expectedFirst: Int? = InputOutput.maximumTextChunkUnits - 1
        let expectedLast: Int? = 2
        runner.expectEqual(chunks.count, 2, "chunk count")
        runner.expectEqual(chunks.first?.count, expectedFirst, "first chunk backs off")
        runner.expectEqual(chunks.last?.count, expectedLast, "the surrogate pair stays together")
        runner.expectEqual(
            String(decoding: chunks.flatMap { $0 }, as: UTF16.self),
            text,
            "chunks must reassemble into the original text"
        )
    }

    await runner.check("Chunking covers empty, exact-fit and protocol-maximum input") {
        runner.expect(InputOutput.textChunks("").isEmpty, "empty text must produce no chunks")

        let unit = InputOutput.maximumTextChunkUnits
        runner.expectEqual(InputOutput.textChunks(String(repeating: "a", count: unit)).count, 1, "exact fit")
        runner.expectEqual(InputOutput.textChunks(String(repeating: "a", count: unit + 1)).count, 2, "one past the fit")

        // 4096 UTF-8 bytes is the largest text payload DeskMessage.isValid accepts.
        let maximum = String(repeating: "a", count: 4_096)
        let chunks = InputOutput.textChunks(maximum)
        runner.expectEqual(chunks.reduce(0) { $0 + $1.count }, 4_096, "every unit must be emitted exactly once")
        runner.expect(
            chunks.allSatisfy { $0.count <= unit },
            "no chunk may exceed the unit bound at the protocol maximum"
        )
    }

    await runner.check("Combining marks and ZWJ emoji stay intact across ordinary text chunks") {
        for cluster in ["e\u{301}", "👨‍👩‍👧‍👦", "🇺🇸", "👩🏽‍💻"] {
            let text = String(repeating: "a", count: 19) + cluster + String(repeating: cluster, count: 4)
            let chunks = InputOutput.textChunks(text).map { String(decoding: $0, as: UTF16.self) }
            runner.expectEqual(chunks.joined(), text, "original glyphs survive")
            for chunk in chunks {
                runner.expect(!chunk.unicodeScalars.contains { $0.value == 0xFFFD }, "no replacement characters")
                runner.expect(!chunk.hasPrefix("\u{200D}"), "no chunk begins with a joiner")
            }
        }
    }

    await runner.check("Non-finite and oversized wheel deltas cannot trap") {
        var scroll = ScrollRemainder()
        runner.expectEqual(scroll.take(x: .nan, y: .infinity).x, 0, "NaN is ignored")
        runner.expectEqual(scroll.take(x: .nan, y: .infinity).y, 0, "infinity is ignored")
        let bounded = scroll.take(x: 200_000, y: -200_000)
        runner.expectEqual(bounded.x, 2_000, "positive limit")
        runner.expectEqual(bounded.y, -2_000, "negative limit")
    }

    await runner.check("Every protocol key has a Mac key mapping") {
        runner.expectEqual(
            Set(InputOutput.keys.keys),
            DeskMessage.supportedKeys,
            "the Mac key table and the accepted protocol keys must match exactly"
        )
    }

    await runner.check("Negative origin and Retina scale map through points, not pixels") {
        // A 4K panel left of and above the main display, running a 1920x1080 point mode.
        let left = DisplayInfo(
            id: 2, name: "Left Retina", width: 3840, height: 2160,
            originX: -1920, originY: -240, pointWidth: 1920, pointHeight: 1080
        )
        runner.expect(left.isValid, "the synthetic Retina display must be valid")

        guard let origin = left.point(x: 0, y: 0), let far = left.point(x: 1, y: 1),
              let middle = left.point(x: 0.5, y: 0.5) else {
            runner.expect(false, "normalized corners must map to points")
            return
        }
        runner.expectClose(Double(origin.x), -1920, "top-left x keeps the negative origin")
        runner.expectClose(Double(origin.y), -240, "top-left y keeps the negative origin")
        runner.expectClose(Double(far.x), -1, "the far edge stays inside the display in point space")
        runner.expectClose(Double(far.y), 839, "the far edge stays inside the display in point space")
        runner.expectClose(Double(middle.x), -960.5, "the centre maps through point width, not pixel width")
        runner.expectClose(Double(middle.y), 299.5, "the centre maps through point height, not pixel height")

        runner.expect(left.point(x: 1.000_001, y: 0) == nil, "an out-of-range coordinate must not map")
        runner.expect(left.point(x: -0.000_001, y: 0) == nil, "a negative coordinate must not map")
        runner.expect(left.point(x: .nan, y: 0) == nil, "a non-finite coordinate must not map")
        runner.expect(left.point(x: 0, y: .infinity) == nil, "a non-finite coordinate must not map")
    }

    await runner.check("Live display corners map inside the display's own bounds") {
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned })
        model.refreshInventory()
        guard let info = model.displays.first else {
            runner.expect(false, "no live display available for mapping")
            return
        }
        let bounds = CGDisplayBounds(info.id)
        let corners: [(Double, Double)] = [(0, 0), (1, 0), (0, 1), (1, 1), (0.5, 0.5)]
        for (x, y) in corners {
            guard let point = info.point(x: x, y: y) else {
                runner.expect(false, "normalized (\(x), \(y)) must map on a live display")
                continue
            }
            runner.expect(
                point.x >= bounds.minX && point.x <= bounds.maxX - 1,
                "normalized (\(x), \(y)) mapped x \(point.x) outside \(bounds.minX)...\(bounds.maxX - 1)"
            )
            runner.expect(
                point.y >= bounds.minY && point.y <= bounds.maxY - 1,
                "normalized (\(x), \(y)) mapped y \(point.y) outside \(bounds.minY)...\(bounds.maxY - 1)"
            )
        }
    }

    await runner.check("Repeated permission checks at one instant share a single preflight") {
        let probe = InputPermissionFakes()
        var cache = probe.makeCache()
        let start = probe.clock

        // The pair every input event makes: CompanionModel.receive, then InputOutput.apply.
        let seenByReceive = cache.isAllowed()
        let seenByApply = cache.isAllowed()
        runner.expect(seenByReceive, "receive must see the granted permission")
        runner.expect(seenByApply, "apply must see the same granted permission")
        runner.expectEqual(probe.preflights, 1, "preflights for one event's pair of checks")
        runner.expectEqual(probe.trustReads, 2, "Accessibility reads for one event's pair")

        // CompanionModel admits at most 240 input events a second. 239 further pairs a
        // millisecond apart stay inside one window, so the whole burst keeps reusing that one
        // preflight instead of paying about 7.4ms of main-actor time per check.
        for _ in 0..<239 {
            probe.clock += 0.001
            let allowedForReceive = cache.isAllowed()
            let allowedForApply = cache.isAllowed()
            runner.expect(allowedForReceive && allowedForApply, "every event in the burst must be allowed")
        }
        runner.expect(
            probe.clock - start < InputPermissionCache.maximumAge,
            "the burst must stay inside one window for this check to mean anything"
        )
        runner.expectEqual(probe.preflights, 1, "preflights across 480 checks in one window")
        runner.expectEqual(probe.trustReads, 480, "Accessibility reads across 480 checks")
    }

    await runner.check("A cached preflight expires exactly at the window bound") {
        runner.expect(InputPermissionCache.maximumAge > 0, "the window must be usable")
        runner.expect(InputPermissionCache.maximumAge <= 0.25, "the window must not exceed 0.25s")

        let probe = InputPermissionFakes()
        var cache = probe.makeCache()
        let start = probe.clock
        runner.expect(cache.isAllowed(), "the first call must preflight and allow")
        runner.expectEqual(probe.preflights, 1, "the first call preflights once")

        // Inside the window the held answer is deliberately preferred to another 7.4ms call,
        // so a revocation only the preflight can report is not visible yet.
        probe.canPostEvents = false
        probe.clock = start + InputPermissionCache.maximumAge * 0.99
        runner.expect(cache.isAllowed(), "just inside the window the held grant still serves")
        runner.expectEqual(probe.preflights, 1, "no preflight inside the window")

        // At the bound the entry is gone, so the revoked preflight is observed.
        probe.clock = start + InputPermissionCache.maximumAge
        runner.expect(!cache.isAllowed(), "at the bound the preflight runs again and now denies")
        runner.expectEqual(probe.preflights, 2, "the bound forces exactly one more preflight")

        runner.expect(!cache.isAllowed(), "the refreshed denial is itself reused")
        runner.expectEqual(probe.preflights, 2, "the refreshed answer serves the next check")
    }

    await runner.check("A denied preflight is cached and expires like a granted one") {
        let probe = InputPermissionFakes()
        probe.canPostEvents = false
        var cache = probe.makeCache()
        let start = probe.clock

        runner.expect(!cache.isAllowed(), "a denied preflight must deny")
        runner.expect(!cache.isAllowed(), "the denial is reused, so a denied run pays one preflight too")
        runner.expectEqual(probe.preflights, 1, "preflights while denied")

        // Quartz stays authoritative: a grant made in System Settings is picked up when the
        // window ends, and requestPermission() invalidates around its own prompt.
        probe.canPostEvents = true
        probe.clock = start + InputPermissionCache.maximumAge
        runner.expect(cache.isAllowed(), "a new grant must be observed once the window ends")
        runner.expectEqual(probe.preflights, 2, "the window end forces one more preflight")
    }

    await runner.check("Invalidating forces the next check to preflight again") {
        let probe = InputPermissionFakes()
        var cache = probe.makeCache()
        runner.expect(cache.isAllowed(), "the first call must preflight and allow")

        // What requestPermission() does on both sides of the system prompt, here with the
        // clock standing still: the held grant must not outlive the invalidation.
        cache.invalidate()
        probe.canPostEvents = false
        runner.expect(!cache.isAllowed(), "an invalidated cache must ask Quartz again")
        runner.expectEqual(probe.preflights, 2, "invalidation costs exactly one extra preflight")

        cache.invalidate()
        cache.invalidate()
        runner.expectEqual(probe.preflights, 2, "invalidating never calls Quartz by itself")
        runner.expect(!cache.isAllowed(), "the next check after repeated invalidation still asks")
        runner.expectEqual(probe.preflights, 3, "only that next check preflights, once")
    }

    await runner.check("Losing Accessibility denies at once and drops the cached grant") {
        let probe = InputPermissionFakes()
        var cache = probe.makeCache()
        runner.expect(cache.isAllowed(), "the granted state must be allowed")
        runner.expectEqual(probe.preflights, 1, "preflights while granted")

        // Revoked mid-window with the clock standing still: the held grant must not serve, and
        // the denial must not wait for the window to end.
        probe.isTrusted = false
        runner.expect(!cache.isAllowed(), "an untrusted process must be denied immediately")
        runner.expect(!cache.isAllowed(), "and must stay denied while trust is gone")
        runner.expectEqual(probe.preflights, 1, "denial by lost trust must not pay for a preflight")
        runner.expectEqual(probe.trustReads, 3, "trust is read on every call, not cached")

        // Trust returning inside the same window must re-ask rather than reuse the old grant.
        probe.isTrusted = true
        probe.canPostEvents = false
        runner.expect(!cache.isAllowed(), "the dropped entry must force a fresh preflight")
        runner.expectEqual(probe.preflights, 2, "exactly one preflight once trust returns")
    }

    await runner.check("A clock reading that moves backwards forces a refresh") {
        let probe = InputPermissionFakes()
        var cache = probe.makeCache()
        runner.expect(cache.isAllowed(), "the first call must preflight and allow")

        // A negative age can only mean the reading is not the monotonic source this assumes,
        // so the entry is retired instead of being pinned for however far back it jumped.
        probe.clock -= InputPermissionCache.maximumAge
        probe.canPostEvents = false
        runner.expect(!cache.isAllowed(), "a backwards reading must re-ask, not hold the old answer")
        runner.expectEqual(probe.preflights, 2, "the backwards reading forces one more preflight")
    }
}

/// Fake Quartz probes and a hand-advanced clock for `InputPermissionCache`.
///
/// Every permission check above drives the cache through these instead of the real
/// `AXIsProcessTrusted()` and `CGPreflightPostEventAccess()`, so the results never depend on
/// this Mac's own Accessibility grant, nothing is ever posted, and nobody is ever prompted.
/// Not `@MainActor`, and never shared: the cache calls these closures synchronously, so the
/// counters below are only touched by the one check that owns the instance.
final class InputPermissionFakes {
    var isTrusted = true
    var canPostEvents = true

    /// A plausible `ProcessInfo.systemUptime` reading, advanced by hand. Exactly representable,
    /// so an age compared against the window bound is exact rather than off by a rounding.
    var clock: TimeInterval = 100

    private(set) var trustReads = 0
    private(set) var preflights = 0

    func makeCache() -> InputPermissionCache {
        InputPermissionCache(
            isTrusted: { self.trustReads += 1; return self.isTrusted },
            canPostEvents: { self.preflights += 1; return self.canPostEvents },
            now: { self.clock }
        )
    }
}
