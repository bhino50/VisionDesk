import AppKit
import DeskCore
import DeskTransport

extension CompanionModel {
    var persistentHostingRequested: Bool {
        remoteConfiguration.enabled ? !remoteConfiguration.sharingStopped : lanConfiguration.enabled
    }
    var reconnectControlAllowed: Bool {
        remoteConfiguration.enabled ? remoteConfiguration.allowControl : lanConfiguration.allowControl
    }

    func setLANAvailability(_ enabled: Bool) {
        guard lanConfiguration.enabled != enabled else { return }
        var configuration = lanConfiguration
        configuration.enabled = enabled
        adoptLANConfiguration(configuration)
    }

    func adoptLANConfiguration(_ configuration: LANHostConfiguration) {
        lanConfiguration = configuration
        saveLANConfiguration(configuration)
    }

    /// Control pauses survive a disconnect, capture rebuild and application restart. A grant for
    /// one connection does not become standing consent unless the owner sets the toggle.
    func persistControlPauses() {
        if remoteConfiguration.enabled {
            var configuration = remoteConfiguration
            configuration.ownerPaused = ownerPausedControl
            configuration.peerPaused = peerPausedControl
            adoptRemoteConfiguration(configuration)
            return
        }
        var configuration = lanConfiguration
        configuration.ownerPaused = ownerPausedControl
        configuration.peerPaused = peerPausedControl
        adoptLANConfiguration(configuration)
    }

    func setLANControlAllowed(_ allowed: Bool) {
        guard allowed != lanConfiguration.allowControl else { return }
        guard !allowed || refreshControlPermission() else {
            status = "Allow Accessibility, then turn Mac control on."; return
        }
        var configuration = lanConfiguration
        configuration.allowControl = allowed
        adoptLANConfiguration(configuration)
        if allowed { grantStandingControl() }
        else { withdrawStandingControl() }
    }

    /// This exact plan starts the one server. Loading a credential never rotates it; the
    /// initial Start Sharing action is the only implicit creation opportunity.
    func listenerPlan(remote: (endpoint: RemoteMacAddress, key: PairingKey)?, allowCreation: Bool = true) throws -> HostListenerPlan {
        let name = Host.current().localizedName ?? "VisionDesk Mac"
        if let remote { return HostListenerPlan(key: remote.key, port: remote.endpoint.port, bindHost: remote.endpoint.host, name: name) }
        let key: PairingKey
        if let stored = try loadLANKey() { key = stored }
        else {
            guard allowCreation else { throw PairingKeyStoreError.unreadableItem }
            key = PairingKey.generate()
            try saveLANKey(key)
            revealPairingKey(key, for: keyReveal.firstPairing)
        }
        return HostListenerPlan(key: key, port: nil, bindHost: nil, name: name)
    }

    func showPairingKey() {
        if remoteConfiguration.enabled { showRemotePairingKey(); return }
        guard !connected else { status = "Disconnect Vision Pro before showing the pairing key."; return }
        do {
            guard let key = try loadLANKey() else {
                status = "Start sharing to create the first pairing key."; return
            }
            dropCachedScreenContent()
            revealPairingKey(key, for: keyReveal.onRequest)
        } catch { status = "Could not read saved pairing. \(error.localizedDescription)" }
    }

    /// An explicit, confirmed owner action. The old connection ends before the key changes.
    /// Only this confirmed action removes the old item. If replacement fails, sharing stays
    /// stopped and the owner must retry reset; ordinary saves never delete an existing key.
    func resetLANPairing() {
        guard !remoteConfiguration.enabled else { return }
        stop()
        hidePairingKey()
        var removedOldItem = false
        do {
            let key = PairingKey.generate()
            try deleteLANKey()
            removedOldItem = true
            adoptLANConfiguration(.disabled)
            try saveLANKey(key)
            ownerPausedControl = false; peerPausedControl = false
            revealPairingKey(key, for: keyReveal.firstPairing)
            status = "Pairing reset. Start sharing, then pair Vision Pro with this key."
        } catch {
            status = removedOldItem
                ? "Old pairing removed, but the replacement could not be saved. Sharing is stopped. Retry Reset Saved Pairing. \(error.localizedDescription)"
                : "Could not remove saved pairing. Sharing is stopped and the old item was kept. \(error.localizedDescription)"
        }
    }

    /// Switches the single listener to nearby sharing without forgetting remote pairing.
    /// The saved remote address and consent are retained for a later explicit mode switch.
    func useNearbyConnection() {
        guard remoteConfiguration.enabled else { return }
        stop(headsetNotice: "Switching to same-network sharing. Reconnect from Nearby Macs on Vision Pro.")
        hidePairingKey()
        var remote = remoteConfiguration
        remote.enabled = false
        adoptRemoteConfiguration(remote)
        ownerPausedControl = lanConfiguration.ownerPaused
        peerPausedControl = lanConfiguration.peerPaused
        start()
    }

    func startSavedHosting() {
        if remoteConfiguration.enabled { startConfiguredRemoteAccess() }
        else if lanConfiguration.enabled { start(allowControl: lanConfiguration.allowControl, resetControlPause: false) }
    }

    /// True only while the key-backed reconnect listener exists. An unstarted connection or
    /// a teardown cannot promise persistence to the headset.
    func headsetStatus(_ value: String) -> DeskMessage {
        DeskMessage(kind: "status", status: value, controlEnabled: controlEnabled,
                    keepsPairing: listenerKeepsPairing ? true : nil)
    }
}
