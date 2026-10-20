import Foundation

public struct DisplayInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: UInt32
    public var name: String
    public var width: Int
    public var height: Int
    public var originX: Double
    public var originY: Double
    public var pointWidth: Double
    public var pointHeight: Double

    public init(id: UInt32, name: String, width: Int, height: Int, originX: Double, originY: Double, pointWidth: Double, pointHeight: Double) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.originX = originX
        self.originY = originY
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
    }

    public var isValid: Bool {
        id != 0 && !name.isEmpty && name.utf8.count <= 256
            && (1...32_768).contains(width) && (1...32_768).contains(height)
            && originX.isFinite && originY.isFinite
            && abs(originX) <= 1_000_000 && abs(originY) <= 1_000_000
            && pointWidth.isFinite && pointHeight.isFinite
            && (1...32_768).contains(pointWidth) && (1...32_768).contains(pointHeight)
    }

    /// Maps the displayed image's top-left normalized coordinates to the Mac's
    /// global display coordinates. The far edge stays inside this display.
    public func point(x: Double, y: Double) -> CGPoint? {
        guard isValid, Self.isNormalized(x), Self.isNormalized(y) else { return nil }
        return CGPoint(x: originX + x * (pointWidth - 1), y: originY + y * (pointHeight - 1))
    }

    static func isNormalized(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }
}

public struct DockAppInfo: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var iconPNG: Data?

    public init(id: String, name: String, iconPNG: Data? = nil) {
        self.id = id; self.name = name; self.iconPNG = iconPNG
    }

    public var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 128 && !name.isEmpty && name.utf8.count <= 256
            && (iconPNG.map { !$0.isEmpty && $0.count <= 16 * 1_024 } ?? true)
    }
}

/// Versioned, bounded messages shared by the Mac and visionOS applications.
/// Coordinates are normalized within the selected display, before letterboxing.
public struct DeskMessage: Codable, Equatable, Sendable {
    public static let maximumJPEGBytes = 3 * 1_024 * 1_024 - 1_024
    /// The most displays one session may share. This is the protocol's own bound — `isValid`
    /// refuses a larger `displays` message — and the transport sizes its per-display send
    /// capacity from it, so the two can never disagree about how many streams to plan for.
    public static let maximumSharedDisplays = 4
    public static let maximumDockApps = 64
    /// The only compressed video codec this protocol version carries.
    public static let supportedVideoCodec = "h264"
    /// The only negotiated binary body format this protocol version understands.
    ///
    /// This is an optional capability, not a version bump. A peer that predates the field omits
    /// it and keeps receiving JSON. A peer that offers an unrecognized value is not refused —
    /// unlike `videoCodec`, where a wrong codec means the stream itself cannot be carried —
    /// it simply fails to enable the binary body, because an unknown encoding of a payload both
    /// sides can already exchange as JSON is a missed optimization, not a broken session.
    public static let binaryWireFormat = "binary-v1"
    public static let maximumWireFormatBytes = 64
    public static let supportedKeys: Set<String> = [
        "return", "tab", "escape", "backspace", "space", "left", "right", "up", "down",
        "cmd+c", "cmd+v", "cmd+a", "cmd+z", "cmd+shift+z", "cmd+space"
    ]

    public var version: Int
    public var kind: String
    public var displays: [DisplayInfo]?
    public var displayID: UInt32?
    public var jpeg: Data?
    public var x: Double?
    public var y: Double?
    public var action: String?
    public var text: String?
    public var deltaX: Double?
    public var deltaY: Double?
    public var status: String?
    public var controlEnabled: Bool?
    public var video: EncodedVideoFrame?
    public var videoCodec: String?
    /// Optional, capabilities-only. Absent means "JSON bodies only".
    public var wireFormat: String?
    /// Authenticated status only: the Mac retains this pairing for later sessions.
    /// Absent on older hosts and on temporary pairings.
    public var appPlacement: Bool?
    public var dockApps: [DockAppInfo]?
    public var appID: String?
    public var appRequestID: String?
    public var appLaunchSucceeded: Bool?
    public var dockLauncher: Bool?
    public var keepsPairing: Bool?
    /// Optional negotiated keyboard delivery; success means posted, not application consumption.
    public var keyboardAcknowledgements: Bool?
    public var keyboardRequestID: String?
    public var keyboardResult: String?

