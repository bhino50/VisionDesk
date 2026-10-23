import Combine
import CoreGraphics
import DeskCore
import DeskTransport
import Foundation
import Network
import SwiftUI

@MainActor
final class DeskClientModel: ObservableObject {
    @Published private(set) var peers: [NearbyMac] = []
    @Published var selectedPeerID: String?
    @Published var pairingCode = ""
    /// The host, or host and port, typed for a direct connection. Over a VPN the
    /// owner already runs, this is how the headset reaches a Mac that Bonjour
    /// cannot see — which is every Mac that is not on this same local link.
    @Published var directAddress = ""
    /// Whether a verified connection whose Mac keeps its pairing is saved for next time. There is
    /// no switch for it in the app, where it is always on; tests turn it off.
    @Published var remembersThisMac = true
    @Published private(set) var rememberedMac: RememberedMac?
    @Published private(set) var isReconnecting = false
    @Published private(set) var reconnectAttempt = 0
    @Published private(set) var retryExhausted = false
    @Published private(set) var discoveryStatus = "Looking for nearby Macs…"
    @Published private(set) var connectionMessage: String?
    /// Retained across automatic attempts so backoff copy never hides the transport failure.
    @Published private(set) var lastConnectionFailure: String?
    @Published private(set) var pairingPersistenceWarning: String?
    @Published private(set) var connectedName = ""
    @Published private(set) var isConnecting = false
    @Published private(set) var isLinked = false
    @Published private(set) var isMacControlEnabled = false
    @Published private(set) var statusText = ""
    @Published private(set) var displays: [DisplayStream] = []
    @Published private(set) var hasActiveWindow = false
    /// False once nothing at all — no picture for any display, no status — has arrived from
    /// the linked Mac for longer than a healthy one is ever quiet. True whenever there is no
    /// session. Published only when it changes, from the heartbeat's own check.
    @Published private(set) var isMacResponsive = true
    /// Displays whose pointer has been placed in this session: the only displays where a click
    /// can land without moving the pointer first. Changes only when one is placed or forgotten.
    @Published private(set) var pointedDisplayIDs: Set<UInt32> = []

    /// Bounded, growing waits for one dropped link: five tries across about half a
    /// minute. Re-entering the foreground grants a fresh budget, which is what
    /// makes a Mac that was asleep for a while reachable again without this app
    /// retrying forever in the meantime.
    nonisolated static let reconnectDelays: [UInt64] = [1, 2, 4, 8, 16]
    /// One remembered Mac, one Keychain item. A fixed account cannot orphan a
    /// secret behind a changed address.
    private static let rememberedAccount = "remembered-mac"

    private let browser = DeskBrowser()
    private let retryDelays: [UInt64]
    private let keys: PairingKeyStore
    private let preferences: any RememberedMacStore
    private let makeConnection: @MainActor (NWEndpoint, PairingKey) -> DeskConnection
    private var subscriptions = Set<AnyCancellable>()
    private var lastKeyframeRequests: [UInt32: TimeInterval] = [:]
    private var connection: DeskConnection?
    private var connectionID: UUID?
    private var heartbeatTask: Task<Void, Never>?
    private var backgroundDisconnectTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retry: RetryTarget?
    private var isBrowsing = false
    /// From the wearer's Stop until the Mac answers it; see `stopControl`. Readable so the views
    /// can say so, and set only here.
    private(set) var stopAwaitingAcknowledgement = false
    private var scenePhases: [UUID: ScenePhase] = [:]
    /// Gestures, clicks and typing. Gated by this model and sending only through it. Internal
    /// only so the entry points in `DeskClientModel+Input.swift` can forward to it.
    let pointer = PointerInput()
    let keyboard = KeyboardDelivery()
    @Published private(set) var keyboardNotice: String?
    @Published private(set) var keyboardPendingCount = 0
    private struct KeyboardPresentation {
        var pendingCount = 0
        var notice: String?
    }
    private enum KeyboardPresentationChange {
        case pendingCount(Int)
        case notice(String?)
    }
    private var latestKeyboardPresentation = KeyboardPresentation()
    private var keyboardViewCancellationDepth = 0
    private var keyboardPresentationTask: Task<Void, Never>?
    private var keyboardPresentationGeneration: UInt64 = 0
    let dockLauncher: MacDockLauncherModel
    /// Inbound silence for the current session; see `checkMacResponsiveness`.
    private var monitor: LinkMonitor
    /// How the current or most recent session reached its Mac. See `MacRoute`.
    private var sessionRoute: MacRoute?
    /// How each Mac the wearer stopped control on was reached, until that Mac grants control again.
    ///
    /// A Stop sent into a dead link never arrives, and a Mac that never read it re-arms control
    /// for the next connection and enables it on the first heartbeat. So every later session that
    /// reaches such a Mac the same way — automatic or deliberate, after a drop, a recycle, Cancel
    /// or Disconnect, after sessions with other Macs, and after this app is relaunched — opens by
    /// repeating the Stop before its first heartbeat, and believes no grant until the Mac has
    /// answered. Only a grant accepted after that answer ends it: the Mac's status on attach and
    /// its own revocations also read "not enabled", so an answer alone cannot prove the Stop
    /// arrived. Repeating a Stop the Mac already holds re-applies the same pause. Kept in the
    /// preference store as non-secret routes, loaded at launch and written before a Stop is sent.
    /// Nothing the Mac sends names it, so the same Mac reached another way — discovered once,
    /// typed the next time — is not recognized.
    private var stoppedRoutes: Set<MacRoute> = []

