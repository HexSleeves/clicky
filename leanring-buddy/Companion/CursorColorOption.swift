//
//  CursorColorOption.swift
//  leanring-buddy
//
//  Companion cursor color choices. The selected option drives every accent
//  in the overlay (triangle, glow, waveform, spinner, navigation bubbles)
//  plus the panel logo and the floating text-input chip so the experience
//  reads as one identity.
//
//  Adding a new option: add a case in source-order (it controls grid layout
//  in the picker), give it both a displayColor and glowColor in
//  DesignSystem.Colors, and update displayName. CaseIterable + Codable
//  pick up the new value automatically.
//
//  Don't reorder existing cases without thinking — `rawValue` is what's
//  persisted to UserDefaults under PersistenceKeys.selectedCursorColor.
//  Renaming a case orphans existing users' selections.
//

import SwiftUI

enum CursorColorOption: String, CaseIterable, Identifiable, Codable {
    // Ordered roughly by hue around the color wheel for a coherent
    // picker grid: warm reds → yellows → greens → cools → cools → cools.
    case red
    case orange
    case yellow
    case green
    case teal
    case blue
    case purple
    case pink

    var id: String { rawValue }

    /// Display name shown in tooltips / accessibility labels.
    var displayName: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .teal: return "Teal"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        }
    }

    /// The primary fill color — applied to the triangle, waveform bars, spinner,
    /// the panel cursor logo, response bubble accents, and the text-input pill.
    var displayColor: Color {
        switch self {
        case .red: return DS.Colors.overlayCursorRed
        case .orange: return DS.Colors.overlayCursorOrange
        case .yellow: return DS.Colors.overlayCursorYellow
        case .green: return DS.Colors.overlayCursorGreen
        case .teal: return DS.Colors.overlayCursorTeal
        case .blue: return DS.Colors.overlayCursorBlue
        case .purple: return DS.Colors.overlayCursorPurple
        case .pink: return DS.Colors.overlayCursorPink
        }
    }

    /// Slightly brighter sibling of `displayColor`. Used for drop shadows /
    /// glows so they read as light spillage rather than a duplicate solid fill.
    var glowColor: Color {
        switch self {
        case .red: return DS.Colors.overlayCursorRedGlow
        case .orange: return DS.Colors.overlayCursorOrangeGlow
        case .yellow: return DS.Colors.overlayCursorYellowGlow
        case .green: return DS.Colors.overlayCursorGreenGlow
        case .teal: return DS.Colors.overlayCursorTealGlow
        case .blue: return DS.Colors.overlayCursorBlueGlow
        case .purple: return DS.Colors.overlayCursorPurpleGlow
        case .pink: return DS.Colors.overlayCursorPinkGlow
        }
    }
}
