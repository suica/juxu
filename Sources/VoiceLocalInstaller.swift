import Foundation

public struct VoiceLocalComponentStatus: Equatable, Sendable {
    public let dependencyInstalled: Bool
    public let dependencyPath: String?
    public let modelInstalled: Bool
    public let modelPath: String?
    public let modelSizeBytes: Int64

    public var isReady: Bool {
        dependencyInstalled && modelInstalled
    }

    public var formattedModelSize: String {
        guard modelSizeBytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: modelSizeBytes, countStyle: .file)
    }
}

public enum VoiceInstallPhase: Equatable, Sendable {
    case idle
    case installingDependency(name: String)
    case downloadingModel(name: String, progress: Double, detail: String)
    case completed(String)
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .installingDependency, .downloadingModel:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }
}

/// Strictly on-demand local dependency & model installer (whisper-cpp + GGML, llama.cpp + GGUF).
/// Never instantiated until the user enables voice input and opens/uses Local mode; released on `unload()`.
@MainActor
public final class VoiceLocalInstaller: ObservableObject {
    private static var _shared: VoiceLocalInstaller?

    public static var isLoaded: Bool { _shared != nil }

    public static var shared: VoiceLocalInstaller {
        if let existing = _shared {
            return existing
        }
        let created = VoiceLocalInstaller()
        _shared = created
        return created
    }

    public static func unload() {
        _shared?.cancel()
        _shared = nil
    }

