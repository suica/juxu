import CryptoKit
import Foundation

// One place that knows which local speech models exist. The session, streaming loop, speech gate,
// text cleanup, HUD and commit path only talk to `VoiceASREngine`.
// To add a model: add a preset case, one descriptor below, and at most one executor.

// MARK: - Engine

/// A loaded (or loadable) speech model. Cancelling the calling task cancels a transcription.
@MainActor
public protocol VoiceASREngine: AnyObject {
    func beginSession()
    func endSession()
    func prepare() async throws
    func transcribe(wavData: Data, language: String, timeout: TimeInterval, isFinal: Bool) async throws -> String
    func release()
}

// MARK: - Executors

public enum VoiceASRExecutorID: Sendable {
    case whisperServer
    case qwenHelper
}

/// Runs one family of models.
@MainActor
protocol VoiceASRExecutor {
    /// The program this executor needs, or nil when it is missing.
    func dependencyPath() -> String?
    func makeEngine(modelPath: String, language: String, vocabulary: [String]) -> VoiceASREngine?
    /// One-shot transcription without a resident model; nil when the executor has none.
    func transcribeOnce(dependency: String, modelPath: String, language: String, wavData: Data, client: VoicePipelineClient) async throws -> String?
    func stop()
    func unload()
}

// MARK: - Descriptors

/// A model download pinned to one revision, trusted only after every SHA-256 matches.
public struct VoicePinnedModel: Sendable {
    public struct File: Sendable {
        public let name: String
        public let size: Int64
        public let sha256: String
    }

    public let repository: String
    public let revision: String
    public let directoryName: String
    public let files: [File]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public var directory: URL {
        VoiceLocalInstaller.modelsDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    public func markerURL(in directory: URL) -> URL {
        directory.appendingPathComponent(".verified-\(revision)")
    }

    public func downloadURLs(for file: File) -> [URL] {
        ["https://huggingface.co", "https://hf-mirror.com"].compactMap {
            URL(string: "\($0)/\(repository)/resolve/\(revision)/\(file.name)")
        }
    }

    /// Cheap runtime check: the marker is only written after every checksum passed.
    public func isInstalled(at directory: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: markerURL(in: directory).path) else { return false }
        return files.allSatisfy { file in
            let path = directory.appendingPathComponent(file.name).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            return size == file.size
        }
    }

    public func writeMarker(in directory: URL) throws {
        try Data(revision.utf8).write(to: markerURL(in: directory), options: .atomic)
    }

    public func matches(_ file: File, at url: URL) async -> Bool {
        await Task.detached(priority: .utility) { () -> Bool in
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
                  size == file.size,
                  let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                if Task.isCancelled { return false }
                let done: Bool = autoreleasepool {
                    guard let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty else { return true }
                    hasher.update(data: chunk)
                    return false
                }
                if done { break }
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
        }.value
    }

    /// Verifies every file in full and records the result.
    public func verifyAndMark(directory: URL) async -> Bool {
        for file in files where !(await matches(file, at: directory.appendingPathComponent(file.name))) {
            return false
        }
        return (try? writeMarker(in: directory)) != nil
    }
}

public struct VoiceASRModelDescriptor: Sendable {
    public let displayName: String
    public let sizeLabel: String
    public let licenseNote: String
    /// File or directory name under VoiceModels; nil for options that download nothing.
    public let modelFilename: String?
    public let downloadURLs: [URL]
    public let pinned: VoicePinnedModel?
    /// Nil for options the session handles itself (Apple Speech, custom HTTP).
    public let executor: VoiceASRExecutorID?
    public let engineLabel: String
    /// Lower is tried first when the selected engine fails; nil means never a fallback.
    public let fallbackRank: Int?
}

private func whisperDescriptor(name: String, size: String, file: String, rank: Int) -> VoiceASRModelDescriptor {
    VoiceASRModelDescriptor(
        displayName: name,
        sizeLabel: size,
        licenseNote: "MIT",
        modelFilename: file,
        downloadURLs: [
            URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")!,
            URL(string: "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/\(file)")!,
        ],
        pinned: nil,
        executor: .whisperServer,
        engineLabel: "whisper.cpp",
        fallbackRank: rank
    )
}

