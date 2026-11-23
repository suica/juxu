import Accelerate
import Darwin
import Foundation

// MARK: - Streaming Policy (pure, testable)

public enum VoiceWhisperStreamPolicy {
    public static let sampleRate = 16_000
    /// Target time between the starts of two partial passes.
    public static let partialInterval: TimeInterval = 1.0
    /// Partials only look at this much recent audio, so their cost stays bounded.
    public static let partialWindowSeconds = 12
    public static var partialWindowSamples: Int { partialWindowSeconds * sampleRate }
    /// Voiced audio needed before a partial pass; shorter snippets transcribe unreliably.
    public static let minPartialVoicedSeconds = 0.5
    public static let partialRequestTimeout: TimeInterval = 8
    public static let idleTimeout: TimeInterval = 300
    public static func finalRequestTimeout(sampleCount: Int) -> TimeInterval {
        20 + Double(sampleCount) / Double(sampleRate) * 0.5
    }

    /// Valid Simplified characters that ICU's Hant-Hans would rewrite (俱乐部→具乐部, 摔跤→摔交, 乾隆→干隆).
    /// Found by running the transform over all 6763 GB2312 hanzi. 後/於/麽/徵/夥/菸 are left out
    /// because Whisper emits them in Traditional output and they should convert.
    private static let simplifiedKeep: Set<Character> = Set("藉俱乾著阪苎吒姊箝麴跤摺瞭")

    /// Whisper sometimes answers `zh` in Traditional Chinese. Latin, digits and punctuation are unchanged.
    public static func simplified(_ text: String, language: String) -> String {
        guard language.lowercased().hasPrefix("zh"), !text.allSatisfy(\.isASCII) else { return text }
        let transform = StringTransform("Hant-Hans")
        var out = ""
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            out += run.applyingTransform(transform, reverse: false) ?? run
            run = ""
        }
        for ch in text {
            if simplifiedKeep.contains(ch) {
                flush()
                out.append(ch)
            } else {
                run.append(ch)
            }
        }
        flush()
        return out
    }

    /// Simplified output with hallucinated credit lines removed and segment breaks joined.
    public static func cleanedTranscript(_ text: String, language: String, voicedSeconds: Double) -> String {
        // Simplify first so a Traditional credit line is still recognised by the filter.
        let simple = simplified(text, language: language)
        return normalizedTranscript(VoiceHallucinationFilter.filtered(simple, voicedSeconds: voicedSeconds))
    }

    /// Reads back the canonical 44-byte-header PCM written by `VoiceWAVEncoder`.
    static func pcmSamples(fromWAV wav: Data) -> [Int16] {
        guard wav.count > 44 else { return [] }
        return wav.dropFirst(44).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self))
        }
    }

    /// Whisper separates segments with newlines; dictation should not insert line breaks.
    public static func normalizedTranscript(_ raw: String) -> String {
        let lines = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var out = ""
        for line in lines {
            if let last = out.last, let first = line.first,
               last.isASCII, first.isASCII, last.isLetter || last.isNumber || last.isPunctuation,
               first.isLetter || first.isNumber {
                out.append(" ")
            }
            out.append(line)
        }
        return out
    }
}

// MARK: - Speech Gate

/// Decides from the audio alone whether anyone spoke. Whisper and Qwen cannot be asked: both
/// transcribe silence confidently, and Whisper's `no_speech_prob` stays near 1e-10 even then.
///
/// A frame counts as voiced when it is periodic in the human pitch range, which does not depend on
/// microphone level, and stands above the clip's own noise floor. Thresholds were chosen on half of
/// a real-speech corpus (near-field, spontaneous and far-field meetings) and checked on the other.
public enum VoiceSpeechGate {
    static let hopSamples = 320 // 20 ms
    static let windowSamples = 640 // 40 ms
    static let minLag = 40 // 400 Hz
    static let maxLag = 228 // 70 Hz
    static let voicingThreshold: Float = 0.40
    static let minLevel: Float = 60
    static let noiseFloorRatio: Float = 2.0
    static let maxGapFrames = 10
    static let minRunDensity = 0.5
    /// A long voiced run is speech at any level, so quiet far-field talkers are kept.
    static let longRunFrames = 20
    /// A short run, such as one spoken word, must also be clearly louder than background murmur.
    static let shortRunFrames = 10
    static let shortRunLevel: Float = 120

