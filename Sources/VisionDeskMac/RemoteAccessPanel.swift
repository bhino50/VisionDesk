import DeskCore
import SwiftUI

/// Remote access over Tailscale. Every action answers right here: a refusal with its one-step fix,
/// a confirmation, and the pairing card while the owner has asked to see the key.
struct RemoteAccessPanel: View {
    @ObservedObject var model: CompanionModel
    @State private var address = ""
    @State private var allowControl = true
    @State private var keepAwake = true
    @State private var confirmingForget = false

    private var remote: RemoteHostConfiguration { model.remoteConfiguration }

    var body: some View {
        GroupBox("Remote Workstation · Private VPN") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect both devices to your private VPN, then pair once to reconnect while away. Tailscale, WireGuard and other VPNs must already provide a route between them.")
                    .foregroundStyle(.secondary)
                TextField("This Mac’s VPN IP · IPv4 or [IPv6]", text: $address)
                    .textFieldStyle(.roundedBorder)
                    // Return does what the button does; an address that is already saved changes nothing.
                    .onSubmit(applyAddress)
                // Once remote access is on, both apply the moment they change.
                Toggle("Allow the paired headset to control this Mac",
                       isOn: preference(\.allowControl, before: $allowControl, apply: model.setRemoteControlAllowed))
                Toggle("Keep this Mac awake while sharing",
                       isOn: preference(\.keepAwake, before: $keepAwake, apply: model.setRemoteKeepAwake))
                actions
                feedback

                if remote.enabled {
                    Label(model.connected ? "Vision Pro is connected." : model.status,
                          systemImage: model.connected ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("You can close this window. VisionDesk stays in the menu bar. Locking the Mac pauses sharing until it is unlocked.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(remote.enabled ? "Turn off remote access and forget the pairing key?" : "Forget saved VPN pairing?", isPresented: $confirmingForget) {
            Button("Disable & Forget", role: .destructive) { model.disableRemoteAccess() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.connected
                 ? "The connected headset disconnects now. To use remote access again, pair Vision Pro with a new key."
                 : "To use remote access again, pair Vision Pro with a new key.")
        }
        .onAppear(perform: syncFields)
        .onChange(of: remote.enabled) { _, _ in syncFields() }
        .onChange(of: remote.address) { _, _ in syncFields() }
    }

    @ViewBuilder private var actions: some View {
        HStack {
            if remote.enabled {
                Button("Save Address", action: applyAddress).disabled(!addressEdited)
                Button("Show Pairing Key") { model.showRemotePairingKey() }
                    .disabled(model.connected)
                    .help(model.connected ? "The connected headset already has the key." : "Shows the key for a minute.")
                Button("Disable & Forget…", role: .destructive) { confirmingForget = true }
            } else {
                Button("Enable Remote Access", action: applyAddress).buttonStyle(.borderedProminent)
                if model.remoteFeedback?.tone == .problem {
                    Button("Reset VPN Pairing…", role: .destructive) { confirmingForget = true }
                }
            }
        }
    }

    @ViewBuilder private var feedback: some View {
        if let feedback = model.remoteFeedback, !isSettled(feedback.fix) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: feedback.tone == .problem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(feedback.tone == .problem ? Color.yellow : Color.green)
                Text(feedback.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let fix = feedback.fix { fixButton(fix) }
            }.font(.callout)
        }
    }

    /// A permission problem goes away once the permission is granted.
    private func isSettled(_ fix: RemoteFeedback.Fix?) -> Bool {
        switch fix {
        case .allowAccessibility: return model.inputPermission
        case .allowScreenRecording: return model.screenPermission
        case .useAddress, .none: return false
        }
    }

    @ViewBuilder private func fixButton(_ fix: RemoteFeedback.Fix) -> some View {
        switch fix {
        case .allowAccessibility: Button("Allow Accessibility") { model.requestInputPermission() }
        case .allowScreenRecording: Button("Allow Screen Recording") { model.requestScreenPermission() }
        case .useAddress(let own): Button("Use \(own)") { address = own }
        }
    }

    /// Live once remote access is on; before that, only remembered for Enable Remote Access.
    private func preference(_ saved: KeyPath<RemoteHostConfiguration, Bool>, before: Binding<Bool>,
                            apply: @escaping (Bool) -> Void) -> Binding<Bool> {
        guard remote.enabled else { return before }
        return Binding(get: { model.remoteConfiguration[keyPath: saved] }, set: apply)
    }

    private func applyAddress() {
        model.configureRemoteAccess(address: address,
                                    allowControl: remote.enabled ? remote.allowControl : allowControl,
                                    keepAwake: remote.enabled ? remote.keepAwake : keepAwake)
    }

    private var addressEdited: Bool {
        let typed = address.trimmingCharacters(in: .whitespaces)
        return (RemoteMacAddress(string: typed)?.formatted ?? typed) != remote.address
    }

    /// The address as a person types it: VisionDesk's own port goes without saying.
    private func displayAddress(_ saved: String) -> String {
        guard let parsed = RemoteMacAddress(string: saved) else { return saved }
        return parsed.port == RemoteMacAddress.defaultPort ? RemoteAccessReview.inputAddress(parsed.host) : parsed.formatted
    }

    private func syncFields() {
        guard !remote.enabled else { address = displayAddress(remote.address); return }
        address = model.suggestedRemoteAddress ?? ""
        allowControl = true
        keepAwake = remote.keepAwake
    }
}

/// The remembered key while the owner has asked to see it: everything Vision Pro needs to add this
/// Mac, and how long until the key hides again.
struct RemotePairingCard: View {
    let address: String
    let key: String
    let hidesAt: Date?
    let hide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On Vision Pro, open VisionDesk and add this Mac:").font(.callout.weight(.semibold))
            LabeledContent("Address") { Text(address).font(.body.monospaced()).textSelection(.enabled) }
            LabeledContent("Pairing key") { Text(key).font(.system(.title3, design: .monospaced)).textSelection(.enabled) }
            HStack {
                if let hidesAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Hides in \(Self.remaining(until: hidesAt, now: context.date))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Hide Key", action: hide)
            }
        }
        .padding(12)
        .background(.cyan.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    static func remaining(until end: Date, now: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
