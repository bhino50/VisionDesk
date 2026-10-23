import AppKit
import Security
import Combine
import ScreenCaptureKit
import DeskCore
import DeskTransport

@MainActor
final class CompanionModel: ObservableObject {
    let virtualDisplays = VirtualDisplayManager()
    @Published var displays: [DisplayInfo] = []
    @Published private(set) var availableDisplays: [DisplayInfo] = []
    @Published var selectedDisplayIDs: Set<UInt32>?
    let saveDisplaySelection: (Set<UInt32>?) -> Void
    let resolveDisplaySelection: (([DisplayInfo]) -> Set<UInt32>?)?
    /// The companion's own thumbnails. Refreshed at most once per watchdog tick, and only for
    /// displays whose image changed: every publication redraws the whole companion and menu
    /// bar, and drawing a new thumbnail decodes a full-size JPEG on the main thread — the thread
    /// that applies headset input.
    @Published var previews: [UInt32: NSImage] = [:]
    @Published var status = "Ready. Connect your displays, then start sharing."
    @Published var pairingKey = ""
    @Published var sharing = false
    @Published var busy = false
    @Published var connected = false
    @Published var controlEnabled = false
    @Published var testMode = false { didSet { if oldValue != testMode { revoke("Input mode changed. Enable it again on this Mac.") } } }
    /// True while an automatic restart is scheduled, so the owner can always stop it.
    @Published private(set) var restartPending = false
    // Diagnostic counters must not redraw the companion and menu bar for every input or frame.
    // Values update immediately; the watchdog publishes their UI refresh at most four times/sec.
    var inputCount = 0 { didSet { statisticsDirty = true } }
    var lastInput = "No input received" { didSet { statisticsDirty = true } }
    var framesSent = 0 { didSet { statisticsDirty = true } }
    var framesDropped = 0 { didSet { statisticsDirty = true } }
    // Read directly by the diagnostics that report them. No view shows them, so they never ask
    // for a redraw: encoders keep running while no headset is attached, and marking these dirty
    // redrew the idle companion four times a second for as long as it was left sharing.
    private(set) var encodedFrameCounts: [UInt32: Int] = [:]
    private(set) var encodedByteCount = 0
    var videoEncoderCount: Int { captures.filter(\.isEncodingVideo).count }
    var sendingH264: Bool { peerUsesVideo }
    /// Whether a headset session is attached, which decides whether anyone but this companion
    /// is looking at the JPEG output.
    var isHeadsetAttached: Bool { channel != nil }
    /// The JPEG spacing the captures are currently told to use.
    var imageInterval: TimeInterval {
        DisplayCapture.previewInterval(isDeliveringVideo: peerUsesVideo, isHeadsetAttached: isHeadsetAttached, isVideoCapture: true)
    }
    /// An unattended host that will start sharing by itself — when a pause ends, once the display
    /// arrangement allows, or through the self-heal check — though no restart is scheduled yet.
    /// Every change to its inputs also publishes `status`, `busy` or `sharing`, so views stay current.
    var autoRecoveryArmed: Bool {
        persistentHostingRequested && remoteHostingRequested && !manuallyStopped && !sharing && !busy
    }
    /// Whether Stop Sharing has something to stop: a session, its preparation, a scheduled
    /// restart, or an armed automatic one.
    var canStopSharing: Bool { sharing || busy || restartPending || autoRecoveryArmed }
    /// Fires for every image a capture delivers, idle repeats included, so a diagnostic can
    /// confirm capture is alive without depending on how often the thumbnails are redrawn.
    let imageDelivered = PassthroughSubject<UInt32, Never>()
    @Published var screenPermission = false
    @Published var inputPermission = false
    @Published private(set) var remoteConfiguration: RemoteHostConfiguration
    /// The answer to the owner's last action in the remote access panel, shown beside it.
    @Published var lanConfiguration: LANHostConfiguration
    let loadLANKey: () throws -> PairingKey?
    let deleteLANKey: () throws -> Void
    let saveLANKey: (PairingKey) throws -> Void
    let saveLANConfiguration: (LANHostConfiguration) -> Void
    /// Set only after the remembered-key listener starts; cleared on every teardown.
    var listenerKeepsPairing = false
    @Published var remoteFeedback: RemoteFeedback?
    /// When the remembered key on screen hides itself. Nil unless the owner asked to see that key.
    @Published private(set) var pairingKeyHidesAt: Date?
    /// The last status this Mac addressed to a connected headset, for diagnostics. Never the key.
    private(set) var lastHeadsetNotice: String?
    // What remote access reads and writes outside this process. Injected so the checks never read
    // this Mac's interfaces, Keychain, preferences or permission grants.
    let localAddresses: () -> [String]
    let loadRemoteKey: () throws -> PairingKey?
    let saveRemoteKey: (PairingKey) throws -> Void
    let deleteRemoteKey: () throws -> Void
    let saveRemoteConfiguration: (RemoteHostConfiguration) -> Void
    let screenCaptureAccess: () -> Bool
    let keyReveal: PairingKeyReveal
    private var autoEnablePending = false
    private var statisticsDirty = false
    private var lastIdlePermissionProbe = -Double.infinity
    private var sessionRequestedControl = false
    var ownerPausedControl = false
    var peerPausedControl = false
    /// Whether compressed video is actually going to the peer. Every capture is told, because
    /// that — not the presence of an encoder — is what sets each display's JPEG cadence: during
    /// negotiation the encoders are already running while the headset is still being served
    /// images, and throttling on encoder existence would hold that window at two frames/sec.
    private var videoSendRecovery = VideoSendRecovery()
    private var peerUsesVideo = false {
        didSet {
            guard oldValue != peerUsesVideo else { return }
            videoSendRecovery = VideoSendRecovery()
            if peerUsesVideo { videoSendRecovery.requireKeyframes(for: displays.map(\.id)) }
            captures.forEach { $0.setDeliveringVideo(peerUsesVideo) }
        }
    }
    private var peerSupportsVideo = false
    private var lastKeyframeRequest: [UInt32: TimeInterval] = [:]
    let keepAwake: KeepAwakeHold
    var resumeTask: Task<Void, Never>? {
        didSet { if restartPending != (resumeTask != nil) { restartPending = resumeTask != nil } }
    }
    var remoteSuspended = false
    var hostSession = HostSessionFlags()
    var backoff = RemoteRecoveryBackoff()
    private var sharingStartedUptime: TimeInterval?
    /// Set once remote hosting has been asked for, so the self-heal backstop never starts a host
    /// nobody started. A manual stop withdraws it through `manuallyStopped`.
    var remoteHostingRequested = false
    var lastSelfHealUptime = -Double.infinity
    private var keyHideTask: Task<Void, Never>?
    var manuallyStopped = false
    private let server = DeskServer()
    let dockAppLauncher: DockAppLauncher
    private var keyboardReceipts: [UUID: String] = [:]
    private var keyboardReceiptOrder: [UUID] = []
    private var peerSupportsKeyboardAcknowledgements = false
    private var peerSupportsDockLauncher = false
    private var appLaunchInFlight = false
    private var appLaunchToken: UUID?
    private var lastAppLaunch = -Double.infinity
    private var lastAppCatalog = -Double.infinity
    private var advertisedDockApps: [DockAppInfo] = []
    private let input: InputOutput
    /// The authenticated session. Captures follow it, because whether anyone is attached decides
    /// how often their JPEG has to be encoded.
    private var channel: DeskConnection? {
        didSet {
            guard (oldValue == nil) != (channel == nil) else { return }
            let attached = channel != nil
            captures.forEach { $0.setHeadsetAttached(attached) }
        }
    }
    private var captures: [DisplayCapture] = []
    private var preparingCaptures: [DisplayCapture] = []
    private let captureLifecycle = CaptureLifecycle()
    /// An encoder may fail during asynchronous preparation, before `captures` is installed.
    /// Remember that session-wide fallback so later staged displays inherit it too.
    private(set) var videoFallbackReason: String?
    private var latestFrames: [UInt32: Data] = [:]
    /// Displays whose newest image has not reached `previews` yet.
    private var stalePreviews = Set<UInt32>()
    /// The inventory the current session was built from, before ScreenCaptureKit narrowed it.
    /// Nil whenever nothing is being shared, which a display notification treats as changed.
    var sessionInventory: [DisplayInfo]?
    private var lastHeartbeat = -Double.infinity
    private var rateStart = ProcessInfo.processInfo.systemUptime
    private var rateCount = 0
    var generation = 0
    private var timer: Timer?
    private var notifications: HostNotificationObserver?
    private let contentProvider: () async throws -> SCShareableContent
    let inventoryProvider: @MainActor () -> [DisplayInfo]
    let liveSession: () -> HostSessionObservation
    /// Awake uptime for the unattended-availability decisions: notice precedence, self-heal
    /// pacing and the recovery keep-awake window. Injected so the harness can step through them.
    let uptime: () -> TimeInterval

