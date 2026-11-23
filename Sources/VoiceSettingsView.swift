import AppKit
import SwiftUI

public struct VoiceSettingsView: View {
    @ObservedObject public var bridge: JuxuBridge
    @ObservedObject public var voiceStore: VoicePreferencesStore

    @State private var primaryKeyDraft: String = ""
    @State private var splitLLMKeyDraft: String = ""
    @State private var loadedKeyAccount: VoiceKeychainAccount? = nil
    @State private var testStatus: String = ""
    @State private var testOK: Bool = true
    @State private var isTesting: Bool = false

    public init(bridge: JuxuBridge, voiceStore: VoicePreferencesStore) {
        self.bridge = bridge
        self.voiceStore = voiceStore
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("语音识别与智能整理")
                    .font(.system(size: 17, weight: .semibold))
                Text("云端预设填 Key 即用，本地一键下载模型与依赖；未开启时不占内存、不申请麦克风权限")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            // Master Switch Card — zero side effects when off
            card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("开启句序语音输入入口")
                                .font(.system(size: 13.5, weight: .semibold))
                            Text(
                                voiceStore.prefs.enabled
                                    ? "已激活：\(voiceStore.prefs.triggerKey.displayName)说话，松手自动整理上屏（Esc 取消）"
                                    : "默认关闭。未开启时不加载音频引擎、语音识别器、网络会话与悬浮窗"
                            )
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: voiceBinding(\.enabled))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    if !voiceStore.prefs.enabled {
                        Divider()
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.shield")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text("按需加载：开启后才加载语音模块与配置；随时关闭即立刻释放全部资源。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if voiceStore.prefs.enabled {
                providerCard
                if voiceStore.prefs.providerMode == .cloudBYOK {
                    cloudBYOKCard
                } else {
                    LocalVoiceConfigCard(
                        voiceStore: voiceStore,
                        installer: VoiceLocalInstaller.shared
                    )
                }
                triggerAndBehaviorCard
                vocabularyAndTestCard
            }
        }
        .onAppear {
            if voiceStore.prefs.enabled {
                reloadKeysForCurrentPreset()
            }
        }
        .onChange(of: voiceStore.prefs.enabled) { _, enabled in
            if enabled {
                reloadKeysForCurrentPreset()
            } else {
                primaryKeyDraft = ""
                splitLLMKeyDraft = ""
                loadedKeyAccount = nil
                testStatus = ""
            }
        }
        .onChange(of: voiceStore.prefs.cloudPreset) { _, _ in
            if voiceStore.prefs.enabled {
                reloadKeysForCurrentPreset()
            }
        }
    }

    // MARK: - Provider Mode Selector

    private var providerCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("运行方案")
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 10) {
                    providerOptionCard(.cloudBYOK)
                    providerOptionCard(.local)
                }
            }
        }
    }

    private func providerOptionCard(_ mode: VoiceProviderMode) -> some View {
        let selected = voiceStore.prefs.providerMode == mode
        return Button {
            voiceStore.update { $0.providerMode = mode }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(mode.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                Text(mode.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.11) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor : Color.primary.opacity(0.10),
                        lineWidth: selected ? 1.2 : 0.6
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Cloud BYOK Card (Preset + Key = Ready, or Custom URL + Key)

    private var cloudBYOKCard: some View {
        let preset = voiceStore.prefs.cloudPreset
        let hasSavedKey = !primaryKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return card {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("云端服务商")
                            .font(.system(size: 13, weight: .semibold))
                        Text(preset.subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: voiceBinding(\.cloudPreset)) {
                        ForEach(VoiceCloudPreset.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 195)
                }

                Divider()

                fieldRow(title: "API Key") {
                    HStack(spacing: 8) {
                        SecureField(preset.keyPlaceholder, text: $primaryKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: primaryKeyDraft) { _, newVal in
                                VoiceKeychainStore.write(newVal, for: preset.keychainAccount)
                            }
                        Text(hasSavedKey ? "✓ 钥匙串" : "必填")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(hasSavedKey ? Color.green : Color.orange)
                            .frame(width: 52, alignment: .trailing)
                    }
                }

                if preset == .custom {
                    fieldRow(title: "Base URL") {
                        TextField("https://api.openai.com/v1", text: voiceBinding(\.customBaseURL))
                            .textFieldStyle(.roundedBorder)
                    }
                    fieldRow(title: "语音识别模型") {
                        TextField("whisper-1", text: voiceBinding(\.customASRModel))
                            .textFieldStyle(.roundedBorder)
                    }
                    if voiceStore.prefs.cloudPolishEnabled {
                        fieldRow(title: "口语整理模型") {
                            TextField("gpt-4o-mini", text: voiceBinding(\.customLLMModel))
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text("整理模型使用独立接口与 Key")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Toggle("", isOn: voiceBinding(\.customSplitLLM))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                        if voiceStore.prefs.customSplitLLM {
                            fieldRow(title: "整理 Base URL") {
                                TextField("https://api.deepseek.com/v1", text: voiceBinding(\.customLLMBaseURL))
                                    .textFieldStyle(.roundedBorder)
                            }
                            fieldRow(title: "整理 API Key") {
                                SecureField("sk-...", text: $splitLLMKeyDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: splitLLMKeyDraft) { _, newVal in
                                        VoiceKeychainStore.write(newVal, for: .cloudCustomLLMAPIKey)
                                    }
                            }
                        }
                    }
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用云端 AI 口语整理")
                            .font(.system(size: 12.5, weight: .medium))
                        Text("自动去口水词、修正口误并按应用调整语气（\(voiceStore.prefs.effectiveCloudLLMModel)）")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: voiceBinding(\.cloudPolishEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Trigger & Behavior

    private var triggerAndBehaviorCard: some View {
        card {
            VStack(spacing: 11) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("触发快捷键")
                            .font(.system(size: 13, weight: .medium))
                        Text("在句序激活状态下生效；长按模式需按住超过 0.22 秒避免误触")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: voiceBinding(\.triggerKey)) {
                        ForEach(VoiceTriggerKey.allCases) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 205)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("输出模式与语气")
                            .font(.system(size: 13, weight: .medium))
                        Text("智能整理会自动去口水词、修正口误，并按聊天/IDE/邮件切换风格")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: voiceBinding(\.outputMode)) {
                        ForEach(VoiceOutputMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 165)
                }

                if voiceStore.prefs.outputMode == .smartPolish {
                    HStack {
                        Text("语气风格")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: voiceBinding(\.toneMode)) {
                            ForEach(VoiceToneMode.allCases) { tone in
                                Text(tone.displayName).tag(tone)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 195)
                    }
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("选中文本语音改写（Speak to Edit）")
                            .font(.system(size: 13, weight: .medium))
                        Text("先选中文字再说出修改指令（如“改正式一点 / 翻成英文”），直接替换选区")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: voiceBinding(\.speakToEditSelection))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Vocabulary & Connectivity Test

    private var vocabularyAndTestCard: some View {
        card {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("联动句序个人词库（\(bridge.userPhrases.count) 条）")
                            .font(.system(size: 13, weight: .medium))
                        Text("自动把句序里的自造词作为热词注入语音识别与整理")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: voiceBinding(\.syncJuxuLexicon))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("自定义语音热词（逗号或换行分隔）")
                        .font(.system(size: 12.5, weight: .medium))
                    TextField("例如：句序, Juxu, RWKV-7, Typeless, SwiftUI", text: voiceBinding(\.customVocabulary))
                        .textFieldStyle(.roundedBorder)
                }

                Divider()

                HStack {
                    Button(isTesting ? "检测中…" : "检测当前配置") {
                        guard !isTesting else { return }
                        isTesting = true
                        testStatus = ""
                        Task { @MainActor in
                            let res = await VoiceSessionController.shared.testCurrentConfiguration()
                            testOK = res.ok
                            testStatus = res.message
                            isTesting = false
                        }
                    }
                    .controlSize(.small)
                    .disabled(isTesting)

                    Spacer()

                    Text("配置：\(voiceStore.fileURL.lastPathComponent)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                if !testStatus.isEmpty {
                    Text(testStatus)
                        .font(.system(size: 11.5))
                        .foregroundStyle(testOK ? Color.green : Color.red)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Helpers

    private func reloadKeysForCurrentPreset() {
        let account = voiceStore.prefs.cloudPreset.keychainAccount
        if loadedKeyAccount != account {
            loadedKeyAccount = account
            primaryKeyDraft = VoiceKeychainStore.read(account)
        }
        if voiceStore.prefs.cloudPreset == .custom {
            splitLLMKeyDraft = VoiceKeychainStore.read(.cloudCustomLLMAPIKey)
        }
    }

    private func fieldRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
            )
    }

    private func voiceBinding<T>(_ keyPath: WritableKeyPath<VoicePreferences, T>) -> Binding<T> {
        Binding(
            get: { voiceStore.prefs[keyPath: keyPath] },
            set: { newValue in
                voiceStore.update { $0[keyPath: keyPath] = newValue }
            }
        )
    }
}

/// Separate subview so `VoiceLocalInstaller.shared` is ONLY instantiated when Local mode is active.
private struct LocalVoiceConfigCard: View {
    @ObservedObject var voiceStore: VoicePreferencesStore
    @ObservedObject var installer: VoiceLocalInstaller

    var body: some View {
        let _ = installer.refreshToken
        let asrPreset = voiceStore.prefs.localASRPreset
        let asrStatus = VoiceLocalInstaller.asrStatus(for: asrPreset)
        let llmPreset = voiceStore.prefs.localLLMPreset
        let llmStatus = VoiceLocalInstaller.llmStatus(for: llmPreset)

        VStack(alignment: .leading, spacing: 12) {
            // 1. Local ASR Section
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("本地语音识别模型")
                        .font(.system(size: 13, weight: .semibold))
                    Text("选择模型并一键下载；按需运行，闲置自动释放")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: binding(\.localASRPreset)) {
                    ForEach(VoiceLocalASRModelPreset.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .labelsHidden()
                .frame(width: 245)
            }

            switch asrPreset.backend {
            case .engine:
                installActionRow(
                    status: asrStatus,
                    sizeLabel: asrPreset.approximateSizeLabel,
                    depName: asrPreset.descriptor.engineLabel,
                    onInstall: { installer.installASR(preset: asrPreset) },
                    onDelete: {
                        if let file = asrPreset.modelFilename {
                            installer.deleteModel(filename: file)
                        }
                    }
                )
            case .appleSpeech:
                HStack(spacing: 10) {
                    Text("识别语言")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    TextField("zh-CN", text: binding(\.localAppleLocale))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Spacer()
                    Text("仅离线")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: binding(\.localAppleRequireOnDevice))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            case .customHTTP:
                HStack(spacing: 8) {
                    TextField("http://127.0.0.1:8080/v1", text: binding(\.localHTTPASRBaseURL))
                        .textFieldStyle(.roundedBorder)
                    TextField("whisper-1", text: binding(\.localHTTPASRModel))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
            }

            Divider()

            // 2. Local Polish Section
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("本地 LLM 整理引擎")
                        .font(.system(size: 13, weight: .semibold))
                    Text("一键下载 Qwen2.5-1.5B（llama.cpp Metal 加速），或接入已有本地 LLM 服务")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: binding(\.localLLMPreset)) {
                    ForEach(VoiceLocalLLMPreset.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .labelsHidden()
                .frame(width: 245)
            }

            if llmPreset == .qwen15B {
                installActionRow(
                    status: llmStatus,
                    sizeLabel: llmPreset.approximateSizeLabel,
                    depName: "llama.cpp",
                    onInstall: { installer.installLLM(preset: .qwen15B) },
                    onDelete: {
                        if let file = llmPreset.modelFilename {
                            installer.deleteModel(filename: file)
                        }
                    }
                )
            } else if llmPreset == .ollamaHTTP {
                HStack(spacing: 8) {
                    TextField("http://127.0.0.1:11434/v1", text: binding(\.localHTTPLLMBaseURL))
                        .textFieldStyle(.roundedBorder)
                    TextField("qwen2.5:3b", text: binding(\.localHTTPLLMModel))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
            }

            // 3. Live Installer Progress / Status Banner
            switch installer.phase {
            case .idle:
                EmptyView()
            case .installingDependency(let name):
                Divider()
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在通过 Homebrew 安装 \(name)…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { installer.cancel() }
                        .controlSize(.mini)
                }
            case .downloadingModel(let name, let progress, let detail):
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("正在下载 \(name)")
                            .font(.system(size: 11.5, weight: .medium))
                        Spacer()
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button("取消") { installer.cancel() }
                            .controlSize(.mini)
                    }
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }
            case .completed(let msg):
                Divider()
                Text(msg)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.green)
            case .failed(let msg):
                Divider()
                Text(msg)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        )
    }

    private func installActionRow(
        status: VoiceLocalComponentStatus,
        sizeLabel: String,
        depName: String,
        onInstall: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: status.isReady ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(status.isReady ? Color.green : Color.accentColor)
                .font(.system(size: 13))

            if status.isReady {
                Text("已就绪（\(depName) + 模型 \(status.formattedModelSize)）")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清理模型", action: onDelete)
                    .controlSize(.small)
                    .disabled(installer.phase.isBusy)
            } else {
                let missingText: String = {
                    if !status.dependencyInstalled && !status.modelInstalled {
                        return "需安装 \(depName) 并下载模型（约 \(sizeLabel)）"
                    } else if !status.dependencyInstalled {
                        return "模型已在本地，需安装 \(depName) 依赖"
                    } else {
                        return "\(depName) 已就绪，需下载模型（约 \(sizeLabel)）"
                    }
                }()
                Text(missingText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("一键下载并安装", action: onInstall)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(installer.phase.isBusy)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func binding<T>(_ keyPath: WritableKeyPath<VoicePreferences, T>) -> Binding<T> {
        Binding(
            get: { voiceStore.prefs[keyPath: keyPath] },
            set: { newValue in
                voiceStore.update { $0[keyPath: keyPath] = newValue }
            }
        )
    }
}
