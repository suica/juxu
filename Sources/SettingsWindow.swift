import AppKit
import SwiftUI

public enum SettingsSection: String, CaseIterable, Identifiable {
    case schema = "方案与输入"
    case typo = "误触与热区"
    case lexicon = "组词与词库"
    case voice = "语音输入"
    case appearance = "外观与标点"

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .schema: return "keyboard"
        case .typo: return "hand.tap"
        case .lexicon: return "character.book.closed"
        case .voice: return "waveform"
        case .appearance: return "sparkles.rectangle.stack"
        }
    }
}

public struct SettingsRootView: View {
    @ObservedObject public var bridge: JuxuBridge
    @State public var selectedSection: SettingsSection
    @State private var newPhraseInput: String = ""
    @State private var phraseBanner: String = ""
    @State private var labCommittedText: String = "输入"
    @State private var lastTouchInfo: String = "点按下方键帽或两键交界处体验连续高斯热区与 N-gram 置信度纠错"

    public init(bridge: JuxuBridge, initialSection: SettingsSection = .schema) {
        self.bridge = bridge
        self._selectedSection = State(initialValue: initialSection)
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar aligned to macOS System Settings
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.98, green: 0.97, blue: 0.94), Color(red: 0.91, green: 0.89, blue: 0.85)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                            )
                            .frame(width: 32, height: 32)
                        Image(systemName: "pencil.tip")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(red: 0.11, green: 0.12, blue: 0.15))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("句序 Juxu")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(bridge.state.schemaName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 12)

                ForEach(SettingsSection.allCases) { sec in
                    Button {
                        selectedSection = sec
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: sec.symbolName)
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 18)
                                .foregroundStyle(selectedSection == sec ? Color.white : Color.accentColor)
                            Text(sec.rawValue)
                                .font(.system(size: 13, weight: selectedSection == sec ? .medium : .regular))
                                .foregroundStyle(selectedSection == sec ? Color.white : Color.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6.5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selectedSection == sec ? Color.accentColor : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                VStack(alignment: .leading, spacing: 3) {
                    Text("零拷贝 mmap 内核")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("macOS · iOS 通用引擎")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 10)
            .frame(width: 176)
            .background(.ultraThinMaterial)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedSection {
                    case .schema:
                        schemaSectionView
                    case .typo:
                        typoSectionView
                    case .lexicon:
                        lexiconSectionView
                    case .voice:
                        VoiceSettingsView(bridge: bridge, voiceStore: VoicePreferencesStore.shared)
                    case .appearance:
                        appearanceSectionView
                    }
                }
                .padding(22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, minHeight: 540)
    }

    // MARK: - Section 1: Schema & Core Typing

    private var schemaSectionView: some View {
        let activeCategory = bridge.prefs.schemaCategory
        let isCangjie = bridge.prefs.isCangjieFamily
        let maxCodeLabel = isCangjie ? "五" : "四"
        let pushCodeLabel = isCangjie ? "六" : "五"
        return VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: "输入方案与编码规则",
                subtitle: "内置拼音、五笔、仓颉三大类零拷贝词典，共用 RWKV-7 语言模型与触点纠错"
            )

            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("1. 选择方案大类")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("当前：\(activeCategory.rawValue) · \(bridge.state.schemaName)")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 10) {
                            ForEach(InputSchemaCategory.allCases) { category in
                                schemaCategoryCard(category)
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("2. 选择\(activeCategory.rawValue)方案版本")
                            .font(.system(size: 13, weight: .semibold))

                        HStack(spacing: 10) {
                            ForEach(InputSchemaOption.options(for: activeCategory)) { option in
                                schemaOptionCard(id: option.id, title: option.title, desc: option.desc)
                            }
                        }
                    }
                }
            }

            if !bridge.prefs.isPinyinFamily {
                settingsCard {
                    VStack(spacing: 11) {
                        toggleRow(
                            title: "\(maxCodeLabel)码唯一自动上屏",
                            subtitle: "输满\(maxCodeLabel)码且精确匹配唯一候选时免按空格直接上屏",
                            isOn: binding(\.fourthCodeAutoCommit)
                        )
                        Divider()
                        toggleRow(
                            title: "第\(pushCodeLabel)码顶字上屏",
                            subtitle: "\(maxCodeLabel)码存在重码时，继续敲第 \(isCangjie ? "6" : "5") 码自动将首选词顶上屏并开始新编码",
                            isOn: binding(\.fifthCodePushCommit)
                        )
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(maxCodeLabel)码空码处理")
                                    .font(.system(size: 13, weight: .medium))
                                Text("第\(maxCodeLabel)码无匹配且无高置信度纠错项时的行为")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("", selection: binding(\.fourthEmptyBehavior)) {
                                Text("阻断第 \(isCangjie ? "5" : "4") 码并提示").tag("block")
                                Text("自动清空重输").tag("clear")
                            }
                            .labelsHidden()
                            .frame(width: 168)
                        }
                    }
                }
            }

            settingsCard {
                VStack(spacing: 11) {
                    if bridge.prefs.isPinyinFamily {
                        toggleRow(
                            title: "声母简拼",
                            subtitle: bridge.prefs.schemaId == 21
                                ? "支持单键声母简拼（如 u/i/v 分别对应 sh/ch/zh，urf → 输入法）"
                                : "支持首字母简拼与全简混拼（如 srf / shurf → 输入法）",
                            isOn: binding(\.pinyinInitialAbbr)
                        )
                        Divider()
                    } else {
                        toggleRow(
                            title: "流式无空格连打（实验）",
                            subtitle: "连续输入词组和简码。标点确认中文，回车输入原始字母",
                            isOn: binding(\.spaceless)
                        )
                        Divider()
                        toggleRow(
                            title: "最短编码（简码）优先",
                            subtitle: isCangjie
                                ? "输入 1–4 码时精确匹配字词始终优先于长码前缀补全"
                                : "输入 1–3 码时简码字词始终优先于长码前缀补全",
                            isOn: binding(\.shortestCodeFirst)
                        )
                        Divider()
                        toggleRow(
                            title: "全码显示简码提示",
                            subtitle: isCangjie
                                ? "打较长编码时在候选旁标注更短编码"
                                : "打全码时在候选旁标注最短简码（如打 khk 在“中”旁轻提示 k）",
                            isOn: binding(\.showShortcodeHint)
                        )
                        Divider()
                        toggleRow(
                            title: "出简不出全",
                            subtitle: bridge.prefs.spaceless
                                ? "优先按首选简码切分单字，较长的编码仍可出字"
                                : "拥有首选简码的单字在输入\(maxCodeLabel)码全码时后置",
                            isOn: binding(\.strictShortcode)
                        )
                        if bridge.prefs.isWubiFamily || isCangjie {
                            Divider()
                            toggleRow(
                                title: isCangjie ? "z 键拼音反查" : "z 键万能通配与拼音反查",
                                subtitle: isCangjie
                                    ? "首字母输 z 接拼音反查当前仓颉版本的字根与编码（如 zmian → 面 一田尸中 mwsl）"
                                    : "第 2–4 位输 z 通配任意码元；首字母输 z 接拼音反查当前版本的五笔码",
                                isOn: binding(\.zOmnipotent)
                            )
                        }
                        Divider()
                    }
                    toggleRow(
                        title: "启用 Unicode 扩展区大字集",
                        subtitle: "包含 CJK 扩展 B–I 生僻古籍字（日常盲打建议关闭以保持重码精简）",
                        isOn: binding(\.enableRareCharset)
                    )
                }
            }
        }
    }

    // MARK: - Section 2: Typo Correction & Touch Hitbox Lab

    private var typoSectionView: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: "统计置信度误触纠正与动态触控热区",
                subtitle: "融合连续二维触点高斯似然、语料 N-gram、RWKV-7 与个人输入历史，专为解决打字滑偏与错键痛点设计"
            )

            settingsCard {
                VStack(spacing: 11) {
                    toggleRow(
                        title: "启用贝叶斯误触纠正解码器",
                        subtitle: "对空码滑偏、键边缘误触与双指快速换位产出归一化置信度",
                        isOn: binding(\.typoEnabled)
                    )
                    Divider()
                    toggleRow(
                        title: "纠错救回项抑制「四码自动上屏」",
                        subtitle: "纠错产生的非精确首选词满四码时留待空格/第五码确认，绝不盲目顶错字",
                        isOn: binding(\.suppressAutoCommitOnCorrection)
                    )
                    Divider()
                    toggleRow(
                        title: "语言模型漏空格切分纠错",
                        subtitle: "打完简码或三码字漏按空格续打下一字时，结合 Micro-RWKV-7 智能顶屏或提示切分候选",
                        isOn: binding(\.missedSpaceCorrection)
                    )
                    Divider()
                    toggleRow(
                        title: "触屏个人热区动态校准（EMA 自适应）",
                        subtitle: "根据历史触点残差微调每个按键判定中心（限幅 ±0.20 键宽），适配个人拇指习惯",
                        isOn: binding(\.touchHitboxAdapt)
                    )
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("空码 / 边缘滑偏直推首选阈值：\(Int(bridge.prefs.promoteThreshold * 100))%")
                                .font(.system(size: 13, weight: .medium))
                            Text("置信度达到该阈值时直接救回至 1 号候选位")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Slider(value: binding(\.promoteThreshold), in: 0.60...0.96, step: 0.02)
                            .frame(width: 170)
                    }
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("精确码有效时次选纠错提示阈值：\(Int(bridge.prefs.suggestThreshold * 100))%")
                                .font(.system(size: 13, weight: .medium))
                            Text("精确首选不动，将高于该置信度的邻键常用词放在 2 号位备选")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Slider(value: binding(\.suggestThreshold), in: 0.15...0.70, step: 0.05)
                            .frame(width: 170)
                    }
                    Divider()
                    HStack {
                        Text("已学习热区偏移按键数：\(bridge.state.calibratedKeyCount) / 26")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("重置热区校准") {
                            bridge.resetTouchCalibration()
                            lastTouchInfo = "已清空全部按键的个人热区偏移校准记录"
                        }
                        .controlSize(.small)
                    }
                }
            }

            // Interactive iOS 26-Key Touch Hitbox Simulator!
            settingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("触屏热区与误触纠正实时演练台", systemImage: "iphone.gen3")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("前文语境：\(labCommittedText.isEmpty ? "（无）" : labCommittedText)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Button("清空") {
                            bridge.clearComposition()
                            labCommittedText = ""
                        }
                        .controlSize(.mini)
                    }

                    Text(lastTouchInfo)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if !bridge.state.preedit.isEmpty {
                        // The bar reports its content width. Scroll it so long candidates cannot widen
                        // the card and move the keys under the pointer between taps.
                        ScrollView(.horizontal, showsIndicators: false) {
                            CandidateBarView(
                                state: bridge.state,
                                onSelectCandidate: { idx in
                                    let res = bridge.selectCandidate(pageRelIndex: idx, timestampMs: currentMs())
                                    if !res.commitText.isEmpty {
                                        labCommittedText += res.commitText
                                    }
                                },
                                onTurnPage: { d in
                                    _ = bridge.turnPage(delta: d)
                                }
                            )
                        }
                        .frame(minHeight: 34, alignment: .leading)
                    } else {
                        HStack {
                            Text("试着点偏 T/Y 交界输入 y-r-w-u（救回「我们」），或在「输入」后点偏 U/I 交界输入 u-f-c-y（救回「法」）")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(height: 34)
                    }

                    TouchKeyboardSimulatorView { ch, normX, normY in
                        let out = bridge.pushTouch(
                            reportedAscii: ch,
                            x: normX,
                            y: normY,
                            isNormalized: true,
                            timestampMs: currentMs()
                        )
                        if !out.commitText.isEmpty {
                            labCommittedText += out.commitText
                        }
                        let scalar = UnicodeScalar(ch)
                        lastTouchInfo = String(
                            format: "触点 (%.2f, %.2f) 落入 [%@] 键区 → 编码 \"%@\"",
                            normX, normY, String(Character(scalar)), out.preedit
                        )
                    } onBackspace: {
                        _ = bridge.handleKey(keyCode: 0x33, scalar: 0, hasCmdOrCtrl: false, timestampMs: currentMs())
                    } onSpace: {
                        let out = bridge.handleKey(keyCode: 0x31, scalar: 32, hasCmdOrCtrl: false, timestampMs: currentMs())
                        if !out.commitText.isEmpty {
                            labCommittedText += out.commitText
                        }
                    }
                }
            }

            settingsCard {
                VStack(alignment: .leading, spacing: 11) {
                    toggleRow(
                        title: "记录输入与选词诊断日志（本地 Eval Set）",
                        subtitle: "保存手选非首选、RWKV 策略压制标记、纠错与退格重打到 ~/Library/Application Support/Juxu/eval_log.jsonl",
                        isOn: binding(\.evalLogging)
                    )
                    Divider()
                    let s = bridge.evalLogSummary
                    HStack(spacing: 12) {
                        macEvalStatBox(title: "总上屏", value: "\(s.commits)")
                        macEvalStatBox(title: "Top-1 命中率", value: s.commits > 0 ? String(format: "%.1f%%", s.top1RatePercent) : "—")
                        macEvalStatBox(title: "手选非首选", value: "\(s.manualSelects)")
                        macEvalStatBox(title: "策略压制模型", value: "\(s.lmOverruled)")
                        macEvalStatBox(title: "退格重打", value: "\(s.backspaceAfterCommit)")
                        macEvalStatBox(title: "纠错触发", value: "\(s.typoTriggered)")
                    }
                    HStack(spacing: 8) {
                        Button("刷新统计") {
                            bridge.reloadEvalLogSummary()
                        }
                        .controlSize(.small)

                        Button("在 Finder 中显示日志") {
                            if FileManager.default.fileExists(atPath: bridge.evalLogURL.path) {
                                NSWorkspace.shared.activateFileViewerSelecting([bridge.evalLogURL])
                            } else {
                                NSWorkspace.shared.open(bridge.evalLogURL.deletingLastPathComponent())
                            }
                        }
                        .controlSize(.small)

                        Spacer()

                        Button("清空日志", role: .destructive) {
                            bridge.clearEvalLog()
                        }
                        .controlSize(.small)
                        .disabled(s.totalEvents == 0)
                    }
                }
                .onAppear {
                    bridge.reloadEvalLogSummary()
                }
            }
        }
    }

    private func macEvalStatBox(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    // MARK: - Section 3: Auto-Phrase & Personal Lexicon

    private var lexiconSectionView: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: "自动组词、动态调频与跨版本个人词库",
                subtitle: "自造词仅存词条文本，切换 86 / 98 / 新世纪时实时按目标方案字根重算四码"
            )

            settingsCard {
                VStack(spacing: 11) {
                    toggleRow(
                        title: "连打单字自动组词",
                        subtitle: "连续单字输入同一双字/三字组合达到阈值后自动收录进个人词库（打字时也可按 Ctrl + = 手动造词）",
                        isOn: binding(\.autoPhrase)
                    )
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动成词触发次数")
                                .font(.system(size: 13, weight: .medium))
                            Text("默认重复 2 次自动成词，避免偶然相邻单字污染词库")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: binding(\.autoPhraseThreshold)) {
                            Text("连打 1 次即成词").tag(1)
                            Text("连打 2 次成词（推荐）").tag(2)
                            Text("连打 3 次成词").tag(3)
                        }
                        .labelsHidden()
                        .frame(width: 168)
                    }
                    Divider()
                    toggleRow(
                        title: "词组动态调频",
                        subtitle: "常用词组与上下文连贯词组自动前移",
                        isOn: binding(\.dynamicWordFreq)
                    )
                    Divider()
                    toggleRow(
                        title: "单字动态调频",
                        subtitle: "默认关闭以保持单字固定重码顺序，保护五笔盲打肌肉记忆",
                        isOn: binding(\.dynamicCharFreq)
                    )
                }
            }

            settingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("添加个人词条（自动按当前 \(bridge.state.schemaName) 推导编码）")
                        .font(.system(size: 13, weight: .medium))

                    HStack(spacing: 8) {
                        TextField("输入 2–12 字中文词条，如：句序", text: $newPhraseInput)
                            .textFieldStyle(.roundedBorder)
                        Button("添加词条") {
                            let code = bridge.addUserPhrase(newPhraseInput)
                            if !code.isEmpty {
                                phraseBanner = "✓ 已收录「\(newPhraseInput)」，当前方案编码：\(code)"
                                newPhraseInput = ""
                            } else {
                                phraseBanner = "请输入至少 2 个规范汉字"
                            }
                        }
                        .disabled(newPhraseInput.trimmingCharacters(in: .whitespaces).count < 2)
                    }

                    if !phraseBanner.isEmpty {
                        Text(phraseBanner)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.accentColor)
                    }

                    Divider()

                    if bridge.userPhrases.isEmpty {
                        Text("暂无个人词条。日常连打单字会自动学习常用新词，也可在上方手动添加。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 4) {
                            ForEach(bridge.userPhrases.prefix(12)) { item in
                                HStack {
                                    Text(item.text)
                                        .font(.system(size: 13.5, weight: .medium))
                                    Text(item.code)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.primary.opacity(0.06), in: Capsule())
                                    if item.auto {
                                        Text("自动组词")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.teal)
                                    }
                                    Spacer()
                                    Text("频次 \(item.count)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    Button {
                                        bridge.removeUserPhrase(item.text)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Section 4: Appearance & Punctuation

    private var appearanceSectionView: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: "原生候选栏外观、中英切换与标点",
                subtitle: "对齐 macOS 原生毛玻璃材质与深浅色自适应，配置文件保存于 \(bridge.configURL.lastPathComponent)"
            )

            settingsCard {
                VStack(spacing: 11) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("候选词排列方向")
                                .font(.system(size: 13, weight: .medium))
                            Text("横排贴近苹果原生中文输入法，竖排适合快速扫视多行重码")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: binding(\.vertical)) {
                            Text("横排候选窗").tag(false)
                            Text("竖排候选窗").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    Divider()
                    HStack {
                        Text("每页候选词数量：\(bridge.prefs.pageSize) 个")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Stepper("", value: binding(\.pageSize), in: 3...9)
                            .labelsHidden()
                    }
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Shift 键切换中/英时行为")
                                .font(.system(size: 13, weight: .medium))
                            Text("正在输入五笔编码时点按 Shift 键如何处理已敲字母")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: binding(\.shiftToggleMode)) {
                            Text("原样上屏英文编码").tag("commit_code")
                            Text("上屏首选中文词").tag("commit_first")
                            Text("清空未上屏编码").tag("clear")
                        }
                        .labelsHidden()
                        .frame(width: 168)
                    }
                    Divider()
                    toggleRow(
                        title: "中文标点与引号智能配对",
                        subtitle: "中文模式下自动转换全角标点，并成对输入引号、括号、直角引号与书名号",
                        isOn: binding(\.smartPunctuation)
                    )
                    Divider()
                    toggleRow(
                        title: "Emoji 候选",
                        subtitle: "输入时，在匹配的词语后显示 Emoji 作为次要候选（如 思考 → 🤔）",
                        isOn: binding(\.emojiCandidates)
                    )
                    Divider()
                    toggleRow(
                        title: "中英文之间自动加空格",
                        subtitle: "中英混输或切换上屏时自动在汉字与英文边界补全空格（保留 URL 及退格删去的空格）",
                        isOn: binding(\.autoSpaceZhEn)
                    )
                    if bridge.prefs.autoSpaceZhEn {
                        Divider()
                        toggleRow(
                            title: "数字与中文之间也加空格",
                            subtitle: "在汉字与数字边界自动加空格（如「第 2 候选词」；关闭后仅对英文词加空格）",
                            isOn: binding(\.autoSpaceDigits)
                        )
                    }
                    Divider()
                    toggleRow(
                        title: "分号 (;) 与引号 (') 快捷选重",
                        subtitle: "编码输入中按 ; 直接上屏第 2 候选词、按 ' 上屏第 3 候选词",
                        isOn: binding(\.semicolonQuoteSelect)
                    )
                }
            }

            // Live Appearance Preview Card
            settingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("候选窗实时预览")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)

                    CandidateBarView(state: samplePreviewState(vertical: bridge.prefs.vertical))
                }
            }
        }
    }

    // MARK: - Reusable Helpers

    private func samplePreviewState(vertical: Bool) -> JuxuActionState {
        JuxuActionState(
            consumed: true,
            bell: false,
            asciiMode: false,
            schemaId: bridge.prefs.schemaId,
            page: 0,
            totalPages: 2,
            vertical: vertical,
            schemaName: bridge.state.schemaName,
            commitText: "",
            preedit: "yrwu",
            notice: "",
            userPhraseCount: bridge.userPhrases.count,
            calibratedKeyCount: bridge.state.calibratedKeyCount,
            candidates: [
                JuxuCandidateItem(index: 1, text: "我们", comment: "⌖trwu 96%", badge: 2, confidence: 0.96, isExact: false),
                JuxuCandidateItem(index: 2, text: "句序", comment: "", badge: 5, confidence: 0.02, isExact: true),
                JuxuCandidateItem(index: 3, text: "国", comment: "⚡l", badge: 1, confidence: 0.01, isExact: true),
                JuxuCandidateItem(index: 4, text: "语言", comment: "", badge: 0, confidence: 0.01, isExact: true),
            ]
        )
    }

    private func schemaCategoryCard(_ category: InputSchemaCategory) -> some View {
        let selected = bridge.prefs.schemaCategory == category
        return Button {
            if !selected {
                bridge.switchSchema(category.defaultSchemaId)
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: category.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Color.accentColor)
                    Text(category.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.92))
                    }
                }
                Text(category.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: selected ? 1.2 : 0.6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func schemaOptionCard(id: UInt32, title: String, desc: String) -> some View {
        let selected = bridge.prefs.schemaId == id
        return Button {
            bridge.switchSchema(id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                Text(desc)
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
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: selected ? 1.2 : 0.6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
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

    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<JuxuPreferences, T>) -> Binding<T> {
        Binding(
            get: { bridge.prefs[keyPath: keyPath] },
            set: { newVal in
                var copy = bridge.prefs
                copy[keyPath: keyPath] = newVal
                bridge.applyAndSavePreferences(copy)
            }
        )
    }

    private func currentMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000.0)
    }
}

