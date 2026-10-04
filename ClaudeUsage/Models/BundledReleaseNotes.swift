import Foundation

nonisolated struct BundledReleaseNote: Identifiable, Equatable, Sendable {
    let version: String
    let markdown: String

    var id: String { version }

    var blocks: [ReleaseNoteBlock] {
        ReleaseNoteBlock.parse(markdown, version: version)
    }
}

nonisolated enum BundledReleaseNotes {
    static func load(bundle: Bundle = .main, upTo currentVersion: String? = nil) -> [BundledReleaseNote] {
        guard let directory = bundle.url(forResource: "release-notes", withExtension: nil) else { return [] }
        let version = currentVersion ?? bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return load(directory: directory, upTo: version)
    }

    static func load(directory: URL, upTo currentVersion: String) -> [BundledReleaseNote] {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.compactMap { file -> BundledReleaseNote? in
            let version = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "md",
                version.range(of: #"^[0-9]+(?:\.[0-9]+){1,2}$"#, options: .regularExpression) != nil,
                !VersionOrder.isNewer(version, than: currentVersion),
                let markdown = try? String(contentsOf: file, encoding: .utf8),
                !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return BundledReleaseNote(version: version, markdown: markdown)
        }
        .sorted { VersionOrder.isNewer($0.version, than: $1.version) }
    }
}

nonisolated struct ReleaseNoteBlock: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case heading
        case paragraph
        case bullet
    }

    let id: Int
    let kind: Kind
    let text: String

    static func parse(_ markdown: String, version: String) -> [Self] {
        var blocks: [Self] = []
        var paragraph: [String] = []
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(Self(id: blocks.count, kind: .paragraph, text: paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }
        for line in markdown.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                flushParagraph()
            } else if text.hasPrefix("# ") && String(text.dropFirst(2)) == version {
                flushParagraph()
            } else if text.hasPrefix("#") {
                flushParagraph()
                let heading = text.drop(while: { $0 == "#" || $0 == " " })
                blocks.append(Self(id: blocks.count, kind: .heading, text: String(heading)))
            } else if text.hasPrefix("- ") {
                flushParagraph()
                blocks.append(Self(id: blocks.count, kind: .bullet, text: String(text.dropFirst(2))))
            } else {
                paragraph.append(text)
            }
        }
        flushParagraph()
        return blocks
    }
}
