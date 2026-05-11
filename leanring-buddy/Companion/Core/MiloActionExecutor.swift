//
//  MiloActionExecutor.swift
//  leanring-buddy
//
//  Synthesizes CGEvents to execute a MiloAction sequence. Each verb
//  has its own executor function; steps run sequentially with a small
//  inter-step delay so the OS has time to settle (focus changes after
//  a click, key repeat windows after a keypress, etc.).
//
//  Coordinate translation from screenshot-pixel → AppKit global is
//  delegated to CoordinateTranslator. Caller must supply the screen
//  capture metadata for each step that has coordinates.
//

import CoreGraphics
import Foundation

@MainActor
enum MiloActionExecutor {

    /// Inter-step delay so the OS can settle between events. 80ms is
    /// long enough for focus to change after a click and short enough
    /// that a multi-step sequence still feels snappy.
    private static let interStepDelayNanoseconds: UInt64 = 80_000_000

    /// Resolves a step's screenshot-pixel coordinate to AppKit-global.
    /// The orchestrator owns this closure since coordinate translation
    /// depends on the screen capture metadata captured for the response.
    typealias CoordinateResolver = @MainActor (
        _ screenshotPoint: CGPoint,
        _ screenNumber: Int?
    ) -> (globalLocation: CGPoint, displayFrame: CGRect)?

    /// Runs every step in the action sequentially. Returns when the
    /// last step has fired — callers should not assume the OS has
    /// finished reacting (e.g. a `type` step kicks events into the
    /// HID stream; the focused app processes them async).
    static func execute(_ action: MiloAction, resolveCoordinate: CoordinateResolver) async {
        for (index, step) in action.steps.enumerated() {
            executeStep(step, resolveCoordinate: resolveCoordinate)
            if index < action.steps.count - 1 {
                try? await Task.sleep(nanoseconds: interStepDelayNanoseconds)
            }
        }
    }

    private static func executeStep(_ step: MiloActionStep, resolveCoordinate: CoordinateResolver) {
        switch step {
        case .point:
            // No CGEvent — the cursor flight already happened earlier
            // in the response pipeline based on the parsed coordinate.
            // `point` exists in the grammar so Claude can express "look
            // here without clicking", which is the legacy POINT behavior.
            break

        case let .click(x, y, screen, _):
            guard let resolved = resolveCoordinate(
                CGPoint(x: Double(x), y: Double(y)),
                screen
            ) else { return }
            performClick(at: resolved.globalLocation, on: resolved.displayFrame)

        case let .type(text):
            performType(text)

        case let .keypress(key, modifiers):
            performKeypress(key: key, modifiers: modifiers)

        case let .scroll(x, y, screen, deltaX, deltaY):
            guard let resolved = resolveCoordinate(
                CGPoint(x: Double(x), y: Double(y)),
                screen
            ) else { return }
            performScroll(at: resolved.globalLocation, deltaX: deltaX, deltaY: deltaY)
        }
    }

    // MARK: - Click

    private static func performClick(at appKitGlobal: CGPoint, on displayFrame: CGRect) {
        // CGEvent uses top-left-origin global coordinates ("Quartz"
        // space). AppKit uses bottom-left. Flip y within the display's
        // frame. This mirrors the conversion in CompanionManager's
        // legacy postLeftMouseClick.
        let quartzPoint = CGPoint(
            x: appKitGlobal.x,
            y: displayFrame.maxY - appKitGlobal.y
        )
        let source = CGEventSource(stateID: .hidSystemState)

        CGWarpMouseCursorPosition(quartzPoint)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))

        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: quartzPoint, mouseButton: .left)?
            .post(tap: .cghidEventTap)

        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                mouseCursorPosition: quartzPoint, mouseButton: .left)?
            .post(tap: .cghidEventTap)

        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                mouseCursorPosition: quartzPoint, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    // MARK: - Type

    /// Synthesizes Unicode insertion via `keyboardSetUnicodeString`,
    /// which sidesteps keyboard layout entirely — the focused app sees
    /// the literal string the user wanted to type, regardless of
    /// whether the user is on QWERTY, AZERTY, or Dvorak.
    private static func performType(_ text: String) {
        // Filter out control characters — those need to go through
        // `keypress` (e.g. \n → keypress(key:"return")). Letting them
        // through here either produces garbage or no-ops depending on
        // the focused app.
        let safe = text.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint && $0.value >= 32 }
        let cleaned = String(String.UnicodeScalarView(safe))
        guard !cleaned.isEmpty else { return }

        let source = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(cleaned.utf16)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        utf16.withUnsafeBufferPointer { buffer in
            keyDown?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            keyUp?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Keypress

    private static func performKeypress(key: String, modifiers: [MiloActionStep.Modifier]) {
        guard let virtualKey = virtualKeyCode(for: key) else {
            print("⚠️ MiloActionExecutor: unknown key '\(key)'")
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let flags = cgEventFlags(from: modifiers)

        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    private static func cgEventFlags(from modifiers: [MiloActionStep.Modifier]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case .cmd: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            case .fn: flags.insert(.maskSecondaryFn)
            }
        }
        return flags
    }

    /// Maps named keys to their macOS virtual key codes. Covers the
    /// common keyboard actions Claude can be expected to produce:
    /// return/enter, tab, escape, arrows, space, backspace/delete.
    /// Single printable characters are looked up by char value (best
    /// effort — locale-specific). Returns nil for unknown keys; the
    /// executor logs and skips rather than guessing.
    private static func virtualKeyCode(for key: String) -> CGKeyCode? {
        let lower = key.lowercased()
        switch lower {
        case "return", "enter": return 0x24
        case "tab": return 0x30
        case "space": return 0x31
        case "delete", "backspace": return 0x33
        case "escape", "esc": return 0x35
        case "left", "leftarrow": return 0x7B
        case "right", "rightarrow": return 0x7C
        case "down", "downarrow": return 0x7D
        case "up", "uparrow": return 0x7E
        case "home": return 0x73
        case "end": return 0x77
        case "pageup": return 0x74
        case "pagedown": return 0x79
        default:
            // Single-character key fallback. Limited; production-grade
            // implementations would use TIS APIs to remap by current
            // layout. For v1 we cover the alphabetics by their position
            // on US-QWERTY (the most common keyboard).
            return Self.usQwertyCharToVirtualKey[lower]
        }
    }

    /// US-QWERTY character → virtual key code map. Suitable for the
    /// alphabetic + digit keys that hotkey combos most often target
    /// (cmd+s, cmd+c, cmd+v, etc.). Not exhaustive — sufficient for
    /// the most common Claude-emitted hotkeys.
    private static let usQwertyCharToVirtualKey: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D,
        "]": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23,
        "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29, "\\": 0x2A,
        ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
    ]

    // MARK: - Scroll

    private static func performScroll(at appKitGlobal: CGPoint, deltaX: Int, deltaY: Int) {
        let source = CGEventSource(stateID: .hidSystemState)

        // Move the cursor to the target first so the scroll lands on
        // the right surface.
        CGWarpMouseCursorPosition(appKitGlobal)

        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else { return }

        scrollEvent.post(tap: .cghidEventTap)
    }
}
