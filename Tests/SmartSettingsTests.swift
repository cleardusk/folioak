import Foundation

private final class MemorySmartCredentials: SmartCredentialStorage {
    var value: String?
    var reads = 0, writes = 0, deletes = 0
    var fails = false
    func read() throws -> String? {
        reads += 1
        if fails { throw SmartSettingsError.readFailed }
        return value
    }
    func write(_ key: String) throws {
        writes += 1
        if fails { throw SmartSettingsError.saveFailed }
        value = key
    }
    func delete() throws {
        deletes += 1
        if fails { throw SmartSettingsError.deleteFailed }
        value = nil
    }
}

extension CoreTests {
    @MainActor static func smartSettingsTests() throws {
        let suite = "folioak-smart-settings-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let credentials = MemorySmartCredentials()
        let settings = SmartSettings(preferences, credentials: credentials)
        try expect(!settings.enabled && !settings.hasKey && credentials.reads == 0,
                   "smart input defaults off without reading credentials")
        do { _ = try settings.apiKey(); throw TestFailure.failed("disabled smart input read key") }
        catch SmartSettingsError.disabled {}
        try expect(credentials.reads == 0, "disabled input never reads keychain")

        settings.enabled = true
        do { _ = try settings.apiKey(); throw TestFailure.failed("missing smart key accepted") }
        catch SmartSettingsError.missingKey {}
        try expect(settings.enabled && !settings.hasKey, "missing key preserves explicit routing preference")
        for invalid in ["", " \n ", "sk-key\ninjection", "sk-key value", "密钥", String(repeating: "x", count: 513)] {
            do { try settings.saveKey(invalid); throw TestFailure.failed("invalid smart key accepted") }
            catch SmartSettingsError.invalidKey {}
        }
        try expect(credentials.writes == 0, "invalid credentials never reach keychain")

        try settings.saveKey("  sk-test-key-only  \n")
        try expect(settings.hasKey && credentials.value == "sk-test-key-only", "saved credentials normalized")
        let stored = preferences.persistentDomain(forName: suite) ?? [:]
        try expect(!stored.values.contains { ($0 as? String)?.contains("sk-test-key-only") == true },
                   "preferences do not contain credential material")
        let reads = credentials.reads
        let restored = SmartSettings(preferences, credentials: credentials)
        try expect(restored.enabled && restored.hasKey && credentials.reads == reads,
                   "restoring smart settings does not read keychain")
        try expect(try restored.apiKey() == "sk-test-key-only", "explicit request reads stored key")

        credentials.fails = true
        do { try settings.saveKey("sk-replacement"); throw TestFailure.failed("failed credential write accepted") }
        catch SmartSettingsError.saveFailed {}
        try expect(settings.hasKey && credentials.value == "sk-test-key-only", "failed replacement preserves old key")
        do { try settings.clearKey(); throw TestFailure.failed("failed credential deletion accepted") }
        catch SmartSettingsError.deleteFailed {}
        try expect(settings.hasKey && settings.enabled, "failed deletion preserves configured state")
        do { _ = try settings.apiKey(); throw TestFailure.failed("failed key read accepted") }
        catch SmartSettingsError.readFailed {}
        try expect(settings.hasKey, "keychain access failure is not represented as missing key")

        credentials.fails = false
        credentials.value = nil
        do { _ = try settings.apiKey(); throw TestFailure.failed("stale configured key accepted") }
        catch SmartSettingsError.missingKey {}
        try expect(!settings.hasKey && settings.enabled, "missing key reconciles stale flag without changing routing")
        try settings.saveKey("sk-next-key")
        try settings.clearKey()
        try expect(!settings.hasKey && settings.enabled && credentials.value == nil,
                   "explicit key removal clears credential without silently changing routing")
        print("PASS smart input credential settings")
    }
}
