//
//  RoleStorage.swift
//  leanring-buddy
//
//  Pluggable persistence boundary for `AppRole`. Production uses
//  `FileRoleStorage`; tests inject `InMemoryRoleStorage` (or a stub
//  that returns nil to simulate corruption).
//

import Foundation

protocol RoleStorage {
    func loadRole() -> AppRole?
    func saveRole(_ role: AppRole) throws
    func clear()
}

/// JSON-on-disk role store. Matches the `NotesStore` pattern so we have
/// a single Application Support layout to reason about across managers.
///
/// Corruption posture (Phase 1 Test Plan): a malformed or unreadable
/// file logs and returns nil. The caller treats nil as "no role chosen
/// yet" and re-prompts. Never throw on read — Mom never sees a crash
/// because her plist got corrupted.
final class FileRoleStorage: RoleStorage {
    private let storeFileURL: URL

    init(storeFileURL: URL? = nil) {
        if let storeFileURL {
            self.storeFileURL = storeFileURL
        } else {
            self.storeFileURL = FileRoleStorage.defaultStoreFileURL()
        }
    }

    func loadRole() -> AppRole? {
        guard FileManager.default.fileExists(atPath: storeFileURL.path) else {
            return nil
        }
        do {
            let payloadData = try Data(contentsOf: storeFileURL)
            let decodedRole = try JSONDecoder().decode(AppRole.self, from: payloadData)
            return decodedRole
        } catch {
            // Corrupted file — drop it on the floor and re-prompt.
            // We DON'T delete the bad file here; if the user hits a
            // recovery flow we want the file present for inspection.
            NSLog("[RoleManager] Failed to decode persisted role at \(storeFileURL.path): \(error)")
            return nil
        }
    }

    func saveRole(_ role: AppRole) throws {
        let payloadData = try JSONEncoder().encode(role)
        try ensureParentDirectoryExists()
        try payloadData.write(to: storeFileURL, options: [.atomic])
    }

    func clear() {
        try? FileManager.default.removeItem(at: storeFileURL)
    }

    private func ensureParentDirectoryExists() throws {
        let parentDirectoryURL = storeFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private static func defaultStoreFileURL() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupportDirectory
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("role.json")
    }
}

/// In-memory storage for tests. Optionally pretends to be corrupted on
/// load so we can exercise the "persistence corruption → fresh prompt"
/// path without scribbling on the user's disk.
final class InMemoryRoleStorage: RoleStorage {
    private(set) var savedRole: AppRole?
    var loadShouldReturnNilToSimulateCorruption = false

    init(initialRole: AppRole? = nil) {
        self.savedRole = initialRole
    }

    func loadRole() -> AppRole? {
        if loadShouldReturnNilToSimulateCorruption {
            return nil
        }
        return savedRole
    }

    func saveRole(_ role: AppRole) throws {
        savedRole = role
    }

    func clear() {
        savedRole = nil
    }
}
