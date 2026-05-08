//
//  NotesStore.swift
//  leanring-buddy
//
//  Persists user-supplied memory notes for Clicky. Notes are saved as JSON
//  under Application Support and re-loaded on launch. The store publishes
//  changes so SwiftUI views and the Claude system-prompt builder stay in
//  sync without explicit notification plumbing.
//

import Foundation
import Combine

@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var notes: [ClickyNote] = []

    /// Maximum number of notes injected into the Claude system prompt. Older
    /// notes still live on disk; this cap just prevents the prompt from
    /// drifting unbounded as the user accumulates memories.
    static let promptInjectionLimit: Int = 30

    private let storageURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(storageURL: URL? = nil) {
        let resolvedStorageURL = storageURL ?? Self.defaultStorageURL()
        self.storageURL = resolvedStorageURL

        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        jsonEncoder.dateEncodingStrategy = .iso8601
        self.encoder = jsonEncoder

        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        self.decoder = jsonDecoder

        self.notes = loadNotesFromDisk()
    }

    // MARK: - Mutations

    /// Adds a new note. Empty / whitespace-only text is ignored. Returns the
    /// stored note (or `nil` if the input was empty) so callers can chain TTS
    /// or analytics on success.
    @discardableResult
    func add(text: String) -> ClickyNote? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }

        let newNote = ClickyNote(text: trimmedText)
        // Newest first so the panel and the Claude prompt both reflect recency.
        notes.insert(newNote, at: 0)
        persistToDisk()
        return newNote
    }

    func remove(id: UUID) {
        notes.removeAll { $0.id == id }
        persistToDisk()
    }

    func removeAll() {
        notes.removeAll()
        persistToDisk()
    }

    // MARK: - Claude Integration

    /// Returns the formatted block injected into the Claude system prompt.
    /// Empty when no notes exist so the prompt stays clean.
    func systemPromptBlock() -> String? {
        guard !notes.isEmpty else { return nil }

        let trimmedNotes = notes.prefix(Self.promptInjectionLimit)
        let bulletList = trimmedNotes
            .map { "- \($0.text)" }
            .joined(separator: "\n")

        return """
        the user has saved these long-running notes for you to remember across conversations. treat them as persistent context — refer to them naturally when relevant, but do not list them back unless the user asks.

        \(bulletList)
        """
    }

    // MARK: - Persistence

    private func loadNotesFromDisk() -> [ClickyNote] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: storageURL)
            return try decoder.decode([ClickyNote].self, from: data)
        } catch {
            print("⚠️ NotesStore: failed to load notes from \(storageURL.path): \(error)")
            return []
        }
    }

    private func persistToDisk() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(notes)
            // Atomic write so a crash mid-save can't corrupt the file.
            try data.write(to: storageURL, options: [.atomic])
        } catch {
            print("⚠️ NotesStore: failed to write notes to \(storageURL.path): \(error)")
        }
    }

    private static func defaultStorageURL() -> URL {
        let fileManager = FileManager.default
        let appSupportDir = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory

        return appSupportDir
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("notes.json")
    }
}
