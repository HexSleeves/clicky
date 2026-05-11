//
//  UILabelCategorizer.swift
//  leanring-buddy
//
//  Maps Claude's element_label string (which can contain user-visible
//  text like "Reply to John about loan") to a fixed enum bucket. The
//  raw label MUST NOT leave the device — only the category does.
//  Bucketing happens at the analytics call boundary so the rest of the
//  app keeps working with raw labels for UI/logging, and there's exactly
//  one place to audit for PII leakage.
//
//  Why a switch + contains() blob instead of an ML classifier:
//  - Deterministic output keeps PostHog dashboards stable across versions
//  - The full policy reads in <100 lines, easy to review in PRs
//  - "unknown" is a feature — its frequency curve tells you which
//    categories to add next, instead of guessing
//

import Foundation

enum UICategory: String, CaseIterable {

    // Intent-bearing (highest-value buckets for product analytics)
    case sendSubmit         // "send", "submit", "post", "publish", "reply"
    case saveConfirm        // "save", "confirm", "apply", "done", "ok", "got it"
    case deleteDestructive  // "delete", "remove", "trash", "discard", "clear"
    case cancel             // "cancel", "back", "go back"
    case close              // "close", "dismiss", "×", "x"

    // Generic surfaces
    case button             // anything labeled "button" with no clearer intent
    case link               // "link", URLs, "open" + URL-ish
    case menuItem           // "menu", any item that opens further options
    case textField          // "field", "input", "search box"
    case textArea           // "textarea", multiline editors
    case dropdown           // "dropdown", "select", "picker", "menu" + arrow

    // Navigation
    case tab                // "tab"
    case listItem           // "row", "item"
    case navItem            // "nav", "navigation"
    case toolbarItem        // "toolbar"
    case sidebarItem        // "sidebar"

    // Media
    case mediaPlay          // "play"
    case mediaPause         // "pause"
    case mediaSeek          // "seek", "scrubber", "timeline"

    // Discovery
    case search             // "search"
    case filter             // "filter"
    case sort               // "sort"

    // App chrome / identity
    case settings           // "settings", "preferences", "options"
    case profile            // "profile", "account", "avatar"
    case notification       // "notification", "bell", "alert"

    case unknown
}

enum UILabelCategorizer {

    /// Buckets a raw label into a UICategory. Pure function; no logging
    /// of the input. Order of checks matters: more specific intents
    /// (send/save/delete) win over generic types (button) when both
    /// would match — that's what makes the high-value buckets useful.
    static func bucket(_ rawLabel: String?) -> UICategory {
        guard let label = rawLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !label.isEmpty else { return .unknown }

        // ---- Intent-bearing (check first, most specific) ----

        if containsAny(label, ["delete", "remove", "trash", "discard"]) {
            return .deleteDestructive
        }
        if containsAny(label, ["send", "submit", "post ", "publish", "reply"]) {
            return .sendSubmit
        }
        if containsAny(label, ["save", "confirm", "apply", "done", "got it"])
            || label == "ok" {
            return .saveConfirm
        }
        if containsAny(label, ["cancel", "go back"]) || label == "back" {
            return .cancel
        }
        if containsAny(label, ["close", "dismiss"]) || label == "x" || label == "×" {
            return .close
        }

        // ---- Discovery (specific intents that aren't destructive) ----

        if label.contains("search") { return .search }
        if label.contains("filter") { return .filter }
        if label.contains("sort") { return .sort }

        // ---- Media ----

        if label.contains("pause") { return .mediaPause }
        if label.contains("play") { return .mediaPlay }
        if containsAny(label, ["seek", "scrubber", "timeline"]) { return .mediaSeek }

        // ---- App chrome ----

        if containsAny(label, ["settings", "preferences", "options"]) {
            return .settings
        }
        if containsAny(label, ["profile", "account", "avatar"]) {
            return .profile
        }
        if containsAny(label, ["notification", "alert"]) {
            return .notification
        }

        // ---- Navigation surfaces ----

        if label.contains("sidebar") { return .sidebarItem }
        if label.contains("toolbar") { return .toolbarItem }
        if containsAny(label, ["nav", "navigation"]) { return .navItem }
        if label.contains("tab") { return .tab }

        // ---- Generic surfaces (lowest-precedence fallbacks) ----

        if containsAny(label, ["dropdown", "select", "picker"]) { return .dropdown }
        if containsAny(label, ["textarea", "text area"]) { return .textArea }
        if containsAny(label, ["field", "input", "text box", "search box"]) {
            return .textField
        }
        if containsAny(label, ["link", "url", "http"]) { return .link }
        if containsAny(label, ["menu item", "menu"]) { return .menuItem }
        if containsAny(label, ["row", " item"]) { return .listItem }
        if label.contains("button") { return .button }

        return .unknown
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        for needle in needles where haystack.contains(needle) {
            return true
        }
        return false
    }
}
