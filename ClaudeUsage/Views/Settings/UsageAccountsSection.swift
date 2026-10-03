import AppKit
import Combine
import SwiftUI

/// 계정 패널 맨 위의 계정 목록. 계정이 1개면 지금 화면 그대로이고, 2개째가 연결되면 팝오버가 여러 계정 화면으로 바뀐다.
struct UsageAccountsSection: View {
    @ObservedObject var controller: UsageAccountsController
    let service: PopoverService
    var onLoginClaude: () -> Void
    /// 앱이 저장한 Claude 웹 로그인을 지운다. 인자는 웹 계정 id.
    var onDeleteWebLogin: ((String) -> Void)?
    @State private var isAdding = false
    @State private var deletingWebLogin: UsageAccount?
    @State private var renaming: UsageAccount?
    @State private var newName = ""
    @State private var switching: SwitchRequest?
    @State private var isSwitching = false
    @State private var switchResult: String?

    struct SwitchRequest: Identifiable {
        let account: UsageAccount
        let running: CodexAccountSwitcher.RunningCodex?
        var id: String { account.id }
    }

    private var all: [UsageAccount] { controller.orderedAccounts(for: service) }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            HStack {
                Text("계정").font(AppDesign.Typography.headline)
                Spacer()
                Button("계정 추가") { isAdding = true }.controlSize(.small)
            }
            Toggle(
                isOn: Binding(
                    get: { controller.preferences.isMultiAccountEnabled },
                    set: { controller.setMultiAccountEnabled($0) })
            ) {
                VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                    Text("여러 계정")
                    Text("Claude와 Codex 계정 여러 개의 한도를 팝오버에 함께 보여주고, 쓰지 않는 계정도 5분마다 확인합니다. 끄면 메뉴바 계정 하나만 보입니다.")
                        .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
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
                    Text("계정을 바꾸는 중").font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(all) { account in row(account) }
            if all.isEmpty {
                Text("연결된 계정이 없습니다.").font(AppDesign.Typography.caption).foregroundStyle(.secondary)
            }
            if controller.isMultiAccount(service) {
                Picker("팝오버 보기", selection: $controller.preferences.popoverMode) {
                    ForEach(UsageAccountPreferences.PopoverMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("메뉴바와 팝오버 큰 카드는 메뉴바에 표시한 계정 하나입니다. 숨긴 계정은 지우지 않으며 여기서 다시 보이게 할 수 있습니다.")
                    .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $isAdding) {
            AddUsageAccountSheet(controller: controller, service: service, onLoginClaude: onLoginClaude) {
                isAdding = false
            }
        }
        .confirmationDialog(
            switchTitle, isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } }),
            presenting: switching
        ) { request in
            Button(request.running?.isEmpty == false ? "종료하고 전환" : "전환") { perform(request) }
            Button("취소", role: .cancel) { switching = nil }
        } message: { request in
            Text(switchMessage(request))
        }
        .alert(
            "계정 전환", isPresented: Binding(get: { switchResult != nil }, set: { if !$0 { switchResult = nil } })
        ) {
            Button("확인") { switchResult = nil }
        } message: {
            Text(switchResult ?? "")
        }
        .confirmationDialog(
            "저장한 웹 로그인을 지울까요?",
            isPresented: Binding(get: { deletingWebLogin != nil }, set: { if !$0 { deletingWebLogin = nil } }),
            presenting: deletingWebLogin
        ) { account in
            Button("지우기", role: .destructive) {
                if let webID = webLoginID(account) { onDeleteWebLogin?(webID) }
                deletingWebLogin = nil
            }
            Button("취소", role: .cancel) { deletingWebLogin = nil }
        } message: { account in
            Text(
                "\(controller.preferences.displayName(for: account, among: all))의 로그인을 이 앱에서 지웁니다. 브라우저와 Claude 앱의 로그인은 그대로입니다."
            )
        }
        .alert(
            "이름 바꾸기",
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField("이름", text: $newName)
            Button("저장") {
                if let renaming { controller.rename(renaming.id, to: newName) }
                renaming = nil
            }
            Button("취소", role: .cancel) { renaming = nil }
        }
    }

    private func row(_ account: UsageAccount) -> some View {
        let hidden = controller.preferences.hidden.contains(account.id)
        let archived = controller.preferences.archived.contains(account.id)
        let state = controller.states[account.id]
        return HStack(spacing: AppDesign.Space.row) {
            Text(controller.preferences.displayName(for: account, among: all))
                .font(AppDesign.Typography.subheadline)
                .lineLimit(1)
            if controller.isRuntimeAccount(account) { InUseAccountLabel() }
            ForEach(account.badges, id: \.self) { AccountBadgeView(badge: $0, service: service) }
            Spacer(minLength: AppDesign.Space.row)
            Text(statusText(account: account, state: state, hidden: hidden, archived: archived))
                .font(AppDesign.Typography.caption)
                .foregroundStyle(.secondary)
            Menu {
                if controller.canShowInMenuBar(account) {
                    Button("메뉴바에 표시") { controller.showInMenuBar(account) }
                    Divider()
                }
                if controller.canSwitch(to: account) {
                    Button("이 계정으로 전환") {
                        switching = SwitchRequest(
                            account: account,
                            running: service == .codex ? CodexAccountSwitcher.runningCodex() : nil)
                    }
                    .disabled(isSwitching)
                    Divider()
                }
                if multi {
                    Button("이름 바꾸기") {
                        newName = controller.preferences.aliases[account.id] ?? ""
                        renaming = account
                    }
                    if !controller.isRuntimeAccount(account) {
                        Button(controller.preferences.pinnedTop == account.id ? "맨 위 고정 해제" : "맨 위에 고정") {
                            controller.preferences.pinnedTop =
                                controller.preferences.pinnedTop == account.id ? nil : account.id
                        }
                    }
                    Button(hidden ? "다시 보이기" : "숨기기") { controller.setHidden(!hidden, account.id) }
                        .disabled(!hidden && !controller.canHide(account))
                    if !controller.isRuntimeAccount(account) {
                        Button(archived ? "다시 조회" : "조회 멈추고 보관") { controller.setArchived(!archived, account) }
                    }
                }
                if account.sources.contains(where: { isUserAdded($0) }) {
                    Divider()
                    Button("목록에서 빼기") { controller.removeDirectory(account) }
                }
                if onDeleteWebLogin != nil, webLoginID(account) != nil {
                    Divider()
                    Button("저장한 웹 로그인 지우기", role: .destructive) { deletingWebLogin = account }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("계정 관리")
        }
        .opacity(hidden && multi ? 0.5 : 1)
        .padding(.vertical, AppDesign.Space.tight)
    }

    private var multi: Bool { controller.preferences.isMultiAccountEnabled }

    private var switchTitle: String { "\(service.providerKind.displayName) 기본 로그인 바꾸기" }

    private func switchMessage(_ request: SwitchRequest) -> String {
        let name = controller.preferences.displayName(for: request.account, among: all)
        if service == .codex {
            if let running = request.running, !running.isEmpty {
                return
                    "실행 중인 Codex가 있습니다(ChatGPT 앱 \(running.applications.count)개, 터미널 \(running.processes.count)개). 종료한 뒤 기본 로그인(~/.codex)을 \(name)(으)로 바꿉니다. 지금 기본 로그인은 그 계정의 폴더로 옮깁니다."
            }
            return "기본 로그인(~/.codex)을 \(name)(으)로 바꿉니다. 지금 기본 로그인은 그 계정의 폴더로 옮깁니다. 바꾼 뒤 확인하고, 다르면 되돌립니다."
        }
        return
            "기본 Claude Code 로그인을 \(name)(으)로 바꿉니다. 지금 기본 로그인은 그 계정의 폴더로 옮깁니다. macOS가 Keychain 사용을 물을 수 있고, 실행 중인 Claude Code는 30초 안에 새 로그인을 씁니다."
    }

    private func perform(_ request: SwitchRequest) {
        switching = nil
        isSwitching = true
        Task {
            let failure = await controller.switchDefault(to: request.account, terminating: request.running)
            isSwitching = false
            switchResult = failure ?? "기본 로그인을 바꿨습니다."
        }
    }

    private func webLoginID(_ account: UsageAccount) -> String? {
        account.sources.first { $0.kind == .claudeWeb }?.reference
    }

    private func isUserAdded(_ source: UsageAccountSource) -> Bool {
        controller.preferences.claudeDirectories.contains(source.reference)
            || controller.preferences.codexDirectories.contains(source.reference)
            || source.reference.hasPrefix(CodexHomeAccount.managedRoot.path)
    }

    private func statusText(account: UsageAccount, state: UsageAccountState?, hidden: Bool, archived: Bool) -> String {
        if controller.isRuntimeAccount(account) && (!hidden || !multi) { return "" }
        guard multi else { return "" }
        if hidden { return "숨김" }
        switch state?.status(isArchived: archived) ?? .checking {
        case .checking: return "확인 전"
        case .current: return state?.fetchedAt.map { OtherAccountRow.age(since: $0) } ?? ""
        case .stale: return "오래된 값"
        case .loginExpired: return "로그인 만료"
        case .needsPermission: return "허용 필요"
        case .archived: return "보관"
        }
    }
}

struct AddUsageAccountSheet: View {
    @ObservedObject var controller: UsageAccountsController
    let service: PopoverService
    var onLoginClaude: () -> Void
    var onDone: () -> Void
    @StateObject private var deviceLogin = CodexDeviceLogin()

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            Text("\(service.providerKind.displayName) 계정 추가").font(AppDesign.Typography.headline)
            if service == .claude {
                option("Claude 계정 로그인", "브라우저 로그인 가져오기 또는 앱 안 로그인") {
                    Button("로그인") {
                        onDone()
                        onLoginClaude()
                    }
                }
                option("Claude Code 폴더", "다른 Claude Code 로그인이 있는 CLAUDE_CONFIG_DIR 폴더") {
                    Button("선택") { chooseFolder() }
                }
            } else {
                option("새 Codex 계정 로그인", "앱이 만든 폴더에서 공식 codex 로그인을 엽니다. ~/.codex는 바꾸지 않습니다") {
                    Button("로그인") { deviceLogin.start { controller.addDirectory($0, service: .codex) } }
                        .disabled(deviceLogin.isRunning)
                }
                deviceLoginStatus
                option("Codex 폴더", "다른 Codex 로그인이 있는 CODEX_HOME 폴더") {
                    Button("선택") { chooseFolder() }
                }
            }
            Text("2개째가 연결되면 팝오버가 여러 계정 화면으로 바뀝니다.")
                .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("닫기") {
                    deviceLogin.cancel()
                    onDone()
                }
            }
        }
        .padding(AppDesign.Space.window)
        .frame(width: 440)
    }

    @ViewBuilder
    private var deviceLoginStatus: some View {
        switch deviceLogin.phase {
        case .idle: EmptyView()
        case .starting: ProgressView().controlSize(.small)
        case .waiting(let url, let code):
            VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                Text("아래 코드를 브라우저에 입력해 로그인하세요. 코드는 15분 동안 쓸 수 있습니다.")
                    .font(AppDesign.Typography.caption)
                HStack {
                    Text(code).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                    Link("로그인 페이지 열기", destination: url)
                }
            }
        case .succeeded: Label("연결했습니다", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Text(message).font(AppDesign.Typography.caption).foregroundStyle(.red)
        }
    }

    private func option<Trailing: View>(_ title: String, _ detail: String, @ViewBuilder trailing: () -> Trailing)
        -> some View
    {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                Text(title).font(AppDesign.Typography.subheadline.weight(.semibold))
                Text(detail).font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        controller.addDirectory(url, service: service)
        onDone()
    }
}

