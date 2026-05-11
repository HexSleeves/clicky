//
//  UILabelCategorizerTests.swift
//  leanring-buddyTests
//
//  Pins the categorizer behavior so changes to the rule set are deliberate.
//  Order of checks matters: more specific intents (delete/send/save) win
//  over generic types (button) when both would match. The "unknown"
//  bucket is a feature — its frequency curve drives which categories to
//  add next, so we deliberately don't try to make everything map.
//

import Testing
@testable import Milo

struct UILabelCategorizerTests {

    // MARK: - Intent-bearing (the high-value buckets)

    @Test func sendButtonBucketsAsSendSubmit() {
        #expect(UILabelCategorizer.bucket("Send") == .sendSubmit)
        #expect(UILabelCategorizer.bucket("Submit form") == .sendSubmit)
        #expect(UILabelCategorizer.bucket("Reply") == .sendSubmit)
    }

    @Test func saveOkApplyBucketAsSaveConfirm() {
        #expect(UILabelCategorizer.bucket("Save") == .saveConfirm)
        #expect(UILabelCategorizer.bucket("OK") == .saveConfirm)
        #expect(UILabelCategorizer.bucket("Apply changes") == .saveConfirm)
        #expect(UILabelCategorizer.bucket("Done") == .saveConfirm)
    }

    @Test func deleteRemoveTrashBucketAsDestructive() {
        #expect(UILabelCategorizer.bucket("Delete") == .deleteDestructive)
        #expect(UILabelCategorizer.bucket("Remove from list") == .deleteDestructive)
        #expect(UILabelCategorizer.bucket("Move to trash") == .deleteDestructive)
        #expect(UILabelCategorizer.bucket("Discard changes") == .deleteDestructive)
    }

    @Test func cancelAndCloseDistinguished() {
        // Cancel is "do not commit"; close is "dismiss the surface".
        // Keeping them separate lets product see if users back out vs.
        // bail out — different signals.
        #expect(UILabelCategorizer.bucket("Cancel") == .cancel)
        #expect(UILabelCategorizer.bucket("Go back") == .cancel)
        #expect(UILabelCategorizer.bucket("Close") == .close)
        #expect(UILabelCategorizer.bucket("Dismiss") == .close)
        #expect(UILabelCategorizer.bucket("×") == .close)
    }

    // MARK: - Precedence — intent wins over generic shape

    @Test func deleteButtonBucketsAsDestructiveNotButton() {
        // "Delete button" mentions both "delete" and "button" — destructive
        // intent must win. Mixing destructive actions into the generic
        // .button bucket would lose the safety story for T1 work.
        #expect(UILabelCategorizer.bucket("Delete button") == .deleteDestructive)
    }

    @Test func sendMenuItemBucketsAsSendSubmitNotMenuItem() {
        #expect(UILabelCategorizer.bucket("Send menu item") == .sendSubmit)
    }

    // MARK: - Discovery

    @Test func searchFilterSortBucketCorrectly() {
        #expect(UILabelCategorizer.bucket("Search bar") == .search)
        #expect(UILabelCategorizer.bucket("Filter results") == .filter)
        #expect(UILabelCategorizer.bucket("Sort by name") == .sort)
    }

    // MARK: - Media

    @Test func playPauseSeekBucketCorrectly() {
        #expect(UILabelCategorizer.bucket("Play") == .mediaPlay)
        #expect(UILabelCategorizer.bucket("Pause") == .mediaPause)
        #expect(UILabelCategorizer.bucket("Seek bar") == .mediaSeek)
        // Pause should win over play when both substrings appear because
        // "pause" is the more specific intent for the currently-playing
        // state. (Test pinning so a careless rule reorder doesn't break it.)
        #expect(UILabelCategorizer.bucket("Pause / Play toggle") == .mediaPause)
    }

    // MARK: - Generic surfaces (fallbacks)

    @Test func buttonWithoutIntentFallsThroughToButton() {
        #expect(UILabelCategorizer.bucket("Mystery button") == .button)
    }

    @Test func textFieldBucketsFromMultipleSynonyms() {
        #expect(UILabelCategorizer.bucket("Email field") == .textField)
        #expect(UILabelCategorizer.bucket("Username input") == .textField)
    }

    @Test func searchBoxBucketsAsSearchNotTextField() {
        // Intent wins over generic shape: "Search box" is a textField
        // structurally, but its purpose is search. Counting it as .search
        // is what makes the search funnel measurable.
        #expect(UILabelCategorizer.bucket("Search box") == .search)
    }

    // MARK: - Edge cases

    @Test func emptyLabelBucketsAsUnknown() {
        #expect(UILabelCategorizer.bucket("") == .unknown)
        #expect(UILabelCategorizer.bucket(nil) == .unknown)
        #expect(UILabelCategorizer.bucket("   ") == .unknown)
    }

    @Test func unrecognizedLabelBucketsAsUnknown() {
        // The "unknown" bucket is a feature — its frequency tells us
        // which categories to add next.
        #expect(UILabelCategorizer.bucket("Frobnicate the widget") == .unknown)
    }

    @Test func caseDoesNotMatter() {
        #expect(UILabelCategorizer.bucket("SAVE") == .saveConfirm)
        #expect(UILabelCategorizer.bucket("Save") == .saveConfirm)
        #expect(UILabelCategorizer.bucket("save") == .saveConfirm)
    }

    // MARK: - PII safety check

    @Test func userContentInLabelStillProducesACategory() {
        // The whole point of bucketing: even if the label contains
        // user-visible text, the *output* is just an enum case. The
        // raw label never leaves this function in any form.
        let veryPersonalLabel = "Reply to John about loan paperwork"
        let bucket = UILabelCategorizer.bucket(veryPersonalLabel)
        #expect(bucket == .sendSubmit)
        // Sanity: the bucket's rawValue is a fixed string, not the input.
        #expect(!bucket.rawValue.contains("John"))
        #expect(!bucket.rawValue.contains("loan"))
    }
}
