import SwiftUI
import AppKit
import ApplicationServices
import Combine
import DeskCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: CompanionModel? { didSet { runDiagnosticsWhenReady() } }
    let companionWindow = CompanionWindowLifecycle()
    private var captureCheck: CaptureCheck?
    private var hasLaunched = false
    private var diagnosticsStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        hasLaunched = true
        runDiagnosticsWhenReady()
    }

    private func runDiagnosticsWhenReady() {
        guard hasLaunched, let model, !diagnosticsStarted,
              CommandLine.arguments.contains("--runtime-report") || CommandLine.arguments.contains("--capture-check") || CommandLine.arguments.contains("--input-latency-check") || CommandLine.arguments.contains("--pairing-store-check") else { return }
        diagnosticsStarted = true
        Task { @MainActor [self] in
            if CommandLine.arguments.contains("--pairing-store-check") {
                PairingStoreCheck.run()
                if !CommandLine.arguments.contains("--runtime-report") { return }
            }
            // Bind to the window's actual onAppear instead of assuming it appears by 0.8s.
            for _ in 0..<20 {
                if NSApp.windows.contains(where: { $0.isVisible }) { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            for _ in 0..<100 {
                if !model.busy { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            writeRuntimeReport(model)
            if CommandLine.arguments.contains("--input-latency-check") {
                await InputLatencyCheck().run()
            } else if CommandLine.arguments.contains("--capture-check") {
                let check = CaptureCheck()
                captureCheck = check
                await check.run(model: model)
                captureCheck = nil
            } else if CommandLine.arguments.contains("--runtime-report") {
                // A short opt-in observation window verifies codec choice and reconnects on
                // the actual signed host; no pairing key or desktop pixels enter the report.
                for _ in 0..<40 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    writeRuntimeReport(model)
                }
            }
        }
    }

    private func writeRuntimeReport(_ model: CompanionModel) {
        let args = CommandLine.arguments
        let markerIndex = args.firstIndex(of: "--runtime-report-id")
        let marker = markerIndex.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "manual"
        let report: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "reportID": marker, "processID": ProcessInfo.processInfo.processIdentifier,
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "windows": NSApp.windows.filter { $0.isVisible }.map { $0.title },
            "displayCount": model.displays.count,
            "screenCaptureAllowed": model.screenPermission,
            "inputAllowed": model.inputPermission,
            "accessibilityTrusted": AXIsProcessTrusted(),
            "eventPostingAllowed": CGPreflightPostEventAccess(),
            "sharing": model.sharing, "connected": model.connected,
            "controlEnabled": model.controlEnabled, "inputCount": model.inputCount,
            "videoEncoderCount": model.videoEncoderCount, "sendingH264": model.sendingH264,
            "framesSent": model.framesSent, "framesDropped": model.framesDropped,
            "encodedFrameCounts": Dictionary(uniqueKeysWithValues: model.encodedFrameCounts.map { (String($0.key), $0.value) }),
            "remoteAccessEnabled": model.remoteConfiguration.enabled,
            // Whether a key is on screen, never the key itself.
            "pairingKeyVisible": !model.pairingKey.isEmpty,
            "remoteAddress": model.remoteConfiguration.address, "status": model.status,
            "restartPending": model.restartPending, "autoRecoveryArmed": model.autoRecoveryArmed,
            "imageIntervalSeconds": model.imageInterval
        ]
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("runtime-report.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch { NSLog("VisionDesk runtime report could not be saved: %@", error.localizedDescription) }
    }

    func applicationWillTerminate(_ notification: Notification) { model?.stop(manual: false, headsetNotice: HeadsetNotice.quit) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// A Dock click or a second launch. A remote host keeps running with its window closed, so
    /// this brings the companion window back instead of leaving nothing to click.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        companionWindow.shouldHandleReopen()
    }
}

@main
struct VisionDeskMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = CommandLine.arguments.contains("--capture-check")
        ? CaptureCheck.makeModel()
        : CompanionModel(saveDisplaySelection: CompanionModel.persistDisplaySelection,
                         resolveDisplaySelection: CompanionModel.resolveSavedDisplaySelection,
                         lanConfiguration: .load(), remoteConfiguration: .load())
    var body: some Scene {
        // One window with a stable identity: opening it again raises or recreates this window and
        // never adds a second (see `CompanionWindowLifecycle`).
        Window("VisionDesk · Mac Companion", id: CompanionWindowLifecycle.sceneID) {
            CompanionWindowRoot(model: model, delegate: delegate)
        }
        .defaultSize(width: 880, height: 750)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
        MenuBarExtra("VisionDesk", systemImage: model.controlEnabled ? "cursorarrow.rays" : "display.2") {
            OpenCompanionButton(companionWindow: delegate.companionWindow)
            Divider()
            // Enabled during a scheduled restart too, so the owner can retry without waiting.
            Button("Start Sharing") { model.start() }
                .disabled(model.sharing || model.busy)
            Text(model.connected ? "Headset connected" : model.sharing ? "Ready to connect" : model.status)
            Button("Stop Input") { model.revoke() }.disabled(!model.controlEnabled)
            Button("Stop Sharing") { model.stop() }
            Button("Quit VisionDesk") { NSApp.terminate(nil) }
        }
    }
}

/// The companion window's root. It passes SwiftUI's open action on for the Dock and relaunch
/// path, and reports the window appearing and closing, so launch-only work runs once.
struct CompanionWindowRoot: View {
    let model: CompanionModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        CompanionView(model: model)
            .onAppear {
                delegate.companionWindow.register { openWindow(id: CompanionWindowLifecycle.sceneID) }
                if delegate.companionWindow.windowAppeared(model) { delegate.model = model }
            }
            .onDisappear { delegate.companionWindow.windowClosed(model) }
    }
}