    /// How often an idle remote host that should be sharing re-checks the live session.
    static let selfHealInterval: TimeInterval = 15
    /// What a pause says. Only these give way to the display limit again; see `resumeRemote`.
    static let pausedStatus = "Remote sharing paused. It resumes when this Mac is awake and unlocked."
    static let pausedUntilUnlockedStatus = "Remote sharing is paused until this Mac is unlocked."

    init(selectedDisplayIDs: Set<UInt32>? = nil,
         saveDisplaySelection: @escaping (Set<UInt32>?) -> Void = { _ in },
         resolveDisplaySelection: (([DisplayInfo]) -> Set<UInt32>?)? = nil,
         lanConfiguration: LANHostConfiguration = .disabled,
         loadLANKey: @escaping () throws -> PairingKey? = LANHostKeychain.load,
         saveLANKey: @escaping (PairingKey) throws -> Void = LANHostKeychain.save,
         deleteLANKey: @escaping () throws -> Void = LANHostKeychain.delete,
         saveLANConfiguration: @escaping (LANHostConfiguration) -> Void = { $0.save() },
         remoteConfiguration: RemoteHostConfiguration = .disabled,
         localAddresses: @escaping () -> [String] = LocalNetworkAddresses.all,
         loadRemoteKey: @escaping () throws -> PairingKey? = RemoteHostKeychain.load,
         saveRemoteKey: @escaping (PairingKey) throws -> Void = RemoteHostKeychain.save,
         deleteRemoteKey: @escaping () throws -> Void = RemoteHostKeychain.delete,
         saveRemoteConfiguration: @escaping (RemoteHostConfiguration) -> Void = { $0.save() },
         contentProvider: @escaping () async throws -> SCShareableContent = {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    },
         inventory: @escaping @MainActor () -> [DisplayInfo] = CompanionModel.liveInventory,
         liveSession: @escaping () -> HostSessionObservation = HostSessionObservation.current,
         keepAwake: KeepAwakeHold = KeepAwakeHold(),
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         screenCaptureAccess: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         controlAccess: InputPermissionCache = InputPermissionCache(),
         keyReveal: PairingKeyReveal = .standard,
         dockAppLauncher: DockAppLauncher? = nil) {
        self.dockAppLauncher = dockAppLauncher ?? DockAppLauncher()
        self.selectedDisplayIDs = selectedDisplayIDs
        self.saveDisplaySelection = saveDisplaySelection
        self.resolveDisplaySelection = resolveDisplaySelection
        self.lanConfiguration = lanConfiguration
        self.loadLANKey = loadLANKey
        self.saveLANKey = saveLANKey
        self.deleteLANKey = deleteLANKey
        self.saveLANConfiguration = saveLANConfiguration
        ownerPausedControl = remoteConfiguration.enabled ? remoteConfiguration.ownerPaused : lanConfiguration.ownerPaused
        peerPausedControl = remoteConfiguration.enabled ? remoteConfiguration.peerPaused : lanConfiguration.peerPaused
        self.localAddresses = localAddresses
        self.loadRemoteKey = loadRemoteKey
        self.saveRemoteKey = saveRemoteKey
        self.deleteRemoteKey = deleteRemoteKey
        self.saveRemoteConfiguration = saveRemoteConfiguration
        self.contentProvider = contentProvider
        self.inventoryProvider = inventory
        self.liveSession = liveSession
        self.keepAwake = keepAwake
        self.uptime = uptime
        self.screenCaptureAccess = screenCaptureAccess
        self.keyReveal = keyReveal
        self.remoteConfiguration = remoteConfiguration
        input = InputOutput(permission: controlAccess)
        let observed = liveSession()
        hostSession.locked = observed.screenLocked
        hostSession.sessionInactive = !observed.onConsole
        hostSession.screensAsleep = observed.displaysAsleep
        inputPermission = input.hasPermission
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdog() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        notifications = HostNotificationObserver(session: { [weak self] notice in self?.receiveSessionNotice(notice) },
                                                 displaysChanged: { [weak self] in self?.displayConfigurationChanged() })
        refreshInventory()
    }

