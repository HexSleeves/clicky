//
//  CursorColorOption.swift
//  leanring-buddy
//
//  Companion cursor color choices. The selected option drives every accent
//  in the overlay (triangle, glow, waveform, spinner, navigation bubbles)
//  plus the panel logo and the floating text-input chip so the experience
//  reads as one identity.
//

import SwiftUI

enum CursorColorOption: String, CaseIterable, Identifiable, Codable {
    case red
    case blue
    case yellow
    case green

    var id: String { rawValue }

    /// Display name shown in tooltips / accessibility labels.
    var displayName: String {
        switch self {
        case .red: return "Red"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        case .green: return "Green"
        }
    }

    /// The primary fill color — applied to the triangle, waveform bars, spinner,
    /// the panel cursor logo, response bubble accents, and the text-input pill.
    var displayColor: Color {
        switch self {
        case .red: return DS.Colors.overlayCursorRed
        case .blue: return DS.Colors.overlayCursorBlue
        case .yellow: return DS.Colors.overlayCursorYellow
        case .green: return DS.Colors.overlayCursorGreen
        }
    }

    /// Slightly brighter sibling of `displayColor`. Used for drop shadows /
    /// glows so they read as light spillage rather than a duplicate solid fill.
    var glowColor: Color {
        switch self {
        case .red: return DS.Colors.overlayCursorRedGlow
        case .blue: return DS.Colors.overlayCursorBlueGlow
        case .yellow: return DS.Colors.overlayCursorYellowGlow
        case .green: return DS.Colors.overlayCursorGreenGlow
        }
    }
}