    private static let hann: [Float] = (0..<windowSamples).map {
        Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(windowSamples - 1)))
    }

    /// The window's own autocorrelation, so peaks at different lags are comparable.
    private static let hannAutocorrelation: [Float] = {
        var values = [Float](repeating: 0, count: maxLag + 1)
        hann.withUnsafeBufferPointer { h in
            for lag in 0...maxLag {
                var sum: Float = 0
                vDSP_dotpr(h.baseAddress!, 1, h.baseAddress! + lag, 1, &sum, vDSP_Length(windowSamples - lag))
                values[lag] = sum
            }
        }
        let first = values[0]
        return values.map { max($0 / first, 1e-6) }
    }()

    private static func frameFeatures(_ samples: [Int16]) -> (levels: [Float], voicing: [Float]) {
        guard samples.count >= windowSamples else { return ([], []) }
        let count = (samples.count - windowSamples) / hopSamples + 1
        var levels = [Float](repeating: 0, count: count)
        var voicing = [Float](repeating: 0, count: count)
        var raw = [Float](repeating: 0, count: windowSamples)
        var x = [Float](repeating: 0, count: windowSamples)
        let n = vDSP_Length(windowSamples)
        for frame in 0..<count {
            let start = frame * hopSamples
            for i in 0..<windowSamples { raw[i] = Float(samples[start + i]) }
            var power: Float = 0
            vDSP_svesq(raw, 1, &power, n)
            levels[frame] = (power / Float(windowSamples)).squareRoot()
            var mean: Float = 0
            vDSP_meanv(raw, 1, &mean, n)
            for i in 0..<windowSamples { x[i] = (raw[i] - mean) * hann[i] }
            var energy: Float = 0
            vDSP_svesq(x, 1, &energy, n)
            guard energy > 0 else { continue }
            var best: Float = 0
            x.withUnsafeBufferPointer { p in
                for lag in minLag...maxLag {
                    var r: Float = 0
                    vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &r, vDSP_Length(windowSamples - lag))
                    best = max(best, (r / energy) / hannAutocorrelation[lag])
                }
            }
            voicing[frame] = min(best, 1.2)
        }
        return (levels, voicing)
    }

    /// Per-frame flags, true only inside runs that look like speech.
    public static func voicedFrames(_ samples: [Int16]) -> [Bool] {
        let (levels, voicing) = frameFeatures(samples)
        guard !levels.isEmpty else { return [] }
        var flags = [Bool](repeating: false, count: levels.count)
        let sorted = levels.sorted()
        let position = Float(sorted.count - 1) * 0.1
        let lower = Int(position)
        let upper = min(lower + 1, sorted.count - 1)
        let floor = sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Float(lower))
        let threshold = max(minLevel, floor * noiseFloorRatio)
        let voiced = levels.indices.filter { voicing[$0] >= voicingThreshold && levels[$0] >= threshold }
        guard voiced.count >= shortRunFrames else { return flags }

        var runStart = 0
        for i in 0..<voiced.count {
            let endsRun = i == voiced.count - 1 || voiced[i + 1] - voiced[i] > maxGapFrames + 1
            guard endsRun else { continue }
            let run = voiced[runStart...i]
            let span = voiced[i] - voiced[runStart] + 1
            if Double(run.count) / Double(span) >= minRunDensity {
                var isSpeech = run.count >= longRunFrames
                if !isSpeech, run.count >= shortRunFrames {
                    let runLevels = run.map { levels[$0] }.sorted()
                    let middle = runLevels.count / 2
                    let median = runLevels.count % 2 == 0
                        ? (runLevels[middle - 1] + runLevels[middle]) / 2
                        : runLevels[middle]
                    isSpeech = median >= shortRunLevel
                }
                if isSpeech { run.forEach { flags[$0] = true } }
            }
            runStart = i + 1
        }
        return flags
    }

    static func speechSlice(_ samples: [Int16], leadSeconds: Double, tailSeconds: Double) -> (audio: [Int16], voicedSeconds: Double)? {
        let flags = voicedFrames(samples)
        guard let first = flags.firstIndex(of: true), let last = flags.lastIndex(of: true) else { return nil }
        let rate = Double(VoiceWhisperStreamPolicy.sampleRate)
        let start = max(0, first * hopSamples - Int(leadSeconds * rate))
        let end = min(samples.count, last * hopSamples + windowSamples + Int(tailSeconds * rate))
        let voiced = Double(flags.lazy.filter { $0 }.count) * Double(hopSamples) / rate
        return (Array(samples[start..<end]), voiced)
    }

    /// Audio for a partial pass, or nil until there is enough speech to be worth transcribing.
    public static func partialAudio(_ window: [Int16]) -> [Int16]? {
        guard let slice = speechSlice(window, leadSeconds: 0.2, tailSeconds: 0.3),
              slice.voicedSeconds >= VoiceWhisperStreamPolicy.minPartialVoicedSeconds else { return nil }
        return slice.audio
    }

    /// The whole recording, or nil when nobody spoke. It is never trimmed: quiet far-field words
    /// can sit outside the voiced frames, and cutting them made finals lose real speech.
    public static func finalAudio(_ samples: [Int16]) -> (audio: [Int16], voicedSeconds: Double)? {
        let voiced = voicedSeconds(samples)
        return voiced > 0 ? (samples, voiced) : nil
    }

    static func voicedSeconds(_ samples: [Int16]) -> Double {
        let voiced = voicedFrames(samples).lazy.filter { $0 }.count
        return Double(voiced) * Double(hopSamples) / Double(VoiceWhisperStreamPolicy.sampleRate)
    }
}

