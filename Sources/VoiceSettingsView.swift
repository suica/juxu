import AppKit
import ApplicationServices
import SwiftUI

public struct VoiceSettingsView: View {
    @State private var globalPermissions = VoiceGlobalPermissions(inputMonitoring: false, accessibility: false)
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
                VoiceContextInspectorCard(
                    inspector: VoiceContextInspectorStore.shared,
                    voiceStore: voiceStore
                )
                vocabularyAndTestCard
            } else {
                VoiceContextInspectorCard(
                    inspector: VoiceContextInspectorStore.shared,
                    voiceStore: voiceStore
                )
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

    private var globalHotkeyBinding: Binding<Bool> {
        Binding(
            get: { voiceStore.prefs.isGlobalHotkeyEnabled },
            set: { isOn in
                voiceStore.update { $0.globalVoiceHotkey = isOn ? true : nil }
                if isOn { VoiceGlobalPermissions.request() }
                globalPermissions = VoiceGlobalPermissions.current()
            }
        )
    }

    private var globalHotkeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("全局语音快捷键")
                        .font(.system(size: 13, weight: .medium))
                    Text("在任何应用里按住语音键，即使当前输入法不是句序")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: globalHotkeyBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if voiceStore.prefs.isGlobalHotkeyEnabled {
                if !voiceStore.prefs.triggerKey.isHoldToTalk {
                    Text("全局模式需要长按类触发键，请改选右 Option、右 Command 或 Fn")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                }
                globalPermissionRow("输入监控（监听语音键）", granted: globalPermissions.inputMonitoring, pane: VoiceGlobalPermissions.inputMonitoringPane)
                globalPermissionRow("辅助功能（写入其他应用）", granted: globalPermissions.accessibility, pane: VoiceGlobalPermissions.accessibilityPane)
                if !globalPermissions.inputMonitoring || !globalPermissions.accessibility {
                    Text("如果列表里已勾选句序仍显示未授权，通常是应用更新后签名变化：请移除句序后重新添加。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { globalPermissions = VoiceGlobalPermissions.current() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            guard voiceStore.prefs.isGlobalHotkeyEnabled else { return }
            globalPermissions = VoiceGlobalPermissions.current()
        }
    }

    private func globalPermissionRow(_ title: String, granted: Bool, pane: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? Color.green : Color.orange)
                .font(.system(size: 12))
            Text(title + (granted ? "：已授权" : "：未授权"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
            if !granted {
                Button("打开系统设置") { NSWorkspace.shared.open(pane) }
                    .controlSize(.small)
            }
        }
    }

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

                globalHotkeyRow

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开始和结束提示音")
                            .font(.system(size: 13, weight: .medium))
                        Text("双击语音键可免按住长录，再按一下结束，Esc 取消")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { voiceStore.prefs.areVoiceCuesEnabled },
                        set: { isOn in voiceStore.update { $0.voiceCues = isOn ? nil : false } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
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

/// Interactive tester & inspector for Typeless-style AXUIElement + AXEnhancedUserInterface context capture.
private struct VoiceContextInspectorCard: View {
    @ObservedObject var inspector: VoiceContextInspectorStore
    @ObservedObject var voiceStore: VoicePreferencesStore
    @State private var showRawJSON = false
    @State private var copiedNotice = false
    @State private var copiedASRNotice = false
    @State private var axTrusted = AXIsProcessTrusted()

    private func resolvedPreview(for captured: VoiceCapturedContext) -> VoiceContextPromptPreview {
        if !inspector.lastASRTargetLabel.isEmpty {
            return VoiceContextPromptPreview(
                asrTargetLabel: inspector.lastASRTargetLabel,
                asrContext: inspector.lastASRContext,
                polishBudgetLabel: inspector.lastPolishBudgetLabel,
                polishContext: inspector.lastPolishContext
            )
        }
        let prefs = voiceStore.prefs
        var vocab = prefs.parsedCustomVocabulary
        if prefs.syncJuxuLexicon {
            vocab.append(contentsOf: JuxuBridge.shared.userPhrases.prefix(40).map(\.text))
        }
        let ctx = VoiceContext(personalVocabulary: vocab).merged(with: captured)
        return VoiceContextPromptPreview.build(context: ctx, prefs: prefs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("上下文抓取实测（AXUIElement）")
                        .font(.system(size: 13, weight: .semibold))
                    Text("按 Typeless 方式抓取前台 App、窗口标题、网页 URL、光标前后文、选区与屏幕可见文本")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: axTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(axTrusted ? Color.green : Color.orange)
                        .font(.system(size: 11.5))
                    Text(axTrusted ? "辅助功能已授权" : "未授权辅助功能")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                if inspector.isCapturing {
                    Button(inspector.countdownSeconds > 0 ? "切到目标 App… (\(inspector.countdownSeconds)s)" : "抓取中…") {
                        inspector.cancelScheduledCapture()
                    }
                    .controlSize(.small)
                } else {
                    Button("3 秒后抓取前台窗口") {
                        axTrusted = AXIsProcessTrusted()
                        inspector.captureAfterDelay(seconds: 3)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Toggle("敏感应用/URL 黑名单", isOn: $inspector.respectBlacklist)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))

                Spacer()

                if !inspector.lastJSON.isEmpty {
                    Button(copiedNotice ? "已复制" : "复制 JSON") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(inspector.lastJSON, forType: .string)
                        copiedNotice = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            copiedNotice = false
                        }
                    }
                    .controlSize(.small)

                    Button(showRawJSON ? "收起 JSON" : "展开 JSON") {
                        showRawJSON.toggle()
                    }
                    .controlSize(.small)
                }
            }

            if let captured = inspector.lastCaptured {
                let app = captured.activeApplication
                let ip = captured.textInsertionPoint
                let cur = ip.cursorState
                let sur = ip.surroundingContext
                let meta = captured.contextMetadata

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    summaryRow("应用", "\(app.appName.isEmpty ? "(未知)" : app.appName) · \(app.appIdentifier) (\(app.appType)) · \(meta.elapsedMs) ms")
                    if !app.windowTitle.isEmpty {
                        summaryRow("窗口", app.windowTitle)
                    }
                    if let url = app.webURL {
                        summaryRow("URL", url)
                    }
                    summaryRow(
                        "状态",
                        "enhancedUI=\(meta.enhancedUIEnabled ? "是" : "否") · role=\(ip.accessibilityRole.isEmpty ? "无" : ip.accessibilityRole) · editable=\(ip.inputCapabilities.isEditable ? "是" : "否")\(meta.isBlacklisted ? " · 命中黑名单(\(meta.blacklistReason ?? ""))" : "")\(meta.isSecureInput ? " · 密码框已跳过" : "")"
                    )
                    if !cur.selectedText.isEmpty {
                        summaryRow("选区", compactPreview(cur.selectedText))
                    }
                    if !cur.textBeforeCursor.isEmpty || !cur.textAfterCursor.isEmpty {
                        summaryRow("光标前/后", "前(\(cur.textBeforeCursor.count)字)：\(compactPreview(cur.textBeforeCursor, limit: 60)) | 后(\(cur.textAfterCursor.count)字)：\(compactPreview(cur.textAfterCursor, limit: 40))")
                    }
                    if !sur.textBeforeInputArea.isEmpty || !sur.textAfterInputArea.isEmpty {
                        summaryRow("周边上下文", "上(\(sur.textBeforeInputArea.count)字) / 下(\(sur.textAfterInputArea.count)字)")
                    }
                    let visCount = app.visibleScreenContent?.count ?? 0
                    summaryRow("屏幕可见文本", visCount > 0 ? "\(visCount) 字：\(compactPreview(app.visibleScreenContent ?? "", limit: 80))" : (meta.isBlacklisted ? "黑名单跳过" : "无"))
                }

                let preview = resolvedPreview(for: captured)
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("实际送给 ASR 模型的上下文")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("\(preview.asrTargetLabel) · 实发 \(preview.asrContext.count) 字")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !preview.asrContext.isEmpty {
                            Button(copiedASRNotice ? "已复制" : "复制") {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(preview.asrContext, forType: .string)
                                copiedASRNotice = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                                    copiedASRNotice = false
                                }
                            }
                            .controlSize(.mini)
                        }
                    }
                    ScrollView(.vertical) {
                        Text(preview.asrContext.isEmpty ? "（无上下文发送）" : preview.asrContext)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(preview.asrContext.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 36, maxHeight: 110)
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    HStack(spacing: 8) {
                        Text("实际送给润色模型的上下文")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("\(preview.polishBudgetLabel) · \(preview.polishContext.count) 字")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    ScrollView(.vertical) {
                        Text(preview.polishContext.isEmpty ? "（无参考上下文）" : preview.polishContext)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(preview.polishContext.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 32, maxHeight: 100)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                if showRawJSON {
                    ScrollView([.vertical, .horizontal]) {
                        Text(inspector.lastJSON)
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 210)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            } else {
                Text("点击「3 秒后抓取前台窗口」后切到 Chrome / Slack / Cursor / 微信等任意应用，或在任意窗口按右 Command 语音输入，即可在此看到实时抓取结果。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
        .onAppear { axTrusted = AXIsProcessTrusted() }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func compactPreview(_ s: String, limit: Int = 90) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ⏎ ")
        if oneLine.count <= limit { return oneLine }
        return String(oneLine.prefix(limit)) + "…"
    }
}
