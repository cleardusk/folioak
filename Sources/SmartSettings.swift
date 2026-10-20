import SwiftUI
import Security

protocol SmartCredentialStorage {
    func read() throws -> String?
    func write(_ key: String) throws
    func delete() throws
}

protocol SmartCredentialValidating: Sendable {
    func validate(_ key: String) async throws
}

struct DeepSeekCredentialValidator: SmartCredentialValidating {
    private let api: any HTTPTransport
    init(api: (any HTTPTransport)? = nil) { self.api = api ?? SmartAPITransport() }

    func validate(_ key: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/models")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await api.data(for: request)
            try Task.checkCancellation()
            switch response.statusCode {
            case 200: break
            case 401, 403: throw SmartSettingsError.rejectedKey
            case 429: throw SmartSettingsError.validationUnavailable
            default: throw SmartSettingsError.validationUnavailable
            }
            guard response.url == request.url, data.count <= ResourceLimits.metadataBytes,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["object"] as? String == "list",
                  let models = object["data"] as? [[String: Any]],
                  models.contains(where: { ($0["id"] as? String)?.isEmpty == false }) else {
                throw SmartSettingsError.validationUnavailable
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as SmartSettingsError { throw error }
        catch {
            try Task.checkCancellation()
            // Never expose a server body or transport error that could echo credentials.
            throw SmartSettingsError.validationUnavailable
        }
    }
}

enum SmartSettingsError: LocalizedError {
    case disabled, missingKey, invalidKey, readFailed, saveFailed, deleteFailed, rejectedKey, validationUnavailable
    var errorDescription: String? {
        switch self {
        case .disabled: return L("智能输入已关闭。")
        case .missingKey: return L("请粘贴 DeepSeek API Key。")
        case .invalidKey: return L("API Key 格式无效，请检查后重新粘贴。")
        case .readFailed: return L("无法读取钥匙串中的 API Key，请检查访问权限后重试。")
        case .saveFailed: return L("API Key 未能保存到钥匙串，原有设置已保留。")
        case .deleteFailed: return L("API Key 未能从钥匙串移除，原有设置已保留。")
        case .rejectedKey: return L("Key 无效或已撤销，请重新粘贴。")
        case .validationUnavailable: return L("暂时无法验证，请检查网络后重试。")
        }
    }
}

struct KeychainSmartCredentialStorage: SmartCredentialStorage {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.paperrepo.arxiv-downloader.deepseek",
         kSecAttrAccount as String: "api-key"]
    }

    func read() throws -> String? {
        var request = query
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw SmartSettingsError.readFailed }
        return key
    }

    func write(_ key: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SmartSettingsError.saveFailed }
        var request = query.merging(attributes) { _, new in new }
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw SmartSettingsError.saveFailed }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SmartSettingsError.deleteFailed }
    }
}

@MainActor final class SmartSettings: ObservableObject {
    static let enabledPreferenceKey = "smartInputEnabled"
    static let configuredPreferenceKey = "smartInputKeyConfigured"
    static let thinkingPreferenceKey = "smartInputThinkingEffort"
    private let preferences: UserDefaults
    private let credentials: any SmartCredentialStorage
    private let validator: any SmartCredentialValidating
    private var connectionRevision = 0
    private var connectionOwner: UUID?
    @Published var enabled: Bool {
        didSet {
            if !enabled { cancelPendingConnection() }
            preferences.set(enabled, forKey: Self.enabledPreferenceKey)
        }
    }
    @Published private(set) var hasKey: Bool
    @Published var thinking: SmartThinkingEffort {
        didSet { preferences.set(thinking.rawValue, forKey: Self.thinkingPreferenceKey) }
    }

    init(_ preferences: UserDefaults, credentials: any SmartCredentialStorage = KeychainSmartCredentialStorage(),
         validator: any SmartCredentialValidating = DeepSeekCredentialValidator()) {
        self.preferences = preferences
        self.credentials = credentials
        self.validator = validator
        enabled = preferences.bool(forKey: Self.enabledPreferenceKey)
        // This is a display hint, not proof of access. Startup must not unlock
        // the Keychain or expose credentials to unrelated downloads and tests.
        hasKey = preferences.bool(forKey: Self.configuredPreferenceKey)
        thinking = preferences.string(forKey: Self.thinkingPreferenceKey).flatMap(SmartThinkingEffort.init(rawValue:)) ?? .off
    }

    func apiKey() throws -> String {
        guard enabled else { throw SmartSettingsError.disabled }
        let saved: String?
        do { saved = try credentials.read() }
        catch { throw SmartSettingsError.readFailed }
        guard let saved else {
            setConfigured(false)
            throw SmartSettingsError.missingKey
        }
        let key = try Self.validated(saved)
        setConfigured(true)
        return key
    }

    func saveKey(_ raw: String) throws {
        cancelPendingConnection()
        let key = try Self.validated(raw)
        do { try credentials.write(key) }
        catch { throw SmartSettingsError.saveFailed }
        setConfigured(true)
    }

