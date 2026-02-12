//
//  Logger.swift
//  ClaudeUsage
//
//  Phase 1: 디버그 로깅 유틸리티
//

import Foundation

/// 로그 레벨
enum LogLevel: Sendable {
    case debug
    case info
    case warning
    case error

    nonisolated var emoji: String {
        switch self {
        case .debug:   return "🔍"
        case .info:    return "ℹ️"
        case .warning: return "⚠️"
        case .error:   return "❌"
        }
    }

    nonisolated var label: String {
        switch self {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARN"
        case .error:   return "ERROR"
        }
    }
}

/// 간단한 로거 (DEBUG 빌드에서만 출력)
enum Logger {
    /// 로그 출력
    nonisolated static func log(_ message: String, level: LogLevel = .info, file: String = #file, line: Int = #line) {
        #if DEBUG
        let fileName = (file as NSString).lastPathComponent
        let timestamp = Self.formatTimestamp()
        print("\(level.emoji) [\(timestamp)] [\(level.label)] \(fileName):\(line) - \(message)")
        #endif
    }

    // MARK: - 편의 메서드

    nonisolated static func debug(_ message: String, file: String = #file, line: Int = #line) {
        log(message, level: .debug, file: file, line: line)
    }

    nonisolated static func info(_ message: String, file: String = #file, line: Int = #line) {
        log(message, level: .info, file: file, line: line)
    }

    nonisolated static func warning(_ message: String, file: String = #file, line: Int = #line) {
        log(message, level: .warning, file: file, line: line)
    }

    nonisolated static func error(_ message: String, file: String = #file, line: Int = #line) {
        log(message, level: .error, file: file, line: line)
    }

    // MARK: - Private

    nonisolated private static func formatTimestamp() -> String {
        let date = Date()
        let calendar = Calendar.current
        let h = calendar.component(.hour, from: date)
        let m = calendar.component(.minute, from: date)
        let s = calendar.component(.second, from: date)
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
