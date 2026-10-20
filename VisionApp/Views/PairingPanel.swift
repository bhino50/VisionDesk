import DeskCore
import SwiftUI

/// The way in while no Mac is connected.
///
/// A returning wearer sees the saved Mac and one Connect. Everyone else sees the Macs on this
/// network: choose one, enter the key it shows, connect. Everything rarer — a Mac reached by
/// address, forgetting the saved Mac, pairing a different one — is a step away and never beside
/// the primary action. The content scrolls while the status line and the actions stay in view, so
/// the window's minimum size never hides the button that moves things forward.
@MainActor
struct PairingPanel: View {
    @ObservedObject var model: DeskClientModel
    @State private var isPairingAnotherMac = false

    var body: some View {
        Group {
            if let saved = model.rememberedMac, !isPairingAnotherMac {
                SavedMacPanel(model: model, mac: saved) { isPairingAnotherMac = true }
            } else {
                PairingForm(model: model, savedMacName: model.rememberedMac?.name) {
                    isPairingAnotherMac = false
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
}

/// Content that scrolls above a status line and an action row that never do. While a Mac is being
/// dialled, or a retry is waiting, the actions are the ones that apply to that: Try Now when a
/// retry is waiting, and Cancel.
@MainActor
private struct PanelLayout<Content: View, Actions: View>: View {
    @ObservedObject var model: DeskClientModel
    private let content: Content
    private let actions: Actions

    init(model: DeskClientModel, @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        _model = ObservedObject(wrappedValue: model)
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            ConnectionStatusLine(model: model)
            HStack(spacing: 14) {
                if model.isConnecting || model.isReconnecting {
                    Spacer(minLength: 0)
                    // Between scheduled attempts nothing is in flight, so waiting out the backoff
                    // is optional: a Mac worth retrying can be dialled at once.
                    if model.canReconnectNow {
                        Button("Try Now", action: model.reconnectNow)
                    }
                    Button("Cancel") { model.disconnect() }
                } else {
                    actions
                }
            }
        }
    }
}

/// The Mac this headset already trusts. Connecting needs no key, because its key is in this
/// Vision Pro's keychain rather than on anyone's screen. Pairing a different Mac and forgetting
/// this one are rare, so they wait behind More.
@MainActor
private struct SavedMacPanel: View {
    @ObservedObject var model: DeskClientModel
    let mac: RememberedMac
    let pairAnotherMac: () -> Void
    @State private var isConfirmingForget = false

    var body: some View {
        PanelLayout(model: model) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.cyan)
                        .frame(width: 64, height: 64)
                        .background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mac.name).font(.title2.weight(.semibold)).lineLimit(1)
                        Text(SessionCopy.savedMacDetail(mac))
                            .font(mac.address == nil ? .subheadline : .subheadline.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Text("Saved on this Vision Pro, so it connects without a pairing key.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.lastConnectionFailure != nil {
                    Button("Pair Again…") {
                        model.disconnect()
                        pairAnotherMac()
                    }
                    Text("Use the Mac’s current pairing key or network address. Your saved pairing stays until a new connection succeeds.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            Menu {
                Button("Use a Different Mac", action: pairAnotherMac)
                Button("Forget This Mac…", role: .destructive) { isConfirmingForget = true }
            } label: {
                // Named, not an icon alone: the advice for a saved Mac that stopped answering says
                // to look under More.
                Label("More", systemImage: "ellipsis.circle")
            }
            Spacer(minLength: 0)
            Button("Connect", action: model.connectRemembered)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canConnectRemembered)
        }
        .confirmationDialog("Forget \(mac.name)?", isPresented: $isConfirmingForget, titleVisibility: .visible) {
            Button("Forget This Mac", role: .destructive, action: model.forgetRememberedMac)
            Button("Keep It", role: .cancel) {}
        } message: {
            Text("Removes its pairing key from this Vision Pro. To connect again, you'll need the key shown on your Mac.")
        }
    }
}

/// Pairing with a key. The Macs on this network come first; a Mac on another network, reached at
/// its address over a VPN, is the one alternative, a step away. A verified connection is saved
/// for next time on its own, so there is nothing to choose about that here.
@MainActor
private struct PairingForm: View {
    @ObservedObject var model: DeskClientModel
    let savedMacName: String?
    let backToSavedMac: () -> Void
    @FocusState private var focus: Field?
    @State private var usesAddress = false
    @State private var isKeyVisible = false

    private enum Field: Hashable { case address, key }

