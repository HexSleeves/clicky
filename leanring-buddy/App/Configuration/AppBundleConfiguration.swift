//
//  AppBundleConfiguration.swift
//  leanring-buddy
//
//  Shared helper for reading runtime configuration from the built app bundle.
//

import Foundation

enum AppBundleConfiguration {
    // `nonisolated` so this helper can be called from any context —
    // matches the WorkerEndpoints pattern. Project ships with default
    // actor isolation = MainActor, which would otherwise make this
    // implicitly isolated.
    nonisolated static func stringValue(forKey key: String) -> String? {
        if let environmentOverride = nonEmptyStringValue(ProcessInfo.processInfo.environment[key]) {
            return environmentOverride
        }

        if let userDefaultsOverride = nonEmptyStringValue(UserDefaults.standard.string(forKey: key)) {
            return userDefaultsOverride
        }

        if let bundleValue = nonEmptyStringValue(Bundle.main.object(forInfoDictionaryKey: key) as? String) {
            return bundleValue
        }

        guard let resourceInfoPath = Bundle.main.path(forResource: "Info", ofType: "plist"),
              let resourceInfo = NSDictionary(contentsOfFile: resourceInfoPath),
              let value = resourceInfo[key] as? String else {
            return nil
        }

        return nonEmptyStringValue(value)
    }

    private nonisolated static func nonEmptyStringValue(_ value: String?) -> String? {
        guard let value else { return nil }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
