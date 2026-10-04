import SwiftUI

struct ReleaseNotesButton: View {
    enum Presentation {
        case shortcut
        case history
    }

    var presentation: Presentation = .shortcut
    @State private var isPresented = false

    var body: some View {
        button
            .help("현재 버전과 이전 버전의 변경 내역을 봅니다")
            .sheet(isPresented: $isPresented) {
                ReleaseNotesView(notes: BundledReleaseNotes.load()) { isPresented = false }
            }
    }

    @ViewBuilder
    private var button: some View {
        switch presentation {
        case .shortcut:
            Button("변경 내역") { isPresented = true }
                .buttonStyle(.link)
                .controlSize(.small)
        case .history:
            Button("버전별 변경 내역") { isPresented = true }
                .buttonStyle(.bordered)
        }
    }
}

struct UpdateHistoryActions: View {
    var onShowWhatsNew: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            Text("변경 내역")
                .font(AppDesign.Typography.subheadline.weight(.semibold))
            HStack(spacing: AppDesign.Space.content) {
                ReleaseNotesButton(presentation: .history)
                if let onShowWhatsNew {
                    Button("새 기능 다시 보기", action: onShowWhatsNew)
                        .buttonStyle(.link)
                        .controlSize(.small)
                        .help("열려 있는 안내의 같은 페이지로 돌아가거나 최신 새 기능을 다시 봅니다")
                }
            }
        }
    }
}

struct ReleaseNotesView: View {
    let notes: [BundledReleaseNote]
    let onClose: () -> Void
    @State private var selectedVersion: String?

    init(notes: [BundledReleaseNote], selectedVersion: String? = nil, onClose: @escaping () -> Void) {
        self.notes = notes
        self.onClose = onClose
        _selectedVersion = State(
            initialValue: notes.first(where: { $0.id == selectedVersion })?.id ?? notes.first?.id)
    }

    private var selectedNote: BundledReleaseNote? {
        notes.first { $0.id == selectedVersion }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            HStack {
                Text("변경 내역").font(AppDesign.Typography.headline)
                Spacer()
                if !notes.isEmpty {
                    Picker("버전", selection: $selectedVersion) {
                        ForEach(notes) { note in
                            Text("v\(note.version)").tag(Optional(note.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("변경 내역 버전")
                }
            }

            if notes.isEmpty {
                VStack(alignment: .leading, spacing: AppDesign.Space.row) {
                    Text("변경 내역을 찾지 못했습니다")
                        .font(AppDesign.Typography.subheadline.weight(.semibold))
                    Text("이 앱에 포함된 변경 내역이 없습니다.")
                        .font(AppDesign.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let selectedNote {
                Divider()
                ScrollView {
                    ReleaseNotesDocumentView(note: selectedNote)
                }
                .id(selectedNote.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            HStack {
                Text("앱에 포함된 버전별 변경 내역")
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("닫기", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(AppDesign.Space.window)
        .frame(width: 720, height: 540)
    }
}

private struct ReleaseNotesDocumentView: View {
    let note: BundledReleaseNote

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            ForEach(note.blocks) { block in
                switch block.kind {
                case .heading:
                    Text(inlineMarkdown(block.text))
                        .font(AppDesign.Typography.subheadline.weight(.semibold))
                        .padding(.top, AppDesign.Space.control)
                        .accessibilityAddTraits(.isHeader)
                case .paragraph:
                    Text(inlineMarkdown(block.text))
                        .font(AppDesign.Typography.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                case .bullet:
                    HStack(alignment: .top, spacing: AppDesign.Space.row) {
                        Text("\u{2022}").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(inlineMarkdown(block.text))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(AppDesign.Typography.subheadline)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