private let qwen3ASRPinned = VoicePinnedModel(
    repository: "Qwen/Qwen3-ASR-0.6B",
    revision: "5eb144179a02acc5e5ba31e748d22b0cf3e303b0",
    directoryName: "Qwen3-ASR-0.6B-5eb1441",
    files: [
        .init(name: "vocab.json", size: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
        .init(name: "merges.txt", size: 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        .init(name: "tokenizer_config.json", size: 12_487, sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
        .init(name: "config.json", size: 6_193, sha256: "76d3ae4601ce939830b2517f4a6cadb86cc51316c3900af6b020b051c21a478c"),
        .init(name: "model.safetensors", size: 1_876_091_704, sha256: "79d6cbd4c98c7bbffe9db2edac07f56cd6637d0d5944b27f6c2b8353840323ea"),
    ]
)

/// How the session reaches a preset.
public enum VoiceLocalASRBackend: Sendable {
    case engine
    case appleSpeech
    case customHTTP
}

extension VoiceLocalASRModelPreset {
    public var descriptor: VoiceASRModelDescriptor {
        switch self {
        case .qwen3ASR:
            return VoiceASRModelDescriptor(
                displayName: "Qwen3-ASR 0.6B（推荐）",
                sizeLabel: "1.9 GB",
                licenseNote: "Apache-2.0",
                modelFilename: qwen3ASRPinned.directoryName,
                downloadURLs: [],
                pinned: qwen3ASRPinned,
                executor: .qwenHelper,
                engineLabel: "Qwen 引擎",
                fallbackRank: nil
            )
        case .whisperTurbo:
            return whisperDescriptor(name: "Whisper v3 Turbo", size: "547 MB", file: "ggml-large-v3-turbo-q5_0.bin", rank: 0)
        case .whisperBase:
            return whisperDescriptor(name: "Whisper Base（轻量极速）", size: "142 MB", file: "ggml-base.bin", rank: 1)
        case .appleSpeech:
            return Self.builtIn("Apple 端侧语音（免下载）")
        case .customHTTP:
            return Self.builtIn("已有本地 HTTP 服务")
        }
    }

    private static func builtIn(_ name: String) -> VoiceASRModelDescriptor {
        VoiceASRModelDescriptor(
            displayName: name, sizeLabel: "0 MB", licenseNote: "", modelFilename: nil, downloadURLs: [],
            pinned: nil, executor: nil, engineLabel: "", fallbackRank: nil
        )
    }

    public var backend: VoiceLocalASRBackend {
        if descriptor.executor != nil { return .engine }
        return self == .appleSpeech ? .appleSpeech : .customHTTP
    }
}

// MARK: - Registry

@MainActor
public enum VoiceASRRegistry {
    private static func executor(_ id: VoiceASRExecutorID) -> VoiceASRExecutor {
        switch id {
        case .whisperServer: return VoiceWhisperExecutor()
        case .qwenHelper: return VoiceQwenExecutor()
        }
    }

    private static let allExecutors: [VoiceASRExecutorID] = [.whisperServer, .qwenHelper]

    public static func dependencyPath(for preset: VoiceLocalASRModelPreset) -> String? {
        preset.descriptor.executor.flatMap { executor($0).dependencyPath() }
    }

    /// The resident engine for the selected model, or nil when it is not ready to run.
    public static func engine(for prefs: VoicePreferences, vocabulary: [String]) -> VoiceASREngine? {
        let preset = prefs.localASRPreset
        guard let id = preset.descriptor.executor else { return nil }
        let status = VoiceLocalInstaller.asrStatus(for: preset)
        guard status.isReady, let modelPath = status.modelPath else { return nil }
        return executor(id).makeEngine(modelPath: modelPath, language: prefs.language, vocabulary: vocabulary)
    }

    /// Transcribes with the selected model if it has a one-shot path, otherwise with an installed
    /// fallback model, so a recording is not lost when the selected engine fails.
    public static func transcribeWithFallback(
        prefs: VoicePreferences,
        client: VoicePipelineClient,
        wavData: Data
    ) async throws -> String {
        let fallbacks = VoiceLocalASRModelPreset.allCases
            .filter { $0.descriptor.fallbackRank != nil && $0 != prefs.localASRPreset }
            .sorted { ($0.descriptor.fallbackRank ?? 0) < ($1.descriptor.fallbackRank ?? 0) }
        for preset in [prefs.localASRPreset] + fallbacks {
            guard let id = preset.descriptor.executor else { continue }
            let status = VoiceLocalInstaller.asrStatus(for: preset)
            guard status.isReady, let dependency = status.dependencyPath, let modelPath = status.modelPath else { continue }
            if let text = try await executor(id).transcribeOnce(
                dependency: dependency,
                modelPath: modelPath,
                language: prefs.language,
                wavData: wavData,
                client: client
            ) {
                return text
            }
        }
        throw VoiceEngineError.cliFailed("所选语音模型不可用，且没有已安装的备用模型，请在「句序偏好设置 → 语音输入」中下载")
    }

    public static func stopAll() {
        allExecutors.forEach { executor($0).stop() }
    }

    public static func unloadAll() {
        allExecutors.forEach { executor($0).unload() }
    }
}

// MARK: - Whisper Executor

@MainActor
struct VoiceWhisperExecutor: VoiceASRExecutor {
    func dependencyPath() -> String? { VoiceLocalInstaller.detectWhisperCLIBinary() }

    func makeEngine(modelPath: String, language: String, vocabulary: [String]) -> VoiceASREngine? {
        guard let server = VoiceWhisperServerManager.detectServerBinary() else { return nil }
        let manager = VoiceWhisperServerManager.shared
        manager.configure(binaryPath: server, modelPath: modelPath, language: language)
        return manager
    }

    func transcribeOnce(dependency: String, modelPath: String, language: String, wavData: Data, client: VoicePipelineClient) async throws -> String? {
        try await client.transcribeLocalCLI(binaryPath: dependency, modelPath: modelPath, language: language, wavData: wavData)
    }

    func stop() { VoiceWhisperServerManager.sharedIfLoaded?.stop() }
    func unload() { VoiceWhisperServerManager.unload() }
}

// MARK: - Qwen Executor

@MainActor
struct VoiceQwenExecutor: VoiceASRExecutor {
    func dependencyPath() -> String? { VoiceQwenHelperManager.helperBinaryPath() }

    func makeEngine(modelPath: String, language: String, vocabulary: [String]) -> VoiceASREngine? {
        let manager = VoiceQwenHelperManager.shared
        manager.configure(modelDirectory: modelPath, context: nil)
        return manager
    }

    /// The helper is the only Qwen path, so a failure here goes to the next installed model.
    func transcribeOnce(dependency: String, modelPath: String, language: String, wavData: Data, client: VoicePipelineClient) async throws -> String? {
        nil
    }

    func stop() { VoiceQwenHelperManager.sharedIfLoaded?.stop() }
    func unload() { VoiceQwenHelperManager.unload() }
}
