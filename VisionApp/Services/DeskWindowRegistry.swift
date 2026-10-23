import Combine
import Foundation
import SwiftUI
import UIKit

/// One native scene for the overview and for each physical Mac display. Reserve an opening
/// before SwiftUI constructs it, so rapid taps cannot enqueue duplicate windows.
@MainActor
final class DeskWindowRegistry: ObservableObject {
    enum Key: Hashable {
        case overview
        case display(UInt32)
    }

    struct Entry: Equatable {
        let owner: UUID
        let sessionID: String
    }

    @Published private(set) var entries: [Key: Entry] = [:]
    @Published private(set) var message: String?
    private struct Opening { let started: TimeInterval; let token: UUID }
    private var pending: [Key: Opening] = [:]
    private var sessions: [String: UISceneSession] = [:]
    private var sceneDisconnectObserver: AnyCancellable?
    private let now: () -> TimeInterval
    var activate: (String) -> Void
    var destroy: (String) -> Void

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         activate: ((String) -> Void)? = nil, destroy: ((String) -> Void)? = nil) {
        self.now = now
        self.activate = activate ?? { _ in }
        self.destroy = destroy ?? { _ in }
        if activate == nil {
            self.activate = { [weak self] id in
                guard let self else { return }
                let captured = self.entries.filter { $0.value.sessionID == id }
                guard let session = self.sessions[id] else {
                    self.activationFailed(captured)
                    return
                }
                UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: session)) { [weak self] _ in
                    self?.activationFailed(captured)
                }
            }
        }
        sceneDisconnectObserver = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)
            .sink { [weak self] notification in
                guard let scene = notification.object as? UIScene else { return }
                let id = scene.session.persistentIdentifier
                Task { @MainActor [weak self] in self?.sceneDisconnected(id) }
            }
        if destroy == nil {
            self.destroy = { [weak self] id in
                guard let session = self?.sessions[id] else { return }
                UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { [weak self] _ in
                    self?.message = "This window could not be closed. Use its system close button."
                }
            }
        }
    }

    /// A failed request must only invalidate the registration it actually attempted.
    func activationFailed(_ captured: [Key: Entry]) {
        var removed = false
        for (key, entry) in captured where entries[key] == entry {
            entries[key] = nil
            releaseSession(entry.sessionID)
            removed = true
        }
        if removed {
            message = "This window could not be opened. Choose the screen again to open a new window."
        }
    }

    func sceneDisconnected(_ id: String) {
        for key in entries.keys.filter({ entries[$0]?.sessionID == id }) {
            entries[key] = nil
        }
        sessions[id] = nil
    }

    var openDisplayCount: Int {
        entries.keys.filter { if case .display = $0 { return true }; return false }.count
    }

    func isOpen(_ id: UInt32) -> Bool { entries[.display(id)] != nil }

    func open(_ key: Key, create: () -> Void) {
        message = nil
        if let existing = entries[key] {
            activate(existing.sessionID)
            return
        }
        // A failed native creation must not permanently disable a screen's button.
        if let opening = pending[key], now() - opening.started < 5 { return }
        pending[key] = Opening(started: now(), token: UUID())
        create()
    }

    func openingToken(for key: Key) -> UUID? { pending[key]?.token }

    func creationFailed(_ key: Key, token: UUID) {
        guard entries[key] == nil, pending[key]?.token == token else { return }
        pending[key] = nil
        message = "This screen could not open. Choose it again to retry."
    }

    /// Returns false for a duplicate scene; the bridge closes only that duplicate instance.
    @discardableResult
    func register(_ key: Key, owner: UUID, sessionID: String) -> Bool {
        if let existing = entries[key], existing.sessionID == sessionID, existing.owner == owner { return true }
        if let existing = entries[key], existing.sessionID != sessionID {
            destroy(sessionID)
            activate(existing.sessionID)
            return false
        }
        pending[key] = nil
        entries[key] = Entry(owner: owner, sessionID: sessionID)
        return true
    }

    func attach(_ key: Key, owner: UUID, session: UISceneSession) {
        sessions[session.persistentIdentifier] = session
        register(key, owner: owner, sessionID: session.persistentIdentifier)
    }

    func unregister(_ key: Key, owner: UUID) {
        guard let entry = entries[key], entry.owner == owner else { return }
        entries[key] = nil
        sessions[entry.sessionID] = nil
    }

    func releaseSession(_ id: String) {
        guard !entries.values.contains(where: { $0.sessionID == id }) else { return }
        sessions[id] = nil
    }

    func close(_ key: Key) {
        guard let entry = entries[key] else { return }
        destroy(entry.sessionID)
        // Keep the reservation until UIKit actually removes the view; a second tap while
        // the close is in flight must not create a replacement behind the closing scene.
    }

    func closeAllDisplays() {
        for key in Array(entries.keys) {
            if case .display = key { close(key) }
        }
    }
}