    nonisolated public static var modelsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Juxu/VoiceModels", isDirectory: true)
    }

    @Published public private(set) var phase: VoiceInstallPhase = .idle
    @Published public private(set) var refreshToken: Int = 0

    private var activeTask: Task<Void, Never>?
    private var activeProcess: Process?
    private var activeDownloadDelegate: ModelDownloadDelegate?

    private init() {}

    // MARK: - Fast Local Status Checks (Zero Network)

    public static func detectBrewBinary() -> String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    public static func detectWhisperCLIBinary() -> String? {
        for path in [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
        ] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    public static func detectLlamaCLIBinary() -> String? {
        for path in [
            "/opt/homebrew/bin/llama-cli",
            "/usr/local/bin/llama-cli",
            "/opt/homebrew/bin/llama-completion",
            "/usr/local/bin/llama-completion",
        ] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    public static func modelURL(for filename: String) -> URL {
        modelsDirectory.appendingPathComponent(filename)
    }

    public static func asrStatus(for preset: VoiceLocalASRModelPreset) -> VoiceLocalComponentStatus {
        if let pinned = preset.descriptor.pinned {
            let dependency = VoiceASRRegistry.dependencyPath(for: preset)
            let installed = pinned.isInstalled(at: pinned.directory)
            return VoiceLocalComponentStatus(
                dependencyInstalled: dependency != nil,
                dependencyPath: dependency,
                modelInstalled: installed,
                modelPath: pinned.directory.path,
                modelSizeBytes: installed ? pinned.totalBytes : 0
            )
        }
        guard let filename = preset.modelFilename else {
            return VoiceLocalComponentStatus(
                dependencyInstalled: true,
                dependencyPath: nil,
                modelInstalled: true,
                modelPath: nil,
                modelSizeBytes: 0
            )
        }
        let bin = detectWhisperCLIBinary()
        let url = modelURL(for: filename)
        let size = fileSizeIfNonEmpty(at: url)
        return VoiceLocalComponentStatus(
            dependencyInstalled: bin != nil,
            dependencyPath: bin,
            modelInstalled: size > 1_000_000,
            modelPath: url.path,
            modelSizeBytes: size
        )
    }

    public static func llmStatus(for preset: VoiceLocalLLMPreset) -> VoiceLocalComponentStatus {
        guard let filename = preset.modelFilename else {
            return VoiceLocalComponentStatus(
                dependencyInstalled: true,
                dependencyPath: nil,
                modelInstalled: true,
                modelPath: nil,
                modelSizeBytes: 0
            )
        }
        let bin = detectLlamaCLIBinary()
        let url = modelURL(for: filename)
        let size = fileSizeIfNonEmpty(at: url)
        return VoiceLocalComponentStatus(
            dependencyInstalled: bin != nil,
            dependencyPath: bin,
            modelInstalled: size > 1_000_000,
            modelPath: url.path,
            modelSizeBytes: size
        )
    }

    private static func fileSizeIfNonEmpty(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    // MARK: - One-Click Installers

    public func installASR(preset: VoiceLocalASRModelPreset) {
        guard !phase.isBusy, let filename = preset.modelFilename else { return }
        if let pinned = preset.descriptor.pinned {
            installPinnedModel(pinned, displayName: preset.displayName)
            return
        }
        let urls = preset.downloadURLs
        let displayName = preset.displayName

        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if Self.detectWhisperCLIBinary() == nil {
                    self.phase = .installingDependency(name: "whisper.cpp（Metal 加速引擎）")
                    try await self.runBrewInstall(formula: "whisper.cpp")
                    guard Self.detectWhisperCLIBinary() != nil else {
                        throw VoiceEngineError.cliFailed("Homebrew 安装完成后未检测到 whisper-cli")
                    }
                }

                let destURL = Self.modelURL(for: filename)
                if Self.fileSizeIfNonEmpty(at: destURL) <= 1_000_000 {
                    try await self.downloadModelWithFallback(
                        urls: urls,
                        destination: destURL,
                        displayName: displayName
                    )
                }

                self.refreshToken += 1
                self.phase = .completed("✓ \(displayName) 与依赖已就绪，现在即可语音输入")
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
            self.activeTask = nil
        }
    }

    /// Downloads a pinned revision file by file and verifies every SHA-256 before use.
    private func installPinnedModel(_ pinned: VoicePinnedModel, displayName: String) {
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let directory = pinned.directory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: pinned.markerURL(in: directory))
                for file in pinned.files {
                    try Task.checkCancellation()
                    let destination = directory.appendingPathComponent(file.name)
                    if await pinned.matches(file, at: destination) { continue }
                    try await self.downloadModelWithFallback(
                        urls: pinned.downloadURLs(for: file),
                        destination: destination,
                        displayName: "\(displayName) · \(file.name)"
                    )
                    self.phase = .downloadingModel(name: displayName, progress: 1, detail: "校验 \(file.name)…")
                    guard await pinned.matches(file, at: destination) else {
                        try? FileManager.default.removeItem(at: destination)
                        throw VoiceEngineError.cliFailed("\(file.name) 校验失败，已删除，请重试")
                    }
                }
                try pinned.writeMarker(in: directory)
                self.refreshToken += 1
                self.phase = .completed("✓ \(displayName) 已就绪，现在即可语音输入")
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
            self.activeTask = nil
        }
    }

    public func installLLM(preset: VoiceLocalLLMPreset) {
        guard !phase.isBusy, let filename = preset.modelFilename else { return }
        let urls = preset.downloadURLs
        let displayName = preset.displayName

        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if Self.detectLlamaCLIBinary() == nil {
                    self.phase = .installingDependency(name: "llama.cpp（Metal 本地推理）")
                    try await self.runBrewInstall(formula: "llama.cpp")
                    guard Self.detectLlamaCLIBinary() != nil else {
                        throw VoiceEngineError.cliFailed("Homebrew 安装完成后未检测到 llama-cli")
                    }
                }

                let destURL = Self.modelURL(for: filename)
                if Self.fileSizeIfNonEmpty(at: destURL) <= 1_000_000 {
                    try await self.downloadModelWithFallback(
                        urls: urls,
                        destination: destURL,
                        displayName: displayName
                    )
                }

                self.refreshToken += 1
                self.phase = .completed("✓ \(displayName) 与依赖已就绪")
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
            self.activeTask = nil
        }
    }

    public func deleteModel(filename: String) {
        let url = Self.modelURL(for: filename)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("part"))
        refreshToken += 1
        phase = .idle
    }

    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
        if let proc = activeProcess, proc.isRunning {
            proc.terminate()
        }
        activeProcess = nil
        activeDownloadDelegate?.cancel()
        activeDownloadDelegate = nil
        if phase.isBusy {
            phase = .idle
        }
    }

    // MARK: - Private Helpers

    private func runBrewInstall(formula: String) async throws {
        guard let brewPath = Self.detectBrewBinary() else {
            throw VoiceEngineError.cliFailed("未检测到 Homebrew，请先安装 Homebrew 后重试（https://brew.sh）")
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: brewPath)
            proc.arguments = ["install", formula]
            var env = ProcessInfo.processInfo.environment
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
            proc.environment = env

            let errPipe = Pipe()
            proc.standardOutput = Pipe()
            proc.standardError = errPipe

            self.activeProcess = proc

            proc.terminationHandler = { [weak self] finishedProc in
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                Task { @MainActor [weak self] in
                    self?.activeProcess = nil
                    if Task.isCancelled || finishedProc.terminationReason == .uncaughtSignal {
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    if finishedProc.terminationStatus == 0 {
                        cont.resume(returning: ())
                    } else {
                        let msg = String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "退出码 \(finishedProc.terminationStatus)"
                        cont.resume(throwing: VoiceEngineError.cliFailed("brew install \(formula) 失败：\(String(msg.suffix(180)))"))
                    }
                }
            }

            do {
                try proc.run()
            } catch {
                self.activeProcess = nil
                cont.resume(throwing: VoiceEngineError.cliFailed(error.localizedDescription))
            }
        }
    }

    private func downloadModelWithFallback(
        urls: [URL],
        destination: URL,
        displayName: String
    ) async throws {
        try FileManager.default.createDirectory(
            at: Self.modelsDirectory,
            withIntermediateDirectories: true
        )

        var lastError: Error = VoiceEngineError.networkError("无可用下载地址")
        for (idx, url) in urls.enumerated() {
            try Task.checkCancellation()
            let sourceTag = idx == 0 ? "HuggingFace" : "镜像源"
            self.phase = .downloadingModel(
                name: displayName,
                progress: 0,
                detail: "连接 \(sourceTag)…"
            )
            do {
                try await downloadFile(
                    from: url,
                    to: destination,
                    displayName: displayName,
                    sourceTag: sourceTag
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func downloadFile(
        from url: URL,
        to destination: URL,
        displayName: String,
        sourceTag: String
    ) async throws {
        let partURL = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partURL)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let delegate = ModelDownloadDelegate(
                destination: destination,
                partURL: partURL,
                onProgress: { [weak self] fraction, written, expected in
                    Task { @MainActor [weak self] in
                        let writtenStr = ByteCountFormatter.string(fromByteCount: written, countStyle: .file)
                        let detail: String
                        if expected > 0 {
                            let totalStr = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
                            detail = "\(sourceTag) · \(writtenStr) / \(totalStr)"
                        } else {
                            detail = "\(sourceTag) · 已下载 \(writtenStr)"
                        }
                        self?.phase = .downloadingModel(
                            name: displayName,
                            progress: fraction,
                            detail: detail
                        )
                    }
                },
                onComplete: { [weak self] result in
                    Task { @MainActor [weak self] in
                        self?.activeDownloadDelegate = nil
                        switch result {
                        case .success:
                            cont.resume(returning: ())
                        case .failure(let err):
                            cont.resume(throwing: err)
                        }
                    }
                }
            )
            self.activeDownloadDelegate = delegate
            delegate.start(url: url)
        }
    }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let partURL: URL
    private let onProgress: @Sendable (Double, Int64, Int64) -> Void
    private let onComplete: @Sendable (Result<Void, Error>) -> Void
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var finished = false
    private let lock = NSLock()

    init(
        destination: URL,
        partURL: URL,
        onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void,
        onComplete: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        self.destination = destination
        self.partURL = partURL
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func start(url: URL) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 6 * 3600
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        self.session = s
        let t = s.downloadTask(with: url)
        self.task = t
        t.resume()
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        finish(.failure(CancellationError()))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction = totalBytesExpectedToWrite > 0
            ? min(1.0, max(0.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
            : 0.0
        onProgress(fraction, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(VoiceEngineError.networkError("下载失败（HTTP \(http.statusCode)）")))
            return
        }
        do {
            try? FileManager.default.removeItem(at: partURL)
            try FileManager.default.moveItem(at: location, to: partURL)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partURL, to: destination)
            finish(.success(()))
        } catch {
            try? FileManager.default.removeItem(at: partURL)
            finish(.failure(VoiceEngineError.networkError("保存模型文件失败：\(error.localizedDescription)")))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(VoiceEngineError.networkError(error.localizedDescription)))
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
        onComplete(result)
    }
}
