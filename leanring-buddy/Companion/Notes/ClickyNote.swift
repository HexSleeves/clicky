//
//  ClickyNote.swift
//  leanring-buddy
//
//  A single saved memory note. Persisted by NotesStore and surfaced to
//  Claude on every prompt so Clicky has long-running user context.
//

import Foundation

struct ClickyNote: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}
