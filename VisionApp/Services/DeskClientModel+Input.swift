import CoreGraphics
import Foundation

// MARK: Input
//
// The rules for gestures, clicks and typing live in `PointerInput`, with the reasoning for each.
// These entry points keep the surface, the keyboard and the tests talking to one object, and
// every one of them is gated by this model's `canControl` and sends only through this model's
// `send`. They hold no state of their own, which is why they can live apart from the model.
extension DeskClientModel {
    /// A primary click where this display's pointer already is. Refused until the pointer has
    /// been placed on this display; see `PointerInput.clickAtLastPointer`.
    func clickAtLastPointer(displayID: UInt32) {
        pointer.clickAtLastPointer(displayID: displayID)
    }

    /// Pointer mode's native tap: clicks where the pointer already is and never where the tap
    /// landed. See `PointerInput.tapClick`.
    func directTapClick(displayID: UInt32, at point: CGPoint) {
        pointer.directTapClick(displayID: displayID, at: point)
    }

    func tapClick(displayID: UInt32, at point: CGPoint) {
        pointer.tapClick(displayID: displayID, at: point)
    }

    func updateGesture(
        token: UUID, displayID: UInt32, mode: ScreenInteractionMode,
        start: CGPoint, point: CGPoint, translation: CGSize
    ) {
        pointer.updateGesture(token: token, displayID: displayID, mode: mode,
                              start: start, point: point, translation: translation)
    }

    func endGesture(token: UUID) {
        pointer.endGesture(token: token)
    }

    func finishGesture(token: UUID, displayID: UInt32, mode: ScreenInteractionMode,
                       start: CGPoint, point: CGPoint, translation: CGSize) {
        pointer.finishGesture(token: token, displayID: displayID, mode: mode,
                              start: start, point: point, translation: translation)
    }

    func cancelGesture(token: UUID) {
        pointer.cancelGesture(token: token)
    }

    func gestureStateDidReset(token: UUID) {
        pointer.gestureStateDidReset(token: token)
    }

    func click(displayID: UInt32, action: String) {
        pointer.click(displayID: displayID, action: action)
    }

    /// Places this display's pointer without clicking, for an activation that has no hand
    /// position to pinch and move with. See `PointerInput.placePointer`.
    func placePointer(displayID: UInt32, at point: CGPoint) {
        pointer.placePointer(displayID: displayID, at: point)
    }

    func sendText(_ text: String, displayID: UInt32) -> Bool {
        pointer.sendText(text, displayID: displayID)
    }

    func sendKey(_ key: String, displayID: UInt32) {
        pointer.sendKey(key, displayID: displayID)
    }
}
