import DeskCore
import SwiftUI
import UIKit

@MainActor
struct DisplayWindow: View {
    @ObservedObject var model: DeskClientModel
    let displayID: UInt32
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var windows: DeskWindowRegistry

    var body: some View {
        Group {
            if let stream = model.display(id: displayID) {
                ConnectedDisplay(model: model, stream: stream)
            } else {
                let placeholder = SessionCopy.displayPlaceholder(
                    isLinked: model.isLinked, isReconnecting: model.isReconnecting,
                    isConnecting: model.isConnecting, macName: model.connectedName
                )
                VStack(spacing: 18) {
                    Image(systemName: placeholder.symbol)
                        .font(.system(size: 50, weight: .light))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(placeholder.title)
                        .font(.title2.weight(.semibold))
                    Text(placeholder.detail)
                        .foregroundStyle(.secondary)
                    if placeholder.showsProgress {
                        ProgressView()
                        if let message = model.connectionMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    // While the screen is on its way back, waiting is the next step, so opening the
                    // overview is offered without being the one thing to do.
                    if placeholder.showsProgress {
                        Button("Open VisionDesk") { windows.open(.overview) { openWindow(id: "desk") } }
                    } else {
                        Button("Open VisionDesk") { windows.open(.overview) { openWindow(id: "desk") } }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Close this screen", systemImage: "xmark.rectangle") {
                        windows.close(.display(displayID))
                    }
                }
                .multilineTextAlignment(.center)
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassBackgroundEffect()
            }
        }
        .frame(minWidth: 100, minHeight: 100)
        .modifier(DeskWindowLifecycle(model: model))
    }
}

@MainActor
private struct ConnectedDisplay: View {
    @ObservedObject var model: DeskClientModel
    @ObservedObject var stream: DisplayStream
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var windows: DeskWindowRegistry
    @State private var mode: ScreenInteractionMode = .direct
    private enum Accessory { case dock, keyboard, help, details }
    @State private var accessory: Accessory?
    @State private var focusView = false
    @State private var geometryMessage: String?
    @State private var gestureToken = UUID()

