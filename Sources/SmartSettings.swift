import SwiftUI
import Security

protocol SmartCredentialStorage {
    func read() throws -> String?
    func write(_ key: String) throws
    func delete() throws
}

enum SmartSettingsError: LocalizedError {
    case disabled, missingKey, invalidKey, readFailed, saveFailed, deleteFailed
    var errorDescription: String? {
        switch self {
        case .disabled: return L("智能输入已关闭。")
        case .missingKey: return L("请先在设置的“智能输入”中保存 DeepSeek API Key。")
        case .invalidKey: return L("API Key 格式无效，请检查后重新粘贴。")
        case .readFailed: return L("无法读取钥匙串中的 API Key，请检查访问权限后重试。")
        case .saveFailed: return L("API Key 未能保存到钥匙串，原有设置已保留。")
        case .deleteFailed: return L("API Key 未能从钥匙串移除，原有设置已保留。")
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
    private let preferences: UserDefaults
    private let credentials: any SmartCredentialStorage
    @Published var enabled: Bool {
        didSet { preferences.set(enabled, forKey: Self.enabledPreferenceKey) }
    }
    @Published private(set) var hasKey: Bool

    init(_ preferences: UserDefaults, credentials: any SmartCredentialStorage = KeychainSmartCredentialStorage()) {
        self.preferences = preferences
        self.credentials = credentials
        enabled = preferences.bool(forKey: Self.enabledPreferenceKey)
        // This is a display hint, not proof of access. Startup must not unlock
        // the Keychain or expose credentials to unrelated downloads and tests.
        hasKey = preferences.bool(forKey: Self.configuredPreferenceKey)
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
        let key = try Self.validated(raw)
        do { try credentials.write(key) }
        catch { throw SmartSettingsError.saveFailed }
        setConfigured(true)
    }

    func clearKey() throws {
        do { try credentials.delete() }
        catch { throw SmartSettingsError.deleteFailed }
        setConfigured(false)
        // Keep the user's routing choice. A missing key is an explicit setup
        // error, never permission to discard conditions and download bare URLs.
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
    @SmartSettingsViewState private var key = ""
    @SmartSettingsViewState private var notice: String?
    @SmartSettingsViewState private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(L("启用智能输入"), isOn: $settings.enabled).toggleStyle(.checkbox)
                    .accessibilityIdentifier("smart-input-toggle")
                HStack(spacing: 10) {
                    SecureField(L("DeepSeek API Key"), text: $key)
                        .textFieldStyle(.roundedBorder).onSubmit(save)
                        .accessibilityIdentifier("smart-input-api-key")
                    Button(L("保存"), action: save).controlSize(.small)
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("smart-input-save-key")
                }
                HStack(spacing: 12) {
                    Text(L(settings.hasKey ? "Key 已保存" : "未设置 Key"))
                        .font(.caption).foregroundStyle(ThemePalette.color(palette.secondary))
                        .accessibilityIdentifier("smart-input-key-status")
                    if settings.hasKey {
                        Button(L("移除 Key"), action: remove).controlSize(.small)
                            .accessibilityIdentifier("smart-input-remove-key")
                    }
                }
                Text(L("智能请求及相关网页内容会发送至 DeepSeek；纯链接本机处理，Key 保存在本机钥匙串。"))
                    .font(.caption).foregroundStyle(ThemePalette.color(palette.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                if let notice {
                    Text(L(notice)).font(.caption)
                        .foregroundStyle(failed ? Color.red : ThemePalette.color(palette.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("smart-input-key-notice")
                }
            }.padding(.trailing, 4).frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear { key = "" }
    }

    private func save() {
        do { try settings.saveKey(key); key = ""; notice = nil; failed = false }
        catch { notice = error.localizedDescription; failed = true }
    }

    private func remove() {
        do { try settings.clearKey(); key = ""; notice = nil; failed = false }
        catch { notice = error.localizedDescription; failed = true }
    }
}
