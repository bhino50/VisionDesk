import DeskCore
import SwiftUI

/// The same authenticated Mac catalog in the overview and each screen’s inline panel.
@MainActor
struct MacDockLauncher: View {
    @ObservedObject var model: DeskClientModel
    @ObservedObject var launcher: MacDockLauncherModel
    var expanded = false
    @State private var selectedDisplayID: UInt32?

    init(model: DeskClientModel, expanded: Bool = false, defaultDisplayID: UInt32? = nil) {
        self.model = model
        self.launcher = model.dockLauncher
        self.expanded = expanded
        self._selectedDisplayID = State(initialValue: defaultDisplayID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mac Dock").font(.headline)
                    Text(launcher.supportsPlacement ? "Opens or moves the app on your Mac" : "Opens on your Mac").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: model.refreshDockApps) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!model.hasActiveWindow || !model.isLinked || !model.isMacResponsive)
                .accessibilityHint("Reads the apps currently in your Mac’s Dock.")
            }
            if launcher.supportsPlacement {
                Picker("Open on", selection: $selectedDisplayID) {
                    Text("Current location").tag(UInt32?.none)
                    ForEach(Array(model.displays.enumerated()), id: \.element.id) { index, display in
                        Text("\(index + 1) · \(display.info.name)").tag(Optional(display.id))
                    }
                    if let selectedDisplayID, model.display(id: selectedDisplayID) == nil {
                        Text("Selected screen is no longer shared").tag(Optional(selectedDisplayID))
                    }
                }
                .disabled(launcher.isLaunching)
                .accessibilityHint("Choose which Mac screen receives the app window. No other app is closed.")
            } else {
                Text("Apps open at their current location. Update the Mac companion to choose a screen.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !destinationAvailable {
                Text("That screen is no longer shared. Choose another destination before opening an app.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if launcher.apps.isEmpty {
                Text("No launchable apps were found in your Mac’s Dock. Add an app there, then refresh.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if expanded {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        appButtons
                    }
                }
                .frame(maxHeight: 330)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) { appButtons }
                }
                .scrollIndicators(.hidden)
            }
            if let status = launcher.launchStatus {
                HStack(alignment: .top, spacing: 8) {
                    if launcher.isLaunching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: launcher.launchSucceeded == true ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(launcher.launchSucceeded == true ? .green : .orange)
                    }
                    Text(status).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("dock-launch-status")
            }
            if !model.isMacResponsive {
                Text("Your Mac is not responding. App buttons will return when it reconnects.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !model.canControl {
                HStack(alignment: .center) {
                    Text("Viewing only. Request Control to open apps on your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Request Control", action: model.resumeControl)
                        .disabled(!model.canResumeControl)
                }
            }
        }
        .padding(expanded ? 22 : 14)
        .background(.white.opacity(expanded ? 0 : 0.04), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("mac-dock-launcher")
    }

    private var destinationAvailable: Bool {
        guard launcher.supportsPlacement, let selectedDisplayID else { return true }
        return model.display(id: selectedDisplayID) != nil
    }

    private var appButtons: some View {
        ForEach(launcher.apps) { app in
            Button { model.launchDockApp(id: app.id, displayID: launcher.supportsPlacement ? selectedDisplayID : nil) } label: {
                VStack(spacing: 6) {
                    ZStack {
                        if let image = launcher.icons[app.id] {
                            Image(uiImage: image).resizable().scaledToFit()
                        } else {
                            Image(systemName: "app.fill").resizable().scaledToFit().padding(7)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 48, height: 48)
                    Text(app.name).font(.caption).lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: 82, height: 34, alignment: .top)
                }
                .padding(8)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .disabled(!model.canLaunchDockApps || !destinationAvailable)
            .accessibilityLabel("Open \(app.name) on your Mac")
            .accessibilityValue(launcher.launchingAppID == app.id ? "Opening" : "")
            .accessibilityHint("Launches or brings this Mac app to the front. It stays on your Mac displays.")
        }
    }
}
