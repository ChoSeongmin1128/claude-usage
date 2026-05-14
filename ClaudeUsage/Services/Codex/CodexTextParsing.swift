import Foundation

/// 터미널 출력 텍스트 파싱 유틸리티.
///
/// Codex CLI 의 `/status` 슬래시 명령 응답은 ANSI escape sequence + 사람 친화 텍스트로 나온다.
/// 그 텍스트에서 사용량 % / Credits / reset 시각 같은 필드를 추출하는 데 사용.
///
/// 출처: CodexBar (MIT License) Sources/CodexBarCore/TextParsing.swift
/// Copyright (c) 2026 Peter Steinberger
/// https://github.com/steipete/CodexBar
enum CodexTextParsing {
    /// CSI escape sequence (ESC [ ... ending in 0x40–0x7E) 제거.
    /// regex 매칭 전 단계에서 정규화 — 색상/커서 제어 코드가 패턴 매칭을 방해하지 않게.
    static func stripANSICodes(_ text: String) -> String {
        let pattern = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    static func firstNumber(pattern: String, text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        let raw = String(text[r])
        return Self.parseNumber(raw)
    }

    static func firstInt(pattern: String, text: String) -> Int? {
        guard let value = firstNumber(pattern: pattern, text: text) else { return nil }
        return Int(value)
    }

    static func firstLine(matching pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let r = Range(match.range(at: 0), in: text) else { return nil }
        return String(text[r])
    }

    static func percentLeft(fromLine line: String) -> Int? {
        firstInt(pattern: #"([0-9]{1,3})%\s+left"#, text: line)
    }

    static func resetString(fromLine line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"resets?\s+(.+)"#, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: line)
        else { return nil }
        return String(line[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Number parsing helpers

    /// "1,234.56" / "1.234,56" / "1,234" 같은 로케일 변형을 Double 로 정규화.
    private static func parseNumber(_ raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "\u{00A0}", with: "")  // NBSP
        text = text.replacingOccurrences(of: "\u{202F}", with: "")  // narrow NBSP
        text = text.replacingOccurrences(of: " ", with: "")

        let hasComma = text.contains(",")
        let hasDot = text.contains(".")

        if hasComma, hasDot {
            if let lastComma = text.lastIndex(of: ","), let lastDot = text.lastIndex(of: ".") {
                if lastComma > lastDot {
                    // "1.234,56" → 유럽 스타일, 콤마가 소수점
                    text = text.replacingOccurrences(of: ".", with: "")
                    text = text.replacingOccurrences(of: ",", with: ".")
                } else {
                    // "1,234.56" → 영미 스타일, 콤마는 천 단위
                    text = text.replacingOccurrences(of: ",", with: "")
                }
            }
        } else if hasComma {
            // 천 단위 콤마인지 (1,234 / 12,345) 아니면 소수점 콤마인지 (1,5)
            if text.range(of: #"^\d{1,3}(,\d{3})+$"#, options: .regularExpression) != nil {
                text = text.replacingOccurrences(of: ",", with: "")
            } else {
                text = text.replacingOccurrences(of: ",", with: ".")
            }
        } else if hasDot {
            if text.range(of: #"^\d{1,3}(\.\d{3})+$"#, options: .regularExpression) != nil {
                // "1.234.567" → 유럽 천 단위
                text = text.replacingOccurrences(of: ".", with: "")
            }
        }

        return Double(text)
    }
}
