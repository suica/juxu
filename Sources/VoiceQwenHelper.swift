import Foundation

/// Owns the on-demand Qwen3-ASR helper. Never allocated until a Qwen recording starts.
///
/// The helper is a child process that talks over stdin/stdout and opens no port. It exits as soon
/// as its stdin closes, so it cannot outlive Juxu, even if Juxu is killed with SIGKILL.
@MainActor
public final class VoiceQwenHelperManager: VoiceASREngine {
    private static var _shared: VoiceQwenHelperManager?

    public static var isLoaded: Bool { _shared != nil }
    public static var sharedIfLoaded: VoiceQwenHelperManager? { _shared }

    public static var shared: VoiceQwenHelperManager {
        if let existing = _shared {
            return existing
        }
        let created = VoiceQwenHelperManager()
        _shared = created
        return created
    }

    public static func unload() {
        _shared?.stop()
        _shared = nil
    }

    nonisolated public static func helperBinaryPath() -> String? {
        if let override = ProcessInfo.processInfo.environment["JUXU_QWEN_HELPER"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        guard let directory = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = directory.appendingPathComponent("juxu-qwen-asr").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Qwen's prompt names the language in English.
    static func modelLanguage(_ code: String) -> String? {
        switch code.lowercased().split(separator: "-").first.map(String.init) ?? "" {
        case "zh": return "Chinese"
        case "en": return "English"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "yue": return "Cantonese"
        default: return nil
        }
    }

    private final class Connection {
        let process: Process
        let stdin: FileHandle
        let writer = DispatchQueue(label: "juxu.qwen.helper.writer")
        var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
        var ready: CheckedContinuation<Void, Error>?
        var isReady = false

        init(process: Process, stdin: FileHandle) {
            self.process = process
            self.stdin = stdin
        }
    }

    public var idleTimeout: TimeInterval = VoiceWhisperStreamPolicy.idleTimeout

    private var modelDirectory = ""
    private var context: String?
    private var connection: Connection?
    private var startTask: Task<Void, Error>?
    private var idleItem: DispatchWorkItem?
    private var activeSessions = 0
    private var nextID = 1

    public var isHelperRunning: Bool { connection?.process.isRunning == true && connection?.isReady == true }
    public var helperPID: Int32? { connection?.process.processIdentifier }
    /// Highest physical footprint the helper has reported, in MB.
    public private(set) var peakFootprintMB = 0

    private init() {}

    public func configure(modelDirectory: String, context: String?) {
        if connection != nil, self.modelDirectory != modelDirectory {
            stop()
        }
        self.modelDirectory = modelDirectory
        self.context = context?.isEmpty == true ? nil : context
    }

    /// Takes effect from the next pass: a partial already in flight keeps the context it was sent with.
    public func updateContext(_ context: VoiceContext) {
        self.context = VoiceASRContextBuilder.recognitionContext(context, target: .qwen, language: "")
    }

    /// The context string the next request carries.
    var currentContext: String? { context }

    /// The JSON line that precedes a job's PCM samples on the helper's stdin.
    static func requestHeader(id: Int, isFinal: Bool, sampleCount: Int, language: String, context: String?) -> [String: Any] {
        var request: [String: Any] = ["id": id, "kind": isFinal ? "final" : "partial", "samples": sampleCount]
        if let name = modelLanguage(language) { request["language"] = name }
        if let context, !context.isEmpty { request["context"] = context }
        return request
    }

    public func beginSession() {
        activeSessions += 1
        idleItem?.cancel()
        idleItem = nil
    }

    public func endSession() {
        activeSessions = max(0, activeSessions - 1)
        scheduleIdleStopIfNeeded()
    }

    public func prepare() async throws {
        try await ensureReady()
    }

    public func release() { stop() }

    public func stop() {
        idleItem?.cancel()
        idleItem = nil
        startTask?.cancel()
        startTask = nil
        guard let current = connection else { return }
        connection = nil
        close(current, error: VoiceEngineError.cliFailed("Qwen 引擎已停止"))
    }

    public func transcribe(wavData: Data, language: String, timeout: TimeInterval, isFinal: Bool) async throws -> String {
        let sentContext = context
        let text = try await run(wavData: wavData, language: language, timeout: timeout, isFinal: isFinal, context: sentContext)
        guard VoiceASRContextBuilder.isPromptEcho(text, prompt: sentContext) else { return text }
        // The model read the context back instead of the speech: a partial is dropped, a final is redone without it.
        guard isFinal else { return "" }
        return try await run(wavData: wavData, language: language, timeout: timeout, isFinal: true, context: nil)
    }

    private func run(wavData: Data, language: String, timeout: TimeInterval, isFinal: Bool, context: String?) async throws -> String {
        try await ensureReady()
        try Task.checkCancellation()
        guard let current = connection else { throw VoiceEngineError.cliFailed("Qwen 引擎未运行") }

        let pcm = wavData.dropFirst(44)
        let id = nextID
        nextID += 1
        let request = Self.requestHeader(id: id, isFinal: isFinal, sampleCount: pcm.count / 2, language: language, context: context)
        var payload = try JSONSerialization.data(withJSONObject: request)
        payload.append(0x0A)
        payload.append(pcm)

        let reply: [String: Any] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                current.pending[id] = continuation
                let timer = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let waiting = current.pending.removeValue(forKey: id) else { return }
                        waiting.resume(throwing: VoiceEngineError.cliFailed("Qwen 引擎响应超时"))
                        if isFinal, self?.connection === current { self?.stop() } else { self?.send(cancel: id, on: current) }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timer)
                current.writer.async { [weak self] in
                    do {
                        try current.stdin.write(contentsOf: payload)
                    } catch {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { self?.handleExit(of: current) }
                        }
                    }
                }
            }
        } onCancel: {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let waiting = current.pending.removeValue(forKey: id) else { return }
                    waiting.resume(throwing: CancellationError())
                    self?.send(cancel: id, on: current)
                }
            }
        }

        peakFootprintMB = max(peakFootprintMB, reply["peak_mb"] as? Int ?? 0)
        try Task.checkCancellation()
        if reply["cancelled"] as? Bool == true { throw CancellationError() }
        if let message = reply["error"] as? String { throw VoiceEngineError.cliFailed("Qwen 引擎错误：\(message)") }
        guard let text = reply["text"] as? String else { throw VoiceEngineError.cliFailed("Qwen 引擎返回异常") }
        // A final that hit the token limit is incomplete; the caller falls back rather than commit it.
        if isFinal, reply["truncated"] as? Bool == true {
            throw VoiceEngineError.cliFailed("Qwen 结果不完整")
        }
        return VoiceWhisperStreamPolicy.cleanedTranscript(
            text,
            language: language,
            voicedSeconds: VoiceSpeechGate.voicedSeconds(VoiceWhisperStreamPolicy.pcmSamples(fromWAV: wavData))
        )
    }

    // MARK: Private

    private func send(cancel id: Int, on current: Connection) {
        guard var line = try? JSONSerialization.data(withJSONObject: ["id": id, "kind": "cancel"]) else { return }
        line.append(0x0A)
        current.writer.async { try? current.stdin.write(contentsOf: line) }
    }

    private func scheduleIdleStopIfNeeded() {
        idleItem?.cancel()
        idleItem = nil
        guard activeSessions == 0, connection != nil || startTask != nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.activeSessions == 0 else { return }
                // Never pull the model out from under a transcription that is still running.
                if self.connection?.pending.isEmpty == false {
                    self.scheduleIdleStopIfNeeded()
                    return
                }
                self.stop()
            }
        }
        idleItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: item)
    }

    private func ensureReady() async throws {
        if let connection, connection.isReady, connection.process.isRunning { return }
        if let startTask {
            try await startTask.value
            return
        }
        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.launch()
        }
        startTask = task
        defer { if startTask == task { startTask = nil } }
        try await task.value
    }

    private func launch() async throws {
        guard let binary = Self.helperBinaryPath() else {
            throw VoiceEngineError.cliNotFound("juxu-qwen-asr")
        }
        guard (VoiceLocalASRModelPreset.qwen3ASR.descriptor.pinned?.isInstalled(at: URL(fileURLWithPath: modelDirectory, isDirectory: true)) ?? false) else {
            throw VoiceEngineError.cliFailed("Qwen 模型未安装或不完整")
        }
        // A write to a helper that just died must fail with an error rather than kill Juxu.
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [modelDirectory]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let current = Connection(process: process, stdin: input.fileHandleForWriting)
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleExit(of: current) }
            }
        }
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        connection = current
        startReader(output.fileHandleForReading, for: current)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if current.isReady {
                    continuation.resume()
                    return
                }
                current.ready = continuation
                let timer = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let waiting = current.ready else { return }
                        current.ready = nil
                        waiting.resume(throwing: VoiceEngineError.cliFailed("Qwen 引擎启动超时"))
                        if self?.connection === current { self?.stop() }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timer)
            }
        } onCancel: {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    if self?.connection === current { self?.stop() }
                }
            }
        }
        scheduleIdleStopIfNeeded()
    }

    private func startReader(_ handle: FileHandle, for current: Connection) {
        let thread = Thread { [weak self] in
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                    let box = ReplyBox(object)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.handle(box.value, from: current) }
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleExit(of: current) }
            }
        }
        thread.name = "juxu.qwen.helper.reader"
        thread.start()
    }

    private func handle(_ reply: [String: Any], from current: Connection) {
        if let event = reply["event"] as? String {
            if event == "ready" {
                current.isReady = true
                let waiting = current.ready
                current.ready = nil
                waiting?.resume()
            } else if event == "error", !current.isReady {
                let waiting = current.ready
                current.ready = nil
                waiting?.resume(throwing: VoiceEngineError.cliFailed("Qwen 引擎加载失败"))
            }
            return
        }
        guard let id = reply["id"] as? Int, let waiting = current.pending.removeValue(forKey: id) else { return }
        waiting.resume(returning: reply)
    }

    private func handleExit(of current: Connection) {
        if connection === current { connection = nil }
        close(current, error: VoiceEngineError.cliFailed("Qwen 引擎已退出"))
    }

    private func close(_ current: Connection, error: Error) {
        let waiting = Array(current.pending.values)
        current.pending.removeAll()
        let ready = current.ready
        current.ready = nil
        waiting.forEach { $0.resume(throwing: error) }
        ready?.resume(throwing: error)
        // Closing stdin is what makes the helper exit; terminate covers a helper stuck in Metal.
        current.writer.async { try? current.stdin.close() }
        if current.process.isRunning {
            current.process.terminate()
        }
    }
}

private final class ReplyBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}