    func clearKey() throws {
        cancelPendingConnection()
        do { try credentials.delete() }
        catch { throw SmartSettingsError.deleteFailed }
        setConfigured(false)
        // Keep the user's routing choice. A missing key is an explicit setup
        // error, never permission to discard conditions and download bare URLs.
    }

    func cancelPendingConnection() {
        connectionRevision += 1
        connectionOwner = nil
    }

    func cancelPendingConnection(owner: UUID) {
        guard connectionOwner == owner else { return }
        cancelPendingConnection()
    }

    func connect(_ raw: String, owner: UUID? = nil) async throws {
        try Task.checkCancellation()
        cancelPendingConnection()
        connectionOwner = owner
        let revision = connectionRevision
        defer { if revision == connectionRevision { connectionOwner = nil } }
        let key = try Self.validated(raw)
        try await validator.validate(key)
        try Task.checkCancellation()
        guard revision == connectionRevision else { throw CancellationError() }
        // Only a verified credential can replace the previous one. There is no
        // suspension between the final cancellation check, write and activation.
        try saveKey(key)
        enabled = true
    }

    func connectSavedKey(owner: UUID? = nil) async throws {
        try Task.checkCancellation()
        cancelPendingConnection()
        connectionOwner = owner
        let revision = connectionRevision
        defer { if revision == connectionRevision { connectionOwner = nil } }
        let saved: String?
        do { saved = try credentials.read() }
        catch { throw SmartSettingsError.readFailed }
        guard let saved else { setConfigured(false); throw SmartSettingsError.missingKey }
        let key = try Self.validated(saved)
        try await validator.validate(key)
        try Task.checkCancellation()
        guard revision == connectionRevision else { throw CancellationError() }
        setConfigured(true)
        enabled = true
    }

    private func setConfigured(_ value: Bool) {
        hasKey = value
        preferences.set(value, forKey: Self.configuredPreferenceKey)
    }

    private static func validated(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 512, key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw SmartSettingsError.invalidKey
        }
        return key
    }
}

private typealias SmartSettingsViewState<Value> = SwiftUI.State<Value>

struct SmartSettingsView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var settings: SmartSettings
    let palette: ThemePalette
    var isActive = true
    @SmartSettingsViewState private var replacingKey = false
    @SmartSettingsViewState private var notice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if settings.hasKey && settings.enabled && !replacingKey {
                    HStack {
                        Label(L("已连接"), systemImage: "checkmark.circle")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button(L("停用")) { settings.enabled = false }
                            .buttonStyle(.plain).foregroundStyle(secondary)
                            .accessibilityIdentifier("smart-input-disable")
                    }
                    HStack(spacing: 12) {
                        Text(L("Key 已保存")).foregroundStyle(secondary)
                            .accessibilityIdentifier("smart-input-key-status")
                        Spacer()
                        Button(L("更换 Key")) { notice = nil; replacingKey = true }
                            .accessibilityIdentifier("smart-input-replace-key")
                        Button(L("移除 Key"), action: remove)
                            .accessibilityIdentifier("smart-input-remove-key")
                    }.font(.system(size: 12)).buttonStyle(.plain)
                    SmartConnectionPrivacy(palette: palette)
                } else {
                    if settings.hasKey {
                        HStack {
                            Text(L(replacingKey ? "更换 Key" : "已停用"))
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Button(L("移除 Key"), action: remove)
                                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(secondary)
                                .accessibilityIdentifier("smart-input-remove-key")
                        }
                    }
                    SmartConnectionForm(settings: settings, palette: palette,
                        requiresNewKey: replacingKey, isActive: isActive,
                        onConnected: { replacingKey = false; notice = nil },
                        onCancel: replacingKey ? { replacingKey = false } : nil)
                }
                if let notice {
                    Text(L(notice)).font(.caption).foregroundStyle(Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("smart-input-key-notice")
                }
                Divider()
                Picker(L("思考强度"), selection: $settings.thinking) {
                    ForEach(SmartThinkingEffort.allCases, id: \.self) { effort in
                        Text(L(effort.label)).tag(effort)
                    }
                }
                .pickerStyle(.menu).frame(maxWidth: 320, alignment: .leading)
                .accessibilityIdentifier("smart-input-thinking")
                Text(L("默认关闭。更高强度可能增加等待时间和用量，仅影响新请求。"))
                    .font(.system(size: 11)).foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.trailing, 4).frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(!isActive)
        .onDisappear(perform: leave)
        .onChange(of: isActive) { active in if !active { leave() } }
    }

    private var secondary: Color { ThemePalette.color(palette.secondary) }
    private func leave() {
        replacingKey = false
        notice = nil
    }

    private func remove() {
        settings.cancelPendingConnection()
        do { try settings.clearKey(); replacingKey = false; notice = nil }
        catch { notice = error.localizedDescription }
    }
}