    var body: some View {
        DisplaySurface(model: model, stream: stream, mode: mode)
            .id(gestureToken)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DisplayWindowGeometry(
                imageSize: CGSize(width: stream.info.width, height: stream.info.height),
                onFailure: { geometryMessage = $0 }
            ))
            .ornament(attachmentAnchor: .scene(.top), contentAlignment: .bottom) {
                VStack(spacing: 6) {
                    header
                    if let message = windows.message ?? geometryMessage {
                        Text(message).font(.footnote).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(width: 560)
                .glassBackgroundEffect()
                .padding(.bottom, 8)
            }
            .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
                VStack(spacing: 8) {
                    inputToolbar
                    if !focusView {
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            Text(controlHint(model, stream: stream, mode: mode))
                                .font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10)
                .frame(width: 560)
                .glassBackgroundEffect()
                .padding(.top, 8)
            }
            .ornament(attachmentAnchor: .scene(.trailing), contentAlignment: .leading) {
                if let accessory {
                    VStack(alignment: .trailing, spacing: 6) {
                        Button("Done", systemImage: "xmark") { self.accessory = nil }
                        ScrollView {
                            switch accessory {
                            case .dock: MacDockLauncher(model: model, defaultDisplayID: stream.id)
                            case .keyboard: KeyboardPanel(model: model, displayID: stream.id)
                            case .help: ScreenControlHelpPanel(mode: mode)
                            case .details: ConnectionDetailsPanel(model: model)
                            }
                        }
                    }
                    .padding(12)
                    .frame(width: 340, height: 560)
                    .glassBackgroundEffect()
                    .padding(.leading, 14)
                }
            }
        .onChange(of: mode) { _, _ in
            // Replacing the surface ends its own active pinch in onDisappear; its recognizer
            // cannot continue in the previous mode after the selection has changed.
            gestureToken = UUID()
        }
        .onChange(of: accessory) { _, _ in gestureToken = UUID() }
        .onChange(of: focusView) { _, _ in
            // Resizing the visible surface ends any previous coordinate space's pinch.
            gestureToken = UUID()
        }
    }

    private var inputToolbar: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                HStack(spacing: 10) {
                    Picker("Interaction mode", selection: $mode) {
                        ForEach(ScreenInteractionMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.symbol).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 350)
                    .disabled(!model.canControl(displayID: stream.id))

                    Spacer(minLength: 0)
                    Menu {
                        Button("Left click", systemImage: "cursorarrow.click") {
                            model.clickAtLastPointer(displayID: stream.id)
                        }
                        .disabled(!model.canClick(displayID: stream.id))
                        Button("Right click") {
                            model.click(displayID: stream.id, action: "rightClick")
                        }
                        .disabled(!model.canClick(displayID: stream.id))
                        Button("Double click") {
                            model.click(displayID: stream.id, action: "doubleClick")
                        }
                        .disabled(!model.canClick(displayID: stream.id))
                        Divider()
                        Button("Center pointer", systemImage: "scope") {
                            model.placePointer(displayID: stream.id, at: CGPoint(x: 0.5, y: 0.5))
                        }
                        .disabled(!model.canPlacePointer(displayID: stream.id))
                    } label: {
                        Label("Mouse", systemImage: "computermouse")
                            .labelStyle(.iconOnly)
                    }
                    .help("Mouse actions")
                    .accessibilityHint("Click actions use the last pointer position on this screen.")
                    if model.controlSummary.action == .requestControl {
                        Button("Request Control", action: model.resumeControl)
                            .disabled(!model.canResumeControl)
                            .accessibilityHint("Asks your Mac to allow input. Your Mac decides.")
                    } else {
                        Button(role: .destructive, action: model.stopControl) {
                            Text("Stop")
                        }
                        // A grant can always be stopped, even if this display has gone stale.
                        .disabled(!model.isMacControlEnabled)
                        .accessibilityLabel("Stop control on all displays")
                        .help("Stop control on all displays")
                    }
                }
            }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("\(screenNumber)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.cyan)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.08), in: Circle())
                .accessibilityLabel("Screen \(screenNumber)")
            VStack(alignment: .leading, spacing: 3) {
                Text(stream.info.name).font(.headline).lineLimit(1)
                if !focusView {
                    Text("\(model.connectedName) · \(stream.info.width) × \(stream.info.height)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            DisplayControlBadge(model: model, stream: stream)
            if !model.isMacResponsive, model.canReconnectNow {
                Button("Reconnect", action: model.reconnectNow)
                    .accessibilityHint("Dials your Mac again with the key this session already verified.")
            }
            if model.dockLauncher.isAvailable {
                Button("Dock", systemImage: "dock.rectangle") {
                    accessory = accessory == .dock ? nil : .dock
                }
                .labelStyle(.iconOnly)
                .help("Mac Dock apps")
                .accessibilityLabel("Mac Dock apps")
            }
            Button("Keyboard", systemImage: "keyboard") {
                accessory = accessory == .keyboard ? nil : .keyboard
            }
            .labelStyle(.iconOnly)
            .help("Keyboard")
            .accessibilityLabel("Text and keyboard shortcuts")
            Menu {
                Button(focusView ? "Show screen details" : "Focus view",
                       systemImage: "arrow.up.left.and.arrow.down.right") { focusView.toggle() }
                Button("Connection details", systemImage: "info.circle") { accessory = .details }
                Button("Screen control help", systemImage: "questionmark.circle") { accessory = .help }
                Button("Display overview", systemImage: "square.grid.2x2") {
                    windows.open(.overview) { openWindow(id: "desk") }
                }
                Section("Screens") {
                    ForEach(model.displays) { display in
                        let number = (model.displays.firstIndex(where: { $0.id == display.id }) ?? 0) + 1
                        Button("\(number) · \(display.info.name)", systemImage: "display") {
                            DisplayWindowActivity.open(displayID: display.id, registry: windows)
                        }
                    }
                }
                Section("Close windows") {
                    Button("Close this screen", systemImage: "xmark.rectangle") { windows.close(.display(stream.id)) }
                    Button("Close all screens", systemImage: "rectangle.stack.badge.minus") {
                        windows.open(.overview) { openWindow(id: "desk") }
                        windows.closeAllDisplays()
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More screen options")
        }
    }

    private var screenNumber: Int {
        (model.displays.firstIndex(where: { $0.id == stream.id }) ?? 0) + 1
    }
}

private struct ScreenControlHelpPanel: View {
    let mode: ScreenInteractionMode

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Control this screen").font(.title3.weight(.semibold))
            Label(mode.instruction, systemImage: mode.symbol)
            Label("Center Pointer places the Mac pointer in the middle without clicking. The click buttons act at its current position on this screen.",
                  systemImage: "scope")
            Label("Use the window bar to move this screen in your space, and a lower corner to resize it. Focus view gives the desktop more room.",
                  systemImage: "arrow.up.left.and.arrow.down.right")
            Label("Click the Mac text field you want first. Keyboard sends typing and shortcuts to the focused Mac app.",
                  systemImage: "keyboard")
            Label("Stop Control disables input on every screen. Request Control asks your Mac to enable it again.",
                  systemImage: "stop.circle")
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .padding(26)
        .frame(maxWidth: .infinity)
    }
}

/// One source for the "can I interact with this screen" copy, shared by the footer and the
/// accessibility hint so they cannot disagree with the buttons beside them. The per-display
/// gate also covers a frame that has gone stale, which the Mac-control copy would misexplain,
/// and a Pointer screen whose pointer has not been placed, where a tap clicks nothing yet.
@MainActor
private func controlHint(
    _ model: DeskClientModel, stream: DisplayStream, mode: ScreenInteractionMode
) -> String {
    SessionCopy.controlHint(
        canControlDisplay: model.canControl(displayID: stream.id),
        canControlMac: model.canControl,
        isMacResponsive: model.isMacResponsive,
        mode: mode,
        pointerPlaced: model.pointedDisplayIDs.contains(stream.id)
    )
}

@MainActor
private final class PinchTarget: ObservableObject {
    @Published var point: CGPoint?
}

@MainActor
private struct TargetRing: View {
    @ObservedObject var target: PinchTarget
    let rect: CGRect

    var body: some View {
        if let point = target.point {
            Circle().stroke(.cyan.opacity(0.85), lineWidth: 2)
                .frame(width: 18, height: 18)
                .position(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
        }
    }
}

private struct DisplayHitRegion: Shape {
    let imageRect: CGRect
    /// `rect` is deliberately unused: `imageRect` is already expressed in this view's local
    /// space, which is the same space `rect` describes, so re-deriving it would only risk
    /// disagreeing with the coordinates the gesture normalizes against.
    func path(in rect: CGRect) -> Path {
        Path { $0.addRect(imageRect) }
    }
}

/// How a pinch on the surface splits between a click and a pan, kept apart from the view so the
/// rules can be checked directly. The surface builds its real gesture from these values.
enum ScreenGesturePolicy {
    /// Local points a Pointer pinch must travel before it pans rather than taps: small enough
    /// that deliberate pointing starts at once, large enough that click jitter never moves the
    /// pointer.
    static let pointerPanThreshold: CGFloat = 10

    /// Direct and Trackpad taps take precedence over pans. Their exclusive recognizer
    /// makes each pinch a tap or a drag, never both. Explicit Drag and Scroll have no tap.
    static func tapClicks(in mode: ScreenInteractionMode) -> Bool { mode == .pointer || mode == .direct }

    /// Direct and Trackpad pans wait for real travel; Drag and Scroll start on pinch-down.
    static func panMinimumDistance(for mode: ScreenInteractionMode) -> CGFloat {
        tapClicks(in: mode) ? pointerPanThreshold : 0
    }

    /// A trackpad stroke may continue beyond the picture without losing hand travel.
    /// Absolute modes still clamp to its edge; only the resulting remote pointer is clamped
    /// for relative strokes. The initial pinch remains confined to the image by the caller.
    static func gesturePoint(_ location: CGPoint, in size: CGSize, image: CGSize,
                             mode: ScreenInteractionMode) -> CGPoint? {
        guard mode == .pointer else {
            return DisplayGeometry.normalized(location, in: size, image: image, clampToImage: true)
        }
        guard location.x.isFinite, location.y.isFinite,
              let rect = DisplayGeometry.imageRect(in: size, image: image) else { return nil }
        let point = CGPoint(x: (location.x - rect.minX) / rect.width,
                            y: (location.y - rect.minY) / rect.height)
        return point.x.isFinite && point.y.isFinite ? point : nil
    }
}

@MainActor
private struct DisplaySurface: View {
    @ObservedObject var model: DeskClientModel
    @ObservedObject var stream: DisplayStream
    let mode: ScreenInteractionMode
    @GestureState private var gestureIsActive = false
    // The gesture host does not subscribe to target changes. Only TargetRing
    // observes hand positions, so a callback does not invalidate the video body.
    @State private var pinchTarget = PinchTarget()
    @State private var pinchToken = UUID()
    @State private var activePinchToken: UUID?
    /// Until when the "place the pointer first" prompt shows after a refused tap.
    @State private var placementPromptUntil: Date?

    /// Long enough to read one sentence, short enough not to linger over the screen.
    private static let placementPromptDuration: TimeInterval = 3

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let image = stream.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                if mode != .pointer, model.canControl(displayID: stream.id),
                   let rect = DisplayGeometry.imageRect(in: geometry.size, image: stream.imageSize) {
                    // Local target feedback follows the hand immediately. The streamed Mac
                    // cursor remains authoritative; this ring is only the current pinch target.
                    TargetRing(target: pinchTarget, rect: rect)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                  if !stream.isFresh() {
                    if stream.image == nil {
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.large)
                            Text("Waiting for your screen").font(.headline)
                            Text(SessionCopy.pausedScreenDetail(decodeWarning: stream.decodeWarning,
                                                                isMacResponsive: model.isMacResponsive))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                        .padding(26)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                        .padding(24)
                        .allowsHitTesting(false)
                    } else {
                        Label("Recovering screen…", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .padding(14)
                            .allowsHitTesting(false)
                    }
                  } else if let until = placementPromptUntil, context.date < until {
                    VStack {
                        Spacer(minLength: 0)
                        Label(SessionCopy.pointerPlacementHint, systemImage: "cursorarrow.motionlines")
                            .font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(.regularMaterial, in: Capsule())
                            .padding(24)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                  }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(DisplayHitRegion(imageRect: DisplayGeometry.imageRect(in: geometry.size, image: stream.imageSize) ?? .zero))
            .gesture(surfaceGesture(in: geometry.size, token: pinchToken))
            .onChange(of: geometry.size) { _, _ in
                // A resized picture has a new coordinate space. Never continue a held
                // button with coordinates normalized against the previous geometry.
                if let token = activePinchToken { model.cancelGesture(token: token) }
                activePinchToken = nil
                pinchToken = UUID()
                pinchTarget.point = nil
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(stream.info.name), \(stream.isFresh() ? "live screen" : "waiting for a fresh frame")")
            .accessibilityHint(controlHint(model, stream: stream, mode: mode))
            // An assistive activation has no hand position, so the
            // primary action clicks where this display's pointer already is, as a Pointer tap
            // and the toolbar's Left click do. Until something has placed that pointer, the
            // clicks are refused out loud, and the named placement action is the explicit,
            // click-free way to give them a position.
            .accessibilityAction {
                announceIfUnplaced()
                model.clickAtLastPointer(displayID: stream.id)
            }
            .accessibilityAction(named: "Right click") {
                announceIfUnplaced()
                model.click(displayID: stream.id, action: "rightClick")
            }
            .accessibilityAction(named: "Double click") {
                announceIfUnplaced()
                model.click(displayID: stream.id, action: "doubleClick")
            }
            .accessibilityAction(named: Text(SessionCopy.placePointerActionName)) {
                model.placePointer(displayID: stream.id, at: CGPoint(x: 0.5, y: 0.5))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onChange(of: gestureIsActive) { _, active in
            // SwiftUI resets GestureState for a cancellation and a completed drag alike, and
            // this reset is not ordered against `onEnded`. Reporting the reset rather than
            // deciding what it meant is what keeps a completed gesture's drain from depending
            // on which of the two the surface happens to observe first.
            if !active, let token = activePinchToken {
                pinchTarget.point = nil; activePinchToken = nil
                model.gestureStateDidReset(token: token)
                pinchToken = UUID()
            }
        }
        .onDisappear {
            pinchTarget.point = nil
            if let token = activePinchToken { model.cancelGesture(token: token) }
            activePinchToken = nil
        }
    }

    /// The surface's one gesture. Direct and Trackpad modes try the native tap first and lets its pan
    /// recognize only once the tap has failed and the hand has travelled past the threshold, so
    /// a quick pinch is one click. Direct mode aims it; Trackpad preserves the last pointer.
    /// Drag and Scroll have no tap and start on pinch-down. A direct pan starts a held
    /// press at the original target only after deliberate hand travel.
    private func surfaceGesture(in size: CGSize, token: UUID) -> AnyGesture<Void> {
        let pan = screenGesture(in: size, token: token,
                                minimumDistance: ScreenGesturePolicy.panMinimumDistance(for: mode))
        guard ScreenGesturePolicy.tapClicks(in: mode) else { return AnyGesture(pan.map { _ in () }) }
        return AnyGesture(pointerTap(in: size).exclusively(before: pan).map { _ in () })
    }

    private func screenGesture(in size: CGSize, token: UUID, minimumDistance: CGFloat) -> some Gesture {
        // Pointer mode only moves: it never holds a button and never clicks on its own; its
        // click is the native tap that takes precedence over it. Drag mode explicitly holds the
        // button. The model owns both lifecycles.
        DragGesture(minimumDistance: minimumDistance, coordinateSpace: .local)
            .updating($gestureIsActive) { _, active, _ in active = true }
            .onChanged { value in
                guard let start = DisplayGeometry.normalized(value.startLocation, in: size, image: stream.imageSize),
                      let point = ScreenGesturePolicy.gesturePoint(value.location, in: size,
                                                                  image: stream.imageSize, mode: mode)
                else { return }
                if activePinchToken == nil { activePinchToken = token }
                pinchTarget.point = point
                model.updateGesture(
                    token: token, displayID: stream.id, mode: mode,
                    start: start, point: point, translation: value.translation
                )
            }
            .onEnded { value in
                // SwiftUI may provide a final location without a preceding changed callback.
                if let start = DisplayGeometry.normalized(value.startLocation, in: size, image: stream.imageSize),
                   let point = ScreenGesturePolicy.gesturePoint(value.location, in: size,
                                                               image: stream.imageSize, mode: mode) {
                    model.finishGesture(token: token, displayID: stream.id, mode: mode,
                                        start: start, point: point, translation: value.translation)
                } else {
                    model.endGesture(token: token)
                }
                if activePinchToken == token { activePinchToken = nil }
                pinchToken = UUID()
                pinchTarget.point = nil
            }
    }

    /// Direct mode aims at the tap; Trackpad mode clicks the previously placed pointer.
    /// Exclusive recognition prevents either tap from also completing a drag.
    private func pointerTap(in size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 1, coordinateSpace: .local)
            .onEnded { value in
                // The hit region already confines a tap to the picture, so clamping only absorbs
                // rounding at its edge, where a validated tap must not be lost.
                guard ScreenGesturePolicy.tapClicks(in: mode),
                      let point = DisplayGeometry.normalized(value.location, in: size,
                                                             image: stream.imageSize, clampToImage: true)
                else { return }
                if mode == .pointer && isRefusedForPlacement() {
                    placementPromptUntil = Date().addingTimeInterval(Self.placementPromptDuration)
                }
                if mode == .direct {
                    model.directTapClick(displayID: stream.id, at: point)
                } else {
                    model.tapClick(displayID: stream.id, at: point)
                }
            }
    }

    /// True when a click on this screen would be refused only because its pointer has not
    /// been placed: control is otherwise available, so the refusal is worth explaining.
    private func isRefusedForPlacement() -> Bool {
        model.canControl(displayID: stream.id) && !model.hasPointerPosition(displayID: stream.id)
    }

    private func announceIfUnplaced() {
        guard isRefusedForPlacement() else { return }
        UIAccessibility.post(notification: .announcement, argument: SessionCopy.assistivePlacementHint)
    }
}

@MainActor
private struct KeyboardPanel: View {
    @ObservedObject var model: DeskClientModel
    let displayID: UInt32
    @Environment(\.scenePhase) private var scenePhase
    @State private var focusRequest = UUID()
    @StateObject private var keyboardCommands = RemoteKeyboardCommands()

    private let keys: [(label: String, key: String, spoken: String)] = [
        ("Return", "return", "Return"), ("Tab", "tab", "Tab"),
        ("Escape", "escape", "Escape"), ("Delete", "backspace", "Delete backward"),
        ("←", "left", "Left arrow"), ("↓", "down", "Down arrow"),
        ("↑", "up", "Up arrow"), ("→", "right", "Right arrow"),
        ("⌘ C", "cmd+c", "Copy"), ("⌘ V", "cmd+v", "Paste"),
        ("⌘ A", "cmd+a", "Select all"), ("⌘ Z", "cmd+z", "Undo"),
        ("Redo", "cmd+shift+z", "Redo"), ("Spotlight", "cmd+space", "Open Spotlight")
    ]

    var body: some View {
        // Recheck the grant even when the peer stops publishing updates. An expired grant
        // must resign the native input receiver, including any unfinished composition.
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let enabled = scenePhase == .active && model.canControl(displayID: displayID)
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keyboard").font(.title3.weight(.semibold))
                        if let display = model.display(id: displayID) {
                            Text(display.info.name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Show keyboard") { focusRequest = UUID() }
                        .disabled(!enabled)
                }
                Text("Click a text field on your Mac first. Typing here goes directly to the focused Mac app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                RemoteKeyboardInput(isEnabled: enabled, focusRequest: focusRequest,
                                    onText: { model.sendText($0, displayID: displayID) },
                                    onKey: { model.sendKey($0, displayID: displayID) },
                                    onCancel: { model.cancelKeyboardInput() },
                                    commands: keyboardCommands, destinationID: displayID)
                    .frame(height: 92)
                Button("Send remaining text", systemImage: "paperplane") {
                    keyboardCommands.retryRemainingText()
                }
                .disabled(!enabled)
                .accessibilityHint("Retries only text still shown in the keyboard field, without adding a key.")
                Text("Text left in the field has not been sent. If the keyboard was busy, wait, then choose Send remaining text.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let notice = model.keyboardNotice {
                    Text(notice)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("keyboard-delivery-notice")
                } else if model.keyboardPendingCount > 0 {
                    Label("Sending keyboard input…", systemImage: "keyboard")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !enabled {
                    Text(SessionCopy.keyboardPaused(isWindowActive: scenePhase == .active,
                                                    canControlMac: model.canControl,
                                                    isMacResponsive: model.isMacResponsive))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                    ForEach(keys, id: \.key) { item in
                        Button(item.label) { keyboardCommands.send(item.key) }
                            .frame(maxWidth: .infinity)
                            .disabled(!enabled)
                            .accessibilityLabel(item.spoken)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}
