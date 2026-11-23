import Foundation
import MLX
import MLXNN

struct EngineResult {
    let text: String
    /// True when any chunk stopped at the token limit instead of the model's end token.
    let truncated: Bool
    let cancelled: Bool
}

/// Qwen3-ASR-0.6B on MLX, loading the official BF16 checkpoint unchanged.
final class QwenEngine {
    private static let maxChunkSeconds = 28
    private static let splitSearchSeconds = 5

    private let audioEncoder: Qwen3AudioEncoder
    private let textModel: FloatTextModel
    private let lmHead: Linear
    private let tokenizer = Qwen3Tokenizer()
    private let features = WhisperFeatureExtractor()
    private let dtype: DType

    init(modelDirectory: URL, dtype: DType = .float16) throws {
        self.dtype = dtype
        try tokenizer.load(from: modelDirectory.appendingPathComponent("vocab.json"))
        let config = TextDecoderConfig.small
        audioEncoder = Qwen3AudioEncoder(config: .default)
        textModel = FloatTextModel(config: config)
        lmHead = Linear(config.hiddenSize, config.vocabSize, bias: false)

        let raw = try MLX.loadArrays(url: modelDirectory.appendingPathComponent("model.safetensors"))
        var weights: [String: MLXArray] = [:]
        weights.reserveCapacity(raw.count)
        for (key, value) in raw where key.hasPrefix("thinker.") {
            weights[String(key.dropFirst("thinker.".count))] = value.asType(dtype)
        }
        try apply(weights)
        eval(audioEncoder, textModel, lmHead)
    }

    private func apply(_ weights: [String: MLXArray]) throws {
        var audio: [String: MLXArray] = [:]
        var text: [String: MLXArray] = [:]
        for (key, value) in weights {
            if key.hasPrefix("audio_tower.") {
                var v = value
                let name = String(key.dropFirst("audio_tower.".count))
                // PyTorch Conv2d weights are [out, in, h, w]; MLX expects [out, h, w, in].
                if name.hasPrefix("conv2d"), name.hasSuffix(".weight") {
                    v = v.transposed(0, 2, 3, 1)
                }
                audio[name] = v
            } else if key.hasPrefix("model.") {
                text[Self.textKey(String(key.dropFirst("model.".count)))] = value
            }
        }
        guard let head = weights["lm_head.weight"] else { throw EngineError.missingWeight("lm_head.weight") }
        try audioEncoder.update(parameters: ModuleParameters.unflattened(audio), verify: [.all])
        try textModel.update(parameters: ModuleParameters.unflattened(text), verify: [.all])
        try lmHead.update(parameters: ModuleParameters.unflattened(["weight": head]), verify: [.all])
    }

    private static func textKey(_ key: String) -> String {
        key.replacingOccurrences(of: "embed_tokens", with: "embedTokens")
            .replacingOccurrences(of: "post_attention_layernorm", with: "postAttentionLayerNorm")
            .replacingOccurrences(of: "input_layernorm", with: "inputLayerNorm")
            .replacingOccurrences(of: "self_attn", with: "selfAttn")
            .replacingOccurrences(of: "q_proj", with: "qProj")
            .replacingOccurrences(of: "k_proj", with: "kProj")
            .replacingOccurrences(of: "v_proj", with: "vProj")
            .replacingOccurrences(of: "o_proj", with: "oProj")
            .replacingOccurrences(of: "q_norm", with: "qNorm")
            .replacingOccurrences(of: "k_norm", with: "kNorm")
            .replacingOccurrences(of: "gate_proj", with: "gateProj")
            .replacingOccurrences(of: "up_proj", with: "upProj")
            .replacingOccurrences(of: "down_proj", with: "downProj")
    }

    func transcribe(
        pcm: [Float],
        language: String?,
        context: String?,
        isCancelled: () -> Bool
    ) -> EngineResult {
        var parts: [String] = []
        var truncated = false
        for chunk in Self.chunks(pcm) {
            if isCancelled() { return EngineResult(text: "", truncated: false, cancelled: true) }
            guard let (text, hitLimit) = decode(chunk, language: language, context: context, isCancelled: isCancelled) else {
                return EngineResult(text: "", truncated: false, cancelled: true)
            }
            truncated = truncated || hitLimit
            parts.append(text)
        }
        Memory.clearCache()
        return EngineResult(text: parts.joined(), truncated: truncated, cancelled: false)
    }

