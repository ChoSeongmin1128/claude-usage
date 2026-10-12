import SwiftUI

struct MenuBarPresetsSection: View {
    let provider: AppProviderKind
    @ObservedObject var settings: AppSettings
    @ObservedObject var antigravity: AntigravitySettingsViewModel
    @ObservedObject private var store: MenuBarPresetStore
    @StateObject private var model: MenuBarPresetEditorModel
    let limits: [UsageLimit]
    let codexUsage: CodexUsageResponse?
    let preview: (MenuBarPresetDisplay) -> MenuBarPresetPreviewImage?

    init(
        provider: AppProviderKind, settings: AppSettings, antigravity: AntigravitySettingsViewModel,
        limits: [UsageLimit], codexUsage: CodexUsageResponse?,
        preview: @escaping (MenuBarPresetDisplay) -> MenuBarPresetPreviewImage?
    ) {
        self.provider = provider
        self.settings = settings
        self.antigravity = antigravity
        self.limits = limits
        self.codexUsage = codexUsage
        self.preview = preview
        _store = ObservedObject(wrappedValue: settings.menuBarPresets)
        _model = StateObject(
            wrappedValue: MenuBarPresetEditorModel(
                provider: provider, store: settings.menuBarPresets,
                application: MenuBarPresetApplication(settings: settings, antigravity: antigravity)))
    }

