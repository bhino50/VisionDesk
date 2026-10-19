import Foundation
// `errSecUserCanceled` and `errSecAuthFailed` are read below when classifying a Keychain failure.
import Security
import DeskCore
import DeskTransport

// Remote access: turning it on, moving it to a new address, its two preferences, showing its
// pairing key, and turning it off. Every action answers in `remoteFeedback`, which the panel shows
// beside the control the owner used, and nothing is saved, started or read from Keychain before a
// request checks out. A saved key goes on screen only when the owner asks, and only for a while.
extension CompanionModel {
    /// What a remote start found before touching capture.
    enum RemoteStartCheck {
        case ready(RemoteMacAddress, PairingKey)
        /// Cannot work until the owner acts, so nothing retries.
        case stop(String)
        /// Can clear by itself, so it retries on the backoff.
        case retry(String)
    }

    /// Checks a remote start in the order that costs least: the saved address, that this Mac has it,
    /// then the pairing key. Only `.ready` goes on to capture.
    func checkRemoteStart() -> RemoteStartCheck {
        guard let endpoint = RemoteAccessReview.endpoint(from: remoteConfiguration.address) else {
            return .stop("Remote host configuration is invalid. Enable remote access again.")
        }
        // Tailscale can still be connecting at login or after a wake. Waiting costs no capture.
        guard localAddresses().contains(endpoint.host) else {
            return .retry(RemoteAccessReview.waitingForTailscale(endpoint.host))
        }
        do {
            guard let key = try loadRemoteKey() else {
                return .stop("Remote pairing key is missing. Enable remote access again on this Mac.")
            }
            return .ready(endpoint, key)
        } catch let storageError as PairingKeyStoreError {
            switch storageError {
            case .invalidAccount, .notEntitled, .unreadableItem:
                return .stop("Remote pairing needs repair: \(storageError.localizedDescription)")
            case .accessDenied(let code) where code == errSecUserCanceled || code == errSecAuthFailed:
                return .stop("Remote pairing access was denied. Start sharing again after allowing Keychain access.")
            default:
                return .retry(Self.keychainMayBeLocked)
            }
        } catch {
            return .retry(Self.keychainMayBeLocked)
        }
    }

    /// The login keychain may still be locked just after login, so this retries cheaply before any
    /// capture preparation instead of latching unattended sharing off.
    private static let keychainMayBeLocked = "Could not read the remote pairing key. Keychain may still be locked."

    /// Turns remote access on, or moves it to a new address. The same address changes nothing: the
    /// preferences apply on their own, so Update and Return never drop a connected headset.
    @discardableResult
    func configureRemoteAccess(address: String, allowControl: Bool, keepAwake: Bool) -> RemoteAccessChange {
        guard let endpoint = RemoteAccessReview.endpoint(from: address) else {
            remoteFeedback = RemoteAccessReview.unreadable(localAddresses: localAddresses())
            return .refused
        }
        if remoteConfiguration.enabled, endpoint.formatted == remoteConfiguration.address {
            setRemoteControlAllowed(allowControl)
            setRemoteKeepAwake(keepAwake)
            return .unchanged
        }
        let addresses = localAddresses()
        guard addresses.contains(endpoint.host) else {
            remoteFeedback = RemoteAccessReview.notOnThisMac(endpoint.host, localAddresses: addresses)
            return .refused
        }
        guard screenCaptureAccess() else { remoteFeedback = .needsScreenRecording; return .refused }
        guard !allowControl || refreshControlPermission() else { remoteFeedback = .needsAccessibility; return .refused }
        let firstPairing = !remoteConfiguration.enabled
        var newKey: PairingKey?
        do {
            if try loadRemoteKey() == nil {
                let key = PairingKey.generate()
                try saveRemoteKey(key)
                newKey = key
            }
        } catch {
            remoteFeedback = .problem("Could not save the pairing key securely: \(error.localizedDescription)")
            return .refused
        }
        stop(headsetNotice: firstPairing ? HeadsetNotice.remoteTurnedOn : HeadsetNotice.addressChanged)
        adoptRemoteConfiguration(RemoteHostConfiguration(enabled: true, address: endpoint.formatted,
                                                         allowControl: allowControl, keepAwake: keepAwake))
        testMode = false
        if let newKey {
            revealPairingKey(newKey, for: keyReveal.firstPairing)
            remoteFeedback = .done("Remote access is on. On Vision Pro, add this Mac with its address and pairing key.")
        } else {
            remoteFeedback = firstPairing
                ? .done("Remote access is on. Your saved Vision Pro pairing still works.")
                : .done("Address changed to \(endpoint.host). On Vision Pro, add this Mac again with the new address.")
        }
        start(allowControl: allowControl)
        return .restarted
    }

