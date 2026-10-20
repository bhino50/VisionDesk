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

    struct Entry {
        let owner: UUID
        let sessionID: String
    }

    @Published private(set) var entries: [Key: Entry] = [:]
    @Published private(set) var message: String?
    private var pending: [Key: TimeInterval] = [:]
    private var sessions: [String: UISceneSession] = [:]
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
                guard let session = self?.sessions[id] else { return }
                UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: session)) { [weak self] _ in
                    self?.message = "This window could not be brought forward. Find it in your space or close it before opening it again."
                }
            }
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
        if let started = pending[key], now() - started < 5 { return }
        pending[key] = now()
        create()
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
        var sessionID: String?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            bindAfterViewUpdate()
        }

        func bindAfterViewUpdate() {
            // Registration publishes window state. Defer it beyond SwiftUI's current update.
            Task { @MainActor [weak self] in
                guard let self, let registry = self.registry, let key = self.key,
                      let session = self.window?.windowScene?.session else { return }
                if let previous = self.boundKey, previous != key {
                    registry.unregister(previous, owner: self.owner)
                }
                self.sessionID = session.persistentIdentifier
                self.boundKey = key
                registry.attach(key, owner: self.owner, session: session)
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
        if let registry = view.registry, let key = view.boundKey { registry.unregister(key, owner: view.owner) }
        if let id = view.sessionID { view.registry?.releaseSession(id) }
        view.registry = nil
    }
}