    public init(version: Int = 1, kind: String, displays: [DisplayInfo]? = nil, displayID: UInt32? = nil, jpeg: Data? = nil, x: Double? = nil, y: Double? = nil, action: String? = nil, text: String? = nil, deltaX: Double? = nil, deltaY: Double? = nil, status: String? = nil, controlEnabled: Bool? = nil, video: EncodedVideoFrame? = nil, videoCodec: String? = nil, wireFormat: String? = nil, keepsPairing: Bool? = nil, dockApps: [DockAppInfo]? = nil, appID: String? = nil, appRequestID: String? = nil, appLaunchSucceeded: Bool? = nil, dockLauncher: Bool? = nil, appPlacement: Bool? = nil, keyboardAcknowledgements: Bool? = nil, keyboardRequestID: String? = nil, keyboardResult: String? = nil) {
        self.keyboardAcknowledgements = keyboardAcknowledgements
        self.keyboardRequestID = keyboardRequestID
        self.keyboardResult = keyboardResult
        self.version = version
        self.kind = kind
        self.displays = displays
        self.displayID = displayID
        self.jpeg = jpeg
        self.x = x
        self.y = y
        self.action = action
        self.text = text
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.status = status
        self.controlEnabled = controlEnabled
        self.video = video
        self.videoCodec = videoCodec
        self.wireFormat = wireFormat
        self.keepsPairing = keepsPairing
        self.appPlacement = appPlacement
        self.dockApps = dockApps; self.appID = appID; self.appRequestID = appRequestID
        self.appLaunchSucceeded = appLaunchSucceeded; self.dockLauncher = dockLauncher
    }

    public var isValid: Bool {
        guard version == 1,
              keyboardAcknowledgements == nil || kind == "capabilities",
              keyboardRequestID == nil || kind == "input" || kind == "keyboardResult",
              keyboardRequestID.map({ $0.utf8.count <= 64 && UUID(uuidString: $0) != nil }) ?? true,
              keyboardResult == nil || kind == "keyboardResult",
              dockApps == nil || kind == "apps",
              appPlacement == nil || kind == "apps",
              dockLauncher == nil || kind == "capabilities",
              appID == nil || kind == "launchApp" || kind == "appLaunchResult",
              appRequestID == nil || kind == "launchApp" || kind == "appLaunchResult",
              appLaunchSucceeded == nil || kind == "appLaunchResult",
              appID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
              appRequestID.map({ $0.utf8.count <= 64 && UUID(uuidString: $0) != nil }) ?? true,
              jpeg == nil || kind == "frame",
              displays == nil || kind == "displays",
              video == nil || kind == "video",
              videoCodec == nil || kind == "capabilities",
              wireFormat == nil || kind == "capabilities",
              keepsPairing == nil || kind == "status",
              (wireFormat?.utf8.count ?? 0) <= Self.maximumWireFormatBytes,
              (text?.utf8.count ?? 0) <= 4_096,
              (status?.utf8.count ?? 0) <= 1_024,
              x.map(DisplayInfo.isNormalized) ?? true,
              y.map(DisplayInfo.isNormalized) ?? true,
              deltaX.map({ $0.isFinite && abs($0) <= 2_000 }) ?? true,
              deltaY.map({ $0.isFinite && abs($0) <= 2_000 }) ?? true else { return false }
        switch kind {
        case "keyboardResult":
            return keyboardRequestID != nil && ["posted", "busy", "rejected", "uncertain"].contains(keyboardResult ?? "")
        case "apps":
            guard let dockApps, dockApps.count <= Self.maximumDockApps else { return false }
            return dockApps.allSatisfy(\.isValid) && Set(dockApps.map(\.id)).count == dockApps.count
        case "requestApps":
            return true
        case "launchApp":
            return appID != nil && appRequestID != nil && (displayID.map { $0 != 0 } ?? true)
        case "appLaunchResult":
            return appID != nil && appRequestID != nil && status != nil && appLaunchSucceeded != nil
        case "displays":
            guard let displays, displays.count <= Self.maximumSharedDisplays else { return false }
            return displays.allSatisfy(\.isValid) && Set(displays.map(\.id)).count == displays.count
        case "frame":
            guard let displayID, displayID != 0, let jpeg else { return false }
            return !jpeg.isEmpty && jpeg.count <= Self.maximumJPEGBytes
        case "video":
            guard let displayID, displayID != 0, let video else { return false }
            return video.isValid
        case "capabilities":
            // An unrecognized codec is a rejection, never a silent downgrade: the peer has to
            // learn that its offer was refused rather than assume it was accepted.
            guard let videoCodec else { return false }
            return videoCodec == Self.supportedVideoCodec
        case "keyframe":
            return displayID.map { $0 != 0 } ?? false
        case "input":
            guard let displayID, displayID != 0, let action,
                  keyboardRequestID == nil || action == "text" || action == "key" else { return false }
            switch action {
            case "move", "leftDown", "leftUp", "rightClick", "doubleClick":
                return x != nil && y != nil
            case "scroll":
                return deltaX != nil && deltaY != nil
            case "text":
                return text?.isEmpty == false
            case "key":
                return text.map(Self.supportedKeys.contains) ?? false
            default:
                return false
            }
        case "status":
            return status != nil || controlEnabled != nil || keepsPairing != nil
        case "heartbeat", "stop", "requestControl":
            return true
        default:
            return false
        }
    }
}
