import Foundation
import os

/// Timing of one dictation, for finding where latency goes. It records durations only, never text.
struct VoiceSessionTimeline {
    enum Mark: String, CaseIterable {
        case keyDown, holdFired, hudShown, engineReady, micRunning, firstBuffer
        case firstRequest, firstResult, firstDraw, release, finalDone, inserted
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "im.juxu.inputmethod.Juxu",
        category: "voice-timing"
    )
    private var times: [Mark: CFAbsoluteTime] = [:]
    private var passes = 0

    mutating func begin() {
        times = [.keyDown: CFAbsoluteTimeGetCurrent()]
        passes = 0
    }

    /// Keeps the first time each point is reached.
    mutating func mark(_ mark: Mark, at time: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        if times[mark] == nil { times[mark] = time }
    }

    mutating func countPass() { passes += 1 }

    func has(_ mark: Mark) -> Bool { times[mark] != nil }

    var summary: String {
        guard let start = times[.keyDown] else { return "" }
        let points = Mark.allCases.compactMap { mark in
            times[mark].map { "\(mark.rawValue)=\(Int(($0 - start) * 1000))" }
        }
        return (points + ["passes=\(passes)"]).joined(separator: " ")
    }

    func log() {
        let line = summary
        guard !line.isEmpty else { return }
        Self.logger.notice("timeline \(line, privacy: .public)")
    }

    static func logListener(inputMonitoring: Bool, accessibility: Bool, listening: Bool) {
        logger.notice("global-key inputMonitoring=\(inputMonitoring, privacy: .public) accessibility=\(accessibility, privacy: .public) listening=\(listening, privacy: .public)")
    }
}