    var body: some View {
        PanelLayout(model: model) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if usesAddress {
                    addressField
                } else {
                    nearbyList
                }
                keyField
                Button(switchTitle) {
                    focus = nil
                    usesAddress.toggle()
                }
                .font(.footnote)
                .buttonStyle(.borderless)
                .disabled(model.isConnecting)
            }
        } actions: {
            if let savedMacName {
                Button(action: backToSavedMac) {
                    Label("Saved Mac", systemImage: "chevron.backward")
                }
                .accessibilityLabel("Back to \(savedMacName)")
            }
            Spacer(minLength: 0)
            if savedMacName == nil, model.canReconnectNow {
                // The retries gave up, but that Mac and its key are still known, so bringing it
                // back needs no key and no address.
                Button("Reconnect", action: model.reconnectNow)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityHint("Dials \(SessionCopy.macName(model.connectedName)) again without asking for a pairing key.")
                Button("Connect", action: connect)
                    .controlSize(.large)
                    .disabled(!canConnect)
            } else {
                Button("Connect", action: connect)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canConnect)
            }
        }
        .onChange(of: model.pairingCode.isEmpty) { _, isEmpty in
            // The key is cleared once a connection is made, and is never left revealed for the next.
            if isEmpty { isKeyVisible = false }
        }
    }

    private var title: String { usesAddress ? "Connect by address" : "Connect to your Mac" }

    private var subtitle: String {
        usesAddress
            ? "For a Mac on another network, reached over a VPN such as Tailscale."
            : "Choose your Mac, then enter the pairing key it shows."
    }

    private var switchTitle: String { usesAddress ? "Back to Macs on This Network" : "Connect by Address" }

    private var canConnect: Bool { usesAddress ? model.canConnectDirectly : model.canConnect }

    private func connect() {
        focus = nil
        if usesAddress {
            model.connectDirectly()
        } else {
            model.connect()
        }
    }

    // MARK: On this network

    @ViewBuilder
    private var nearbyList: some View {
        if model.peers.isEmpty {
            discoveryState
        } else {
            VStack(spacing: 10) {
                ForEach(model.peers) { peer in
                    peerRow(peer)
                }
            }
        }
    }

    /// While no Mac is listed: searching, which is normal and needs nothing, or the one thing to
    /// change so a Mac can appear. Searching runs on its own, so searching again is offered only
    /// when something stopped it.
    private var discoveryState: some View {
        let guidance = SessionCopy.discoveryGuidance(status: model.discoveryStatus)
        return VStack(spacing: 10) {
            if guidance.needsAttention {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
            }
            Text(guidance.title).font(.headline)
            Text(guidance.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if guidance.needsAttention {
                Button("Search Again", action: model.refreshDiscovery)
                    .disabled(model.isConnecting)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 17))
    }

    private func peerRow(_ peer: NearbyMac) -> some View {
        let isSelected = model.selectedPeerID == peer.id
        return Button {
            model.selectedPeerID = peer.id
            focus = .key
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "desktopcomputer").font(.title2).accessibilityHidden(true)
                Text(peer.name).font(.headline).lineLimit(1)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.cyan : Color.secondary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(isSelected ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 17))
            .contentShape(RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .disabled(model.isConnecting)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    // MARK: By address

    private var addressField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mac address").font(.subheadline.weight(.medium))
            TextField("100.64.0.42 or mac-studio.tailnet.ts.net", text: $model.directAddress)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.body.monospaced())
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .address)
                .submitLabel(.next)
                .onSubmit { focus = .key }
                .disabled(model.isConnecting)
            addressHint
        }
    }

    /// Echoing the parsed form is the honest signal available before a handshake: it confirms the
    /// text is usable, not that the Mac answers.
    @ViewBuilder
    private var addressHint: some View {
        if let parsed = model.directMacAddress {
            Label("Will connect to \(parsed.formatted)", systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.green)
        } else if !model.directAddress.isEmpty {
            Label("Not a usable address yet. A name or IP, with an optional :port.", systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.orange)
        } else {
            Text("Uses port \(String(RemoteMacAddress.defaultPort)) unless you add another one.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Pairing key

    /// Hidden by default and shown only on request, so 32 characters can be checked against the
    /// Mac before connecting. The line beneath says what is missing; it never repeats the key.
    private var keyField: some View {
        let entry = model.keyEntry
        return VStack(alignment: .leading, spacing: 8) {
            Text("Pairing key").font(.subheadline.weight(.medium))
            HStack(spacing: 10) {
                Group {
                    if isKeyVisible {
                        TextField("Shown in VisionDesk on your Mac", text: $model.pairingCode)
                    } else {
                        SecureField("Shown in VisionDesk on your Mac", text: $model.pairingCode)
                    }
                }
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .key)
                .submitLabel(.go)
                .onSubmit(connect)
                .disabled(model.isConnecting)
                .accessibilityLabel("Pairing key")
                Button {
                    isKeyVisible.toggle()
                } label: {
                    Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                }
                .accessibilityLabel(isKeyVisible ? "Hide pairing key" : "Show pairing key")
                .help(isKeyVisible ? "Hide pairing key" : "Show pairing key")
            }
            Label(SessionCopy.keyEntryHint(entry), systemImage: Self.symbol(for: entry))
                .font(.footnote)
                .foregroundStyle(Self.tint(for: entry))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func symbol(for entry: SessionCopy.KeyEntry) -> String {
        switch entry {
        case .complete: return "checkmark.circle"
        case .invalidCharacters, .tooLong: return "exclamationmark.circle"
        case .empty, .partial: return "key"
        }
    }

    private static func tint(for entry: SessionCopy.KeyEntry) -> Color {
        switch entry {
        case .complete: return .green
        case .invalidCharacters, .tooLong: return .orange
        case .empty, .partial: return .secondary
        }
    }
}
