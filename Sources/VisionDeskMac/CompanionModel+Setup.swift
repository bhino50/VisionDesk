import AppKit
import DeskCore

// What the companion reports to the Setup Check panel, the display inventory it shares, and the
// screen recording request. None of it touches session or consent state.
extension CompanionModel {
    static let displaySelectionPreference = "VisionDesk.SelectedDisplays"

    static func displayIdentity(_ id: UInt32) -> String? {
        guard let identity = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, identity) as String
    }

    static func resolveSavedDisplaySelection(inventory: [DisplayInfo]) -> Set<UInt32>? {
        guard let saved = UserDefaults.standard.object(forKey: displaySelectionPreference) else { return nil }
        // Old or malformed numeric preferences fail closed and need owner reselection.
        guard let identities = saved as? [String] else { return [] }
        let current = Dictionary(uniqueKeysWithValues: inventory.compactMap { display in
            displayIdentity(display.id).map { (display.id, $0) }
        })
        return DisplayCapturePlan.resolve(identities: Set(identities), current: current)
    }

    static func persistDisplaySelection(_ selection: Set<UInt32>?) {
        if let selection { UserDefaults.standard.set(selection.compactMap(displayIdentity).sorted(), forKey: displaySelectionPreference) }
        else { UserDefaults.standard.removeObject(forKey: displaySelectionPreference) }
    }

    var displaySelectionUnavailableStatus: String {
        selectedDisplayIDs == nil
            ? "No connected displays are ready. Connect or wake a screen to resume sharing."
            : "Your selected screens are unavailable. Reconnect them, or Stop Sharing and choose screens under Displays."
    }

    func setDisplayShared(_ id: UInt32, shared: Bool) {
        guard !canStopSharing, availableDisplays.contains(where: { $0.id == id }) else { return }
        var selection = Set(displays.map(\.id))
        if shared {
            guard selection.count < DeskMessage.maximumSharedDisplays else { return }
            selection.insert(id)
        } else {
            guard selection.count > 1 else { return }
            selection.remove(id)
        }
        selectedDisplayIDs = selection
        saveDisplaySelection(selection)
        refreshInventory()
    }

    func useAutomaticDisplaySelection() {
        guard !canStopSharing else { return }
        selectedDisplayIDs = nil
        saveDisplaySelection(nil)
        refreshInventory()
    }

    /// Observed readiness for the Setup Check panel. Reads published state only and passes flags,
    /// never the pairing key itself. A remote host has remembered pairing: its saved headset
    /// connects with the key it stored, so an empty key on screen calls for no new one.
    var setupReadiness: SetupReadiness {
        SetupReadiness(snapshot: SetupSnapshot(displayCount: displays.count,
                                               screenRecordingAllowed: screenPermission,
                                               accessibilityAllowed: inputPermission,
                                               preparing: busy,
                                               sharing: sharing,
                                               connected: connected,
                                               controlEnabled: controlEnabled,
                                               testMode: testMode,
                                               pairingKeyReady: !pairingKey.isEmpty,
                                               rememberedPairing: listenerKeepsPairing,
                                               nearbyPairing: !remoteConfiguration.enabled))
    }

    /// Every display macOS reports, valid, unique and main-display first.
    static func liveInventory() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen -> DisplayInfo? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            let bounds = CGDisplayBounds(id)
            let width = CGDisplayPixelsWide(id)
            let height = CGDisplayPixelsHigh(id)
            let name = DisplayIdentity.name(localizedName: screen.localizedName, displayID: id,
                                            builtIn: CGDisplayIsBuiltin(id) != 0,
                                            main: id == CGMainDisplayID(), width: width, height: height)
            return DisplayInfo(id: id, name: name, width: width, height: height, originX: bounds.minX, originY: bounds.minY, pointWidth: bounds.width, pointHeight: bounds.height)
        }
        // One display reporting unusable geometry would otherwise make the whole "displays"
        // message invalid, so the client would silently receive no list at all.
        .filter(\.isValid)
        .sorted {
            if ($0.id == CGMainDisplayID()) != ($1.id == CGMainDisplayID()) { return $0.id == CGMainDisplayID() }
            return $0.id < $1.id
        }
    }

    func requestScreenPermission() {
        screenPermission = CGRequestScreenCaptureAccess()
        status = screenPermission ? "Screen capture allowed. Start sharing when ready." : "Allow VisionDeskMac in Privacy & Security → Screen & System Audio Recording, then relaunch if macOS requests it."
    }
}