// MARK: - Subtitle-Credit Hallucination Filter

/// Whisper learned video credits from its training data. A line is dropped only when all of it is
/// such a credit AND the audio holds too little speech to have said it, so a person who really
/// says "请大家点赞转发" keeps their words.
public enum VoiceHallucinationFilter {
    static let maxCharsPerVoicedSecond = 9.0
    static let secondsPerOrdinaryChar = 0.18
    private static let creditWords = ["点赞", "订阅", "转发", "打赏", "收藏", "一键三连", "明镜"]
    private static let wholeLinePatterns: [NSRegularExpression] = [
        #"^(请|请大家|大家|记得|欢迎|不吝|不要忘记|点赞|订阅|转发|打赏|收藏|关注|支持|一键三连|明镜|点点|栏目|频道|我们|我的|的|与|和|并|以及|谢谢|感谢|[\s、,，.。!！])+$"#,
        #"^(中文)?字幕(组|志愿者|制作|提供|校对|翻译|由|by|BY|:|：|\s).{0,24}$"#,
        #"^(感谢|谢谢)(大家|您|你|各位)?的?(观看|收看|收听)[\s。.!！]*$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func isCreditLine(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..., in: text)
        for (index, regex) in wholeLinePatterns.enumerated()
        where regex.firstMatch(in: text, range: range) != nil {
            // The first pattern is a broad word list, so it also needs two distinct credit words.
            return index != 0 || creditWords.filter { text.contains($0) }.count >= 2
        }
        return false
    }

    public static func shouldDrop(_ line: String, voicedSeconds: Double) -> Bool {
        guard isCreditLine(line) else { return false }
        return Double(spokenCharacterCount(line)) > voicedSeconds * maxCharsPerVoicedSecond
    }

