import CoreGraphics
import Foundation
import DeskCore

// MARK: Input
//
// PointerInput owns gestures and click safety; KeyboardDelivery owns ordered acknowledged
// typing. Every entry point uses this model's control gate and authenticated connection.
extension DeskClientModel {
    /// A primary click where this display's pointer already is. Refused until the pointer has
    /// been placed on this display; see `PointerInput.clickAtLastPointer`.
    func clickAtLastPointer(displayID: UInt32) {
        keyboard.cancel()
        pointer.clickAtLastPointer(displayID: displayID)
    }

    /// Pointer mode's native tap: clicks where the pointer already is and never where the tap
    /// landed. See `PointerInput.tapClick`.
    func directTapClick(displayID: UInt32, at point: CGPoint) {
        keyboard.cancel()
        pointer.directTapClick(displayID: displayID, at: point)
    }

    func tapClick(displayID: UInt32, at point: CGPoint) {
        keyboard.cancel()
        pointer.tapClick(displayID: displayID, at: point)
    }

    func updateGesture(
        token: UUID, displayID: UInt32, mode: ScreenInteractionMode,
        start: CGPoint, point: CGPoint, translation: CGSize
    ) {
        keyboard.cancel()
        pointer.updateGesture(token: token, displayID: displayID, mode: mode,
                              start: start, point: point, translation: translation)
    }

    func endGesture(token: UUID) {
        pointer.endGesture(token: token)
    }

    func finishGesture(token: UUID, displayID: UInt32, mode: ScreenInteractionMode,
                       start: CGPoint, point: CGPoint, translation: CGSize) {
        keyboard.cancel()
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
        keyboard.cancel()
        pointer.click(displayID: displayID, action: action)
    }

    /// Places this display's pointer without clicking, for an activation that has no hand
    /// position to pinch and move with. See `PointerInput.placePointer`.
    func placePointer(displayID: UInt32, at point: CGPoint) {
        keyboard.cancel()
        pointer.placePointer(displayID: displayID, at: point)
    }

    func cancelKeyboardInput() { keyboard.cancel() }

    func sendText(_ text: String, displayID: UInt32) -> Bool {
        guard !text.isEmpty, pointer.prepareKeyboardInput(displayID: displayID) else { return false }
        return keyboard.enqueueText(text, displayID: displayID)
    }

    func sendKey(_ key: String, displayID: UInt32) {
        guard DeskMessage.supportedKeys.contains(key), pointer.prepareKeyboardInput(displayID: displayID) else { return }
        keyboard.enqueueKey(key, displayID: displayID)
    }
}
