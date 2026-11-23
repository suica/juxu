import Foundation
import Security

public enum VoiceProviderMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case cloudBYOK = "cloud_byok"
    case local = "local"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cloudBYOK: return "云端 BYOK"
        case .local: return "本地模型"
        }
    }

    public var summary: String {
        switch self {
        case .cloudBYOK: return "预设服务填 Key 即用，或自定义 URL"
        case .local: return "一键下载本机依赖与模型，离线按需运行"
        }
    }
}

public enum VoiceCloudPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case groq = "groq"
    case openai = "openai"
    case siliconflow = "siliconflow"
    case custom = "custom"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .groq: return "Groq（推荐 · 极速）"
        case .openai: return "OpenAI"
        case .siliconflow: return "硅基流动（国内直连）"
        case .custom: return "自定义（OpenAI 兼容）"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .groq: return "https://api.groq.com/openai/v1"
        case .openai: return "https://api.openai.com/v1"
        case .siliconflow: return "https://api.siliconflow.cn/v1"
        case .custom: return "https://api.openai.com/v1"
        }
    }

    public var defaultASRModel: String {
        switch self {
        case .groq: return "whisper-large-v3-turbo"
        case .openai: return "gpt-4o-mini-transcribe"
        case .siliconflow: return "FunAudioLLM/SenseVoiceSmall"
        case .custom: return "whisper-1"
        }
    }

    public var defaultLLMModel: String {
        switch self {
        case .groq: return "llama-3.3-70b-versatile"
        case .openai: return "gpt-4o-mini"
        case .siliconflow: return "Qwen/Qwen2.5-7B-Instruct"
        case .custom: return "gpt-4o-mini"
        }
    }

    public var keyPlaceholder: String {
        switch self {
        case .groq: return "gsk_..."
        case .openai, .siliconflow, .custom: return "sk-..."
        }
    }

    public var subtitle: String {
        switch self {
        case .groq: return "单个 Key 同时驱动 Whisper v3 Turbo 识别 + Llama 3.3 极速整理"
        case .openai: return "单个 Key 同时驱动 gpt-4o-mini-transcribe + gpt-4o-mini 整理"
        case .siliconflow: return "国内直连，单个 Key 同时驱动 SenseVoice 识别 + Qwen2.5 整理"
        case .custom: return "自由填写 OpenAI 兼容 Base URL、模型名与 API Key"
        }
    }

    public var keychainAccount: VoiceKeychainAccount {
        switch self {
        case .groq: return .cloudGroqAPIKey
        case .openai: return .cloudOpenAIAPIKey
        case .siliconflow: return .cloudSiliconFlowAPIKey
        case .custom: return .cloudCustomASRAPIKey
        }
    }
}

public enum VoiceLocalASRModelPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case whisperTurbo = "whisper_turbo"
    case whisperBase = "whisper_base"
    case appleSpeech = "apple_speech"
    case customHTTP = "custom_http"

    public var id: String { rawValue }

    public var displayName: String { descriptor.displayName }
    public var modelFilename: String? { descriptor.modelFilename }
    public var approximateSizeLabel: String { descriptor.sizeLabel }
    public var downloadURLs: [URL] { descriptor.downloadURLs }
}

public enum VoiceLocalLLMPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case qwen15B = "qwen_1_5b"
    case ollamaHTTP = "ollama_http"
    case none = "none"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qwen15B: return "本地 Qwen2.5-1.5B（AI 整理）"
        case .ollamaHTTP: return "已有本地服务（Ollama 等）"
        case .none: return "不整理（原话直出）"
        }
    }

    public var modelFilename: String? {
        switch self {
        case .qwen15B: return "qwen2.5-1.5b-instruct-q4_k_m.gguf"
        case .ollamaHTTP, .none: return nil
        }
    }

    public var approximateSizeLabel: String {
        switch self {
        case .qwen15B: return "1.0 GB"
        case .ollamaHTTP, .none: return "0 MB"
        }
    }

    public var downloadURLs: [URL] {
        guard let filename = modelFilename else { return [] }
        return [
            URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/\(filename)")!,
            URL(string: "https://hf-mirror.com/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/\(filename)")!,
        ]
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VoiceLocalLLMPreset(rawValue: raw) ?? .qwen15B
    }
}

public enum VoiceTriggerKey: String, Codable, CaseIterable, Identifiable, Sendable {
    case rightOption = "right_option"
    case rightCommand = "right_command"
    case fnKey = "fn_key"
    case optionSpace = "option_space"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rightOption: return "按住右 Option 键"
        case .rightCommand: return "按住右 Command 键"
        case .fnKey: return "按住 Fn / 地球键"
        case .optionSpace: return "点按 Option + Space 启停"
        }
    }

    public var isHoldToTalk: Bool {
        self != .optionSpace
    }

    public var modifierKeyCode: UInt16? {
        switch self {
        case .rightOption: return 0x3D
        case .rightCommand: return 0x36
        case .fnKey: return 0x3F
        case .optionSpace: return nil
        }
    }
}

public enum VoiceOutputMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case smartPolish = "smart_polish"
    case rawDictation = "raw_dictation"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .smartPolish: return "智能整理（推荐）"
        case .rawDictation: return "原始听写（原话直出）"
        }
    }
}

public enum VoiceToneMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case autoByApp = "auto_by_app"
    case casual = "casual"
    case professional = "professional"
    case concise = "concise"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .autoByApp: return "按当前应用自动适配"
        case .casual: return "自然口语（聊天）"
        case .professional: return "清晰书面（邮件/文档）"
        case .concise: return "精炼要点（列表/结论）"
        }
    }
}