    var body: some View {
        let selection = model.selection(limits: limits, codexUsage: codexUsage)
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: AppDesign.Control.presetTileMinimumWidth), spacing: AppDesign.Space.label)
                ], spacing: AppDesign.Space.label
            ) {
                ForEach(MenuBarPresetCatalog.presets(for: provider)) { preset in
                    let reference = MenuBarPresetReference.builtin(
                        preset,
                        selectedQuotaIDs: provider == .antigravity && preset == .concentric
                            ? model.application.selectedAntigravityQuotaIDs().prefix(2).map { $0 } : nil)
                    MenuBarPresetTile(
                        title: preset.title, isBuiltin: true,
                        isSelected: selection.checked?.origin == .builtin && selection.checked?.id == preset.id,
                        apply: { Task { await model.applyBuiltin(preset) } }
                    ) {
                        previewContent(model.application.display(for: reference, provider: provider))
                    } editing: {
                        EmptyView()
                    }
                }
                ForEach(store.presets.filter { $0.provider == provider }) { preset in
                    MenuBarPresetTile(
                        title: preset.name, isBuiltin: false, isSelected: selection.checked == .user(preset),
                        apply: { Task { await model.applyUser(preset.id) } }
                    ) {
                        previewContent(preset.display)
                    } editing: {
                        Menu {
                            Button("이름 변경") { model.beginNaming(.rename(preset.id)) }
                            Button("삭제", role: .destructive) { model.pendingDelete = preset.id }
                        } label: {
                            Image(systemName: "pencil").font(AppDesign.Typography.body)
                                .frame(
                                    width: AppDesign.Control.regularHitSize, height: AppDesign.Control.regularHitSize)
                        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                            .fixedSize().help("\(preset.name) 편집").accessibilityLabel("\(preset.name) 편집")
                    }
                }
                Button {
                    model.beginNaming(.new)
                } label: {
                    VStack(alignment: .leading, spacing: AppDesign.Space.compact) {
                        Image(systemName: "plus").font(AppDesign.Typography.headline)
                        Text("프리셋 추가").font(AppDesign.Typography.body.weight(.medium))
                        Text("현재 설정 저장").font(AppDesign.Typography.caption).foregroundStyle(AppDesign.Text.secondary)
                    }.frame(
                        maxWidth: .infinity, minHeight: AppDesign.Control.presetTileHeight,
                        maxHeight: AppDesign.Control.presetTileHeight, alignment: .leading
                    )
                    .padding(.horizontal, AppDesign.Space.row)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppDesign.Radius.card)
                            .stroke(AppDesign.Surface.boundary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }.buttonStyle(.plain)
            }
            .disabled(
                model.isApplying || !store.isWritable || (provider == .antigravity && antigravity.state.activity.isBusy)
            )
            if selection.isModified, let source = selection.sourceName {
                HStack {
                    Text("\(source)에서 수정됨").font(AppDesign.Typography.caption).foregroundStyle(AppDesign.Text.secondary)
                    Spacer(minLength: AppDesign.Space.row)
                    if selection.canUpdate { Button("변경 저장") { model.saveChanges() }.buttonStyle(.borderedProminent) }
                    Button("새로 저장") { model.beginNaming(.new) }.buttonStyle(.bordered)
                }
            }
            if !store.isWritable {
                Text(MenuBarPresetStoreError.unavailableStorage.message).font(AppDesign.Typography.caption)
                    .foregroundStyle(AppDesign.Text.secondary)
            }
            if let error = model.errorMessage, model.naming == nil, model.choosingQuotaIDs == nil {
                Text(error).font(AppDesign.Typography.caption).foregroundStyle(AppStatusTone.failure.color)
            }
        }
        .sheet(isPresented: Binding(get: { model.naming != nil }, set: { if !$0 { model.cancel() } })) { nameSheet }
        .sheet(isPresented: Binding(get: { model.choosingQuotaIDs != nil }, set: { if !$0 { model.cancel() } })) {
            quotaSheet
        }
        .confirmationDialog(
            "이 프리셋을 삭제할까요?",
            isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) { model.deleteConfirmed() }
            Button("취소", role: .cancel) { model.cancel() }
        } message: {
            Text("현재 메뉴바 표시는 유지합니다.")
        }
    }

    @ViewBuilder private func previewContent(_ display: MenuBarPresetDisplay?) -> some View {
        if let display, let result = preview(display) {
            Image(nsImage: result.image).accessibilityLabel("메뉴바 미리보기")
                .accessibilityValue(result.accessibilityValue ?? "확인 전")
                .frame(height: AppDesign.Control.menuBarPreviewHeight, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading).clipped()
        } else {
            Text("확인 전").font(AppDesign.Typography.caption).foregroundStyle(AppDesign.Text.secondary).frame(
                height: AppDesign.Control.menuBarPreviewHeight)
        }
    }

    private var nameSheet: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.section) {
            Text(model.naming == .new ? "프리셋 추가" : "이름 변경").font(AppDesign.Typography.headline)
            TextField("프리셋 이름", text: $model.name).textFieldStyle(.roundedBorder).onSubmit { model.saveName() }
            if let error = model.errorMessage {
                Text(error).font(AppDesign.Typography.caption).foregroundStyle(AppStatusTone.failure.color)
            }
            HStack {
                Spacer()
                Button("취소") { model.cancel() }.keyboardShortcut(.cancelAction)
                Button("저장") { model.saveName() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(AppDesign.Space.window).frame(width: AppDesign.Window.presetNameWidth)
    }

    private var quotaSheet: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            Text("동심원에 표시할 두 한도").font(AppDesign.Typography.headline)
            Text("첫 번째 한도는 바깥쪽, 두 번째는 안쪽에 표시합니다.").font(AppDesign.Typography.caption).foregroundStyle(
                AppDesign.Text.secondary)
            ForEach(limits) { limit in
                let selected = model.choosingQuotaIDs?.contains(limit.id) == true
                Toggle(
                    limit.title,
                    isOn: Binding(
                        get: { selected },
                        set: { value in
                            var ids = model.choosingQuotaIDs ?? []
                            if value, ids.count < 2, !ids.contains(limit.id) {
                                ids.append(limit.id)
                            } else if !value {
                                ids.removeAll { $0 == limit.id }
                            }
                            model.choosingQuotaIDs = ids
                        })
                ).toggleStyle(.checkbox).disabled(
                    !selected && (limit.usedPercentage == nil || model.choosingQuotaIDs?.count == 2)
                )
                .frame(minHeight: AppDesign.Control.settingsRowHeight)
            }
            if limits.isEmpty {
                Text("사용량을 확인한 뒤 한도를 선택할 수 있습니다.").font(AppDesign.Typography.caption).foregroundStyle(
                    AppDesign.Text.secondary)
            }
            if let error = model.errorMessage {
                Text(error).font(AppDesign.Typography.caption).foregroundStyle(AppStatusTone.failure.color)
            }
            HStack {
                Spacer()
                Button("취소") { model.cancel() }.keyboardShortcut(.cancelAction)
                Button("적용") { Task { await model.applyBuiltin(.concentric, quotaIDs: model.choosingQuotaIDs) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.choosingQuotaIDs?.count != 2 || model.isApplying)
            }
        }.padding(AppDesign.Space.window).frame(width: AppDesign.Window.presetQuotaWidth)
    }
}