    /// Filters line by line. Speech time is first attributed to the ordinary lines, so a credit
    /// line appended to real dictation cannot borrow their audio as its evidence.
    public static func filtered(_ text: String, voicedSeconds: Double) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let ordinaryChars = lines.filter { !isCreditLine($0) }
            .reduce(0) { $0 + spokenCharacterCount($1) }
        let budget = max(0, voicedSeconds - Double(ordinaryChars) * secondsPerOrdinaryChar)
        return lines.filter { !shouldDrop($0, voicedSeconds: budget) }.joined(separator: "\n")
    }

    private static func spokenCharacterCount(_ line: String) -> Int {
        line.filter { !$0.isWhitespace && !$0.isPunctuation }.count
    }
}

// MARK: - Resident whisper-server Manager

/// Owns the on-demand `whisper-server` child. Never allocated until a local Whisper recording starts.
///
/// The server runs under a small `/bin/sh` supervisor that holds the read end of a pipe whose
/// write end only Juxu has. When Juxu exits for any reason, including SIGKILL, the pipe reaches
/// EOF and the supervisor terminates the server, so it cannot be orphaned.
@MainActor
public final class VoiceWhisperServerManager: VoiceASREngine {
    private static var _shared: VoiceWhisperServerManager?

    public static var isLoaded: Bool { _shared != nil }
    public static var sharedIfLoaded: VoiceWhisperServerManager? { _shared }

    public static var shared: VoiceWhisperServerManager {
        if let existing = _shared {
            return existing
        }
        let created = VoiceWhisperServerManager()
        _shared = created
        return created
    }

    public static func unload() {
        _shared?.stop()
        _shared?.urlSession.invalidateAndCancel()
        _shared = nil
    }