    /// How a channel is built. The default is the production construction and nothing else
    /// uses it, so every gate below behaves identically whichever way the model was made.
    /// A caller may supply its own factory to observe or constrain the real `DeskConnection`
    /// it gets — a smaller send queue, for instance — without relaxing authentication,
    /// which `DeskConnection` enforces either way. `linkPolicy` sets how long the Mac may be
    /// silent; tests shorten it, and nothing about authentication depends on it.
    init(keys: PairingKeyStore = PairingKeyStore(),
         preferences: any RememberedMacStore = UserDefaultsRememberedMacStore(),
         linkPolicy: LinkMonitor.Policy = .standard,
         retryDelays: [UInt64] = DeskClientModel.reconnectDelays,
         dockLaunchTimeoutNanoseconds: UInt64 = 10_000_000_000,
         makeConnection: @escaping @MainActor (NWEndpoint, PairingKey) -> DeskConnection
            = { DeskConnection(endpoint: $0, key: $1) }) {
        self.dockLauncher = MacDockLauncherModel(timeoutNanoseconds: dockLaunchTimeoutNanoseconds)
        self.retryDelays = retryDelays
        self.keys = keys
        self.preferences = preferences
        self.monitor = LinkMonitor(policy: linkPolicy)
        self.makeConnection = makeConnection
        // Every gate the input pipeline applies is this model's, and its only way to the Mac is
        // this model's send, so a failed send is handled exactly once, here.
        dockLauncher.canLaunch = { [weak self] in
            guard let self else { return false }
            return self.canControl && self.isMacResponsive
        }
        dockLauncher.canRefresh = { [weak self] in
            guard let self else { return false }
            return self.hasActiveWindow && self.isLinked && self.isMacResponsive
        }
        dockLauncher.send = { [weak self] in self?.send($0) ?? false }
        dockLauncher.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        keyboard.canControl = { [weak self] id in self?.canControl(displayID: id) ?? false }
        keyboard.send = { [weak self] in self?.send($0) ?? false }
        keyboard.onFailure = { [weak self] in self?.updateKeyboardPresentation(.notice($0)) }
        keyboard.onAccepted = { [weak self] in self?.updateKeyboardPresentation(.notice(nil)) }
        keyboard.onPendingChanged = { [weak self] in self?.updateKeyboardPresentation(.pendingCount($0)) }
        pointer.canControl = { [weak self] id in self?.canControl(displayID: id) ?? false }
        pointer.isLinked = { [weak self] in self?.isLinked ?? false }
        pointer.send = { [weak self] message in self?.send(message) ?? false }
        pointer.onPointedDisplaysChanged = { [weak self] ids in self?.pointedDisplayIDs = ids }
        // Metadata only, so showing the saved Mac costs no Keychain access and
        // raises no unlock prompt before anyone asks to connect.
        rememberedMac = preferences.load()
        // A Stop a Mac may never have read outlives the process that sent it.
        stoppedRoutes = preferences.loadStoppedRoutes()
        browser.$results.sink { [weak self] results in
            guard let self else { return }
            // Stopping discovery to dial a Mac publishes an empty list. Keeping the last one shows
            // the Mac being dialled rather than an empty search, and keeps it chosen for another
            // try. Restarting discovery clears it as before.
            guard self.isBrowsing || !results.isEmpty else { return }
            self.peers = NearbyMacList.peers(from: results.map(\.endpoint))
            let selection = NearbyMacList.selection(keeping: self.selectedPeerID, in: self.peers)
            if selection != self.selectedPeerID { self.selectedPeerID = selection }
        }.store(in: &subscriptions)
        browser.$status.sink { [weak self] in self?.discoveryStatus = $0 }
            .store(in: &subscriptions)
    }

    /// Native receiver configuration and dismantling can happen during a SwiftUI render.
    /// Stop delivery immediately, but publish its UI snapshot after that render returns.
    func cancelKeyboardInputFromView(displayID: UInt32) {
        keyboardViewCancellationDepth += 1
        defer { keyboardViewCancellationDepth -= 1 }
        keyboard.cancel(displayID: displayID)
    }

