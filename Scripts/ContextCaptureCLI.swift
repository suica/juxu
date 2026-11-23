import AppKit
import ApplicationServices
import Foundation

// Standalone CLI wrapper around `VoiceContextCapture.swift`.
// Build: swiftc -O -target arm64-apple-macosx14.0 Sources/VoiceContextCapture.swift Scripts/ContextCaptureCLI.swift -framework Cocoa -framework ApplicationServices -framework Carbon -o build/context-capture

private func printUsage() {
    let text = """
    context-capture — macOS AXUIElement + AXEnhancedUserInterface 上下文抓取工具（Typeless 同款原理）

    用法:
      context-capture [选项]

    选项:
      --delay <秒>         延迟指定秒数后抓取（方便切到 Chrome / Slack / Cursor 等窗口）
      --watch <秒>         按间隔持续轮询抓取，应用/光标/文本变化时输出（如 --watch 1.0）
      --summary            输出可读摘要（默认输出结构化 JSON）
      --compact            输出单行紧凑 JSON
      --no-blacklist       关闭敏感应用/URL 黑名单（密码管理器和密码框仍强制跳过）
      --timeout <毫秒>     单阶段 AX 读取超时（默认 500）
      --max-visible <字符> 屏幕可见文本上限（默认 20000）
      --before <字符>      光标前文与周边上文上限（默认 2000）
      --after <字符>       光标后文与周边下文上限（默认 2000）
      --prompt             若当前终端无辅助功能权限，弹出系统授权提示
      -h, --help           显示此帮助

    示例:
      context-capture --delay 3
      context-capture --delay 3 --no-blacklist --summary
      context-capture --watch 1.0 --summary
    """
    print(text)
}

private func formatSummary(_ ctx: VoiceCapturedContext) -> String {
    let app = ctx.activeApplication
    let ip = ctx.textInsertionPoint
    let cur = ip.cursorState
    let sur = ip.surroundingContext
    let meta = ctx.contextMetadata

    func preview(_ s: String, limit: Int = 140) -> String {
        let single = s.replacingOccurrences(of: "\n", with: " ⏎ ")
        if single.isEmpty { return "(空)" }
        if single.count <= limit { return single }
        return String(single.prefix(limit)) + "…（共 \(s.count) 字）"
    }

    var lines: [String] = []
    lines.append("━━━ Context Capture (\(meta.elapsedMs) ms) ━━━")
    lines.append("App:       \(app.appName) [\(app.appIdentifier)] (\(app.appType))")
    lines.append("Window:    \(app.windowTitle.isEmpty ? "(空)" : app.windowTitle)")
    if let url = app.webURL {
        lines.append("URL:       \(url)")
    }
    lines.append("AX状态:    trusted=\(meta.isAccessibilityTrusted) enhancedUI=\(meta.enhancedUIEnabled) blacklisted=\(meta.isBlacklisted)\(meta.blacklistReason.map { " (\($0))" } ?? "") secure=\(meta.isSecureInput)")
    lines.append("Focus:     role=\(ip.accessibilityRole.isEmpty ? "(无)" : ip.accessibilityRole) area=\(ip.inputAreaType) editable=\(ip.inputCapabilities.isEditable) caret=\(cur.cursorPosition.map(String.init) ?? "nil") selLen=\(cur.selectionLength)")
    lines.append("选中文本:  \(preview(cur.selectedText))")
    lines.append("光标前文:  \(preview(cur.textBeforeCursor))")
    lines.append("光标后文:  \(preview(cur.textAfterCursor))")
    lines.append("周边上文:  \(preview(sur.textBeforeInputArea))")
    lines.append("周边下文:  \(preview(sur.textAfterInputArea))")
    let vis = app.visibleScreenContent ?? ""
    lines.append("屏幕可见:  \(preview(vis, limit: 200))\(meta.timedOutVisible ? " [timeout]" : "")")
    return lines.joined(separator: "\n")
}

