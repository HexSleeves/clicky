//
//  MiloAction.swift
//  leanring-buddy
//
//  The data model for the Action Grammar v2 — a structured action
//  protocol Claude emits at the end of a response when it wants Milo
//  to perform a multi-step UI action. Replaces (but doesn't retire)
//  the simpler `[POINT:x,y:label]` tag.
//
//  Wire format Claude is taught to emit:
//
//    [ACTION:{
//      "steps": [
//        {"verb":"click","x":420,"y":312,"screen":1,"label":"Reply"},
//        {"verb":"type","text":"Hi!"},
//        {"verb":"keypress","key":"return","modifiers":["cmd"]}
//      ],
//      "confirm":"Send 'Hi!' as a reply"
//    }]
//
//  The `confirm` field is Claude-authored summary text rendered in the
//  guided-action panel. Letting Claude generate it produces far better
//  UI copy than client-side stringification of low-level verbs.
//

import CoreGraphics
import Foundation

/// A complete proposed action: ordered steps + a human-readable summary.
struct MiloAction: Equatable, Codable {
    let steps: [MiloActionStep]
    let confirm: String
}

/// One step in a MiloAction sequence. Each case is a distinct verb with
/// its own typed fields. JSON encoding uses a "verb" discriminator that
/// dispatches between cases.
enum MiloActionStep: Equatable {

    /// Move the cursor to a screenshot-pixel coordinate and dwell briefly.
    /// No mouse button click. Aliases the legacy [POINT:...] behavior so
    /// the new grammar fully covers the old.
    case point(x: Int, y: Int, screen: Int?, label: String)

    /// Left-click at a screenshot-pixel coordinate after flying the cursor there.
    case click(x: Int, y: Int, screen: Int?, label: String)

    /// Insert literal text into whatever has keyboard focus.
    /// Newlines + control characters MUST come through `keypress` instead
    /// (executor refuses to type control bytes — they're not insertable
    /// via Unicode and signal a malformed action).
    case type(text: String)

    /// Synthesize one key event with optional modifiers. Supports both
    /// single keys (return, escape, tab) and hotkey combos (cmd+s).
    /// `key` is one of the named keys in MiloActionStep.NamedKey OR a
    /// single printable character. Modifiers compose.
    case keypress(key: String, modifiers: [Modifier])

    /// Scroll wheel events at a coordinate. `deltaY` is positive = down,
    /// `deltaX` is positive = right. Magnitudes match macOS line scroll
    /// units (~10 = noticeable scroll).
    case scroll(x: Int, y: Int, screen: Int?, deltaX: Int, deltaY: Int)

    /// Keyboard modifiers that compose with a `keypress` key.
    enum Modifier: String, Codable, Equatable, CaseIterable {
        case cmd
        case shift
        case option
        case control
        case fn
    }

    /// Discriminator string used in the JSON encoding.
    var verbName: String {
        switch self {
        case .point: return "point"
        case .click: return "click"
        case .type: return "type"
        case .keypress: return "keypress"
        case .scroll: return "scroll"
        }
    }

    /// True for steps that perform a destructive or hard-to-reverse
    /// action. Used by the auto-bypass guard so e.g. `type` of arbitrary
    /// text or hotkey combos never auto-fire even when the setting is on.
    var isPotentiallyDangerous: Bool {
        switch self {
        case .point: return false
        case .click: return false       // single click is the original bypass-safe case
        case .type: return true         // could submit a message, paste a password, etc.
        case .keypress: return true     // ⌘+return sends, ⌘+q quits
        case .scroll: return false
        }
    }
}

// MARK: - Codable

extension MiloActionStep: Codable {
    private enum CodingKeys: String, CodingKey {
        case verb
        case x, y, screen, label
        case text
        case key, modifiers
        case deltaX, deltaY
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let verb = try container.decode(String.self, forKey: .verb)

        switch verb {
        case "point":
            self = .point(
                x: try container.decode(Int.self, forKey: .x),
                y: try container.decode(Int.self, forKey: .y),
                screen: try container.decodeIfPresent(Int.self, forKey: .screen),
                label: try container.decode(String.self, forKey: .label)
            )
        case "click":
            self = .click(
                x: try container.decode(Int.self, forKey: .x),
                y: try container.decode(Int.self, forKey: .y),
                screen: try container.decodeIfPresent(Int.self, forKey: .screen),
                label: try container.decode(String.self, forKey: .label)
            )
        case "type":
            self = .type(
                text: try container.decode(String.self, forKey: .text)
            )
        case "keypress":
            self = .keypress(
                key: try container.decode(String.self, forKey: .key),
                modifiers: try container.decodeIfPresent([Modifier].self, forKey: .modifiers) ?? []
            )
        case "scroll":
            self = .scroll(
                x: try container.decode(Int.self, forKey: .x),
                y: try container.decode(Int.self, forKey: .y),
                screen: try container.decodeIfPresent(Int.self, forKey: .screen),
                deltaX: try container.decodeIfPresent(Int.self, forKey: .deltaX) ?? 0,
                deltaY: try container.decodeIfPresent(Int.self, forKey: .deltaY) ?? 0
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .verb,
                in: container,
                debugDescription: "Unknown verb: '\(verb)'"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(verbName, forKey: .verb)
        switch self {
        case let .point(x, y, screen, label),
             let .click(x, y, screen, label):
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
            try container.encodeIfPresent(screen, forKey: .screen)
            try container.encode(label, forKey: .label)
        case let .type(text):
            try container.encode(text, forKey: .text)
        case let .keypress(key, modifiers):
            try container.encode(key, forKey: .key)
            if !modifiers.isEmpty {
                try container.encode(modifiers, forKey: .modifiers)
            }
        case let .scroll(x, y, screen, deltaX, deltaY):
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
            try container.encodeIfPresent(screen, forKey: .screen)
            try container.encode(deltaX, forKey: .deltaX)
            try container.encode(deltaY, forKey: .deltaY)
        }
    }
}

// MARK: - Sequence-level helpers

extension MiloAction {
    /// True if every step is safe to auto-execute when the user has
    /// enabled "Auto-click actions". Single-click + point sequences
    /// continue to auto-fire; anything involving typing or hotkeys
    /// requires explicit confirmation regardless of the bypass setting.
    var isSafeForAutoBypass: Bool {
        steps.count <= 1 && !steps.contains(where: { $0.isPotentiallyDangerous })
    }
}
