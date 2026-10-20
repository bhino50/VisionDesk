import SwiftUI

/// The session's state at a glance, in the overview's header and every display window's.
@MainActor
struct ConnectionBadge: View {
    @ObservedObject var model: DeskClientModel
    @State private var showingDetails = false

    var body: some View {
        Button { showingDetails = true } label: {
            Label(model.connectionLabel, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Connection details")
        .accessibilityValue(model.connectionLabel)
        .accessibilityHint("Shows connection status and the freshness of each screen.")
        .help("Connection details")
        .popover(isPresented: $showingDetails) {
            ConnectionDetailsPanel(model: model)
        }
    }

    /// A silent Mac outranks every other state here, as it does in `connectionLabel`, so the
    /// badge never shows a green "Control enabled" over a link nothing is arriving on.
    private var isSilent: Bool { model.isLinked && !model.isMacResponsive }

    private var isDialling: Bool { !model.isLinked && (model.isReconnecting || model.isConnecting) }

    private var symbol: String {
        if isSilent { return "exclamationmark.triangle.fill" }
        if model.canControl { return "checkmark.circle.fill" }
        if isDialling { return "arrow.triangle.2.circlepath" }
        return "circle"
    }

    private var tint: Color {
        if isSilent { return .orange }
        if model.canControl { return .green }
        if isDialling { return .cyan }
        return .secondary
    }
}

/// Available from the status badge even while disconnected. No keys, host addresses or
/// device identifiers are displayed, and opening this panel never changes the session.
@MainActor
private struct ConnectionDetailsPanel: View {
    @ObservedObject var model: DeskClientModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Connection details").font(.title3.weight(.semibold))
                LabeledContent("Status", value: model.connectionLabel)
                LabeledContent("Connection", value: model.connectionRouteLabel)
                if model.isLinked {
                    LabeledContent("Control", value: model.controlSummary.title)
                    LabeledContent("Screens shared", value: "\(model.displays.count)")
                } else if model.retryExhausted {
                    Label("Automatic attempts finished", systemImage: "pause.circle")
                        .foregroundStyle(.orange)
                } else if model.reconnectAttempt > 0 {
                    LabeledContent("Reconnect attempt", value: "\(model.reconnectAttempt) of \(DeskClientModel.reconnectDelays.count)")
                }
                ForEach(Array(model.displays.enumerated()), id: \.element.id) { index, stream in
                    StreamConnectionDetails(stream: stream, number: index + 1)
                }
                Text(ConnectionDiagnostics.recoveryAdvice(
                    isLinked: model.isLinked, isResponsive: model.isMacResponsive,
                    hasDisplays: !model.displays.isEmpty, retryExhausted: model.retryExhausted,
                    isRetrying: model.isConnecting || model.isReconnecting))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.canReconnectNow {
                    Button("Reconnect now", action: model.reconnectNow)
                        .accessibilityHint("Ends the current connection and tries the same Mac again.")
                }
                Text("Frame age is time since a picture was decoded here. It is not a network latency measurement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline)
            .padding(24)
        }
        .frame(width: 480, height: model.displays.isEmpty ? 330 : 550)
    }
}

@MainActor
private struct StreamConnectionDetails: View {
    @ObservedObject var stream: DisplayStream
    let number: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 7) {
                Text("\(number) · \(stream.info.name)").font(.headline)
                LabeledContent("Picture", value: stream.isFresh() ? "Live" : "Waiting for a fresh frame")
                LabeledContent("Format", value: stream.receivedAt == nil ? "Waiting" : stream.usesVideo ? "H.264 video" : "Image updates")
                LabeledContent("Last decoded frame", value: ConnectionDiagnostics.frameAge(
                    receivedAt: stream.receivedAt, now: ProcessInfo.processInfo.systemUptime))
                if let warning = stream.decodeWarning {
                    Text(warning).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

/// The source's readiness, rather than a Mac-wide grant that may outlive a source's last frame.
@MainActor
struct DisplayControlBadge: View {
    @ObservedObject var model: DeskClientModel
    @ObservedObject var stream: DisplayStream
    @State private var showingDetails = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let ready = model.isMacResponsive && model.canControl(displayID: stream.id)
            let paused = !model.isMacResponsive || !stream.isFresh()
            Button { showingDetails = true } label: {
                Label(ready ? "Control ready" : paused ? "Paused" : model.controlSummary.title,
                      systemImage: ready ? "cursorarrow.rays" : paused ? "pause.circle" : "eye")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ready ? Color.green : paused ? Color.orange : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityHint("Open connection details. " + (ready ? "Input is available on this screen."
                               : paused ? "This screen is waiting for a fresh connection or frame before input resumes."
                               : model.controlSummary.detail))
        }
        .popover(isPresented: $showingDetails) { ConnectionDetailsPanel(model: model) }
    }
}

/// Shown while the linked Mac has sent nothing for longer than a healthy one is ever quiet.
///
/// It counts the silence, says whether VisionDesk will recover on its own, and offers the one
/// action that helps: dialling again when this session can, disconnecting when it cannot. A
/// one-time nearby session cannot be dialled again — that Mac stops sharing once its session
/// closes — so it is never offered a reconnection it could not deliver.
@MainActor
struct NotRespondingBanner: View {
    @ObservedObject var model: DeskClientModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(SessionCopy.notRespondingTitle).font(.headline)
                // The silence is read on demand rather than published, so only this line ticks.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(SessionCopy.notRespondingDetail(
                        seconds: model.macSilence() ?? 0,
                        willRecover: model.willRecoverAutomatically,
                        canReconnect: model.canReconnectNow
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if model.canReconnectNow {
                Button("Reconnect", action: model.reconnectNow)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Dials your Mac again with the key this session already verified.")
            } else {
                Button("Disconnect") { model.disconnect() }
            }
        }
        .padding(18)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.orange.opacity(0.3)))
    }
}

