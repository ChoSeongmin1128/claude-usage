import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Claude/Codex/Gemini/Antigravity 모두 공용인 "표시 항목" 설정 섹션.
/// provider별 분기 없이 `PopoverService`와 AppSettings만으로 동작합니다.
struct PopoverItemsSectionView: View {
    @ObservedObject var settings: AppSettings
    let service: PopoverService
    let title: String
    let systemImage: String
    let subtitle: String
    @Binding var compactConfigTab: Int
    @State private var draggingItemID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.separateCompactConfig {
                Picker("", selection: $compactConfigTab) {
                    Text("기본").tag(0)
                    Text("간소화").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            itemsList(isCompact: isEditingCompact)
        }
    }

    private var isEditingCompact: Bool {
        settings.separateCompactConfig && compactConfigTab == 1
    }

    @ViewBuilder
    private func itemsList(isCompact: Bool) -> some View {
        let items = isCompact
            ? settings.compactPopoverItems(for: service)
            : settings.popoverItems(for: service)

        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14)

                        Button {
                            var updated = items
                            updated[index].visible.toggle()
                            if isCompact {
                                settings.setCompactPopoverItems(updated, for: service)
                            } else {
                                settings.setPopoverItems(updated, for: service)
                            }
                        } label: {
                            Image(systemName: item.visible ? "eye" : "eye.slash")
                                .foregroundStyle(item.visible ? .primary : .tertiary)
                                .font(.system(size: 12))
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless)

                        Text(item.displayName)
                            .font(.subheadline)
                            .foregroundStyle(item.visible ? .primary : .tertiary)

                        Spacer()
                    }
                    .frame(height: 26)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())

                    if index < items.count - 1 {
                        Divider().padding(.horizontal, 8)
                    }
                }
                .background(draggingItemID == item.id ? Color.accentColor.opacity(0.1) : Color.clear)
                .cornerRadius(4)
                .onDrag {
                    draggingItemID = item.id
                    return NSItemProvider(object: item.id as NSString)
                }
                .onDrop(of: [.text], delegate: PopoverItemDropDelegate(
                    targetID: item.id,
                    settings: settings,
                    isCompact: isCompact,
                    service: service,
                    draggingItemID: $draggingItemID
                ))
            }
        }
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }
}