    func refreshInventory() {
        let inventory = inventoryProvider()
        if inventory != availableDisplays { availableDisplays = inventory }
        if let resolveDisplaySelection {
            let resolved = resolveDisplaySelection(inventory)
            if resolved != selectedDisplayIDs { selectedDisplayIDs = resolved }
        }
        let selected = DisplayCapturePlan.select(inventory: inventory, preferredIDs: selectedDisplayIDs)
        if selected != displays { displays = selected }
        // Assigning an unchanged value still publishes, which redraws the whole companion, and
        // the setup panel calls this every two seconds while sharing is stopped.
        let screenAllowed = screenCaptureAccess()
        if screenAllowed != screenPermission { screenPermission = screenAllowed }
        refreshControlPermission()
    }

    /// Reads Accessibility access now. Publishes only a change, for the reason above.
    @discardableResult
    func refreshControlPermission() -> Bool {
        let allowed = input.hasPermission
        if allowed != inputPermission { inputPermission = allowed }
        return allowed
    }

    func requestInputPermission() { input.requestPermission(); inputPermission = input.hasPermission }

    func start(allowControl: Bool = false, resetControlPause: Bool = true) {
        guard !sharing, !busy else { return }
        manuallyStopped = false
        remoteHostingRequested = true
        if !remoteConfiguration.enabled { setLANAvailability(true) }
        if persistentHostingRequested && !hostSessionAvailable {
            // Paused exactly like a lock, so the display must not be kept awake behind it.
            keepAwake.release()
            status = Self.pausedUntilUnlockedStatus; return
        }
        refreshInventory()
        let arrangement = displays
        guard !arrangement.isEmpty else {
            keepAwake.release()
            status = displaySelectionUnavailableStatus
            return
        }
        // The saved address, that this Mac has it, then the key, all before capture. A cause that can
        // clear by itself — Tailscale still connecting, the login keychain still locked — retries on
        // the backoff without preparing anything; one that cannot waits for the owner.
        let remote: (endpoint: RemoteMacAddress, key: PairingKey)?
        if remoteConfiguration.enabled {
            switch checkRemoteStart() {
            case .stop(let reason): stop(); status = reason; return
            case .retry(let reason): manuallyStopped = false; recoverRemote(after: reason); return
            case .ready(let endpoint, let key): remote = (endpoint, key)
            }
        } else { remote = nil }
        let plan: HostListenerPlan
        do { plan = try listenerPlan(remote: remote, allowCreation: resetControlPause) }
        catch let error as PairingKeyStoreError {
            switch error {
            case .invalidAccount, .notEntitled:
                stop(); status = error.localizedDescription; return
            case .untrustedItemPolicy, .unreadableItem:
                stop(); status = "Saved pairing needs repair. Open Settings & Troubleshooting and reset pairing, then try again."; return
            case .accessDenied(let code) where code == errSecAuthFailed || code == errSecUserCanceled:
                stop(); status = error.localizedDescription; return
            default:
                recoverRemote(after: "Could not access saved pairing. Unlock Keychain, then try again."); return
            }
        }
        catch { recoverRemote(after: "Could not access saved pairing. Unlock Keychain, then try again."); return }
        manuallyStopped = false
        sessionRequestedControl = allowControl || reconnectControlAllowed
        encodedFrameCounts = [:]; encodedByteCount = 0
        busy = true; generation += 1
        let token = generation
        videoFallbackReason = nil
        sessionInventory = arrangement
        status = "Preparing connected displays…"
        captureLifecycle.start { [self] in
            guard generation == token else { return }
            var staged: [DisplayCapture] = []
            do {
                let content = try await contentProvider()
                guard generation == token else { return }
                refreshInventory()
                sessionInventory = displays
                let sources = content.displays.filter { display in displays.contains { $0.id == display.displayID } }
                try DisplayCapturePlan.validate(inventory: displays, capturableIDs: Set(sources.map(\.displayID)))
                let videoDelivery = OrderedVideoDelivery { [weak self] frames, losses in
                    guard let self, self.generation == token else { return }
                    self.deliverVideo(frames, losses: losses)
                }
                for display in sources {
                    let delivery = LatestFrameDelivery { [weak self] id, jpeg in
                        guard let self, self.generation == token else { return }
                        self.deliverImage(jpeg, displayID: id)
                    }
                    let capture = DisplayCapture(display: display, onFrame: { id, jpeg in
                        delivery.submit(id: id, jpeg: jpeg)
                    }, onEncodedFrame: { id, frame in videoDelivery.submit(id: id, frame: frame) },
                       onVideoUnavailable: { [weak self] reason in
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            self.degradeToImageUpdates(reason)
                        }
                    }, onFailure: { [weak self] failure in
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            self.captureEnded(failure)
                        }
                    })
                    staged.append(capture)
                    preparingCaptures = staged
                    if videoFallbackReason != nil { capture.disableVideo() }
                    try await capture.start()
                    guard generation == token else { for capture in staged { await capture.stop() }; return }
                }
                captures = staged
                preparingCaptures = []
                // A capture built after these were last set has to inherit them; `didSet` only
                // reaches the captures that already existed when the value changed.
                let attached = isHeadsetAttached
                staged.forEach { $0.setDeliveringVideo(peerUsesVideo); $0.setHeadsetAttached(attached) }
                server.onStatus = { [weak self] status in self?.status = status }
                server.onStopped = { [weak self] reason in self?.recoverRemote(after: reason) }
                server.onConnection = { [weak self] connection in self?.attach(connection) }
                try server.start(key: plan.key, name: plan.name, port: plan.port,
                                 allowReconnect: plan.allowsReconnect, bindHost: plan.bindHost)
                listenerKeepsPairing = true
                if remote != nil && remoteConfiguration.keepAwake { keepAwake.hold() } else { keepAwake.release() }
                // The backoff starts over only once this session has stayed up; see the watchdog.
                sharing = true; busy = false; sharingStartedUptime = uptime()
                screenPermission = true
                let ready = "Sharing \(displays.count) of \(availableDisplays.count) displays. Choose this Mac in VisionDesk on Vision Pro."
                status = videoFallbackReason.map { "\(ready) \($0)" } ?? ready
            } catch {
                for capture in staged { await capture.stop() }
                guard generation == token else { return }
                preparingCaptures = []
                captureEnded(CaptureFailure(error), while: "Could not start sharing")
            }
        }
    }

    // Internal so the behavior harness can exercise reconnect consent without opening a socket.
    func attach(_ connection: DeskConnection) {
        input.release(); controlEnabled = false
        keyboardReceipts.removeAll(); keyboardReceiptOrder.removeAll()
        peerSupportsKeyboardAcknowledgements = false
        peerSupportsDockLauncher = false; appLaunchInFlight = false; lastAppLaunch = -.infinity; lastAppCatalog = -.infinity
        channel = connection; connected = true; peerUsesVideo = false; peerSupportsVideo = false; lastKeyframeRequest = [:]
        // The headset has the key now, and the screen it sees may show it.
        hidePairingKey()
        lastHeartbeat = -Double.infinity
        // A local grant in one connection must not become unattended consent after reconnect.
        let reconnectPermitsControl = reconnectControlAllowed
        autoEnablePending = sessionRequestedControl && reconnectPermitsControl && !ownerPausedControl && !peerPausedControl
        connection.onMessage = { [weak self] message in self?.receive(message) }
        connection.onState = { [weak self, weak connection] state in
            if case .disconnected(let reason) = state {
                guard let self, self.channel === connection else { return }
                if self.persistentHostingRequested {
                    self.input.release(); self.controlEnabled = false; self.connected = false
                    self.channel = nil; self.peerUsesVideo = false; self.peerSupportsVideo = false
                    self.status = "Disconnected. Your Mac is ready to reconnect."
                } else { self.stop(); self.status = reason }
            }
        }
        connection.send(DeskMessage(kind: "displays", displays: displays))
        // Capture continues across remote disconnects; every capture teardown clears this cache.
        for (id, jpeg) in latestFrames { connection.send(DeskMessage(kind: "frame", displayID: id, jpeg: jpeg)) }
        captures.forEach { $0.requestKeyframe() }
        publishStatus("Connected securely. Enable input on this Mac if needed.")

    }

    func enableInput() {
        inputPermission = input.hasPermission
        guard connected, (ProcessInfo.processInfo.systemUptime - lastHeartbeat) < 1.5 else { status = "Connect the headset before enabling input."; return }
        // Told to the headset too: a heartbeat or Resume Control lands here, and without this the
        // wearer's last word was "Enable input on this Mac if needed."
        guard testMode || inputPermission else { publishStatus(HeadsetNotice.controlNeedsAccessibility); return }
        ownerPausedControl = false; peerPausedControl = false
        persistControlPauses()
        sessionRequestedControl = true
        controlEnabled = true; rateStart = ProcessInfo.processInfo.systemUptime; rateCount = 0
        publishStatus(testMode ? "Test input enabled. Gestures are counted without moving the pointer." : "Mac control enabled for all shared displays.")
    }

    func revoke(_ reason: String = "Input stopped on this Mac.", ownerPause: Bool = true, peerPause: Bool = false) {
        autoEnablePending = false
        if ownerPause { ownerPausedControl = true }
        if peerPause { peerPausedControl = true }
        if ownerPause || peerPause { persistControlPauses() }
        input.release(); controlEnabled = false
        publishStatus(reason)
    }

    /// Ends the session. `retainKeepAwake` is only for stops that rebuild capture — remote
    /// recovery and a display change — so an unattended Mac is not let fall asleep between
    /// tearing capture down and bringing it back. Every other stop releases the hold. A manual
    /// stop also ends any failing recovery run, so the next start gets a fresh recovery budget.
    /// `headsetNotice` is what a connected headset is told about why.
    func stop(manual: Bool = true, retainKeepAwake: Bool = false, headsetNotice: String = HeadsetNotice.stopped) {
        if manual { if !remoteConfiguration.enabled { setLANAvailability(false) }; manuallyStopped = true; resumeTask?.cancel(); resumeTask = nil; backoff.reset() }
        if !retainKeepAwake { keepAwake.release() }
        peerUsesVideo = false; peerSupportsVideo = false
        keyboardReceipts.removeAll(); keyboardReceiptOrder.removeAll()
        peerSupportsKeyboardAcknowledgements = false
        peerSupportsDockLauncher = false; appLaunchInFlight = false
        generation += 1
        input.release(); controlEnabled = false
        tellHeadset(headsetNotice)
        let current = channel; channel = nil
        current?.onState = nil; current?.onMessage = nil
        listenerKeepsPairing = false
        server.stop(); current?.cancel()
        let oldCaptures = captures + preparingCaptures
        captures = []; preparingCaptures = []
        captureLifecycle.stop(oldCaptures, revoke: { $0.requestStop() }, retire: { await $0.stop() })
        sharing = false; busy = false; connected = false; previews = [:]; latestFrames = [:]
        // A one-session key ends with its session. A remembered key the owner asked to see stays
        // valid, so it hides when its reveal ends instead.
        if pairingKeyHidesAt == nil { pairingKey = "" }
        stalePreviews = []; sessionInventory = nil; sharingStartedUptime = nil
        status = "Sharing stopped."
    }

    private func publishStatus(_ value: String) {
        status = value
        tellHeadset(value)
    }

    /// Sends a status to the connected headset, if there is one.
    private func tellHeadset(_ value: String) {
        guard let channel else { return }
        lastHeadsetNotice = value
        channel.send(headsetStatus(value))
    }

    func receive(_ message: DeskMessage) {
        guard message.isValid else { revoke("Invalid input received. Re-enable locally after checking the client."); return }
        if message.kind == "capabilities", message.keyboardAcknowledgements == true {
            peerSupportsKeyboardAcknowledgements = true
            channel?.send(DeskMessage(kind: "capabilities", videoCodec: DeskMessage.supportedVideoCodec,
                                      keyboardAcknowledgements: true))
        }
        if message.kind == "capabilities", message.dockLauncher == true {
            peerSupportsDockLauncher = true
            sendDockApps()
        }
        if message.kind == "requestApps" { sendDockApps(); return }
        if message.kind == "launchApp" { launchDockApp(message); return }
        if message.kind == "capabilities", message.videoCodec == DeskMessage.supportedVideoCodec {
            peerSupportsVideo = true
            peerUsesVideo = !captures.isEmpty && captures.allSatisfy(\.isEncodingVideo)
            captures.forEach { $0.requestKeyframe() }
            return
        }
        if message.kind == "keyframe", let id = message.displayID {
            requestKeyframe(displayID: id)
            return
        }
        if message.kind == "heartbeat" {
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
            if autoEnablePending, !ownerPausedControl, !controlEnabled { autoEnablePending = false; enableInput() }
            return
        }
        if message.kind == "stop" { revoke("Input stopped from Vision Pro.", ownerPause: false, peerPause: true); return }
        if message.kind == "requestControl" {
            guard reconnectControlAllowed, !ownerPausedControl else {
                publishStatus(HeadsetNotice.controlRefused(remote: true, allowed: reconnectControlAllowed))
                return
            }
            enableInput(); return
        }
        func keyboardReply(_ result: String) {
            guard peerSupportsKeyboardAcknowledgements, let request = message.keyboardRequestID else { return }
            if result != "busy", let id = UUID(uuidString: request), keyboardReceipts[id] == nil {
                if keyboardReceiptOrder.count >= 64 {
                    keyboardReceipts.removeValue(forKey: keyboardReceiptOrder.removeFirst())
                }
                keyboardReceiptOrder.append(id)
                keyboardReceipts[id] = result
            }
            channel?.send(DeskMessage(kind: "keyboardResult", keyboardRequestID: request, keyboardResult: result))
        }
        guard message.kind == "input" else { return }
        guard message.keyboardRequestID == nil || peerSupportsKeyboardAcknowledgements else { return }
        guard controlEnabled else { keyboardReply("rejected"); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard (now - lastHeartbeat) < 1.5 else { keyboardReply("rejected"); releaseForStaleHeartbeat(); return }
        if (now - rateStart) >= 1 { rateStart = now; rateCount = 0 }
        rateCount += 1
        if rateCount > 240, message.action != "leftUp" { keyboardReply("busy"); return }
        guard let id = message.displayID, displays.contains(where: { $0.id == id }), CGDisplayIsOnline(id) != 0 else {
            keyboardReply("rejected")
            revoke("Input exceeded its limits or targeted a disconnected display."); return
        }
        if !testMode, !input.hasPermission { keyboardReply("rejected"); revoke("Accessibility permission was removed."); return }
        if let request = message.keyboardRequestID, let id = UUID(uuidString: request),
           let receipt = keyboardReceipts[id] {
            keyboardReply(receipt); return
        }
        inputCount += 1; lastInput = "\(message.action ?? "Input") · display \(id)"
        if testMode { keyboardReply("rejected") }
        else { keyboardReply(input.apply(message).rawValue) }
    }

    private func sendDockApps() {
        guard peerSupportsDockLauncher, let channel else { return }
        let now = uptime()
        if now - lastAppCatalog >= 1 {
            lastAppCatalog = now
            advertisedDockApps = dockAppLauncher.catalog()
        }
        channel.send(DeskMessage(kind: "apps", dockApps: advertisedDockApps, appPlacement: true))
    }

    private func launchDockApp(_ message: DeskMessage) {
        guard peerSupportsDockLauncher, let connection = channel,
              let id = message.appID, let requestID = message.appRequestID else { return }
        func reply(_ succeeded: Bool, _ status: String) {
            connection.send(DeskMessage(kind: "appLaunchResult", status: status,
                appID: id, appRequestID: requestID, appLaunchSucceeded: succeeded))
        }
        let target: DisplayInfo?
        if let displayID = message.displayID {
            guard let display = displays.first(where: { $0.id == displayID }), CGDisplayIsOnline(displayID) != 0 else {
                reply(false, "The selected Mac screen is no longer shared. Choose another screen."); return
            }
            target = display
        } else { target = nil }
        let now = ProcessInfo.processInfo.systemUptime
        guard connected, controlEnabled, !testMode, now - lastHeartbeat < 1.5, input.hasPermission else {
            reply(false, "Enable Mac control before opening apps."); return
        }
        guard !appLaunchInFlight, now - lastAppLaunch >= 1 else {
            reply(false, "An app is already opening. Try again in a moment."); return
        }
        lastAppLaunch = now; appLaunchInFlight = true
        let token = generation
        let launchToken = UUID()
        appLaunchToken = launchToken
        dockAppLauncher.launch(id: id, target: target, canRoute: { [weak self, weak connection] in
            guard let self, let connection, self.channel === connection, self.generation == token,
                  self.connected, self.controlEnabled, !self.testMode,
                  ProcessInfo.processInfo.systemUptime - self.lastHeartbeat < 1.5, self.input.hasPermission else { return false }
            return target.map { self.displays.contains($0) && CGDisplayIsOnline($0.id) != 0 } ?? true
        }) { [weak self, weak connection] outcome in
            guard let self, self.generation == token, self.appLaunchToken == launchToken, let connection, self.channel === connection else { return }
            self.appLaunchInFlight = false; self.appLaunchToken = nil
            let status: String
            if !outcome.opened { status = "Could not open this app. Refresh Mac apps and try again." }
            else if outcome.placed == true { status = "App opened on the selected Mac screen." }
            else if outcome.placed == false { status = "App opened, but its window could not be moved to the selected screen. It may have no movable window." }
            else { status = "App opened on your Mac." }
            reply(outcome.succeeded, status)
        }
        Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, self.generation == token, self.appLaunchToken == launchToken,
                  let connection, self.channel === connection else { return }
            self.appLaunchInFlight = false; self.appLaunchToken = nil
            reply(false, "The app took too long to open. Refresh Mac apps and try again.")
        }
    }

    /// The single response to a headset that stopped sending heartbeats, wherever it is noticed
    /// first. Input is released at once and control is re-armed for when heartbeats resume.
    ///
    /// The watchdog always answered this way, but an input that reached `receive` first after a
    /// stall — a main thread blocked past the window, then a queued burst with an input ahead of
    /// the next heartbeat — took the owner-pause path instead, and control stayed off until
    /// someone came to the Mac. Consent is unchanged: an owner or headset Stop still holds, and
    /// re-arming requires a grant this connection already had.
    private func releaseForStaleHeartbeat() {
        revoke("Headset stopped responding. Input released.", ownerPause: false)
        autoEnablePending = sessionRequestedControl && !ownerPausedControl && !peerPausedControl
    }

    // MARK: Hooks for remote access
    //
    // The remote access actions live in `CompanionModel+RemoteAccess.swift`. These are the changes
    // they make to this file's private session and consent state.

    /// Saves new remote preferences. The only way they change.
    func adoptRemoteConfiguration(_ configuration: RemoteHostConfiguration) {
        remoteConfiguration = configuration
        saveRemoteConfiguration(configuration)
    }

    /// The owner allowed the remote headset to control this Mac. A connected headset gets control at
    /// its next heartbeat, and one that reconnects at attach, unless it stopped control itself.
    func grantStandingControl() {
        ownerPausedControl = false
        persistControlPauses()
        sessionRequestedControl = true
        autoEnablePending = connected && !controlEnabled && !peerPausedControl
    }

    /// The owner withdrew remote control. It ends now, and neither the headset nor a heartbeat can
    /// turn it back on; only the owner can.
    func withdrawStandingControl() {
        sessionRequestedControl = false
        revoke(HeadsetNotice.controlTurnedOff, ownerPause: true)
    }

    /// Holds the Mac awake while a remote host shares with the preference on, and lets go at once
    /// when the preference is off.
    func applyKeepAwakePreference() {
        if !remoteConfiguration.keepAwake { keepAwake.release() } else if sharing { keepAwake.hold() }
    }

    /// Puts the remembered key on screen until `seconds` pass, a headset connects or the owner hides
    /// it. Nothing logs it: the key exists only in `pairingKey`.
    func revealPairingKey(_ key: PairingKey, for seconds: TimeInterval) {
        keyHideTask?.cancel()
        pairingKey = key.displayValue
        pairingKeyHidesAt = Date().addingTimeInterval(seconds)
        keyHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hidePairingKey()
        }
    }

    func hidePairingKey() {
        keyHideTask?.cancel(); keyHideTask = nil
        if !pairingKey.isEmpty { pairingKey = "" }
        if pairingKeyHidesAt != nil { pairingKeyHidesAt = nil }
    }

    /// Drops cached screen images and thumbnails before a key goes on screen.
    func dropCachedScreenContent() { previews = [:]; latestFrames = [:]; stalePreviews = [] }

    /// Handles one image from a capture: caches it for the next attach, sends it to a headset
    /// that is watching images, and marks the thumbnail for the next watchdog refresh. An idle
    /// repeat of the same image is still sent — it keeps the headset's freshness window open —
    /// but it does not redraw a thumbnail that would look exactly the same.
    func deliverImage(_ jpeg: Data, displayID id: UInt32) {
        if latestFrames[id] != jpeg {
            latestFrames[id] = jpeg
            stalePreviews.insert(id)
        }
        imageDelivered.send(id)
        guard !peerUsesVideo, let channel else { return }
        if channel.send(DeskMessage(kind: "frame", displayID: id, jpeg: jpeg)) { framesSent += 1 }
        else { framesDropped += 1 }
    }

    /// Counts encoded frames, promotes the session to video once every display can carry it,
    /// and sends the frames to the headset. Counting happens even with nobody attached.
    func deliverVideo(_ frames: [(UInt32, EncodedVideoFrame)], losses: Set<UInt32>) {
        for (id, frame) in frames { encodedFrameCounts[id, default: 0] += 1; encodedByteCount += frame.payload.count }
        videoSendRecovery.requireKeyframes(for: Array(losses))
        for id in losses { requestKeyframe(displayID: id) }
        if !peerUsesVideo, peerSupportsVideo, !captures.isEmpty, captures.allSatisfy(\.isEncodingVideo) {
            peerUsesVideo = true; captures.forEach { $0.requestKeyframe() }
        }
        guard peerUsesVideo, let channel else { return }
        for (id, frame) in frames {
            guard videoSendRecovery.allows(id: id, isKeyframe: frame.isKeyframe) else {
                framesDropped += 1; continue
            }
            let sent = channel.send(DeskMessage(kind: "video", displayID: id, video: frame))
            videoSendRecovery.record(id: id, isKeyframe: frame.isKeyframe, sent: sent)
            if sent { framesSent += 1 }
            else { framesDropped += 1; requestKeyframe(displayID: id) }
        }
    }

    /// Hands a display back to the JPEG path after its hardware encoder gave up.
    ///
    /// Capture itself is still healthy, so restarting it would only build a fresh encoder with a
    /// cleared failure latch and arrive back here — the loop this exists to break. Clearing
    /// `peerUsesVideo` is what actually re-opens image delivery: once it is set, the JPEG branch
    /// is skipped for every display, so a session that loses one encoder would otherwise show
    /// nothing at all on that screen. Promotion back to video cannot race this, because it
    /// requires every capture to report `isEncodingVideo`, and the failed one no longer does.
    func degradeToImageUpdates(_ reason: String) {
        guard peerUsesVideo || sharing || busy else { return }
        videoFallbackReason = reason
        peerUsesVideo = false
        lastKeyframeRequest = [:]
        // Image delivery is global, so the switch has to be too. A capture left encoding still
        // treats its JPEG as a background preview and emits it twice a second, which would show
        // as half-second lag on the three healthy displays while the failed one ran at full
        // rate. Latching every capture off also stops paying for encoders nothing consumes.
        (captures + preparingCaptures).forEach { $0.disableVideo() }
        // Re-send the cached image immediately so the display is not left on its last video
        // frame until the next capture callback happens to arrive.
        if let channel {
            for (id, jpeg) in latestFrames where channel.send(DeskMessage(kind: "frame", displayID: id, jpeg: jpeg)) {
                framesSent += 1
            }
        }
        publishStatus(reason)
    }

    deinit {
        timer?.invalidate()
        resumeTask?.cancel(); keyHideTask?.cancel()
        keepAwake.release()
    }

    /// Source drops and peer requests share a limiter so congestion cannot force an IDR on
    /// every encoder submission. Periodic keyframes remain available for eventual recovery.
    @discardableResult
    func requestKeyframe(displayID: UInt32, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard displays.contains(where: { $0.id == displayID }),
              now - (lastKeyframeRequest[displayID] ?? -.infinity) >= 0.5 else { return false }
        lastKeyframeRequest[displayID] = now
        captures.first(where: { $0.id == displayID })?.requestKeyframe()
        return true
    }

    /// Publishes every changed thumbnail in one update. Returns whether anything was published.
    private func refreshPreviews() -> Bool {
        guard !stalePreviews.isEmpty else { return false }
        var updated = previews
        for id in stalePreviews { updated[id] = latestFrames[id].flatMap(NSImage.init(data:)) }
        stalePreviews.removeAll()
        previews = updated
        return true
    }

    /// Starts the recovery schedule over once a session has stayed up, then runs the self-heal
    /// backstop. Both read the injected uptime.
    private func maintainUnattendedHosting(at now: TimeInterval) {
        if sharing, let started = sharingStartedUptime, RemoteRecoveryBackoff.isStable(sharingFor: now - started) { backoff.reset() }
        selfHealRemoteHosting(now: now)
    }

    private func watchdog() {
        let refreshedPreviews = refreshPreviews()
        // A thumbnail refresh already redraws the counters beside it.
        if statisticsDirty { statisticsDirty = false; if !refreshedPreviews { objectWillChange.send() } }
        maintainUnattendedHosting(at: uptime())
        let now = ProcessInfo.processInfo.systemUptime
        // Keep prompt revocation checks while controlling, but do not query TCC at 4Hz idle.
        if controlEnabled || now - lastIdlePermissionProbe >= 2 {
            refreshControlPermission()
            lastIdlePermissionProbe = now
        }
        guard controlEnabled else { return }
        if (now - lastHeartbeat) >= 1.5 {
            releaseForStaleHeartbeat()
        }
        else if let started = input.dragStarted, (now - started) >= 30 {
            // release() clears dragStarted. A safety timeout must not require a person at the Mac.
            revoke("Drag time limit reached. Input released.", ownerPause: false)
            autoEnablePending = sessionRequestedControl && !ownerPausedControl && !peerPausedControl
        }
    }
}