@main
struct ContextCaptureCLI {
    static func main() {
        var delaySeconds: Double = 0
        var watchInterval: Double? = nil
        var compact = false
        var summary = false
        var promptAX = false
        var options = VoiceContextCaptureOptions()

        let args = Array(CommandLine.arguments.dropFirst())
        var i = 0
        while i < args.count {
            let arg = args[i]
            func nextArg(_ flag: String) -> String {
                guard i + 1 < args.count else {
                    fputs("错误：参数 \(flag) 缺少取值\n", stderr)
                    exit(2)
                }
                i += 1
                return args[i]
            }
            switch arg {
            case "-h", "--help":
                printUsage()
                exit(0)
            case "--delay":
                delaySeconds = Double(nextArg(arg)) ?? 0
            case "--watch":
                watchInterval = max(0.2, Double(nextArg(arg)) ?? 1.0)
            case "--compact":
                compact = true
            case "--summary":
                summary = true
            case "--no-blacklist":
                options.respectBlacklist = false
            case "--timeout":
                options.timeoutMs = Int(nextArg(arg)) ?? 500
            case "--max-visible":
                options.maxVisibleChars = Int(nextArg(arg)) ?? 20_000
            case "--before":
                let v = Int(nextArg(arg)) ?? 2_000
                options.maxCursorBeforeChars = v
                options.maxSurroundingBeforeChars = v
            case "--after":
                let v = Int(nextArg(arg)) ?? 2_000
                options.maxCursorAfterChars = v
                options.maxSurroundingAfterChars = v
            case "--prompt":
                promptAX = true
            default:
                fputs("未知参数：\(arg)\n", stderr)
                printUsage()
                exit(2)
            }
            i += 1
        }

        // Initialize AppKit connection so NSWorkspace.shared.frontmostApplication updates reliably.
        _ = NSApplication.shared

        if !AXIsProcessTrusted() {
            if promptAX {
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            }
            fputs("提示：当前终端尚未获得 macOS「辅助功能」权限，将只能读取应用名而无法读取窗口与文本。\n", stderr)
            fputs("请在「系统设置 → 隐私与安全性 → 辅助功能」中勾选当前终端（或加 --prompt 触发弹窗），也可直接在「句序偏好设置 → 语音输入」中使用免授权预览。\n", stderr)
        }

        func sleepPumpingRunLoop(_ seconds: Double) {
            guard seconds > 0 else { return }
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        if delaySeconds > 0 {
            let whole = Int(ceil(delaySeconds))
            if whole >= 1 {
                for rem in stride(from: whole, through: 1, by: -1) {
                    fputs("将在 \(rem) 秒后抓取前台窗口…\r", stderr)
                    fflush(stderr)
                    sleepPumpingRunLoop(rem == whole ? (delaySeconds - Double(whole - 1)) : 1.0)
                }
                fputs("正在抓取…                   \n", stderr)
                fflush(stderr)
            } else {
                sleepPumpingRunLoop(delaySeconds)
            }
        } else {
            // Let NSWorkspace refresh frontmostApplication on the main RunLoop.
            sleepPumpingRunLoop(0.05)
        }

        func emit(_ ctx: VoiceCapturedContext) {
            if summary {
                print(formatSummary(ctx))
            } else if compact {
                print(ctx.compactJSON())
            } else {
                print(ctx.prettyJSON())
            }
            fflush(stdout)
        }

        if let interval = watchInterval {
            var lastFingerprint = ""
            while true {
                let ctx = VoiceContextCapture.captureSync(options: options)
                let fp = "\(ctx.activeApplication.appIdentifier)|\(ctx.activeApplication.windowTitle)|\(ctx.activeApplication.webURL ?? "")|\(ctx.textInsertionPoint.cursorState.cursorPosition ?? -1)|\(ctx.textInsertionPoint.cursorState.textBeforeCursor.suffix(60))|\(ctx.textInsertionPoint.cursorState.selectedText.prefix(60))|\(ctx.activeApplication.visibleScreenContent?.count ?? 0)"
                if fp != lastFingerprint {
                    lastFingerprint = fp
                    emit(ctx)
                }
                sleepPumpingRunLoop(interval)
            }
        } else {
            let ctx = VoiceContextCapture.captureSync(options: options)
            emit(ctx)
        }
    }
}
