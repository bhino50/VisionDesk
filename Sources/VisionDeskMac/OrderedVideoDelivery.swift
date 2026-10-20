import Foundation
import DeskCore

/// Each display owns two queue slots. An overloaded stream cannot starve the
/// keyframe another display needs; a keyframe always replaces its own pending chain.
final class OrderedVideoDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UInt32: [EncodedVideoFrame]] = [:]
    private var dropped = Set<UInt32>()
    private var needsKeyframe = Set<UInt32>()
    private var scheduled = false
    private let deliver: @MainActor @Sendable ([(UInt32, EncodedVideoFrame)], Set<UInt32>) -> Void
    init(deliver: @escaping @MainActor @Sendable ([(UInt32, EncodedVideoFrame)], Set<UInt32>) -> Void) { self.deliver = deliver }
    func submit(id: UInt32, frame: EncodedVideoFrame) {
        lock.lock()
        if needsKeyframe.contains(id), !frame.isKeyframe { lock.unlock(); return }
        if frame.isKeyframe { pending[id] = []; needsKeyframe.remove(id) }
        if pending[id, default: []].count >= 2 {
            dropped.insert(id); needsKeyframe.insert(id); pending[id] = []
        } else { pending[id, default: []].append(frame) }
        let launch = !scheduled
        scheduled = true
        lock.unlock()
        if launch { Task { @MainActor [self] in drain() } }
    }
    @MainActor private func drain() {
        lock.lock()
        let frames = pending.keys.sorted().flatMap { id in pending[id, default: []].map { (id, $0) } }
        let losses = dropped
        pending.removeAll(keepingCapacity: true); dropped.removeAll(); scheduled = false
        lock.unlock()
        deliver(frames, losses)
    }
}

/// A transport refusal breaks this display's reference chain. Keep predicted frames off the
/// wire until a replacement keyframe was actually accepted, independently for every screen.
struct VideoSendRecovery {
    private var needsKeyframe = Set<UInt32>()

    mutating func requireKeyframes(for displays: [UInt32]) { needsKeyframe.formUnion(displays) }
    func allows(id: UInt32, isKeyframe: Bool) -> Bool { isKeyframe || !needsKeyframe.contains(id) }
    mutating func record(id: UInt32, isKeyframe: Bool, sent: Bool) {
        if !sent { needsKeyframe.insert(id) }
        else if isKeyframe { needsKeyframe.remove(id) }
    }
}
