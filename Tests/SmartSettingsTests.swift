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

private actor ScriptedCredentialValidator: SmartCredentialValidating {
    enum Outcome: Sendable { case success, rejected, timeout, held }
    private let outcome: Outcome
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var keys: [String] = []
    init(_ outcome: Outcome = .success) { self.outcome = outcome }
    func validate(_ key: String) async throws {
        let request = keys.count
        keys.append(key)
        switch outcome {
        case .success: return
        case .rejected: throw SmartSettingsError.rejectedKey
        case .timeout: throw URLError(.timedOut)
        case .held:
            // Deliberately ignores cancellation: host revision checks must
            // prevent a late network result from saving or enabling anything.
            await withCheckedContinuation { pending[request] = $0 }
        }
    }
    func release(_ request: Int = 0) { pending.removeValue(forKey: request)?.resume() }
}

private actor CredentialValidationTransport: HTTPTransport {
    let status: Int
    let body: Data
    let responseURL: URL?
    let fail: Bool
    private(set) var requests: [URLRequest] = []
    init(status: Int = 200, body: Data, responseURL: URL? = nil, fail: Bool = false) {
        self.status = status; self.body = body; self.responseURL = responseURL; self.fail = fail
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if fail {
            throw NSError(domain: "fixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: body, as: UTF8.self)])
        }
        return (body, HTTPURLResponse(url: responseURL ?? request.url!, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
    func download(for request: URLRequest, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (URL, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }
}

extension CoreTests {
    @MainActor static func smartSettingsTests() async throws {
        do {
            let suite = "folioak-smart-thinking-" + UUID().uuidString
            let preferences = UserDefaults(suiteName: suite)!
            defer { preferences.removePersistentDomain(forName: suite) }
            let credentials = MemorySmartCredentials()
            credentials.fails = true
            let initial = SmartSettings(preferences, credentials: credentials)
            try expect(initial.thinking == .off && !initial.enabled &&
                       preferences.object(forKey: "smartInputThinkingEffort") == nil && credentials.reads == 0,
                       "thinking defaults off without creating a preference or reading credentials")

            preferences.set(true, forKey: SmartSettings.enabledPreferenceKey)
            preferences.set(true, forKey: SmartSettings.configuredPreferenceKey)
            let settings = SmartSettings(preferences, credentials: credentials)
            for effort in [SmartThinkingEffort.off, .low, .high, .max] {
                settings.thinking = effort
                let restored = SmartSettings(preferences, credentials: credentials)
                try expect(preferences.string(forKey: "smartInputThinkingEffort") == effort.rawValue &&
                           restored.thinking == effort && restored.enabled && restored.hasKey,
                           "each thinking level persists across startup without changing routing or configured-key state")
            }
            for unknown in ["future-level", "HIGH", ""] {
                preferences.set(unknown, forKey: "smartInputThinkingEffort")
                let restored = SmartSettings(preferences, credentials: credentials)
                try expect(restored.thinking == .off && restored.enabled && restored.hasKey,
                           "unknown thinking preferences fall back to off without affecting setup")
            }
            try expect(credentials.reads == 0 && credentials.writes == 0 && credentials.deletes == 0,
                       "thinking changes and configured startup never access credential storage")
        }

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
        try await smartConnectionTests()
        try await credentialValidatorTests()
        print("PASS smart input credential settings")
    }

    @MainActor private static func smartConnectionTests() async throws {
        let suite = "folioak-smart-connection-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        func rejected(_ operation: () async throws -> Void, _ message: String) async throws {
            var failed = false
            do { try await operation() } catch { failed = true }
            try expect(failed, message)
        }
        func started(_ validator: ScriptedCredentialValidator, count: Int = 1) async throws {
            for _ in 0..<1_000 {
                if await validator.keys.count >= count { return }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            throw TestFailure.failed("credential validator did not start")
        }
        let credentials = MemorySmartCredentials()
        let validator = ScriptedCredentialValidator()
        let settings = SmartSettings(preferences, credentials: credentials, validator: validator)
        try settings.saveKey("sk-original-fixture")
        for invalid in ["", "sk-two words", "sk-header\r\nInjected: yes", "密钥", String(repeating: "x", count: 513)] {
            try await rejected({ try await settings.connect(invalid) }, "invalid key must not reach remote validation")
        }
        let invalidCalls = await validator.keys
        try expect(invalidCalls.isEmpty && credentials.value == "sk-original-fixture" && !settings.enabled,
                   "invalid connection attempts preserve the previous credential and disabled state")
        try await settings.connect(" \n sk-connected-fixture \n ")
        let validatedKeys = await validator.keys
        try expect(validatedKeys == ["sk-connected-fixture"] && credentials.value == "sk-connected-fixture" &&
                   settings.enabled && settings.hasKey && credentials.writes == 2,
                   "one explicit connection validates the trimmed key before storing and enabling it")
        settings.enabled = false
        let beforeSavedWrites = credentials.writes
        try await settings.connectSavedKey()
        let savedCalls = await validator.keys
        try expect(savedCalls == ["sk-connected-fixture", "sk-connected-fixture"] &&
                   credentials.writes == beforeSavedWrites && settings.enabled,
                   "reconnecting a saved key validates and enables without rewriting the credential")
        let preferencesData = try JSONSerialization.data(withJSONObject: preferences.persistentDomain(forName: suite) ?? [:])
        let preferencesText = String(decoding: preferencesData, as: UTF8.self)
        try expect(!preferencesText.contains("sk-connected-fixture") && !preferencesText.contains("sk-original-fixture"),
                   "connection state persists no credential material in preferences")

        for outcome in [ScriptedCredentialValidator.Outcome.rejected, .timeout] {
            for enabled in [false, true] {
                let store = MemorySmartCredentials()
                let checked = SmartSettings(preferences, credentials: store, validator: ScriptedCredentialValidator(outcome))
                try checked.saveKey("sk-previous-fixture")
                checked.enabled = enabled
                try await rejected({ try await checked.connect("sk-rejected-fixture") }, "failed validation must fail connection")
                try expect(store.value == "sk-previous-fixture" && store.writes == 1 && checked.enabled == enabled && checked.hasKey,
                           "authentication or timeout failure preserves the old key and routing preference")
            }
        }
        let failingStore = MemorySmartCredentials()
        let writeFailure = SmartSettings(preferences, credentials: failingStore, validator: ScriptedCredentialValidator())
        try writeFailure.saveKey("sk-kept-fixture"); writeFailure.enabled = false
        failingStore.fails = true
        try await rejected({ try await writeFailure.connect("sk-not-saved-fixture") }, "keychain write failure cannot complete setup")
        try expect(failingStore.value == "sk-kept-fixture" && !writeFailure.enabled && writeFailure.hasKey,
                   "successful remote validation cannot enable input when secure storage fails")

        for action in ["cancel", "task-cancel", "disable", "clear", "replace", "invalid-replacement",
                       "saved-cancel", "owner-cancel", "saved-owner-cancel"] {
            let store = MemorySmartCredentials()
            let held = ScriptedCredentialValidator(.held)
            let checked = SmartSettings(preferences, credentials: store, validator: held)
            try checked.saveKey("sk-original-fixture"); checked.enabled = false
            let owner = UUID()
            let task = Task {
                if action == "saved-cancel" || action == "saved-owner-cancel" {
                    try await checked.connectSavedKey(owner: owner)
                } else { try await checked.connect("sk-late-fixture", owner: owner) }
            }
            try await started(held)
            try expect(!checked.enabled && store.value == "sk-original-fixture" && store.writes == 1,
                       "pending validation does not mutate storage or routing")
            switch action {
            case "cancel", "saved-cancel": checked.cancelPendingConnection()
            case "owner-cancel", "saved-owner-cancel": checked.cancelPendingConnection(owner: owner)
            case "task-cancel": task.cancel()
            case "disable": checked.enabled = false
            case "clear": try checked.clearKey()
            case "replace": try checked.saveKey("sk-explicit-replacement")
            case "invalid-replacement":
                try await rejected({ try await checked.connect("bad key") }, "invalid later attempt is rejected")
            default: break
            }
            await held.release()
            try await rejected({ try await task.value }, "superseded validation must not commit a late response")
            let expected = action == "clear" ? nil : action == "replace" ? "sk-explicit-replacement" : "sk-original-fixture"
            try expect(store.value == expected && !checked.enabled && checked.hasKey == (expected != nil),
                       "cancel, deletion, replacement and disable make an ignored-cancellation response harmless")
        }

        for usesSavedKey in [false, true] {
            let store = MemorySmartCredentials()
            let held = ScriptedCredentialValidator(.held)
            let checked = SmartSettings(preferences, credentials: store, validator: held)
            try checked.saveKey("sk-original-fixture"); checked.enabled = false
            let model = DownloadModel(preferences: preferences, smartSettings: checked)
            let firstState = model.smartInput, secondState = SmartDownloadState(model: model, quick: true)
            firstState.submit("下载主窗口的论文")
            secondState.submit("下载快捷窗口的论文")
            defer { firstState.cancel(); secondState.cancel() }
            guard let firstOwner = firstState.setupConnectionOwner,
                  let secondOwner = secondState.setupConnectionOwner else {
                throw TestFailure.failed("setup sessions must expose independent connection owners")
            }
            try expect(firstOwner != secondOwner, "main and quick setup sessions have distinct owners")
            let first = Task { try await checked.connect("sk-obsolete-fixture", owner: firstOwner) }
            try await started(held)
            let second = Task {
                if usesSavedKey { try await checked.connectSavedKey(owner: secondOwner) }
                else { try await checked.connect("sk-current-fixture", owner: secondOwner) }
            }
            try await started(held, count: 2)
            firstState.cancel()
            // The disappearing form may clean up after its session already did.
            checked.cancelPendingConnection(owner: firstOwner)
            await held.release(0)
            try await rejected({ try await first.value }, "an obsolete window cannot save a late validated key")
            try expect(store.value == "sk-original-fixture" && store.writes == 1 && !checked.enabled,
                       "closing an obsolete connection leaves the current pending connection and saved key intact")
            await held.release(1)
            try await second.value
            let expected = usesSavedKey ? "sk-original-fixture" : "sk-current-fixture"
            try expect(store.value == expected && store.writes == (usesSavedKey ? 1 : 2) &&
                       checked.enabled && checked.hasKey,
                       "closing an older window and receiving its late result cannot cancel the newer owner's connection")
        }

        for usesSavedKey in [false, true] {
            let store = MemorySmartCredentials()
            let held = ScriptedCredentialValidator(.held)
            let checked = SmartSettings(preferences, credentials: store, validator: held)
            try checked.saveKey("sk-original-fixture"); checked.enabled = false
            let model = DownloadModel(preferences: preferences, smartSettings: checked)
            let quick = SmartDownloadState(model: model, quick: true)
            quick.submit("下载快捷窗口的论文")
            guard let owner = quick.setupConnectionOwner else {
                throw TestFailure.failed("quick setup must expose its connection owner")
            }
            let task = Task {
                if usesSavedKey { try await checked.connectSavedKey(owner: owner) }
                else { try await checked.connect("sk-closed-popover-fixture", owner: owner) }
            }
            try await started(held)
            quick.cancel()
            await held.release()
            try await rejected({ try await task.value }, "closing Quick cancels its own pending credential validation")
            try expect(quick.setupConnectionOwner == nil && !quick.needsSetup && !checked.enabled &&
                       store.value == "sk-original-fixture" && store.writes == 1,
                       "a late response after Quick closes cannot save credentials or enable intelligent input")
        }

        let missing = MemorySmartCredentials()
        let missingValidator = ScriptedCredentialValidator()
        let missingSettings = SmartSettings(preferences, credentials: missing, validator: missingValidator)
        missingSettings.enabled = false
        try await rejected({ try await missingSettings.connectSavedKey() }, "missing saved key cannot be reconnected")
        let missingCalls = await missingValidator.keys
        try expect(missingCalls.isEmpty && missing.writes == 0 && !missingSettings.hasKey && !missingSettings.enabled,
                   "a stale configured hint never substitutes for an actual saved credential")
    }

    private static func credentialValidatorTests() async throws {
        let secret = "sk-synthetic-validator-fixture"
        let valid = Data(#"{"object":"list","data":[{"id":"deepseek-flash","object":"model","owned_by":"deepseek"}]}"#.utf8)
        let transport = CredentialValidationTransport(body: valid)
        try await DeepSeekCredentialValidator(api: transport).validate(secret)
        let requests = await transport.requests
        try expect(requests.count == 1 && requests[0].url?.absoluteString == "https://api.deepseek.com/models" &&
                   requests[0].httpMethod == "GET" && requests[0].httpBody == nil &&
                   requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer " + secret &&
                   requests[0].timeoutInterval > 0 && requests[0].timeoutInterval <= SmartInput.deadline,
                   "credential validation uses one bounded fixed-origin GET with the key only in its authorization header")
        let leaked = Data(("server echoed " + secret).utf8)
        let failures = [
            CredentialValidationTransport(status: 401, body: leaked),
            CredentialValidationTransport(status: 403, body: leaked),
            CredentialValidationTransport(status: 429, body: leaked),
            CredentialValidationTransport(status: 500, body: leaked),
            CredentialValidationTransport(status: 302, body: valid),
            CredentialValidationTransport(body: leaked),
            CredentialValidationTransport(body: Data(#"{"object":"list","data":[]}"#.utf8)),
            CredentialValidationTransport(body: Data(#"{"object":"list","data":[{"id":""}]}"#.utf8)),
            CredentialValidationTransport(body: Data(#"{"object":"other","data":[{"id":"model"}]}"#.utf8)),
            CredentialValidationTransport(body: Data(repeating: 32, count: ResourceLimits.metadataBytes + 1)),
            CredentialValidationTransport(body: valid, responseURL: URL(string: "https://attacker.example/models")),
            CredentialValidationTransport(body: leaked, fail: true)
        ]
        for (index, transport) in failures.enumerated() {
            var rejected = false
            do { try await DeepSeekCredentialValidator(api: transport).validate(secret) }
            catch {
                rejected = true
                try expect(error is SmartSettingsError && !error.localizedDescription.contains(secret) &&
                           !error.localizedDescription.contains("server echoed"),
                           "validation errors expose neither server response bodies nor transport errors containing credentials")
                if index < 2 {
                    guard case SmartSettingsError.rejectedKey = error else {
                        throw TestFailure.failed("401 and 403 must identify an invalid credential")
                    }
                }
            }
            try expect(rejected, "unsuccessful or malformed validation response must not activate the credential")
        }
    }
}