    /// Turns remote access off and forgets its pairing key, so every headset has to pair again.
    /// The panel asks the owner to confirm first.
    func disableRemoteAccess() {
        stop(headsetNotice: HeadsetNotice.remoteTurnedOff)
        hidePairingKey()
        adoptRemoteConfiguration(.disabled)
        do {
            try deleteRemoteKey()
            remoteFeedback = .done("Remote access is off, and its pairing key is forgotten.")
        } catch {
            remoteFeedback = .problem("Remote access is off, but the old pairing key could not be removed: \(error.localizedDescription)")
        }
    }

    /// Shows the remembered key for a while, so another headset can pair. Refused while one is
    /// connected: that headset already has the key, and it may be watching this screen.
    func showRemotePairingKey() {
        guard remoteConfiguration.enabled else { return }
        guard !connected else {
            remoteFeedback = .problem("Disconnect the headset to show the pairing key. A connected headset already has it.")
            return
        }
        do {
            guard let key = try loadRemoteKey() else {
                hidePairingKey()
                remoteFeedback = .problem("No pairing key is saved on this Mac. Choose Disable & Forget, then turn remote access on again to make a new one.")
                return
            }
            dropCachedScreenContent()
            revealPairingKey(key, for: keyReveal.onRequest)
            remoteFeedback = nil
        } catch {
            hidePairingKey()
            remoteFeedback = .problem("Could not read the pairing key: \(error.localizedDescription)")
        }
    }

    /// "Allow the paired headset to control this Mac", applied at once without restarting sharing.
    /// Off takes control back from a connected headset immediately and is saved before anything
    /// else can happen; neither the headset nor a heartbeat can turn it on again. On needs
    /// Accessibility access, and a connected headset gets control at its next heartbeat.
    func setRemoteControlAllowed(_ allowed: Bool) {
        guard remoteConfiguration.enabled, allowed != remoteConfiguration.allowControl else { return }
        var updated = remoteConfiguration
        updated.allowControl = allowed
        guard allowed else {
            withdrawStandingControl()
            adoptRemoteConfiguration(updated)
            remoteFeedback = connected ? .done("Control is off. The connected headset can only view this Mac now.") : nil
            return
        }
        guard refreshControlPermission() else {
            remoteFeedback = .problem("Mac control needs Accessibility access for VisionDeskMac. Allow it, then turn control on again.",
                                      fix: .allowAccessibility)
            return
        }
        adoptRemoteConfiguration(updated)
        grantStandingControl()
        remoteFeedback = nil
    }

    /// "Keep this Mac awake while sharing", applied at once.
    func setRemoteKeepAwake(_ keepAwake: Bool) {
        guard remoteConfiguration.enabled, keepAwake != remoteConfiguration.keepAwake else { return }
        var updated = remoteConfiguration
        updated.keepAwake = keepAwake
        adoptRemoteConfiguration(updated)
        applyKeepAwakePreference()
    }

    func startConfiguredRemoteAccess() {
        if remoteConfiguration.enabled { start(allowControl: remoteConfiguration.allowControl, resetControlPause: false) }
    }

    /// This Mac's Tailscale address when it has exactly one, so the owner need not look it up.
    var suggestedRemoteAddress: String? { RemoteAccessReview.onlyTailnetAddress(localAddresses()) }
}