/// The overview's control card: what is true about control now, and the one control action that
/// applies. Everything it says and offers comes from `DeskClientModel.controlSummary`, so Stop is
/// on screen exactly while there is a grant to stop, and a request exactly while there is not.
@MainActor
struct ControlStatusCard: View {
    @ObservedObject var model: DeskClientModel

    var body: some View {
        let summary = model.controlSummary
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: summary.symbol)
                .font(.title2)
                .foregroundStyle(Self.tint(summary.tone))
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(summary.title).font(.headline)
                Text(summary.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            switch summary.action {
            case .requestControl:
                // Disabled exactly while `resumeControl` would refuse, so it never appears to do
                // nothing. The Mac may still decline; its answer replaces the detail above.
                Button("Request Control", action: model.resumeControl)
                    .disabled(!model.canResumeControl)
                    .accessibilityHint("Asks your Mac to turn control on. Your Mac decides.")
            case .stopControl:
                Button(role: .destructive, action: model.stopControl) {
                    Label("Stop Control", systemImage: "stop.circle.fill")
                }
                .accessibilityHint("Revokes control on all displays at once. Viewing continues.")
            case .none:
                EmptyView()
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private static func tint(_ tone: SessionCopy.ControlSummary.Tone) -> Color {
        switch tone {
        case .active: return .green
        case .neutral: return .cyan
        case .attention: return .orange
        }
    }
}

/// Where the connection stands while no Mac is connected: progress while one is being dialled or
/// a retry is waiting, otherwise the last outcome. Nothing while there is nothing to say.
@MainActor
struct ConnectionStatusLine: View {
    @ObservedObject var model: DeskClientModel

    var body: some View {
        if let text {
            HStack(alignment: .top, spacing: 10) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(isBusy ? Color.cyan : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var isBusy: Bool { model.isConnecting || model.isReconnecting }

    private var text: String? {
        if let message = model.connectionMessage { return message }
        guard model.isConnecting else { return nil }
        return "Connecting to \(SessionCopy.macName(model.connectedName))…"
    }
}