/// Renders crisp macOS 26 style capsule switch that keeps its active accent color even in non-key preview windows.
struct NativeAccentSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.16))
                    .frame(width: 34, height: 20)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 0.8)
                    .frame(width: 16, height: 16)
                    .padding(2)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Interactive 1:1 Apple iOS 26-key virtual keyboard simulator for testing continuous touch coordinates!
struct TouchKeyboardSimulatorView: View {
    var onTouchLetter: (UInt8, Float, Float) -> Void
    var onBackspace: () -> Void
    var onSpace: () -> Void

    @State private var lastDot: CGPoint?

    private let rows: [[Character]] = [
        Array("qwertyuiop"),
        Array("asdfghjkl"),
        Array("zxcvbnm"),
    ]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let pitchX = w / 10.0
            let keyH: CGFloat = 36
            let pitchY: CGFloat = 42

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))

                // Render 3 rows of native-proportioned keycaps
                ForEach(0..<3, id: \.self) { r in
                    let indent: CGFloat = r == 0 ? 0.0 : (r == 1 ? 0.5 : 1.5)
                    ForEach(Array(rows[r].enumerated()), id: \.offset) { col, ch in
                        let cx = (CGFloat(col) + indent + 0.5) * pitchX
                        let cy = 8 + CGFloat(r) * pitchY + keyH / 2.0
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .shadow(color: .black.opacity(0.14), radius: 0.6, x: 0, y: 1)
                            .frame(width: pitchX - 5, height: keyH)
                            .overlay(
                                Text(String(ch).uppercased())
                                    .font(.system(size: 14, weight: .regular, design: .rounded))
                            )
                            .position(x: cx, y: cy)
                    }
                }

                // Bottom row: Space & Backspace
                HStack(spacing: 8) {
                    Button {
                        onSpace()
                    } label: {
                        Text("空格确认")
                            .font(.system(size: 12.5))
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                            .shadow(color: .black.opacity(0.12), radius: 0.6, x: 0, y: 1)
                    }
                    .buttonStyle(.plain)

                    Button {
                        onBackspace()
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.system(size: 13))
                            .frame(width: 56, height: 32)
                            .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .offset(y: 8 + 3 * pitchY)

                if let dot = lastDot {
                    Circle()
                        .fill(Color.orange.opacity(0.85))
                        .frame(width: 9, height: 9)
                        .position(dot)
                }

                // Transparent continuous touch surface over the 3 letter rows!
                Color.clear
                    .frame(width: w, height: 8 + 3 * pitchY - 4)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { val in
                                let pt = val.location
                                lastDot = pt
                                let normX = Float((pt.x - pitchX * 0.5) / pitchX)
                                let normY = Float((pt.y - (8 + keyH * 0.5)) / pitchY)
                                let nearest = nearestRawKey(nx: normX, ny: normY)
                                onTouchLetter(nearest, normX, normY)
                            }
                    )
            }
        }
        .frame(height: 178)
    }

    private func nearestRawKey(nx: Float, ny: Float) -> UInt8 {
        var best: UInt8 = UInt8(ascii: "a")
        var bestD: Float = .greatestFiniteMagnitude
        let r0 = Array("qwertyuiop".utf8)
        let r1 = Array("asdfghjkl".utf8)
        let r2 = Array("zxcvbnm".utf8)
        for (i, k) in r0.enumerated() {
            let d = pow(nx - Float(i), 2) + pow(ny - 0.0, 2)
            if d < bestD { bestD = d; best = k }
        }
        for (i, k) in r1.enumerated() {
            let d = pow(nx - (Float(i) + 0.5), 2) + pow(ny - 1.0, 2)
            if d < bestD { bestD = d; best = k }
        }
        for (i, k) in r2.enumerated() {
            let d = pow(nx - (Float(i) + 1.5), 2) + pow(ny - 2.0, 2)
            if d < bestD { bestD = d; best = k }
        }
        return best
    }
}

@MainActor
final class SettingsWindow: NSWindow {
    static func isCloseWindowShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        guard modifiers == .command else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "w"
            || event.characters?.lowercased() == "w"
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) {
            return true
        }
        if Self.isCloseWindowShortcut(event) {
            performClose(nil)
            return true
        }
        return false
    }
}

@MainActor
public final class SettingsWindowController {
    public static let shared = SettingsWindowController()
    private var window: NSWindow?

    private init() {}

    public func show(section: SettingsSection = .schema) {
        if window == nil {
            let win = SettingsWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 580),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "句序偏好设置"
            win.toolbarStyle = .unified
            win.center()
            win.isReleasedWhenClosed = false
            self.window = win
        }
        guard let win = window else { return }
        win.contentView = NSHostingView(rootView: SettingsRootView(bridge: .shared, initialSection: section))
        let bringToFront: @MainActor () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
        }
        bringToFront()
        // Re-assert activation on the next runloop tick so closing the status-bar menu doesn't steal focus back.
        DispatchQueue.main.async {
            bringToFront()
        }
    }
}
