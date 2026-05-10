//
//  NotesPanelView.swift
//  leanring-buddy
//
//  Notes browser surfaced from the companion panel footer. Lists every note
//  the user has saved, lets them add one inline, and delete with a tap.
//  Notes are persisted by NotesStore and injected into Claude's system
//  prompt on every conversation. Hosted in a draggable NSWindow by
//  NotesWindowController so it stays out of the user's way and survives
//  main-panel dismissal.
//

import SwiftUI

struct NotesPanelView: View {
    @ObservedObject var notesStore: NotesStore
    @ObservedObject var companionManager: CompanionManager

    @State private var newNoteText: String = ""
    @FocusState private var isNoteFieldFocused: Bool

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleBarStrip

            if notesStore.notes.isEmpty {
                emptyState
            } else {
                addNoteField
                notesList
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colors.background)
    }

    // MARK: - Title strip

    /// Sits below the traffic lights inside the transparent titlebar window.
    /// Padded enough on the leading edge so the macOS traffic-light controls
    /// never overlap the title.
    private var titleBarStrip: some View {
        HStack(spacing: 10) {
            Text("Milo Notes")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .tracking(-0.2)

            Spacer()

            // Note count chip — small numeric badge so the user can see how
            // much memory Milo has on file at a glance.
            Text("\(notesStore.notes.count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .monospacedDigit()
                .frame(minWidth: 18)

            // Folder glyph — purely visual; clicks open the same Notes
            // storage directory in Finder so users can back up the JSON.
            Button(action: revealNotesStorageInFinder) {
                Image(systemName: "tray")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 28, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Reveal notes storage in Finder")
        }
        // Leave the standard 78pt traffic-light reserved area on the leading
        // edge. Without this, the title would slide under the close button.
        .padding(.leading, 78)
        .padding(.trailing, 4)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    // MARK: - Add Note

    private var addNoteField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(DS.Colors.textTertiary)

            TextField("Add a note for Milo to remember…", text: $newNoteText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .focused($isNoteFieldFocused)
                .onSubmit(submitNewNote)

            if !trimmedNewNoteText.isEmpty {
                Button(action: submitNewNote) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(companionManager.selectedCursorColor.displayColor)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    // MARK: - List + Empty State

    private var notesList: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(notesStore.notes) { savedNote in
                    noteRow(for: savedNote)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func noteRow(for savedNote: MiloNote) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(savedNote.text)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(Self.dateFormatter.string(from: savedNote.createdAt))
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer(minLength: 0)

            Button(action: {
                notesStore.remove(id: savedNote.id)
                MiloAnalytics.trackNoteDeleted()
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Delete note")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    /// Centered empty state — matches the "No articles yet" mockup. Uses a
    /// large outline tray glyph and copy that nudges the user toward the
    /// voice phrasing they need.
    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.7)
                    .frame(width: 56, height: 56)

                Image(systemName: "tray")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            VStack(spacing: 6) {
                Text("No articles yet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("Show Milo something you wanna keep and tell it to save it for you.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 260)
            }

            // A tiny inline add field so empty doesn't mean a dead end —
            // the user can still type their first note here without leaving
            // the empty state.
            addNoteField
                .padding(.top, 6)
                .frame(maxWidth: 320)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 8)
    }

    // MARK: - Helpers

    private var trimmedNewNoteText: String {
        newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitNewNote() {
        let trimmedText = trimmedNewNoteText
        guard !trimmedText.isEmpty else { return }
        notesStore.add(text: trimmedText)
        MiloAnalytics.trackNoteSaved()
        newNoteText = ""
        isNoteFieldFocused = true
    }

    private func revealNotesStorageInFinder() {
        let fileManager = FileManager.default
        guard let appSupportDir = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return }
        let miloDir = appSupportDir.appendingPathComponent("Milo", isDirectory: true)
        try? fileManager.createDirectory(at: miloDir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([miloDir])
    }
}
