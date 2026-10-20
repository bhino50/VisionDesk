import DeskCore
import SwiftUI

@MainActor
struct WorkspaceWindow: View {
    @ObservedObject var model: DeskClientModel
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var windows: DeskWindowRegistry
    @State private var largePreviews = false
    @State private var showingWorkspaceHelp = false
    @State private var showingDetails = false

    var body: some View {
        VStack(spacing: 22) {
            header
            if let message = windows.message {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
            if let warning = model.pairingPersistenceWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("pairingPersistenceWarning")
            }
            if model.isLinked {
                connectedWorkspace
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        if showingDetails {
                            HStack(alignment: .top) {
                                ConnectionDetailsPanel(model: model)
                                Button("Done") { showingDetails = false }
                            }
                        }
                        PairingPanel(model: model)
                    }
                }
            }
        }
        .padding(28)
        .frame(minWidth: 720, idealWidth: 820, minHeight: 600, idealHeight: 720)
        .glassBackgroundEffect()
        .modifier(DeskWindowLifecycle(model: model))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.cyan)
                .frame(width: 60, height: 60)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("VisionDesk").font(.largeTitle.weight(.semibold))
                Text(model.isLinked ? model.connectedName : "Your Mac, across your space")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            ConnectionBadge(model: model)
            Menu {
                Button("Connection details", systemImage: "info.circle") {
                    showingDetails.toggle()
                    showingWorkspaceHelp = false
                }
                if model.isLinked {
                    Button("Arrange & control", systemImage: "questionmark.circle") {
                        showingWorkspaceHelp.toggle()
                        showingDetails = false
                    }
                }
                if windows.openDisplayCount > 0 {
                    Button("Close all screen windows", systemImage: "xmark.rectangle") { windows.closeAllDisplays() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More workspace options")
            // In the header rather than a footer row of its own, so the displays keep that height
            // at the window's minimum size.
            if model.isLinked {
                Button("Disconnect") { model.disconnect() }
                    .accessibilityHint("Ends the session with your Mac and stops control.")
            }
        }
    }

    private var connectedWorkspace: some View {
        VStack(spacing: 18) {
            if !model.isMacResponsive {
                NotRespondingBanner(model: model)
            }
            ControlStatusCard(model: model)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mac displays").font(.title3.weight(.semibold))
                    Text(Self.displayCount(model.displays.count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    largePreviews.toggle()
                } label: {
                    Label(largePreviews ? "Grid" : "Large previews",
                          systemImage: largePreviews ? "square.grid.2x2" : "rectangle")
                }
                .accessibilityHint("Changes the preview size in this overview. Your display windows stay open.")
                Button {
                    for display in model.displays {
                        windows.open(.display(display.id)) { openWindow(id: "display", value: display.id) }
                    }
                } label: {
                    Label(windows.openDisplayCount > 0 ? "Show All" : "Open All", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.displays.isEmpty)
            }

            Label("Choose a screen to open or return to its window.", systemImage: "hand.draw")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                VStack(spacing: 18) {
                    if showingDetails {
                        HStack(alignment: .top) {
                            ConnectionDetailsPanel(model: model)
                            Button("Done") { showingDetails = false }
                        }
                    }
                    if showingWorkspaceHelp {
                        HStack(alignment: .top) {
                            WorkspaceHelpPanel()
                            Button("Done") { showingWorkspaceHelp = false }
                        }
                    }
                    if model.dockLauncher.isAvailable {
                        MacDockLauncher(model: model)
                    }
                    if model.displays.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Waiting for your Mac’s screens").font(.headline)
                            Text("They appear once VisionDesk on your Mac is sharing, which needs Screen Recording permission there.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16),
                                                 count: largePreviews ? 1 : 2),
                                  spacing: 16) {
                            ForEach(model.displays) { display in
                                DisplayOverviewCard(stream: display, number: displayNumber(display.id), isOpen: windows.isOpen(display.id)) {
                                    windows.open(.display(display.id)) { openWindow(id: "display", value: display.id) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func displayNumber(_ id: UInt32) -> Int {
        (model.displays.firstIndex(where: { $0.id == id }) ?? 0) + 1
    }

    private static func displayCount(_ count: Int) -> String {
        switch count {
        case 0: return "None shared yet"
        case 1: return "1 display · Opens in its own window"
        default: return "\(count) displays · Each opens in its own window"
        }
    }
}

/// One shared display. The whole card opens its window: the preview is the largest target on
/// the overview, so it is the one that acts.
@MainActor
private struct DisplayOverviewCard: View {
    @ObservedObject var stream: DisplayStream
    let number: Int
    let isOpen: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 13) {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    ZStack(alignment: .topLeading) {
                        ZStack {
                            Color.black.opacity(0.8)
                            if let image = stream.image {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "display").font(.largeTitle)
                                    Text("Waiting for screen").font(.caption)
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                        .aspectRatio(16 / 10, contentMode: .fit)
                        HStack {
                            Text("\(number)")
                                .font(.headline.monospacedDigit())
                                .frame(width: 30, height: 30)
                                .background(.black.opacity(0.7), in: Circle())
                            Spacer()
                            Label(stream.isFresh() ? "Live" : "Waiting",
                                  systemImage: stream.isFresh() ? "circle.fill" : "pause.circle")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(stream.isFresh() ? Color.green : Color.orange)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.7), in: Capsule())
                        }
                        .padding(10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(number) · \(stream.info.name)").font(.headline).lineLimit(1)
                        Text("\(stream.info.width) × \(stream.info.height)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Label(isOpen ? "Show window" : "Open", systemImage: isOpen ? "rectangle.on.rectangle" : "arrow.up.forward.square")
                        .font(.subheadline.weight(.medium))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22))
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Open screen \(number), \(stream.info.name)")
        .accessibilityValue(stream.isFresh() ? "Live" : "Waiting for a fresh frame")
        .help("Open \(stream.info.name)")
    }
}

/// Advice matches system window behavior; the app does not claim to place windows in space.
private struct WorkspaceHelpPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Make the space yours").font(.title3.weight(.semibold))
            Label("Open one screen, or Open All to work across your physical Mac displays.",
                  systemImage: "square.grid.2x2")
            Label("Move each window using its bottom window bar. Resize it from a lower corner.",
                  systemImage: "arrow.up.left.and.arrow.down.right")
            Label("Use Focus view inside a screen to make more room for your desktop.",
                  systemImage: "arrow.up.left.and.arrow.down.right.rectangle")
            Label("Pinch and move to place the pointer. A quick pinch clicks where that pointer is. Use Drag or Scroll for those actions.",
                  systemImage: "cursorarrow.motionlines")
            Label("Click the intended Mac text field before opening Keyboard. The Mac’s focused app receives your typing.",
                  systemImage: "keyboard")
            Label("Stop Control turns off input on every screen. Your screens remain visible.",
                  systemImage: "stop.circle")
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .padding(26)
        .frame(maxWidth: .infinity)
    }
}

@MainActor
struct DeskWindowLifecycle: ViewModifier {
    let model: DeskClientModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var windowID = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { model.updateScene(windowID, phase: scenePhase) }
            .onChange(of: scenePhase) { _, phase in model.updateScene(windowID, phase: phase) }
            .onDisappear { model.updateScene(windowID, phase: nil) }
    }
}