    public static func detectServerBinary() -> String? {
        for path in ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static let supervisorScript = """
    exec 3<&0
    "$@" </dev/null 3<&- >/dev/null 2>&1 &
    c=$!
    stop() {
      [ -n "${stopping:-}" ] && return
      stopping=1
      kill -TERM "$c" 2>/dev/null
      ( sleep 2; kill -KILL "$c" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
      k=$!
      wait "$c" 2>/dev/null
      kill "$k" 2>/dev/null
      exit 0
    }
    trap stop TERM INT HUP
    ( cat <&3 >/dev/null 2>&1; kill -TERM $$ 2>/dev/null ) &
    w=$!
    exec 3<&-
    wait "$c"
    r=$?
    kill "$w" 2>/dev/null
    exit $r
    """

    public var idleTimeout: TimeInterval = VoiceWhisperStreamPolicy.idleTimeout

    private let urlSession: URLSession
    private var binaryPath = ""
    private var modelPath = ""
    private var launchLanguage = "auto"
    private var process: Process?
    private var stdinPipe: Pipe?
    private var port: Int?
    private var startTask: Task<Int, Error>?
    private var idleItem: DispatchWorkItem?
    private var activeSessions = 0

    public var isServerRunning: Bool { process?.isRunning == true && port != nil }
    public var supervisorPID: Int32? { process?.processIdentifier }
    public var serverPort: Int? { port }

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: cfg)
    }

    public func configure(binaryPath: String, modelPath: String, language: String) {
        if process != nil, self.modelPath != modelPath || self.binaryPath != binaryPath {
            stop()
        }
        self.binaryPath = binaryPath
        self.modelPath = modelPath
        self.launchLanguage = language.isEmpty ? "auto" : language
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
        _ = try await ensureRunning()
    }

    public func release() { stop() }

    public func stop() {
        idleItem?.cancel()
        idleItem = nil
        startTask?.cancel()
        startTask = nil
        terminateChild()
    }

    public func transcribe(wavData: Data, language: String, timeout: TimeInterval, isFinal: Bool) async throws -> String {
        let port = try await ensureRunning()
        try Task.checkCancellation()
        guard let url = URL(string: "http://127.0.0.1:\(port)/inference") else {
            throw VoiceEngineError.invalidEndpoint("127.0.0.1:\(port)")
        }

        let boundary = "JuxuVoice-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = VoiceMultipartBuilder.buildAudioTranscriptionBody(
            boundary: boundary,
            wavData: wavData,
            model: "whisper",
            language: language,
            prompt: nil
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw VoiceEngineError.cliFailed("本地常驻识别返回异常")
        }
        // Plain `json` on purpose: `verbose_json` measured 0.78 s against 0.42 s per pass on this model.
        return VoiceWhisperStreamPolicy.cleanedTranscript(
            text,
            language: language,
            voicedSeconds: VoiceSpeechGate.voicedSeconds(VoiceWhisperStreamPolicy.pcmSamples(fromWAV: wavData))
        )
    }

    // MARK: Private

    private func scheduleIdleStopIfNeeded() {
        idleItem?.cancel()
        idleItem = nil
        guard activeSessions == 0, process != nil || startTask != nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.activeSessions == 0 else { return }
                self.stop()
            }
        }
        idleItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: item)
    }

    private func ensureRunning() async throws -> Int {
        if let port, process?.isRunning == true {
            return port
        }
        if let startTask {
            return try await startTask.value
        }
        let task = Task<Int, Error> { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.launchWithRetries()
        }
        startTask = task
        do {
            let value = try await task.value
            if startTask == task { startTask = nil }
            return value
        } catch {
            if startTask == task { startTask = nil }
            throw error
        }
    }

    private func launchWithRetries() async throws -> Int {
        var lastError: Error = VoiceEngineError.cliFailed("本地常驻识别启动失败")
        for _ in 0..<2 {
            try Task.checkCancellation()
            do {
                return try await launchOnce()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func launchOnce() async throws -> Int {
        guard FileManager.default.isExecutableFile(atPath: binaryPath),
              FileManager.default.fileExists(atPath: modelPath) else {
            throw VoiceEngineError.cliNotFound(binaryPath.isEmpty ? "whisper-server" : binaryPath)
        }
        let chosenPort = try Self.pickLoopbackPort()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [
            "-c", Self.supervisorScript, "juxu-whisper-supervisor",
            binaryPath,
            "-m", modelPath,
            "-l", launchLanguage,
            "--host", "127.0.0.1",
            "--port", String(chosenPort),
            "-t", String(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))),
        ]
        proc.currentDirectoryURL = FileManager.default.temporaryDirectory
        let pipe = Pipe()
        proc.standardInput = pipe
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] ended in
            let id = ObjectIdentifier(ended)
            Task { @MainActor [weak self] in
                self?.handleExit(id)
            }
        }
        try proc.run()
        try? pipe.fileHandleForReading.close()
        process = proc
        stdinPipe = pipe

        do {
            try await waitUntilHealthy(proc, port: chosenPort)
        } catch {
            // Only tear down our own child: a newer launch may already own `process`.
            if process === proc {
                terminateChild()
            } else if proc.isRunning {
                proc.terminate()
            }
            throw error
        }
        port = chosenPort
        scheduleIdleStopIfNeeded()
        return chosenPort
    }

    private func waitUntilHealthy(_ proc: Process, port chosenPort: Int) async throws {
        guard let healthURL = URL(string: "http://127.0.0.1:\(chosenPort)/health") else {
            throw VoiceEngineError.invalidEndpoint("127.0.0.1:\(chosenPort)")
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try Task.checkCancellation()
            guard proc.isRunning else {
                throw VoiceEngineError.cliFailed("whisper-server 启动后退出")
            }
            var req = URLRequest(url: healthURL)
            req.timeoutInterval = 1
            if let (_, resp) = try? await urlSession.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200, proc.isRunning {
                try Task.checkCancellation()
                guard process === proc else { throw CancellationError() }
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw VoiceEngineError.cliFailed("whisper-server 启动超时")
    }

    private func handleExit(_ id: ObjectIdentifier) {
        guard let process, ObjectIdentifier(process) == id else { return }
        try? stdinPipe?.fileHandleForWriting.close()
        self.process = nil
        stdinPipe = nil
        port = nil
    }

    private func terminateChild() {
        let proc = process
        let pipe = stdinPipe
        process = nil
        stdinPipe = nil
        port = nil
        try? pipe?.fileHandleForWriting.close()
        if let proc, proc.isRunning {
            proc.terminate()
        }
    }

    private static func pickLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VoiceEngineError.cliFailed("无法分配本地端口") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr -> Bool in
                bind(fd, ptr, len) == 0 && getsockname(fd, ptr, &len) == 0
            }
        }
        guard bound else { throw VoiceEngineError.cliFailed("无法分配本地端口") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

// MARK: - Streaming Session

/// One held-key dictation. Partials are display-only; `finish` is the only source of committed text.
@MainActor
public final class VoiceWhisperStreamSession {
    public typealias SampleProvider = @Sendable (_ maxCount: Int) -> (samples: [Int16], total: Int)

    private enum State {
        case idle
        case streaming
        case finishing
        case ended
    }

    private let transcriber: VoiceASREngine
    private let language: String
    private let sampleProvider: SampleProvider
    private let onPartial: @MainActor (VoicePartialDisplay) -> Void
    private var stabilizer = VoicePartialStabilizer()
    private var state: State = .idle
    private var loopTask: Task<Void, Never>?

    public init(
        transcriber: VoiceASREngine,
        language: String,
        sampleProvider: @escaping SampleProvider,
        onPartial: @escaping @MainActor (VoicePartialDisplay) -> Void
    ) {
        self.transcriber = transcriber
        self.language = language
        self.sampleProvider = sampleProvider
        self.onPartial = onPartial
    }

    public func start() {
        guard state == .idle else { return }
        state = .streaming
        transcriber.beginSession()
        loopTask = Task { @MainActor [weak self] in
            await self?.runPartialLoop()
        }
    }

    /// Stops partials and transcribes all audio. Throws on failure so the caller can fall back.
    public func finish(wavData: Data, sampleCount: Int) async throws -> String {
        guard state == .streaming else { throw CancellationError() }
        state = .finishing
        loopTask?.cancel()
        loopTask = nil
        defer { endIfNeeded() }
        let text = try await transcriber.transcribe(
            wavData: wavData,
            language: language,
            timeout: VoiceWhisperStreamPolicy.finalRequestTimeout(sampleCount: sampleCount),
            isFinal: true
        )
        try Task.checkCancellation()
        guard state == .finishing else { throw CancellationError() }
        return text
    }

    public func cancel() {
        loopTask?.cancel()
        loopTask = nil
        endIfNeeded()
    }

    private func endIfNeeded() {
        guard state == .streaming || state == .finishing else {
            state = .ended
            return
        }
        state = .ended
        transcriber.endSession()
    }

    private func runPartialLoop() async {
        do {
            try await transcriber.prepare()
        } catch {
            return // finish() retries and the caller falls back to the CLI.
        }

        var lastTotal = 0
        while !Task.isCancelled, state == .streaming {
            let passStart = Date()
            let (window, total) = sampleProvider(VoiceWhisperStreamPolicy.partialWindowSamples)
            // The gate is CPU work, so it stays off the main thread that handles typing.
            let gated = total > lastTotal
                ? await Task.detached(priority: .userInitiated) { VoiceSpeechGate.partialAudio(window) }.value
                : nil
            guard !Task.isCancelled, state == .streaming else { return }
            if let voiced = gated {
                lastTotal = total
                let wav = VoiceWAVEncoder.encodePCM16Mono(samples: voiced, sampleRate: VoiceWhisperStreamPolicy.sampleRate)
                do {
                    let text = try await transcriber.transcribe(
                        wavData: wav,
                        language: language,
                        timeout: VoiceWhisperStreamPolicy.partialRequestTimeout,
                        isFinal: false
                    )
                    guard !Task.isCancelled, state == .streaming else { return }
                    if !text.isEmpty {
                        onPartial(stabilizer.update(text, windowed: total > window.count))
                    }
                } catch {
                    return // Partials are best effort; finish() decides about fallback.
                }
            }
            // Until the first pass has run, poll quickly so the first text appears as soon as possible.
            let interval = lastTotal == 0 ? 0.1 : VoiceWhisperStreamPolicy.partialInterval
            let wait = max(0.1, interval - Date().timeIntervalSince(passStart))
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }
}