struct SmartConnectionForm: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var settings: SmartSettings
    let palette: ThemePalette
    var continuesRequest = false
    var requiresNewKey = false
    var isActive = true
    var connectionOwner: UUID? = nil
    var onConnected: () -> Void = {}
    var onCancel: (() -> Void)?
    @SmartSettingsViewState private var key = ""
    @SmartSettingsViewState private var replacingKey = false
    @SmartSettingsViewState private var connecting = false
    @SmartSettingsViewState private var notice: String?
    @SmartSettingsViewState private var worker: Task<Void, Never>?
    @SmartSettingsViewState private var requestID: UUID?
    @SmartSettingsViewState private var activeConnectionOwner: UUID?
    @FocusState private var keyFocused: Bool

    private var entersKey: Bool { requiresNewKey || replacingKey || !settings.hasKey }
    private var secondary: Color { ThemePalette.color(palette.secondary) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("连接 DeepSeek")).font(.system(size: 15, weight: .semibold))
            if entersKey {
                SecureField(L("DeepSeek API Key"), text: $key)
                    .textFieldStyle(.roundedBorder).onSubmit(connect)
                    .focused($keyFocused)
                    .onAppear { if isActive { keyFocused = true } }
                    .disabled(connecting)
                    .accessibilityIdentifier("smart-input-api-key")
            } else {
                HStack {
                    Text(L("Key 已保存")).foregroundStyle(secondary)
                        .accessibilityIdentifier("smart-input-key-status")
                    Spacer()
                    Button(L("更换 Key")) { cancelConnection(); replacingKey = true }
                        .buttonStyle(.plain).disabled(connecting)
                        .accessibilityIdentifier("smart-input-replace-key")
                }.font(.system(size: 12))
            }
            SmartConnectionPrivacy(palette: palette)
            if let notice {
                Text(L(notice)).font(.system(size: 12)).foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("smart-input-key-notice")
            }
            HStack(spacing: 12) {
                Link(L("获取 Key"), destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                    .font(.system(size: 12)).foregroundStyle(ThemePalette.color(palette.accent))
                    .accessibilityIdentifier("smart-input-get-key")
                Spacer(minLength: 8)
                if connecting || onCancel != nil {
                    Button(L("取消")) { cancelConnection(); onCancel?() }
                        .buttonStyle(.plain).foregroundStyle(secondary)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("smart-input-cancel-connection")
                }
                Button(action: connect) {
                    HStack(spacing: 6) {
                        if connecting { ProgressView().controlSize(.mini) }
                        Text(L(connecting ? "正在连接…" : continuesRequest ? "连接并继续" : "连接"))
                    }
                }
                .buttonStyle(PrimaryActionStyle(palette: palette))
                .keyboardShortcut(.defaultAction)
                .disabled(connecting || (entersKey && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                .accessibilityIdentifier("smart-input-connect")
            }
        }
        .foregroundStyle(ThemePalette.color(palette.text))
        .disabled(!isActive)
        .onDisappear(perform: cancelConnection)
        .onChange(of: isActive) { active in
            if active { keyFocused = entersKey }
            else { cancelConnection() }
        }
        .onChange(of: requiresNewKey) { _ in cancelConnection() }
        .onChange(of: connectionOwner) { _ in cancelConnection() }
        .onChange(of: settings.hasKey) { present in if !present { cancelConnection() } }
        .onChange(of: key) { _ in notice = nil }
    }

    private func connect() {
        guard isActive, !connecting else { return }
        let useSavedKey = !entersKey
        guard useSavedKey || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let id = UUID(), submittedKey = key
        let owner = connectionOwner ?? id
        activeConnectionOwner = owner
        requestID = id; connecting = true; notice = nil
        worker = Task { @MainActor in
            do {
                if useSavedKey { try await settings.connectSavedKey(owner: owner) }
                else { try await settings.connect(submittedKey, owner: owner) }
                guard !Task.isCancelled, requestID == id else { return }
                requestID = nil; worker = nil; activeConnectionOwner = nil; connecting = false; key = ""
                onConnected()
            } catch is CancellationError {
                guard requestID == id else { return }
                // An obsolete form must not invalidate a newer connection
                // started in another window while this response was pending.
                requestID = nil; worker = nil; activeConnectionOwner = nil; connecting = false
                key = ""; notice = nil; keyFocused = false
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                requestID = nil; worker = nil; activeConnectionOwner = nil; connecting = false
                notice = error.localizedDescription
            }
        }
    }

    private func cancelConnection() {
        requestID = nil
        if let owner = activeConnectionOwner { settings.cancelPendingConnection(owner: owner) }
        activeConnectionOwner = nil
        worker?.cancel(); worker = nil
        connecting = false; key = ""; notice = nil; keyFocused = false
    }
}

private struct SmartConnectionPrivacy: View {
    let palette: ThemePalette
    var body: some View {
        Text(L("Key 仅保存在本机钥匙串；智能请求及相关网页内容发送至 DeepSeek，直接链接本机处理。"))
            .font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}