/// `CODEX_HOME=<앱 폴더> codex login --device-auth`를 실행하고 링크와 일회용 코드를 보여준다.
/// auth.json을 폴더 사이에 복사하지 않는다.
@MainActor
final class CodexDeviceLogin: ObservableObject {
    enum Phase: Equatable {
        case idle, starting, succeeded
        case waiting(URL, String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    private var process: Process?
    private var folder: URL?

    var isRunning: Bool { process?.isRunning == true }

    func start(onSuccess: @escaping @MainActor @Sendable (URL) -> Void) {
        guard !isRunning else { return }
        guard let codex = try? CodexOwnerCLI().resolvedExecutable() else {
            phase = .failed("Codex를 찾지 못했습니다. ChatGPT 앱이나 Codex CLI를 먼저 설치하세요.")
            return
        }
        let folder = CodexHomeAccount.managedRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            phase = .failed("계정 폴더를 만들지 못했습니다.")
            return
        }
        self.folder = folder
        let process = Process()
        process.executableURL = codex
        process.arguments = ["login", "--device-auth"]
        process.environment = [
            "HOME": FileManager.default.realHomeDirectory.path, "CODEX_HOME": folder.path,
            "PATH": CodexOwnerCLI.searchPath, "LANG": "en_US.UTF-8",
        ]
        process.currentDirectoryURL = folder
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            Task { @MainActor in self?.consume(text) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                output.fileHandleForReading.readabilityHandler = nil
                if status == 0, FileManager.default.fileExists(atPath: folder.appendingPathComponent("auth.json").path)
                {
                    self.phase = .succeeded
                    onSuccess(folder)
                } else if self.phase != .idle {
                    self.phase = .failed("로그인을 마치지 못했습니다. 다시 시도하세요.")
                    self.discardFolder()
                }
                self.process = nil
            }
        }
        phase = .starting
        do {
            try process.run()
            self.process = process
        } catch {
            phase = .failed("Codex 로그인을 시작하지 못했습니다.")
            discardFolder()
        }
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        phase = .idle
        process.terminate()
        discardFolder()
    }

    private var buffer = ""

    private func consume(_ text: String) {
        buffer += text
        guard let urlRange = buffer.range(of: #"https://auth\.openai\.com/\S+"#, options: .regularExpression),
            let url = URL(string: String(buffer[urlRange]))
        else { return }
        let code = buffer.range(of: #"\b[A-Z0-9]{4,}-[A-Z0-9]{4,}\b"#, options: .regularExpression).map {
            String(buffer[$0])
        }
        switch phase {
        case .starting, .waiting(_, ""): phase = .waiting(url, code ?? "")
        default: break
        }
    }

    /// 로그인을 마치지 못한 빈 폴더만 휴지통으로 옮긴다.
    private func discardFolder() {
        guard let folder else { return }
        try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        self.folder = nil
    }
}