    private func updateKeyboardPresentation(_ change: KeyboardPresentationChange) {
        switch change {
        case .pendingCount(let count): latestKeyboardPresentation.pendingCount = count
        case .notice(let notice): latestKeyboardPresentation.notice = notice
        }
        if keyboardViewCancellationDepth == 0 {
            // A later accepted edit, acknowledgement or session change supersedes a queued
            // view-cancellation snapshot. Ordinary model operations remain synchronous.
            keyboardPresentationGeneration &+= 1
            keyboardPresentationTask?.cancel()
            keyboardPresentationTask = nil
            publishKeyboardPresentation()
            return
        }
        guard keyboardPresentationTask == nil else { return }
        keyboardPresentationGeneration &+= 1
        let generation = keyboardPresentationGeneration
        keyboardPresentationTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self,
                  self.keyboardPresentationGeneration == generation else { return }
            self.keyboardPresentationTask = nil
            // Read the latest snapshot: one cancellation can report both count and notice.
            self.publishKeyboardPresentation()
        }
    }

    private func publishKeyboardPresentation() {
        if keyboardPendingCount != latestKeyboardPresentation.pendingCount {
            keyboardPendingCount = latestKeyboardPresentation.pendingCount
        }
        if keyboardNotice != latestKeyboardPresentation.notice {
            keyboardNotice = latestKeyboardPresentation.notice
        }
    }

    /// Both ways in that take a typed key wait for a whole one, so Connect is never offered for a
    /// key that could only be refused. The line under the field says what is still missing.
    var canConnect: Bool {
        hasActiveWindow && !isLinked && !isConnecting
            && peers.contains(where: { $0.id == selectedPeerID })
            && PairingKey(string: pairingCode) != nil
    }

    /// The typed address, parsed. Nil while the text is incomplete or malformed.
    /// A parsed address says nothing about whether the Mac is reachable, or about
    /// whether any VPN is connected; only a completed handshake shows that.
    var directMacAddress: RemoteMacAddress? { RemoteMacAddress(string: directAddress) }

    var canConnectDirectly: Bool {
        hasActiveWindow && !isLinked && !isConnecting
            && directMacAddress != nil
            && PairingKey(string: pairingCode) != nil
    }

    var canConnectRemembered: Bool {
        hasActiveWindow && !isLinked && !isConnecting && rememberedMac != nil
    }

    var canControl: Bool {
        hasActiveWindow && isLinked && isMacControlEnabled && !stopAwaitingAcknowledgement
    }

    var dockApps: [DockAppInfo] { dockLauncher.apps }

    var canLaunchDockApps: Bool {
        dockLauncher.isAvailable && !dockLauncher.isLaunching && canControl && isMacResponsive
    }

    func refreshDockApps() { dockLauncher.refresh() }

    func launchDockApp(id: String, displayID: UInt32? = nil) {
        guard canLaunchDockApps else { return }
        if displayID != nil, !dockLauncher.supportsPlacement { return }
        if let displayID, display(id: displayID) == nil { return }
        // Switching the focused Mac app cannot leave a remote drag held in the old app.
        keyboard.cancel()
        pointer.releaseGesture()
        dockLauncher.launch(appID: id, displayID: displayID)
    }

    func display(id: UInt32) -> DisplayStream? {
        displays.first { $0.id == id }
    }

    func canControl(displayID: UInt32) -> Bool {
        canControl && display(id: displayID)?.isFresh() == true
    }

    /// Whether this display's pointer has been placed in this session — by a Pointer pan, a
    /// Drag or a Scroll — so that a click has an existing position to land on.
    func hasPointerPosition(displayID: UInt32) -> Bool {
        pointer.hasPosition(displayID: displayID)
    }

    /// Whether a click — a Pointer tap, the toolbar's buttons, an assistive action — would be
    /// accepted on this display right now. Every click lands where the pointer already is, so
    /// a display whose pointer has not been placed has nowhere honest to click.
    func canPlacePointer(displayID: UInt32) -> Bool {
        canControl(displayID: displayID) && pointer.canPerformDiscreteAction
    }

    func canClick(displayID: UInt32) -> Bool {
        canControl(displayID: displayID) && pointer.canPerformDiscreteAction && hasPointerPosition(displayID: displayID)
    }

    /// Whether `reconnectNow` would dial: a target worth retrying is still in memory — a Mac
    /// reached in this session, or the saved Mac — a window is in front, and no attempt is in
    /// flight. The same eligibility as the automatic schedule, so the two never disagree.
    var canReconnectNow: Bool {
        hasActiveWindow && !isConnecting && retry?.isRetryable == true
    }

    /// Whether `resumeControl` would ask the Mac. Not while a Stop from this headset is still
    /// unanswered: a request queued behind it would only race the Stop it follows.
    var canResumeControl: Bool {
        isLinked && hasActiveWindow && !stopAwaitingAcknowledgement
    }

    /// Whether a silent session will be recycled on its own if the silence continues.
    var willRecoverAutomatically: Bool {
        canReconnectNow && monitor.allowsAutomaticRecovery
    }

    /// Connection category only; diagnostics never need to expose private host addresses.
    var connectionRouteLabel: String {
        guard let route = (isLinked || isConnecting ? sessionRoute : nil) ?? retry?.route else {
            return "No connection selected"
        }
        switch route {
        case .service: return "Nearby network"
        case .address: return "Direct connection"
        }
    }

    /// Seconds since the linked Mac last sent anything, or nil while there is no session.
    /// Read on demand rather than published, so a ticking display costs nothing elsewhere.
    func macSilence(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        monitor.silence(at: uptime)
    }

    func updateScene(_ id: UUID, phase: ScenePhase?) {
        backgroundDisconnectTask?.cancel()
        backgroundDisconnectTask = nil
        if let phase { scenePhases[id] = phase }
        else { scenePhases.removeValue(forKey: id) }
        let previouslyActive = hasActiveWindow
        hasActiveWindow = scenePhases.values.contains(.active)
        // Closing an unrelated background screen must not discard typing queued by a
        // still-active screen. Its native receiver handles that keyboard's own focus loss;
        // this model-wide cancellation is for losing every active window.
        if !hasActiveWindow { keyboard.cancel() }
        if hasActiveWindow {
            startDiscovery()
            if !previouslyActive {
                if retryExhausted {
                    reconnectAttempt = 0
                    retryExhausted = false
                }
                resumeRetryIfNeeded()
            }
        } else if previouslyActive {
            // Losing focus is transient. `canControl` already blocks input while no window is
            // active, so only the held button has to be lifted. Latching control off here
            // would make a glance at the Home View require re-enabling control on the Mac.
            pointer.releaseGesture()
            dockLauncher.controlBecameUnavailable()
            // Reconnection is foreground-only. The attempt counter survives, so
            // coming back resumes the same budget rather than starting over.
            cancelRetry()
        }
        if scenePhases.isEmpty || scenePhases.values.allSatisfy({ $0 == .background }) {
            // Scene removal and replacement are separate UIKit events. Let a new window
            // claim the session before treating that transient gap as leaving the app.
            // Input is already disabled and held gestures released above.
            backgroundDisconnectTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
                guard let self, !Task.isCancelled, !self.hasActiveWindow,
                      self.scenePhases.isEmpty || self.scenePhases.values.allSatisfy({ $0 == .background }) else { return }
                self.backgroundDisconnectTask = nil
                self.disconnect(message: "Connect again when you are ready.")
                self.stopDiscovery()
            }
        }
    }

    func refreshDiscovery() {
        guard !isLinked, !isConnecting else { return }
        stopDiscovery()
        startDiscovery()
    }

    func connect() {
        guard hasActiveWindow, !isLinked, !isConnecting,
              let peer = peers.first(where: { $0.id == selectedPeerID }) else { return }
        // Submitting an incomplete key from the field says why nothing happened.
        guard let key = PairingKey(string: pairingCode) else {
            connectionMessage = SessionCopy.incompleteKeyMessage
            return
        }
        connect(to: peer.endpoint, key: key, name: peer.name)
    }

    /// Connects to a Mac at the address the owner typed, rather than by discovery.
    /// Nothing about the address is trusted beyond its syntax: the same PSK TLS
    /// handshake still has to succeed before anything is viewed or remembered.
    func connectDirectly() {
        guard hasActiveWindow, !isLinked, !isConnecting else { return }
        guard let address = directMacAddress else {
            connectionMessage = "Enter your Mac's address or name, for example 100.64.0.42 or mac-studio.tailnet.ts.net. Add a port only if your Mac listens on a different one."
            return
        }
        guard let key = PairingKey(string: pairingCode) else {
            connectionMessage = SessionCopy.incompleteKeyMessage
            return
        }
        pairingPersistenceWarning = nil
        lastConnectionFailure = nil
        reconnectAttempt = 0
        retryExhausted = false
        monitor.resetAutomaticRecoveries()
        attempt(RetryTarget(route: MacRoute(address), name: address.host, key: key,
                            origin: .typed, shouldRemember: remembersThisMac))
    }

    /// Reconnects to the remembered Mac — at its saved address, or by its service on this network —
    /// with the key already in this device's Keychain, so no one has to read it off the Mac.
    func connectRemembered() {
        guard hasActiveWindow, !isLinked, !isConnecting, let remembered = rememberedMac else { return }
        guard remembered.route.endpoint != nil else {
            connectionMessage = "The saved connection to \(remembered.name) is no longer usable. \(SessionCopy.forgetSavedMacAdvice)"
            return
        }
        let stored: PairingKey?
        do {
            stored = try keys.load(account: Self.rememberedAccount)
        } catch {
            connectionMessage = Self.message(for: error, fallback: "The saved pairing key could not be read. \(SessionCopy.forgetSavedMacAdvice)")
            return
        }
        guard let key = stored else {
            connectionMessage = "There is no saved pairing key for \(remembered.name) on this Vision Pro. \(SessionCopy.forgetSavedMacAdvice)"
            return
        }
        lastConnectionFailure = nil
        reconnectAttempt = 0
        retryExhausted = false
        monitor.resetAutomaticRecoveries()
        attempt(RetryTarget(route: remembered.route, name: remembered.name, key: key,
                            origin: .saved, shouldRemember: false))
    }

    /// Dials the same Mac again at once, with the key already in memory for it: one this session
    /// authenticated with, or the saved Mac's.
    ///
    /// Offered while a session that has reached its Mac is silent, and while a reconnection is
    /// waiting out its backoff or has given up. A live session is recycled without telling the
    /// Mac to stop: the Mac releases input whenever a connection closes, and a Stop would pause
    /// its control grant for a reconnection the wearer never meant as a hang-up. A Stop the
    /// wearer did press is repeated first by the new session; see `stoppedRoutes`. A failure
    /// from here joins the ordinary bounded schedule, because this target is worth retrying.
    func reconnectNow() {
        guard canReconnectNow, let target = retry else { return }
        monitor.resetAutomaticRecoveries()
        if isLinked { tearDown(message: nil, notifiesMac: false) }
        cancelRetry()
        reconnectAttempt = 0
        retryExhausted = false
        attempt(target)
        // Reported as a reconnection across the attempt itself, as a scheduled one is.
        guard isConnecting else { return }
        isReconnecting = true
        connectionMessage = "Reconnecting to \(SessionCopy.macName(target.name))."
    }

    /// Stops remembering the saved Mac and removes its key from this device. An
    /// active session keeps viewing; it simply will not come back on its own.
    func forgetRememberedMac() {
        cancelRetry()
        retry = nil
        reconnectAttempt = 0
        retryExhausted = false
        let name = rememberedMac?.name ?? "this Mac"
        do {
            // The key goes first. A cleared preference with a surviving Keychain
            // item would leave a secret on this device that nothing can reach.
            try keys.delete(account: Self.rememberedAccount)
        } catch {
            connectionMessage = Self.message(for: error, fallback: "The saved pairing key could not be removed. Unlock this device and try again.")
            return
        }
        preferences.clear()
        lastConnectionFailure = nil
        rememberedMac = nil
        pairingPersistenceWarning = nil
        connectionMessage = "Forgot \(name). Its pairing key was removed from this Vision Pro."
    }

    /// The single authenticated connection path. `connect()` owns every precondition: an
    /// active window, no existing link, a discovered peer, and a complete pairing key.
    /// This helper adds no gate and relaxes none, so pairing callbacks, the control gates and
    /// the heartbeat behave identically for a discovered Mac and for an authenticated
    /// loopback server under test. Internal callers must still have an active window and
    /// no existing or pending connection; authentication is enforced by DeskConnection.
    ///
    /// A connection made this way is a one-time nearby session, as the Mac's one-time listener
    /// requires: never remembered and never retried on its own, unless the Mac says during it that
    /// it keeps its pairing; see `macKeepsPairing()`.
    func connect(to endpoint: NWEndpoint, key: PairingKey, name: String) {
        guard hasActiveWindow, !isLinked, !isConnecting else { return }
        pairingPersistenceWarning = nil
        lastConnectionFailure = nil
        // Deliberate nearby pairing gets the same fresh silence-recovery allowance as a
        // typed or saved connection. Scheduled retries use the private entry point below.
        monitor.resetAutomaticRecoveries()
        let target = MacRoute(endpoint).map {
            RetryTarget(route: $0, name: name, key: key, origin: .nearby, shouldRemember: false)
        }
        connect(to: endpoint, key: key, name: name, remembering: target)
    }

    private func connect(to endpoint: NWEndpoint, key: PairingKey, name: String, remembering target: RetryTarget?) {
        guard hasActiveWindow, !isLinked, !isConnecting else { return }
        // Only the scheduled wait is dropped here. `isReconnecting` is left alone so
        // the UI keeps reporting a reconnection across the attempt itself.
        retryTask?.cancel()
        retryTask = nil
        retry = target
        let id = UUID()
        let channel = makeConnection(endpoint, key)
        connectionID = id
        connection = channel
        isConnecting = true
        isMacControlEnabled = false
        sessionRoute = target?.route ?? MacRoute(endpoint)
        connectionMessage = nil
        statusText = ""
        connectedName = name
        stopDiscovery()
        channel.onState = { [weak self] state in
            guard let self, self.connectionID == id else { return }
            switch state {
            case .connecting:
                self.isConnecting = true
            case .ready:
                self.lastConnectionFailure = nil
                self.isConnecting = false
                self.isLinked = true
                self.pairingCode = ""
                self.isReconnecting = false
                self.reconnectAttempt = 0
                self.retryExhausted = false
                // From here a drop is a lost link, which this target may come back from.
                self.retry?.hasLinked = true
                self.dockLauncher.beginSession(id)
                self.monitor.linked(at: Self.now())
                self.rememberIfRequested()
                _ = self.connection?.send(DeskMessage(kind: "capabilities", videoCodec: DeskMessage.supportedVideoCodec, dockLauncher: true, keyboardAcknowledgements: true))
                self.replayStopIfPending()
                // Either send above can fail and end this session from inside the call.
                guard self.connectionID == id else { return }
                self.startHeartbeat()
            case .disconnected(let reason):
                self.handleDrop(reason: reason)
            }
        }
        channel.onMessage = { [weak self] message in
            guard let self, self.connectionID == id else { return }
            // Any authenticated arrival proves the link, whatever the message turns out to be.
            self.monitor.received(at: Self.now())
            if !self.isMacResponsive { self.isMacResponsive = true }
            self.receive(message)
        }
        channel.start()
    }

    /// The explicit action. Clears automatic reconnection, so a Mac the owner hung
    /// up on — or a window that went to the background — never comes back by itself.
    func disconnect(message: String? = nil) {
        lastConnectionFailure = nil
        backgroundDisconnectTask?.cancel()
        backgroundDisconnectTask = nil
        cancelRetry()
        retry = nil
        reconnectAttempt = 0
        retryExhausted = false
        tearDown(message: message)
    }

    func resumeControl() {
        guard canResumeControl else { return }
        send(DeskMessage(kind: "requestControl"))
    }

    /// The wearer's Stop. Its intent is recorded, and written to the preference store, before
    /// anything is sent: the release and the Stop below can each fail and end the session from
    /// inside this call, or this process can end before the Stop leaves, and the next session
    /// with this Mac must still open by repeating it. See `stoppedRoutes`.
    func stopControl() {
        keyboard.cancel()
        dockLauncher.controlBecameUnavailable()
        if let sessionRoute, stoppedRoutes.insert(sessionRoute).inserted {
            preferences.saveStoppedRoutes(stoppedRoutes)
        }
        if isLinked {
            isMacControlEnabled = false
            stopAwaitingAcknowledgement = true
            statusText = SessionCopy.controlStoppedStatus
        }
        pointer.releaseGesture()
        guard isLinked else { return }
        send(DeskMessage(kind: "stop"))
    }

    /// Repeats the wearer's Stop on a session that opened while it was still pending. Called
    /// before the heartbeat starts, so the Mac reads the Stop before the first heartbeat, which
    /// is what enables control on a Mac that re-armed it on attach; every other way it grants
    /// control also reaches it after this Stop on the same ordered connection. A failed send is
    /// an ordinary drop, and the Stop is still pending for the session after it.
    private func replayStopIfPending() {
        guard isLinked, let sessionRoute, PendingStopsCodec.requiresStop(for: sessionRoute, in: stoppedRoutes) else { return }
        stopAwaitingAcknowledgement = true
        statusText = SessionCopy.controlStoppedStatus
        send(DeskMessage(kind: "stop"))
    }

    /// The Mac said, inside this authenticated session, that it keeps this pairing: its key and its
    /// listener outlive the session. A session started from the nearby list then comes back by
    /// itself after a drop, on the ordinary bounded schedule, and is saved — the key in the
    /// Keychain, the Bonjour service in preferences — as the Mac this headset reconnects to
    /// without a key. Repeats, and sessions that already keep their pairing, change nothing.
    ///
    /// Run for an authenticated status that carries `keepsPairing`, and for nothing else, so a Mac
    /// that never sends it — any Mac that pairs for one session — stays a one-time nearby session.
    func macKeepsPairing() {
        guard isLinked, var target = retry, target.origin == .nearby, !target.macKeepsPairing else { return }
        target.macKeepsPairing = true
        target.shouldRemember = remembersThisMac
        retry = target
        rememberIfRequested()
    }

    /// Writes the key only now, with TLS already authenticated. A key that never
    /// completed a handshake is not worth remembering, and storing one earlier
    /// would keep a secret for a Mac that may have refused it outright.
    private func rememberIfRequested() {
        guard var target = retry, target.shouldRemember else { return }
        target.shouldRemember = false
        retry = target
        let remembered = RememberedMac(name: target.name, route: target.route)
        do {
            try keys.save(target.key, account: Self.rememberedAccount)
        } catch {
            // Viewing already works. Losing the convenience of remembering is not a
            // reason to drop a session that authenticated.
            pairingPersistenceWarning = "This Mac could not be saved on this Vision Pro. Viewing still works, but you will need its pairing key next time. Pair again to save it."
            return
        }
        preferences.save(remembered)
        rememberedMac = remembered
        pairingPersistenceWarning = nil
    }

    /// An unexpected end. Viewing ends either way.
    ///
    /// A target worth retrying — a Mac this session reached that keeps its pairing, or the saved
    /// Mac — comes back on the bounded schedule while a window is in front. Nothing else has
    /// anything to come back to. A one-time nearby session's Mac has stopped listening, so its end
    /// says how to pair again. An attempt with a typed or discovered key that never authenticated
    /// would repeat the same refusal, so it is reported once, with the typed key left to fix.
    ///
    /// The Mac is not told to stop on the way out. A drop is not the wearer hanging up, and the
    /// Mac releases input whenever a connection closes; a Stop that still reached it would
    /// pause its control grant, so the reconnection would come back viewing only. A Stop the
    /// wearer did press is not lost here either: it is pending on `stoppedRoutes`.
    private func handleDrop(reason: String) {
        lastConnectionFailure = reason
        let target = retry
        let wasEstablished = isLinked
        tearDown(message: reason, notifiesMac: false, keepsPairingCode: !wasEstablished)
        if let target, target.isRetryable {
            guard hasActiveWindow else { return }
            scheduleRetry(target)
            return
        }
        // Nothing keeps the key in memory once nothing can use it.
        retry = nil
        reconnectAttempt = 0
        retryExhausted = false
        isReconnecting = false
        connectionMessage = wasEstablished
            ? SessionCopy.connectionEnded(with: connectedName, reason: reason)
            : SessionCopy.couldNotConnect(to: target?.name ?? connectedName, reason: reason,
                                          route: target?.origin == .typed ? .address : .nearby)
    }

    private func scheduleRetry(_ target: RetryTarget) {
        let total = retryDelays.count
        guard reconnectAttempt < total else {
            isReconnecting = false
            retryExhausted = true
            connectionMessage = SessionCopy.gaveUp(on: target.name, everConnected: target.hasLinked)
            return
        }
        let seconds = retryDelays[reconnectAttempt]
        let attemptNumber = reconnectAttempt + 1
        reconnectAttempt = attemptNumber
        isReconnecting = true
        connectionMessage = SessionCopy.retrying(target.name, inSeconds: seconds, attempt: attemptNumber,
                                                 of: total, everConnected: target.hasLinked)
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            // The live target is dialled, not the copy this wait began with, so nothing recorded
            // about it since — that it linked, that it was remembered — is dialled stale.
            guard self.hasActiveWindow, !self.isLinked, !self.isConnecting,
                  let current = self.retry, current.isRetryable else {
                self.isReconnecting = false
                return
            }
            self.attempt(current)
            guard self.isConnecting else { return }
            self.connectionMessage = SessionCopy.reconnecting(to: current.name, attempt: attemptNumber, of: total)
        }
    }

    /// Reconnection is foreground-only, so a backoff dropped when the window went
    /// away picks up where it left off instead of starting from scratch.
    private func resumeRetryIfNeeded() {
        guard !retryExhausted, let target = retry, target.isRetryable, !isLinked, !isConnecting, retryTask == nil else { return }
        scheduleRetry(target)
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
        isReconnecting = false
    }

    private func attempt(_ target: RetryTarget) {
        // Every route the model makes has an endpoint, so this cannot fail today. It still reports
        // rather than returning quietly, because a silent return here would leave the UI reporting
        // a reconnection forever.
        guard let endpoint = target.route.endpoint else {
            cancelRetry()
            retry = nil
            connectionMessage = "The saved connection to \(target.name) is no longer usable. \(SessionCopy.forgetSavedMacAdvice)"
            return
        }
        connect(to: endpoint, key: target.key, name: target.name, remembering: target)
    }

    /// Ends the session and releases everything the Mac is holding. Deliberately
    /// leaves `retry` alone: whether to come back is the caller's decision.
    ///
    /// The session's identity is retired before anything is released. A release or a Stop that
    /// fails to send below then finds no current session to report, so one teardown is one
    /// drop: a failed release used to re-enter `handleDrop` from inside the teardown already
    /// handling it, and every re-entry spent another attempt of the reconnection budget.
    ///
    /// `notifiesMac` sends the Stop that pauses the Mac's control grant, which only a deliberate
    /// hang-up wants. `keepsPairingCode` leaves a typed code for an attempt that never linked.
    private func tearDown(message: String?, notifiesMac: Bool = true, keepsPairingCode: Bool = false) {
        let channel = connection
        let wasLinked = isLinked
        connectionID = nil
        keyboard.cancel(endSession: true)
        dockLauncher.endSession()
        pointer.releaseGesture()
        if wasLinked, notifiesMac { _ = channel?.send(DeskMessage(kind: "stop")) }
        connection = nil
        channel?.cancel()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        monitor.unlinked()
        if !isMacResponsive { isMacResponsive = true }
        isConnecting = false
        isLinked = false
        isMacControlEnabled = false
        stopAwaitingAcknowledgement = false
        if !keepsPairingCode { pairingCode = "" }
        displays.forEach { stream in
            stream.onKeyframeNeeded = nil
            stream.clear()
        }
        displays = []
        lastKeyframeRequests.removeAll()
        pointer.forgetAllPositions()
        statusText = ""
        connectionMessage = message
        startDiscovery()
    }

    private static func message(for error: Error, fallback: String) -> String {
        (error as? LocalizedError)?.errorDescription ?? fallback
    }

    /// The inbound handler, module-internal rather than private so a test can deliver one
    /// decoded message synchronously and observe what this function does with it. It grants
    /// nothing: every guard below still applies, and a caller that is not linked or that
    /// offers an invalid message is refused exactly as the transport's own callback would be.
    func receive(_ message: DeskMessage) {
        // `FrameCodec.decode` already drops anything that fails `isValid`, so this is a second
        // layer rather than a plugged hole: the model keeps its own invariants even if some
        // future path hands it a message the transport never checked. `isValid` pins
        // `version == 1`, so this is not weaker than the explicit version check it replaces.
        guard isLinked, message.isValid else { return }
        switch message.kind {
        case "capabilities":
            if message.keyboardAcknowledgements == true { keyboard.enable() }
        case "keyboardResult":
            keyboard.receive(message)
        case "apps", "appLaunchResult":
            dockLauncher.receive(message)
        case "displays":
            guard let infos = message.displays else { return }
            applyDisplays(infos)
        case "frame":
            guard let id = message.displayID, let jpeg = message.jpeg else { return }
            display(id: id)?.accept(jpeg: jpeg)
        case "video":
            guard let id = message.displayID, let video = message.video else { return }
            display(id: id)?.accept(video: video)
        case "status":
            if let status = message.status { statusText = String(status.prefix(500)) }
            // Only this authenticated session can say so; a Bonjour record can be published by anyone.
            if message.keepsPairing == true { macKeepsPairing() }
            if message.controlEnabled == false {
                keyboard.cancel()
                isMacControlEnabled = false
                stopAwaitingAcknowledgement = false
                pointer.releaseGesture()
                dockLauncher.controlBecameUnavailable()
            } else if message.controlEnabled == true, !stopAwaitingAcknowledgement {
                // Store the Mac's grant as given. `canControl` applies `hasActiveWindow`, so
                // overwriting the grant with local focus state would only discard it and
                // leave control off until someone re-enabled it at the Mac.
                isMacControlEnabled = true
                // A grant after the Stop was answered is new consent: the Stop is over, and no
                // later session with this Mac repeats it.
                if let sessionRoute, stoppedRoutes.remove(sessionRoute) != nil {
                    preferences.saveStoppedRoutes(stoppedRoutes)
                }
            }
        default:
            break
        }
    }

    /// Installs the Mac's display list.
    ///
    /// Everything here that can send — the release of a gesture on a removed display, the
    /// keyframe a resized display asks for — runs with the new list already installed and is
    /// followed by a check that the session survived it. A send that fails tears the session
    /// down from inside this call, and a list assigned after that would put live-looking
    /// streams back onto a session that no longer exists; installing first means the teardown
    /// empties the list it actually has to empty.
    private func applyDisplays(_ infos: [DisplayInfo]) {
        guard infos.count <= DeskMessage.maximumSharedDisplays else { return }
        var ids = Set<UInt32>()
        // `isValid` also rules out id 0, oversized pixel sizes, and a pointWidth or
        // pointHeight that would make every coordinate unmappable on the Mac.
        let valid = infos.filter { $0.isValid && ids.insert($0.id).inserted }
        // A hotplug or rotation on another screen does not change the destination that
        // already owns admitted typing. Cancel only removed or remapped destinations.
        for stream in displays where !valid.contains(where: {
            $0.id == stream.info.id && !Self.mapsPositionsDifferently(stream.info, $0)
        }) {
            keyboard.cancel(displayID: stream.id)
        }
        if let active = pointer.activeDisplayID, !valid.contains(where: { $0.id == active }) {
            pointer.releaseGesture()
            guard isLinked else { return }
        }
        for removed in displays where !valid.contains(where: { $0.id == removed.id }) {
            // Detached before clearing, because clearing demands a keyframe and there is no
            // display left to send one for. A stream being discarded has nothing to ask for.
            removed.onKeyframeNeeded = nil
            removed.clear()
            lastKeyframeRequests[removed.id] = nil
            pointer.forgetPosition(displayID: removed.id)
        }
        var updates: [(stream: DisplayStream, info: DisplayInfo)] = []
        displays = valid.map { (info) -> DisplayStream in
            guard let existing = displays.first(where: { $0.id == info.id }) else { return makeStream(for: info) }
            updates.append((existing, info))
            return existing
        }
        for update in updates {
            let id = update.info.id
            // A normalized position lands somewhere else on the Mac once the display's point
            // geometry changes, so clicking at the remembered one would move the pointer. A
            // gesture holding the button there is released first, at the position it pressed.
            if Self.mapsPositionsDifferently(update.stream.info, update.info) {
                if pointer.activeDisplayID == id {
                    pointer.releaseGesture()
                    guard isLinked else { return }
                }
                pointer.forgetPosition(displayID: id)
            }
            update.stream.update(info: update.info)
            guard isLinked else { return }
        }
    }

    private func makeStream(for info: DisplayInfo) -> DisplayStream {
        let stream = DisplayStream(info: info)
        let id = info.id
        stream.onKeyframeNeeded = { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - (self.lastKeyframeRequests[id] ?? -.infinity) >= 0.5 else { return }
            self.lastKeyframeRequests[id] = now
            self.send(DeskMessage(kind: "keyframe", displayID: id))
        }
        return stream
    }

    /// Whether the Mac would map the same normalized coordinate to a different global point.
    /// Pixel size alone does not matter: the Mac maps through point geometry.
    private static func mapsPositionsDifferently(_ old: DisplayInfo, _ new: DisplayInfo) -> Bool {
        old.originX != new.originX || old.originY != new.originY
            || old.pointWidth != new.pointWidth || old.pointHeight != new.pointHeight
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isLinked else { return }
                self.keyboard.validateAvailability()
                if let active = self.pointer.activeDisplayID,
                   !self.canControl(displayID: active) {
                    self.pointer.releaseGesture()
                }
                // A recycled session belongs to its reconnection now, not to this loop.
                guard self.checkMacResponsiveness() else { return }
                for stream in self.displays {
                    stream.requestRefreshIfStalled()
                    guard self.isLinked else { return }
                }
                self.send(DeskMessage(kind: "heartbeat"))
                do { try await Task.sleep(nanoseconds: 300_000_000) }
                catch { return }
            }
        }
    }

    /// Reads the link monitor once per heartbeat and publishes only a change.
    ///
    /// A silent session is recycled only when it can come back by itself: it reached its Mac
    /// before, its key is still in memory, and a window is in front to reconnect into: a session
    /// whose Mac keeps listening across a dropped session — saved, typed, or nearby with a Mac that
    /// said it keeps its pairing. A one-time nearby session is never closed for silence — that Mac
    /// stops sharing when its session closes — so it is only reported. Returns false once recycled.
    private func checkMacResponsiveness() -> Bool {
        guard isLinked else { return false }
        let canRecover = hasActiveWindow && retry?.isRetryable == true
        switch monitor.assess(at: Self.now(), canRecover: canRecover) {
        case .responsive:
            if !isMacResponsive { isMacResponsive = true }
            return true
        case .quiet:
            if isMacResponsive {
                isMacResponsive = false
                keyboard.cancel()
                dockLauncher.controlBecameUnavailable()
            }
            return true
        case .recover:
            handleDrop(reason: "\(SessionCopy.macName(retry?.name ?? connectedName)) stopped responding.")
            return false
        }
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The one way anything reaches the Mac.
    ///
    /// A failure is an unexpected drop, not a deliberate hang-up, so a remembered Mac may still
    /// come back — and it is reported once. The transport can already have reported it from
    /// inside `connection.send`, synchronously, and a teardown already under way sends its
    /// release through here after retiring the session; in both cases the session this send
    /// belonged to is gone, and handling the drop again would only spend another attempt of the
    /// reconnection budget and overwrite the message the first handling chose.
    @discardableResult
    private func send(_ message: DeskMessage) -> Bool {
        guard isLinked, let connection else { return false }
        let session = connectionID
        guard connection.send(message) else {
            if let session, connectionID == session {
                handleDrop(reason: "The connection to your Mac was interrupted.")
            }
            return false
        }
        return true
    }

    private func startDiscovery() {
        guard hasActiveWindow, !isLinked, !isConnecting, !isBrowsing else { return }
        isBrowsing = true
        browser.start()
    }

    private func stopDiscovery() {
        guard isBrowsing else { return }
        isBrowsing = false
        browser.stop()
    }
}
