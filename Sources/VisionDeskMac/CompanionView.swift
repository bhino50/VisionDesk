import SwiftUI
import DeskCore

/// The everyday flow is pairing and sharing. Troubleshooting and remote configuration are
/// available without competing with the connection action.
struct CompanionView: View {
    @ObservedObject var model: CompanionModel
    @State private var showSettings = false
    @State private var showDisplays = false
    @State private var resetPairing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(systemName: "vision.pro").font(.system(size: 38)).foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your Mac, on Vision Pro").font(.largeTitle.bold())
                        Text(model.remoteConfiguration.enabled ? "Connect from your saved Mac on Vision Pro." : "Open VisionDesk on Vision Pro and choose this Mac.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Label(model.connected ? "Vision Pro connected" : model.sharing ? "Ready to connect" : "Connect your Vision Pro",
                              systemImage: model.connected ? "checkmark.circle.fill" : "display")
                            .font(.title2.bold())
                        Text(model.status).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Button(model.canStopSharing ? "Stop Sharing" : model.busy ? "Preparing…" : "Start Sharing") {
                                if model.canStopSharing { model.stop() } else { model.start() }
                            }.buttonStyle(.borderedProminent)
                            if !model.screenPermission {
                                Button("Allow Screen Recording") { model.requestScreenPermission() }
                            }
                            Spacer()
                            if model.sharing && !model.connected && model.pairingKey.isEmpty {
                                Button("Show Pairing Key") { model.showPairingKey() }
                            }
                        }
                        if model.remoteConfiguration.enabled {
                            Text("Remote access uses your saved address, so this Mac does not appear in Nearby Macs.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Use Same-Network Connection") { model.useNearbyConnection() }
                        }
                        if !model.pairingKey.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Pair once with this key. Vision Pro saves this Mac.").font(.callout)
                                Text(model.pairingKey).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                                Button("Hide Key") { model.hidePairingKey() }.font(.caption)
                            }
                        }
                        if !model.remoteConfiguration.enabled {
                            Toggle("Allow the paired Vision Pro to control this Mac", isOn: Binding(
                                get: { model.lanConfiguration.allowControl },
                                set: { model.setLANControlAllowed($0) }))
                            if !model.inputPermission {
                                Text("Viewing works without control. Allow Accessibility to use your Mac from Vision Pro.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Allow Accessibility") { model.requestInputPermission() }
                            }
                        }
                        if model.connected {
                            HStack {
                                Label(model.controlEnabled ? "Mac control enabled" : "Viewing only", systemImage: model.controlEnabled ? "cursorarrow" : "eye")
                                Spacer()
                                if model.controlEnabled { Button("Stop Input") { model.revoke() } }
                                else if model.inputPermission { Button("Enable Mac Control") { model.enableInput() } }
                            }.font(.callout)
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                DisclosureGroup("Displays · \(model.displays.count) shared of \(model.availableDisplays.count) connected", isExpanded: $showDisplays) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.canStopSharing ? "Stop Sharing to change which screens are shared." : "Choose up to four screens. Other displays can stay connected.")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(model.availableDisplays) { display in
                            HStack {
                                Toggle(display.name, isOn: Binding(
                                    get: { model.displays.contains { $0.id == display.id } },
                                    set: { model.setDisplayShared(display.id, shared: $0) }))
                                    .disabled(model.canStopSharing || (!model.displays.contains { $0.id == display.id } && model.displays.count >= 4)
                                              || (model.displays.contains { $0.id == display.id } && model.displays.count == 1))
                                Spacer()
                                Text("\(display.width) × \(display.height)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("Refresh Displays") { model.refreshInventory() }.disabled(model.sharing || model.busy)
                        Button("Choose First Four Automatically") { model.useAutomaticDisplaySelection() }
                            .disabled(model.canStopSharing)
                    }.padding(.top, 10)
                }
                DisclosureGroup("Settings & Troubleshooting", isExpanded: $showSettings) {
                    VStack(alignment: .leading, spacing: 16) {
                        RemoteAccessPanel(model: model)
                        SetupCheckPanel(model: model)
                        DisclosureGroup("Diagnostics") {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("Test gestures without moving the Mac pointer", isOn: $model.testMode)
                                Text("Received \(model.inputCount) input events · \(model.lastInput)")
                                Text("Sent \(model.framesSent) frames · dropped \(model.framesDropped)")
                            }.font(.caption).padding(.top, 8)
                        }
                        if !model.remoteConfiguration.enabled {
                            Button("Reset Saved Pairing…", role: .destructive) { resetPairing = true }
                        }
                    }.padding(.top, 12)
                }
                Text("Encrypted connection. Pairing stays on your devices.").font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
        .frame(minWidth: 640, minHeight: 460)
        .preferredColorScheme(.dark)
        .confirmationDialog("Reset pairing?", isPresented: $resetPairing) {
            Button("Reset Pairing", role: .destructive) { model.resetLANPairing() }
        } message: {
            Text("Sharing stops and saved headsets must pair again with a new key.")
        }
    }
}
