import AppKit
import SwiftUI

/// 계정 패널 맨 위의 계정 목록. 여러 계정 설정은 서비스마다 따로 정한다.
struct UsageAccountsSection: View {
    @ObservedObject var controller: UsageAccountsController
    let service: PopoverService
    /// 앱 화면이 처리하는 계정 추가 방법(브라우저에서 가져오기, 앱에서 로그인, 세션 키 직접 입력)
    var onAdd: (UsageAccountAddMethod) -> Void
    /// 앱에 저장한 웹 로그인을 지운다. 인자는 웹 로그인 id.
    var onDeleteWebLogin: (String) -> Void
    @State private var isAdding = false
    @State private var deletingWebLogin: UsageAccount?
    @State private var deletingManagedLogin: UsageAccount?
    @State private var managedLoginDeleteFailed = false
    @State private var renaming: UsageAccount?
    @State private var newName = ""
    @State private var switching: SwitchRequest?
    @State private var isSwitching = false
    @State private var switchResult: String?

    struct SwitchRequest: Identifiable {
        let account: UsageAccount
        let plan: UsageAccountSwitchPlan
        var id: String { account.id }
    }

    private var accounts: [UsageAccount] { controller.orderedAccounts(for: service) }
    private var isMultiAccountEnabled: Bool { controller.isMultiAccountEnabled(service) }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            HStack {
                Text("계정").font(AppDesign.Typography.headline)
                Spacer()
                Button("계정 추가") { isAdding = true }.controlSize(.small)
            }
            Toggle(
                "여러 계정 함께 보기",
                isOn: Binding(
                    get: { isMultiAccountEnabled },
                    set: { controller.setMultiAccountEnabled($0, for: service) })
            )
            .toggleStyle(.switch)
            .help("켜 두면 다른 계정의 사용량도 5분마다 확인합니다.")
            Text("계정별 사용량을 함께 봅니다. 끄면 선택한 계정만 표시합니다.")
                .font(AppDesign.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = controller.revertedSwitch[service] {
                HStack {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(AppDesign.Typography.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("확인") { controller.dismissRevertNotice(service) }.controlSize(.small)
                }
            }
            if isSwitching {
                HStack(spacing: AppDesign.Space.row) {
                    ProgressView().controlSize(.small)
                    Text("전환 중").font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(accounts) { account in row(account) }
            if controller.isMultiAccount(service) {
                Picker(
                    "팝오버 보기",
                    selection: Binding(
                        get: { controller.popoverMode(for: service) },
                        set: { controller.setPopoverMode($0, for: service) })
                ) {
                    ForEach(UsageAccountPreferences.PopoverMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .sheet(isPresented: $isAdding) {
            if let provider = controller.provider(for: service) {
                AddUsageAccountSheet(controller: controller, provider: provider, onAdd: onAdd) { isAdding = false }
            }
        }
        .confirmationDialog(
            "\(service.displayName) 기본 로그인 전환",
            isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } }),
            presenting: switching
        ) { request in
            Button(request.plan.confirmTitle) { perform(request) }
            Button("취소", role: .cancel) { switching = nil }
        } message: { request in
            Text(request.plan.message)
        }
        .alert(
            "기본 로그인 전환", isPresented: Binding(get: { switchResult != nil }, set: { if !$0 { switchResult = nil } })
        ) {
            Button("확인") { switchResult = nil }
        } message: {
            Text(switchResult ?? "")
        }
        .confirmationDialog(
            "웹 로그인을 지울까요?",
            isPresented: Binding(get: { deletingWebLogin != nil }, set: { if !$0 { deletingWebLogin = nil } }),
            presenting: deletingWebLogin
        ) { account in
            Button("지우기", role: .destructive) {
                if let web = account.source(.web) { onDeleteWebLogin(web.reference) }
                deletingWebLogin = nil
            }
            Button("취소", role: .cancel) { deletingWebLogin = nil }
        } message: { _ in
            Text("이 앱에 저장한 로그인만 지웁니다. 브라우저와 Claude 앱의 로그인은 그대로입니다.")
        }
        .confirmationDialog(
            "로그인 폴더를 휴지통으로 옮길까요?",
            isPresented: Binding(get: { deletingManagedLogin != nil }, set: { if !$0 { deletingManagedLogin = nil } }),
            presenting: deletingManagedLogin
        ) { account in
            Button("휴지통으로 옮기기", role: .destructive) {
                managedLoginDeleteFailed = !controller.deleteManagedLogin(account)
                deletingManagedLogin = nil
            }
            Button("취소", role: .cancel) { deletingManagedLogin = nil }
        } message: { _ in
            Text("이 앱에서 추가한 로그인입니다. 다시 보려면 계정을 새로 추가해야 합니다.")
        }
        .alert("로그인 폴더를 옮기지 못했습니다", isPresented: $managedLoginDeleteFailed) {
            Button("확인") { managedLoginDeleteFailed = false }
        }
        .alert("이름 바꾸기", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("이름", text: $newName)
            Button("저장") {
                if let renaming { controller.rename(renaming, to: newName) }
                renaming = nil
            }
            Button("취소", role: .cancel) { renaming = nil }
        }
    }

    private func row(_ account: UsageAccount) -> some View {
        let hidden = controller.isHidden(account)
        let isRuntime = controller.isRuntime(account)
        return HStack(spacing: AppDesign.Space.row) {
            Text(controller.displayName(for: account))
                .font(AppDesign.Typography.subheadline)
                .lineLimit(1)
            if isRuntime { InUseAccountLabel() }
            ForEach(controller.badges(for: account), id: \.self) { AccountBadgeView(badge: $0) }
            Spacer(minLength: AppDesign.Space.row)
            Text(statusText(account, hidden: hidden, isRuntime: isRuntime))
                .font(AppDesign.Typography.caption)
                .foregroundStyle(.secondary)
                .help(
                    controller.states[account.id]?.issue == .executableNotFound
                        ? ClaudeCodeCredentialIssue.executableNotFoundExplanation : "")
            Menu {
                menuItems(account, hidden: hidden, isRuntime: isRuntime)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("계정 관리")
        }
        .opacity(hidden && isMultiAccountEnabled ? 0.5 : 1)
        .padding(.vertical, AppDesign.Space.tight)
    }

    @ViewBuilder
    private func menuItems(_ account: UsageAccount, hidden: Bool, isRuntime: Bool) -> some View {
        if controller.canShowInMenuBar(account) {
            Button("메뉴바에 표시") { controller.showInMenuBar(account) }
            Divider()
        }
        if controller.canSwitch(to: account) {
            Button("이 계정으로 전환") {
                if let plan = controller.switchPlan(for: account) {
                    switching = SwitchRequest(account: account, plan: plan)
                }
            }
            .disabled(isSwitching)
            Divider()
        }
        if isMultiAccountEnabled {
            Button("이름 바꾸기") {
                newName = controller.alias(for: account)
                renaming = account
            }
            if !isRuntime {
                Button(controller.isPinned(account) ? "고정 해제" : "맨 위에 고정") { controller.togglePinned(account) }
            }
            Button(hidden ? "보이기" : "숨기기") { controller.setHidden(!hidden, account) }
                .disabled(!hidden && !controller.canHide(account))
            if !isRuntime {
                let archived = controller.isArchived(account)
                Button(archived ? "보관 해제" : "보관") { controller.setArchived(!archived, account) }
            }
        }
        if controller.isUserAdded(account) {
            Divider()
            Button("목록에서 빼기") { controller.removeDirectory(account) }
        } else if !controller.managedFolders(of: account).isEmpty {
            Divider()
            Button("로그인 지우기", role: .destructive) { deletingManagedLogin = account }
        }
        if account.source(.web) != nil {
            Divider()
            Button("웹 로그인 지우기", role: .destructive) { deletingWebLogin = account }
        }
    }

    private func perform(_ request: SwitchRequest) {
        switching = nil
        isSwitching = true
        Task {
            let failure = await controller.switchDefault(to: request.account, plan: request.plan)
            isSwitching = false
            switchResult = failure ?? "전환했습니다."
        }
    }

    private func statusText(_ account: UsageAccount, hidden: Bool, isRuntime: Bool) -> String {
        guard isMultiAccountEnabled else { return "" }
        if hidden { return "숨김" }
        if isRuntime { return "" }
        let state = controller.states[account.id] ?? UsageAccountState()
        switch state.status(isArchived: controller.isArchived(account)) {
        case .checking: return "확인 중"
        case .current: return state.fetchedAt.map { TimeFormatter.elapsed(since: $0) } ?? ""
        case .stale: return UsageStatusLabel.previousValue
        case .failed: return "확인 실패"
        case .loginExpired: return "로그인 만료"
        case .needsPermission: return "허용 필요"
        case .executableNotFound: return "Claude Code 없음"
        case .archived: return "보관"
        }
    }
}

struct AddUsageAccountSheet: View {
    @ObservedObject var controller: UsageAccountsController
    let provider: any UsageAccountProvider
    var onAdd: (UsageAccountAddMethod) -> Void
    var onDone: () -> Void
    @StateObject private var deviceLogin = CodexDeviceLogin()

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            Text("\(provider.service.displayName) 계정 추가").font(AppDesign.Typography.headline)
            ForEach(provider.addMethods, id: \.self) { method in
                option(method)
                if method == .deviceLogin { deviceLoginStatus }
            }
            HStack {
                Spacer()
                Button("닫기") { onDone() }
            }
        }
        .padding(AppDesign.Space.window)
        .frame(width: 440)
        // 다른 방법을 고르거나 Esc로 닫아도 진행 중인 기기 로그인을 남기지 않는다.
        .onDisappear { deviceLogin.cancel() }
    }

    @ViewBuilder
    private func option(_ method: UsageAccountAddMethod) -> some View {
        switch method {
        case .browserImport:
            row("브라우저에서 가져오기", nil) { Button("가져오기") { handOff(method) } }
        case .inAppLogin:
            row("앱에서 로그인", nil) { Button("로그인") { handOff(method) } }
        case .sessionKey:
            row("세션 키 직접 입력", nil) { Button("입력") { handOff(method) } }
        case .deviceLogin:
            row("새 \(provider.cliName) 계정 로그인", "지금 쓰는 \(provider.cliName) 로그인은 그대로 둡니다") {
                Button("로그인") {
                    deviceLogin.start { [controller, provider] folder in
                        controller.addDirectory(folder, service: provider.service)
                    }
                }
                .disabled(deviceLogin.isRunning)
            }
        case .folder:
            row("\(provider.cliName) 폴더", provider.configDirectoryVariable) { Button("선택") { chooseFolder() } }
        }
    }

    private func handOff(_ method: UsageAccountAddMethod) {
        onDone()
        onAdd(method)
    }

    @ViewBuilder
    private var deviceLoginStatus: some View {
        switch deviceLogin.phase {
        case .idle: EmptyView()
        case .starting: ProgressView().controlSize(.small)
        case .waiting(let url, let code):
            VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                Text("로그인 페이지에 아래 코드를 입력하세요.").font(AppDesign.Typography.caption)
                HStack {
                    Text(code).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                    Link("로그인 페이지 열기", destination: url)
                }
            }
        case .succeeded: Label("추가했습니다", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Text(message).font(AppDesign.Typography.caption).foregroundStyle(.red)
        }
    }

    private func row<Trailing: View>(_ title: String, _ detail: String?, @ViewBuilder trailing: () -> Trailing)
        -> some View
    {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                Text(title).font(AppDesign.Typography.subheadline.weight(.semibold))
                if let detail {
                    Text(detail).font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            trailing().controlSize(.small)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.realHomeDirectory
        panel.prompt = "추가"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.addDirectory(url, service: provider.service)
        onDone()
    }
}
