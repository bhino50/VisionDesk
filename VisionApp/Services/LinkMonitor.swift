import Foundation

/// Decides, from inbound message times alone, whether the linked Mac is still talking.
///
/// A healthy Mac is never quiet for long. Every shared display repeats its last picture about
/// once a second even when nothing on it changes, and the client already treats 2.5 seconds
/// without a picture as a paused screen. Total silence — no picture for any display and no
/// status — is therefore evidence about the link rather than about one screen.
///
/// The transport cannot see that by itself. Only the headset sends heartbeats, so its socket is
/// never idle and TCP keepalive never fires: a Mac that vanishes without closing the connection
/// (a hard sleep, a VPN path that drops) leaves the session looking linked until TCP gives up,
/// minutes later. The Mac, by contrast, drops a headset it has not heard from for ten seconds.
/// This type is the client's half of that symmetry, kept pure so its rules can be tested
/// without a clock or a network.
///
/// It only recommends. The model decides what a session may do about silence, and a session
/// that cannot reconnect on its own is never offered anything beyond `quiet`.
struct LinkMonitor: Equatable {
    struct Policy: Equatable {
        /// Silence after which the Mac is reported as not responding.
        var quietAfter: TimeInterval
        /// Silence after which a session that can reconnect on its own is recycled. Longer
        /// than the Mac's own ten-second limit, so a Mac that already gave up on a dead path
        /// has always released its single session slot before the reconnection arrives.
        var recoverAfter: TimeInterval
        /// Recycles allowed before a recovered session has carried ordinary traffic again.
        /// The cap is what stops a live Mac whose screens are genuinely paused from being
        /// redialled forever: after it, the silence is only reported.
        var maximumAutomaticRecoveries: Int

        static let standard = Policy(quietAfter: 4, recoverAfter: 15, maximumAutomaticRecoveries: 2)
    }

    enum Assessment: Equatable {
        /// Traffic is arriving.
        case responsive
        /// Report the silence; do nothing else.
        case quiet
        /// Recycle the session and let the ordinary reconnection schedule bring it back.
        case recover
    }

    let policy: Policy
    /// When the current session authenticated, or nil while there is no session.
    private(set) var linkedAt: TimeInterval?
    private(set) var lastInbound: TimeInterval?
    /// Recycles since a session last proved healthy. Survives the recycle itself on purpose.
    private(set) var automaticRecoveries = 0

    init(policy: Policy = .standard) {
        self.policy = policy
    }

    /// A completed handshake is itself evidence that the Mac answered.
    mutating func linked(at now: TimeInterval) {
        linkedAt = now
        lastInbound = now
    }

    mutating func received(at now: TimeInterval) {
        guard linkedAt != nil, now.isFinite else { return }
        // Never moves backwards, so a reordered timestamp cannot manufacture silence.
        lastInbound = max(lastInbound ?? now, now)
    }

    mutating func unlinked() {
        linkedAt = nil
        lastInbound = nil
    }

    /// Someone asked to connect. A deliberate attempt gets the whole allowance again.
    mutating func resetAutomaticRecoveries() {
        automaticRecoveries = 0
    }

    /// Whether `assess` could still answer `recover` for a session allowed to reconnect.
    var allowsAutomaticRecovery: Bool {
        automaticRecoveries < policy.maximumAutomaticRecoveries
    }

    /// Seconds since anything arrived, or nil while there is no session. A clock that appears
    /// to run backwards reads as no silence at all, which is the direction that recycles nothing.
    func silence(at now: TimeInterval) -> TimeInterval? {
        guard let lastInbound, now.isFinite else { return nil }
        return max(0, now - lastInbound)
    }

    mutating func assess(at now: TimeInterval, canRecover: Bool) -> Assessment {
        guard let linkedAt, let silence = silence(at: now) else { return .responsive }
        guard silence >= policy.quietAfter else {
            // Traffic this long after authenticating is no longer the burst every Mac sends on
            // attach, so the link has demonstrably recovered and earns its allowance back.
            if now - linkedAt >= policy.recoverAfter { automaticRecoveries = 0 }
            return .responsive
        }
        guard canRecover, silence >= policy.recoverAfter, allowsAutomaticRecovery else { return .quiet }
        automaticRecoveries += 1
        return .recover
    }
}