    /// Splits long audio at the quietest 100 ms near each limit so no word is cut in half.
    static func chunks(_ pcm: [Float]) -> [ArraySlice<Float>] {
        let rate = 16_000
        let limit = maxChunkSeconds * rate
        guard pcm.count > limit else { return [pcm[...]] }
        var out: [ArraySlice<Float>] = []
        var start = 0
        while pcm.count - start > limit {
            let hop = rate / 10
            var bestEnd = start + limit
            var bestEnergy = Float.greatestFiniteMagnitude
            var end = start + limit
            while end >= start + limit - splitSearchSeconds * rate {
                var sum: Float = 0
                for i in (end - hop)..<end { sum += pcm[i] * pcm[i] }
                if sum < bestEnergy {
                    bestEnergy = sum
                    bestEnd = end - hop / 2
                }
                end -= hop
            }
            out.append(pcm[start..<bestEnd])
            start = bestEnd
        }
        out.append(pcm[start...])
        return out
    }

    private func decode(
        _ audio: ArraySlice<Float>,
        language: String?,
        context: String?,
        isCancelled: () -> Bool
    ) -> (String, Bool)? {
        let T = Qwen3ASRTokenIDs.self
        let mel = features.process(Array(audio), sampleRate: 16_000).asType(dtype)
        let audioEmbeds = audioEncoder(mel.expandedDimensions(axis: 0)).expandedDimensions(axis: 0)
        eval(audioEmbeds)
        if isCancelled() { return nil }

        var prefix: [Int32] = [T.imStart, T.system, T.newline]
        if let context, !context.isEmpty {
            prefix += tokenizer.encode(context).map(Int32.init)
        }
        prefix += [T.imEnd, T.newline, T.imStart, T.user, T.newline, T.audioStart]
        var suffix: [Int32] = [T.audioEnd, T.imEnd, T.newline, T.imStart, T.assistant, T.newline]
        if let language {
            suffix += tokenizer.encode("language \(language)").map(Int32.init)
        }
        suffix.append(T.asrText)

        let before = textModel.embedTokens(MLXArray(prefix).expandedDimensions(axis: 0))
        let after = textModel.embedTokens(MLXArray(suffix).expandedDimensions(axis: 0))
        let inputs = concatenated([before, audioEmbeds.asType(before.dtype), after], axis: 1)

        let seconds = Double(audio.count) / 16_000
        let maxTokens = max(64, Int(seconds * 20) + 64)
        let (hidden, firstCache) = textModel(inputsEmbeds: inputs)
        var cache = firstCache
        var next = argMax(lmHead(hidden[0..., (-1)..., 0...]), axis: -1).squeezed().asType(.int32)
        asyncEval(next, cache.flatMap { [$0.0, $0.1] })
        // The next step is queued on the GPU while the current token is read back.
        defer { Stream.defaultStream(.gpu).synchronize() }
        var tokens: [Int] = []
        var sawEnd = false
        for step in 0..<maxTokens {
            if isCancelled() { return nil }
            var following: MLXArray?
            var followingCache: [(MLXArray, MLXArray)]?
            if step + 1 < maxTokens {
                let embed = textModel.embedTokens(next.expandedDimensions(axis: 0).expandedDimensions(axis: 0))
                let (h, c) = textModel(inputsEmbeds: embed, cache: cache)
                let n = argMax(lmHead(h[0..., (-1)..., 0...]), axis: -1).squeezed().asType(.int32)
                asyncEval(n, c.flatMap { [$0.0, $0.1] })
                following = n
                followingCache = c
            }
            let id = next.item(Int32.self)
            if id == T.imEnd || id == T.endOfText {
                sawEnd = true
                break
            }
            tokens.append(Int(id))
            guard let following, let followingCache else { break }
            next = following
            cache = followingCache
        }
        var text = tokenizer.decode(tokens: tokens)
        if let range = text.range(of: "<asr_text>") {
            text = String(text[range.upperBound...])
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), !sawEnd)
    }
}

enum EngineError: Error {
    case missingWeight(String)
}

enum Qwen3ASRTokenIDs {
    static let audioStart: Int32 = 151669
    static let audioEnd: Int32 = 151670
    static let endOfText: Int32 = 151643
    static let imStart: Int32 = 151644
    static let imEnd: Int32 = 151645
    static let asrText: Int32 = 151704
    static let newline: Int32 = 198
    static let system: Int32 = 8948
    static let user: Int32 = 872
    static let assistant: Int32 = 77091
}