public struct VoicePreferences: Codable, Equatable, Sendable {
    /// Master switch: defaults to false so zero voice resources are loaded unless explicitly enabled.
    public var enabled: Bool = false
    public var providerMode: VoiceProviderMode = .cloudBYOK
    public var triggerKey: VoiceTriggerKey = .rightOption
    public var outputMode: VoiceOutputMode = .smartPolish
    public var toneMode: VoiceToneMode = .autoByApp
    public var language: String = "zh"
    public var speakToEditSelection: Bool = true
    public var syncJuxuLexicon: Bool = true
    public var customVocabulary: String = ""

    // Cloud BYOK
    public var cloudPreset: VoiceCloudPreset = .groq
    public var cloudPolishEnabled: Bool = true
    public var customBaseURL: String = "https://api.openai.com/v1"
    public var customASRModel: String = "whisper-1"
    public var customLLMModel: String = "gpt-4o-mini"
    public var customSplitLLM: Bool = false
    public var customLLMBaseURL: String = "https://api.deepseek.com/v1"

    // Local models (one-click download + on-demand execution)
    public var localASRPreset: VoiceLocalASRModelPreset = .whisperTurbo
    public var localAppleLocale: String = "zh-CN"
    public var localAppleRequireOnDevice: Bool = true
    public var localHTTPASRBaseURL: String = "http://127.0.0.1:8080/v1"
    public var localHTTPASRModel: String = "whisper-1"

    public var localLLMPreset: VoiceLocalLLMPreset = .qwen15B
    public var localHTTPLLMBaseURL: String = "http://127.0.0.1:11434/v1"
    public var localHTTPLLMModel: String = "qwen2.5:3b"

    public init() {}

    public var effectiveCloudASRBaseURL: String {
        cloudPreset == .custom ? customBaseURL : cloudPreset.defaultBaseURL
    }

    public var effectiveCloudASRModel: String {
        cloudPreset == .custom ? customASRModel : cloudPreset.defaultASRModel
    }

    public var effectiveCloudLLMBaseURL: String {
        if cloudPreset == .custom {
            return customSplitLLM ? customLLMBaseURL : customBaseURL
        }
        return cloudPreset.defaultBaseURL
    }

    public var effectiveCloudLLMModel: String {
        cloudPreset == .custom ? customLLMModel : cloudPreset.defaultLLMModel
    }

    public var effectiveCloudASRKeyAccount: VoiceKeychainAccount {
        cloudPreset.keychainAccount
    }

    public var effectiveCloudLLMKeyAccount: VoiceKeychainAccount {
        if cloudPreset == .custom && customSplitLLM {
            return .cloudCustomLLMAPIKey
        }
        return cloudPreset.keychainAccount
    }

    public var parsedCustomVocabulary: [String] {
        let separators = CharacterSet(charactersIn: ",，\n;；")
        return customVocabulary
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

public enum VoiceKeychainAccount: String, Sendable {
    case cloudGroqAPIKey = "cloud-key-groq"
    case cloudOpenAIAPIKey = "cloud-key-openai"
    case cloudSiliconFlowAPIKey = "cloud-key-siliconflow"
    case cloudCustomASRAPIKey = "cloud-key-custom-asr"
    case cloudCustomLLMAPIKey = "cloud-key-custom-llm"
}

public enum VoiceKeychainStore {
    private static let service = "im.juxu.voice"
    private static let legacyService = "com.hcyue.juxu.voice"

    public static func read(_ account: VoiceKeychainAccount) -> String {
        for svc in [service, legacyService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
                kSecAttrAccount as String: account.rawValue,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess,
               let data = result as? Data,
               let value = String(data: data, encoding: .utf8),
               !value.isEmpty {
                if svc != service {
                    write(value, for: account)
                }
                return value
            }
        }
        return ""
    }

    @discardableResult
    public static func write(_ value: String, for account: VoiceKeychainAccount) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return delete(account)
        }
        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    public static func delete(_ account: VoiceKeychainAccount) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

@MainActor
public final class VoicePreferencesStore: ObservableObject {
    public static let shared = VoicePreferencesStore()

    @Published public private(set) var prefs: VoicePreferences
    public let fileURL: URL
    private let inMemoryOnly: Bool

    public init(fileURL: URL? = nil, inMemoryOnly: Bool = false) {
        self.inMemoryOnly = inMemoryOnly
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            self.fileURL = home
                .appendingPathComponent("Library/Application Support/Juxu", isDirectory: true)
                .appendingPathComponent("voice.json")
        }
        if !inMemoryOnly,
           FileManager.default.fileExists(atPath: self.fileURL.path),
           let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode(VoicePreferences.self, from: data) {
            self.prefs = decoded
        } else {
            self.prefs = VoicePreferences()
        }
    }

    public func update(_ newPrefs: VoicePreferences, persist: Bool = true) {
        let wasEnabled = prefs.enabled
        self.prefs = newPrefs
        if persist && !inMemoryOnly {
            save()
        }
        if wasEnabled && !newPrefs.enabled {
            VoiceSessionController.unload()
            VoiceLocalInstaller.unload()
        }
    }

    public func update(_ mutate: (inout VoicePreferences) -> Void, persist: Bool = true) {
        var copy = prefs
        mutate(&copy)
        update(copy, persist: persist)
    }

    private func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(prefs) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
