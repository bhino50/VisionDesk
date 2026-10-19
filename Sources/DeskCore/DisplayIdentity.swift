import Foundation

/// A human-readable identity for a currently enumerated Mac display. The display ID
/// disambiguates identical monitor models without depending on enumeration order.
/// macOS may assign a different ID after reconnection; this is not a hardware serial.
public enum DisplayIdentity {
    public static func name(localizedName: String, displayID: UInt32, builtIn: Bool,
                            main: Bool, width: Int, height: Int) -> String {
        let model = localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = builtIn ? "Built-in" : "External"
        let orientation = height > width ? "Portrait" : "Landscape"
        let role = main ? ", Main" : ""
        return "\(source) · \(model.isEmpty ? "Display" : model) · \(orientation)\(role) · ID \(displayID)"
    }
}