/// The way back to a closed companion window while a remote host keeps running without one.
struct OpenCompanionButton: View {
    let companionWindow: CompanionWindowLifecycle
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open VisionDesk") {
            companionWindow.register { openWindow(id: CompanionWindowLifecycle.sceneID) }
            companionWindow.show()
        }
    }
}



private let setupRecheckInterval: TimeInterval = 2

/// Guided readiness panel. Every value comes from CompanionModel's published
/// state, so it follows along while permissions and sessions change. It never
/// repeats the pairing key and never claims more than the Mac can observe.
struct SetupCheckPanel: View {
    @ObservedObject var model: CompanionModel
    @State private var showSteps = true
    @State private var recheck = Timer.publish(every: setupRecheckInterval, on: .main, in: .common).autoconnect()

    var body: some View {
        let readiness = model.setupReadiness
        GroupBox("Setup Check") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: readiness.status(of: .viewing).symbolName)
                        .font(.title3).foregroundStyle(readiness.status(of: .viewing).tint)
                    Text(readiness.headline).font(.headline)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    ForEach(SetupTrack.allCases) { track in
                        badge(track.shortTitle, status: readiness.status(of: track))
                    }
                    Spacer(minLength: 0)
                }
                nextStep(readiness)
                DisclosureGroup(isExpanded: $showSteps) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(SetupTrack.allCases) { track in step(track, readiness: readiness) }
                    }.padding(.top, 8)
                } label: {
                    Text("Step-by-step").font(.caption.bold()).foregroundStyle(.secondary)
                }
                if let note = readiness.displayGoalNote {
                    Label(note, systemImage: "rectangle.3.group").font(.callout).foregroundStyle(.secondary)
                }
                Text("Based only on what this Mac can observe: permissions, capture state, and the session. It cannot confirm what the headset is drawing, input counts do not prove an app reacted, and the pairing key is never repeated here.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onReceive(recheck) { _ in
            // Matches the Refresh Displays button, which macOS only allows
            // while nothing is being captured.
            guard !model.sharing, !model.busy else { return }
            model.refreshInventory()
        }
    }

    private func badge(_ title: String, status: SetupStatus) -> some View {
        Text("\(title): \(status.label)")
            .font(.caption2.bold())
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(status.tint.opacity(0.18), in: Capsule())
            .foregroundStyle(status.tint)
    }

    @ViewBuilder private func nextStep(_ readiness: SetupReadiness) -> some View {
        if let action = readiness.primaryNextStep {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("DO THIS NEXT").font(.caption2.bold())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.yellow.opacity(0.18), in: Capsule())
                    .foregroundStyle(.yellow)
                Text(action).font(.callout).textSelection(.enabled)
                Spacer(minLength: 0)
            }
        } else {
            Label("Everything this Mac can check is in place.", systemImage: "checkmark.seal.fill")
                .font(.callout).foregroundStyle(.green)
        }
    }

    @ViewBuilder private func step(_ track: SetupTrack, readiness: SetupReadiness) -> some View {
        let status = readiness.status(of: track)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(track.title.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
                Text(status.label.uppercased()).font(.caption2.bold()).foregroundStyle(status.tint)
                Spacer(minLength: 0)
            }
            ForEach(readiness.checks.filter { $0.track == track }) { check in row(check) }
        }
    }

    private func row(_ check: SetupCheck) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: check.status.symbolName).foregroundStyle(check.status.tint).frame(width: 17)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.title).font(.callout.weight(.semibold))
                Text(check.detail).font(.caption).foregroundStyle(.secondary)
                if check.status != .ready, let action = check.nextStep {
                    Text(action).font(.caption).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private extension SetupStatus {
    var symbolName: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .inProgress: return "hourglass"
        case .actionNeeded: return "exclamationmark.triangle.fill"
        case .inactive: return "minus.circle"
        }
    }

    var tint: Color {
        switch self {
        case .ready: return .green
        case .inProgress: return .cyan
        case .actionNeeded: return .yellow
        case .inactive: return .secondary
        }
    }
}