/// Binds the SwiftUI value window to its actual UIKit scene without changing global focus.
@MainActor
struct DeskWindowAnchor: UIViewRepresentable {
    let registry: DeskWindowRegistry
    let key: DeskWindowRegistry.Key
    final class Anchor: UIView {
        let owner = UUID()
        var registry: DeskWindowRegistry?
        var key: DeskWindowRegistry.Key?
        var boundKey: DeskWindowRegistry.Key?
        weak var boundRegistry: DeskWindowRegistry?
        var sessionID: String?
        private var isDismantled = false
        override func didMoveToWindow() {
            super.didMoveToWindow()
            bindAfterViewUpdate()
        }

        func bindAfterViewUpdate() {
            guard !isDismantled else { return }
            // Registration publishes window state. Defer it beyond SwiftUI's current update.
            Task { @MainActor [weak self] in
                guard let self, !self.isDismantled else { return }
                let session = self.window?.windowScene?.session
                self.reconcileBinding(sessionID: session?.persistentIdentifier) {
                    guard let session, let registry = self.registry, let key = self.key else { return }
                    registry.attach(key, owner: self.owner, session: session)
                }
            }
        }

        /// Deferred callers read the current window, so a same-turn detach/reattach retains it.
        func reconcileBinding(sessionID nextSessionID: String?, attach: () -> Void) {
            guard !isDismantled else { return }
            let sameRegistry = boundRegistry === registry
            if let previous = boundKey,
               nextSessionID == nil || previous != key || sessionID != nextSessionID || !sameRegistry {
                boundRegistry?.unregister(previous, owner: owner)
                if let sessionID { boundRegistry?.releaseSession(sessionID) }
                boundKey = nil
                sessionID = nil
                boundRegistry = nil
            }
            guard let nextSessionID, let registry, let key else { return }
            sessionID = nextSessionID
            boundKey = key
            boundRegistry = registry
            attach()
        }

        func dismantleAfterViewUpdate() {
            guard !isDismantled else { return }
            isDismantled = true
            let previousRegistry = boundRegistry
            let previousKey = boundKey
            let previousSessionID = sessionID
            let previousOwner = owner
            // Detach locally now, so a previously queued binding cannot reclaim this view.
            // Registry removal publishes and must wait until SwiftUI finishes dismantling.
            registry = nil
            key = nil
            boundRegistry = nil
            boundKey = nil
            sessionID = nil
            guard let previousRegistry, let previousKey else { return }
            Task { @MainActor in
                previousRegistry.unregister(previousKey, owner: previousOwner)
                if let previousSessionID { previousRegistry.releaseSession(previousSessionID) }
            }
        }
    }

    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.isUserInteractionEnabled = false
        view.registry = registry
        view.key = key
        return view
    }

    func updateUIView(_ view: Anchor, context: Context) {
        view.registry = registry
        view.key = key
        view.bindAfterViewUpdate()
    }

    static func dismantleUIView(_ view: Anchor, coordinator: ()) {
        view.dismantleAfterViewUpdate()
    }
}
