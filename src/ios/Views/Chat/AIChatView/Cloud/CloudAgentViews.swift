//
//  CloudAgentViews.swift
//  Minis - VPS Cloud Agent UI
//

import SwiftUI
import VisionKit
import Combine

// MARK: - 1. Settings & Connection View
struct CloudAgentSettingsView: View {
    @ObservedObject private var connection = CloudConnection.shared
    @ObservedObject private var providerStore = ProviderConfigStore.shared

    @State private var passwordInput: String = ""
    @State private var tokenInput: String = ""
    @State private var isConnecting = false
    @State private var isInstalling = false
    @State private var errorMessage: String? = nil

    @AppStorage("OpenMinisCloud_selectedInstanceId") private var selectedProviderInstanceId: String = ""
    @AppStorage("OpenMinisCloud_manualModel") private var manualModel: String = ""
    @AppStorage("OpenMinisCloud_modelsByProvider") private var modelsByProvider = "{}"
    @AppStorage(CloudWorkContext.soulKey) private var includeSoul: Bool = true
    @AppStorage(CloudWorkContext.skillsKey) private var includeSkills: Bool = true
    @AppStorage(CloudWorkContext.memoryKey) private var includeMemory: Bool = false
    @StateObject private var modelCatalog = CloudModelCatalog()
    @State private var selectionOwner = ""
    @State private var modelSearch = ""
    private var matchingModels: [CloudModelChoice] {
        modelCatalog.models.filter { modelSearch.isEmpty || $0.id.localizedCaseInsensitiveContains(modelSearch) || $0.name.localizedCaseInsensitiveContains(modelSearch) }
    }

    private var availableOpenAIInstances: [ProviderInstance] {
        providerStore.config.instances.filter { inst in
            inst.isEnabled && inst.providerType == .openAI && inst.credentialType == .apiKey && !inst.azureMode
        }
    }

    var body: some View {
        Form {
            Section {
                NavigationLink(destination: CloudServersView()) {
                    Label("多台云电脑（切换 · 测负载）", systemImage: "server.rack")
                }
                .disabled(isConnecting || isInstalling)
            }
            Section {
                TextField("连接名称 (如: 我的云电脑)", text: $connection.name)
                    .disabled(isConnecting || isInstalling)
                TextField("IP地址 / 域名", text: $connection.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .disabled(isConnecting || isInstalling)
                HStack {
                    Text("SSH端口")
                    Spacer()
                    TextField("22", value: $connection.sshPort, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .disabled(isConnecting || isInstalling)
                }
                TextField("用户名", text: $connection.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .disabled(isConnecting || isInstalling)
                SecureField("SSH密码", text: $passwordInput)
                    .disabled(isConnecting || isInstalling)
                SecureField("Bearer Token (安装后自动写入)", text: $tokenInput)
                    .disabled(isConnecting || isInstalling)
            } header: {
                Text("云电脑服务器配置")
            } footer: {
                Text("密码与凭据保存在本地 Keychain (ThisDeviceOnly)，绝不在日志中明文记录。\n安装服务需要 Debian / Ubuntu 系统且账号具备 root 或免密 sudo 权限。")
            }

            Section {
                Picker("选择服务商", selection: $selectedProviderInstanceId) {
                    Text("请选择 OpenAI API Key 服务商").tag("")
                    ForEach(availableOpenAIInstances, id: \.id) { inst in
                        Text(inst.label).tag(inst.id)
                    }
                }
                NavigationLink {
                    List {
                        if let error = modelCatalog.error {
                            Text("刷新失败：\(error)").foregroundStyle(.red)
                        }
                        if modelCatalog.loading { HStack { ProgressView(); Text("正在获取在线模型…") } }
                        if matchingModels.isEmpty {
                            Text(modelCatalog.loading ? "正在加载…" : "没有匹配的模型，请刷新或更换搜索词").foregroundStyle(.secondary)
                        }
                        ForEach(matchingModels) { item in
                            Button {
                                manualModel = item.id
                                saveModelSelection()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.id).foregroundStyle(.primary)
                                        if item.name != item.id { Text(item.name).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    if manualModel == item.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                        }
                    }
                    .navigationTitle("选择云端模型")
                    .searchable(text: $modelSearch, prompt: "搜索模型名称或 ID")
                    .refreshable { await refreshCloudModels() }
                    .task { await refreshCloudModels() }
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button { Task { await refreshCloudModels() } } label: { Image(systemName: "arrow.clockwise") }
                                .disabled(modelCatalog.loading)
                        }
                    }
                } label: {
                    HStack {
                        Text("选择模型")
                        Spacer()
                        Text(manualModel.isEmpty ? "请选择" : manualModel).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .disabled(selectedProviderInstanceId.isEmpty)
                Button {
                    Task { await refreshCloudModels() }
                } label: {
                    HStack {
                        if modelCatalog.loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                        Text(modelCatalog.loading ? "正在刷新模型…" : "刷新在线模型（\(modelCatalog.models.count) 个）")
                    }
                }.disabled(modelCatalog.loading || selectedProviderInstanceId.isEmpty)
                if let error = modelCatalog.error {
                    Text("模型刷新失败：\(error)").font(.footnote).foregroundStyle(.red)
                }
                if !manualModel.isEmpty, !modelCatalog.loading, modelCatalog.refreshedAt != nil,
                   !modelCatalog.models.contains(where: { $0.id == manualModel }) {
                    Text("当前选择未出现在最新目录中，可重新选择或刷新后再确认。")
                        .font(.footnote).foregroundStyle(.orange)
                }
            } header: {
                Text("LLM 模型与凭据来源")
            } footer: {
                Text("自动从所选服务商获取在线模型；目录列出不代表已验证工具调用能力。模型分别按服务商记住。所选服务商密钥通过 SSH 传入 VPS 内存供任务调用。")
            }

            if connection.isConnected {
                CloudCredentialSection(selectedInstanceId: selectedProviderInstanceId)
                CloudNotifySection()
                CloudTelegramSection(selectedInstanceId: selectedProviderInstanceId)
            }

            Section {
                Toggle("同步灵魂与人设配置", isOn: $includeSoul)
                Toggle("同步技能说明 (仅 SKILL.md)", isOn: $includeSkills)
                Toggle("同步工作记忆 (GLOBAL 与最近日志)", isOn: $includeMemory)
            } header: {
                Text("云端工作配置")
            } footer: {
                Text("启用记忆会同步 GLOBAL.md 及最近 3 日日常日志，可能包含私密信息；普通会话历史与灵魂会发送至所选 VPS，服务商密钥仅在进程内存使用。默认不向 VPS 同步工作记忆。")
            }

            Section("连接与远端服务") {
                Button {
                    connectAction()
                } label: {
                    HStack {
                        if isConnecting {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Text(isConnecting ? "连接中..." : "保存并测试连接")
                    }
                }
                .disabled(isConnecting || isInstalling || connection.host.isEmpty)

                Button {
                    installAction(desktop: false)
                } label: {
                    HStack {
                        if isInstalling {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Text(isInstalling ? "正在部署安装..." : "安装 / 更新服务器 Agent 服务")
                    }
                }
                .disabled(isConnecting || isInstalling || connection.host.isEmpty || passwordInput.isEmpty)

                Button {
                    installAction(desktop: true)
                } label: {
                    HStack {
                        if isInstalling {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Text(isInstalling ? "正在部署安装..." : "安装 / 更新云电脑桌面环境 (Xvfb/noVNC)")
                    }
                }
                .disabled(isConnecting || isInstalling || connection.host.isEmpty || passwordInput.isEmpty)

                if isInstalling && !connection.installLog.isEmpty {
                    ScrollView {
                        Text(String(connection.installLog.suffix(3000)))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                }
            }

            if let pendingMsg = connection.pendingHostKeyMessage {
                Section("主机指纹首次确认") {
                    Text(pendingMsg)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.orange)
                    Button("确认指纹并接受连接") {
                        Task {
                            errorMessage = nil
                            do {
                                try await connection.acceptHostKeyAndConnect()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if connection.isConnected {
                Section("连接状态") {
                    HStack {
                        Circle().fill(Color.green).frame(width: 10, height: 10)
                        Text("已连接 (本机端口 \(connection.apiPort))")
                        Spacer()
                        Button("断开连接") {
                            connection.disconnect()
                        }
                        .foregroundColor(.red)
                    }

                    #if os(iOS)
                    NavigationLink(destination: CloudSessionsView(
                        model: manualModel,
                        selectedInstanceId: selectedProviderInstanceId
                    )) {
                        Label("进入云端会话列表", systemImage: "cloud.fill")
                            .font(.headline)
                            .foregroundColor(.accentColor)
                    }.disabled(manualModel.isEmpty || selectedProviderInstanceId.isEmpty)

                    NavigationLink(destination: CloudComputerView(botId: nil, sessionId: nil, reason: nil)) {
                        Label("查看 / 接管云电脑桌面", systemImage: "display")
                            .font(.headline)
                            .foregroundColor(.accentColor)
                    }
                    NavigationLink(destination: CloudResourceSettingsView()) {
                        Label("云电脑资源设置", systemImage: "gauge.with.dots.needle.67percent")
                            .font(.headline)
                            .foregroundColor(.accentColor)
                    }
                    #endif
                }
            }

            #if os(iOS)
            Section {
                NavigationLink(destination: CloudRoutinesView()) {
                    Label("云端例行任务", systemImage: "calendar.badge.clock")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                }

                NavigationLink(destination: CloudBotsView()) {
                    Label("我的 Bot", systemImage: "person.2.crop.square.stack")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                }

                NavigationLink(destination: CloudPluginsView()) {
                    Label("插件市场", systemImage: "puzzlepiece.extension")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                }
                .accessibilityIdentifier("pluginMarketRow")

                NavigationLink(destination: CloudMemoryTimelineView()) {
                    Label("记忆时间线", systemImage: "brain.head.profile")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                }

                NavigationLink(destination: CloudPagesView()) {
                    Label("云端页面库", systemImage: "doc.richtext")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                }
            } header: {
                Text("云电脑功能")
            } footer: {
                if !connection.isConnected {
                    Text("未连接时打开会自动尝试连接；若提示服务版本过旧，请先点「安装 / 更新服务器 Agent 服务」。")
                }
            }
            #endif

            if let err = errorMessage ?? (caseErrorString(connection.status)) {
                Section("错误与状态") {
                    Text(err)
                        .foregroundColor(.red)
                        .font(.footnote)
                    Button("重连 / 重试") {
                        connectAction()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle("云电脑设置")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refreshCloudModels() }
        .onAppear {
            reloadCredentialsForCurrentTarget()
            if selectedProviderInstanceId.isEmpty, let first = availableOpenAIInstances.first {
                selectedProviderInstanceId = first.id
            }
        }
        .task(id: selectedProviderInstanceId) {
            activateModelProvider()
            await refreshCloudModels()
        }
        .onChange(of: manualModel) { _ in saveModelSelection() }
        .onChange(of: connection.host) { _ in
            reloadCredentialsForCurrentTarget()
        }
        .onChange(of: connection.sshPort) { _ in
            reloadCredentialsForCurrentTarget()
        }
        .onChange(of: connection.username) { _ in
            reloadCredentialsForCurrentTarget()
        }
    }

    private func activateModelProvider() {
        guard selectionOwner != selectedProviderInstanceId else { return }
        var saved = (try? JSONDecoder().decode([String: String].self, from: Data(modelsByProvider.utf8))) ?? [:]
        if !selectionOwner.isEmpty { saved[selectionOwner] = manualModel }
        // 首次升级沿用原选择，切换服务商后只恢复该服务商的选择。
        if selectionOwner.isEmpty, saved[selectedProviderInstanceId] == nil, !manualModel.isEmpty {
            saved[selectedProviderInstanceId] = manualModel
        }
        selectionOwner = selectedProviderInstanceId
        manualModel = saved[selectedProviderInstanceId] ?? ""
        if let data = try? JSONEncoder().encode(saved), let text = String(data: data, encoding: .utf8) { modelsByProvider = text }
    }

    private func saveModelSelection() {
        guard !selectionOwner.isEmpty, selectionOwner == selectedProviderInstanceId else { return }
        var saved = (try? JSONDecoder().decode([String: String].self, from: Data(modelsByProvider.utf8))) ?? [:]
        saved[selectionOwner] = manualModel
        if let data = try? JSONEncoder().encode(saved), let text = String(data: data, encoding: .utf8) { modelsByProvider = text }
    }

    private func refreshCloudModels() async {
        let id = selectedProviderInstanceId
        await modelCatalog.refresh(providerID: id) {
            guard let instance = availableOpenAIInstances.first(where: { $0.id == id }) else {
                throw NSError(domain: "CloudModels", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先选择有效的服务商"])
            }
            guard let key = ProviderKeychainHelper.loadAPIKey(instanceId: id), !key.isEmpty else {
                throw NSError(domain: "CloudModels", code: 2, userInfo: [NSLocalizedDescriptionKey: "所选服务商尚未配置 API Key"])
            }
            let models = try await OpenAIModelsAPI.fetchModels(apiKey: key,
                baseURL: instance.effectiveCustomBaseURL, appendV1Suffix: instance.appendV1Suffix,
                forceRefresh: true, userAgent: instance.customUserAgent, includeNonChat: true)
            return models.map { CloudModelChoice(id: $0.id, name: $0.displayName) }
        }
        guard selectedProviderInstanceId == id, modelCatalog.providerID == id, !modelCatalog.loading else { return }
        // 获取目录不擅自切换模型，已有选择保留，新服务商由用户点选。
    }

    private func reloadCredentialsForCurrentTarget() {
        passwordInput = connection.getPassword() ?? ""
        tokenInput = connection.getToken() ?? ""
    }

    private func caseErrorString(_ status: CloudConnectionStatus) -> String? {
        if case .error(let msg) = status {
            return msg
        }
        return nil
    }

    private func connectAction() {
        errorMessage = nil
        do {
            try connection.saveCredentials(password: passwordInput, token: tokenInput)
            isConnecting = true
            Task {
                do {
                    try await connection.connect()
                    isConnecting = false
                } catch {
                    isConnecting = false
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func installAction(desktop: Bool) {
        errorMessage = nil
        do {
            try connection.saveCredentials(password: passwordInput, token: tokenInput)
            isInstalling = true
            Task {
                do {
                    try await connection.installAgent(withDesktop: desktop)
                    isInstalling = false
                    if let freshToken = connection.getToken() {
                        tokenInput = freshToken
                    }
                } catch {
                    isInstalling = false
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


// MARK: - 2. Cloud Sessions List View
struct CloudSessionsView: View {
    let model: String
    let selectedInstanceId: String

    @ObservedObject private var connection = CloudConnection.shared
    @State private var sessions: [[String: Any]] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var newSessionTitle: String = ""
    @State private var showNewSessionAlert = false

    var body: some View {
        List {
            Section {
                Button {
                    showNewSessionAlert = true
                } label: {
                    Label("新建云端会话", systemImage: "plus.circle.fill")
                        .font(.headline)
                }
            }

            if let err = errorMessage {
                Section("连接或加载错误") {
                    Text(err)
                        .foregroundColor(.red)
                        .font(.footnote)
                    Button("重试连接与加载") {
                        loadSessions()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Section("云电脑会话列表") {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if sessions.isEmpty {
                    Text("暂无云端会话，点击上方新建。")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(sessions.enumerated()), id: \.offset) { _, sess in
                        let sid = sess["session_id"] as? String ?? ""
                        let title = sess["title"] as? String ?? "未命名会话"
                        let createdAt = sess["created_at"] as? Double ?? 0
                        let dateStr = Date(timeIntervalSince1970: createdAt).formatted()

                        NavigationLink(destination: CloudSessionView(
                            sessionId: sid,
                            sessionTitle: title,
                            model: model,
                            selectedInstanceId: selectedInstanceId
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(title)
                                    .font(.headline)
                                Text("ID: \(sid) • \(dateStr)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("云端会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    loadSessions()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .alert("新建云端会话", isPresented: $showNewSessionAlert) {
            TextField("会话标题", text: $newSessionTitle)
            Button("创建") {
                createSession()
            }
            Button("取消", role: .cancel) {
                newSessionTitle = ""
            }
        }
        .onAppear {
            loadSessions()
        }
        .refreshable {
            loadSessions()
        }
    }

    private func loadSessions() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let res = try await connection.request(method: "GET", path: "/v1/sessions")
                if let list = res["sessions"] as? [[String: Any]] {
                    await MainActor.run {
                        self.sessions = list
                        self.isLoading = false
                    }
                } else {
                    await MainActor.run {
                        self.isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func createSession() {
        let title = newSessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        newSessionTitle = ""
        Task {
            do {
                let body: [String: Any] = ["title": title.isEmpty ? "Cloud Agent Session" : title]
                _ = try await connection.request(method: "POST", path: "/v1/sessions", body: body)
                loadSessions()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}


// MARK: - 3. Single Cloud Session Chat & Task Execution View
private struct CloudChatScrollTracking: ViewModifier {
    @Binding var followLatest: Bool
    @Binding var isUserScrolling: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollPhaseChange { _, phase, context in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    if !isUserScrolling { isUserScrolling = true }
                case .idle where isUserScrolling:
                    let geometry = context.geometry
                    followLatest = geometry.contentSize.height - geometry.visibleRect.maxY <= 64
                    isUserScrolling = false
                default:
                    break
                }
            }
        } else {
            content
        }
    }
}

struct CloudSessionView: View {
    @Environment(\.cloudChatTypography) private var typography
    @Environment(\.dynamicTypeSize) private var typeSize
    let sessionId: String
    let sessionTitle: String
    let model: String
    let selectedInstanceId: String
    /// 会话所属 Bot 已固定模型与凭据时为 true：发送时不要求手机选择服务商
    let botHasOwnModel: Bool
    /// 输入 @ 时可选的 Bot（把任务交给另一个 Bot）
    let mentionBots: [CloudBot]
    /// 多 Bot 模式：用 Bot 的头像颜色做气泡与按钮主题，显示动态头像进度、附件与语音入口
    let theme: CloudBotChatTheme?

    init(sessionId: String, sessionTitle: String, model: String, selectedInstanceId: String,
         botHasOwnModel: Bool = false, mentionBots: [CloudBot] = [], theme: CloudBotChatTheme? = nil) {
        self.theme = theme
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.model = model
        self.selectedInstanceId = selectedInstanceId
        self.botHasOwnModel = botHasOwnModel
        self.mentionBots = mentionBots
    }

    @ObservedObject private var connection = CloudConnection.shared
    @State private var messages: [[String: Any]] = []
    @State private var tasks: [[String: Any]] = []
    @State private var inputPrompt: String = ""
    @State private var replyTarget: CloudReplyTarget?
    /// 用户刚点的表情回应（服务器确认前先显示）；值为 nil 表示刚取消
    @State private var localReactions: [Int: String?] = [:]
    /// 这次对话里发给其他 Bot 的消息：折叠成「N 条消息，与 X」，点开只读线程
    @State private var threadRows: [CloudBotThreadCollapsed] = []
    @State private var pendingExtras: [String: Any] = [:]
    @State private var activeTaskId: String? = nil
    @State private var activeTaskStatus: String = "idle"
    @State private var taskEvents: [[String: Any]] = []
    @State private var isLoading = false
    @State private var isSubmitting = false
    @StateObject private var delivery = CloudDeliveryBox()
    @State private var canStoreOutbox = false
    @State private var failedSends: [UUID: CloudDeliveryBox.Item] = [:]
    @AppStorage(CloudWardVoice.doubleTapKey) private var doubleTapVoice = false
    @State private var watchedTasks: Set<String> = []
    /// 与本地模式同一个消息模型：服务器历史转换后的回合、正在进行任务的那条助手消息
    @State private var turns: [CloudHistoryAdapter.Turn] = []
    /// 已用过的任务事件 id：全量重拉、长轮询、恢复连接重叠时同一事件只用一次
    @State private var ledger = CloudEventLedger()
    /// 进行中的任务已写进历史的那几轮暂时不从历史画（实时那一份负责），任务结束重新加载后恢复
    @State private var historyHidesTask = false
    @State private var activeTaskCreatedAt: Double?
    @State private var liveMessage = ChatMessage(role: .assistant, content: "")
    @State private var completedLiveReplies: [CloudLiveReply] = []
    @State private var initialReplyNonce: String?
    @State private var liveReplyNonce: String?
    @State private var serverTracksReplyTurns = false
    /// 连续几次取不到进度时的一行温和提示（不是红色横幅），恢复后自动清除
    @State private var streamNotice: String?
    @State private var sendStartedAt: Date?
    @State private var autoOpenedComputer: Set<String> = []
    @State private var isPolling = false
    @State private var loadedTaskId: String? = nil
    @State private var errorMessage: String? = nil
    @State private var followUpNotice: String? = nil
    @State private var privacyHits: [CloudPrivacyScan.Hit] = []
    @State private var privacyConfirmed = false
    @State private var showPins = false
    @State private var retractable: CloudRetract? = nil
    @State private var showComputer = false
    @State private var attachments: [CloudPendingAttachment] = []
    /// 服务器上还有更早的消息（分页）
    @State private var hasOlderHistory = false
    @State private var loadingOlder = false
    @State private var followLatest = true
    @State private var isUserScrolling = false
    @State private var historyScrollAnchor: String?
    /// 每个附件的上传状态（托盘卡片上的进度圈 / 重试）
    /// 点了哪个拍照识别要求（用来找更对口的 Bot）
    @State private var photoKind: String?
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showScanner = false
    @State private var showCaseNote = false
    @State private var showFiles = false
    @State private var showVoiceCall = false
    /// 顶部浮动胶囊的实时通话（Bot 模式）
    @StateObject private var call = CloudBotCallController()
    @State private var callDividers: [CloudCallDivider] = []
    @State private var pttHeld = false
    /// 通话方式：realtime = 实时双向（需在实时语音设置里选好服务商）；turns = 听完 → 发送 → 朗读
    @State private var voiceMode = "turns"
    @State private var realtimeNotice: String?
    /// 点声波没接通的原因：浮在输入框上方，几秒后消失
    @State private var voiceProblem: String?
    /// 实时语音接不通的原因：有值时弹去处面板
    @State private var voiceRoute: String?
    @State private var showRealtimeSettings = false
    @StateObject private var dictation = CloudDictation()
    @State private var dictationBase = ""
    @State private var showModelPicker = false
    /// 模型正在生成的文字（服务器流式推送，长轮询拿到）
    @State private var liveText = ""
    @State private var liveReasoning = ""
    @State private var liveTool: CloudLiveTool?
    @AppStorage(CloudSteerMode.key) private var steerInterrupt = true
    @State private var isInjecting = false
    @State private var liveSeq = -1
    @State private var eventCursor = 0
    @State private var isStreaming = false
    @State private var lastWarm = Date.distantPast
    // 回复方式（秒回 / 详细）：秒回时底部一行显示后台在做什么
    @State private var replyPlan: CloudReplyPlan?
    @StateObject private var replyStatus = CloudReplyStatusModel()
    @State private var replyLatency = CloudReplyLatency()

    private let timer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    /// 最近一次任务里 Bot 请求用户接管云电脑的原因（登录、验证码等）
    private var takeoverReason: String? {
        let last = taskEvents.last { $0["type"] as? String == "takeover_request" }
        return (last?["payload"] as? [String: Any])?["reason"] as? String
    }

    var body: some View {
        VStack(spacing: 0) {
            if let err = errorMessage {
                HStack {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                    Spacer()
                    Button("重试") {
                        errorMessage = nil
                        loadSessionDetail()
                    }
                    .font(.caption)
                    Button { errorMessage = nil } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("关闭提示")
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.1))
            }

            if let theme, call.active {
                CloudCallCapsule(call: call, name: theme.name,
                                 avatar: CloudBotAvatarView(spec: theme.spec, size: 34))
                    .padding(.vertical, 4)
            }

            // Messages & Event Log area
            messagesArea

            Divider()

            // Active Task Status Bar if running
            if theme == nil && (activeTaskStatus == "running" || activeTaskStatus == "waiting_user") {
                HStack {
                    ProgressView()
                        .padding(.trailing, 4)
                    Text(activeTaskStatus == "waiting_user" ? "云端任务等待你审批 [\(activeTaskId ?? "")]" : "云端任务执行中 [\(activeTaskId ?? "")]")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Spacer()
                    Button("取消任务") {
                        cancelActiveTask()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.1))
            }

            if !mentionCandidates.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(mentionCandidates) { bot in
                            Button { insertMention(bot) } label: {
                                Text(bot.label).font(.subheadline)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 6)
                }
            }

            // Input Composer Bar
            if let theme {
                themedComposer(theme)
            } else {
            HStack(spacing: 8) {
                TextField(mentionBots.isEmpty ? "给云端 Agent 发送任务..." : "发消息，输入 @ 可交给其他 Bot（键盘麦克风可语音输入）", text: $inputPrompt, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .disabled(false)

                Button {
                    sendTask()
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                    }
                }
                .disabled(inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || activeTaskStatus == "running" || isSubmitting)
            }
            .padding()
            .background(Color(.systemBackground))
            }
        }
        .tint(theme?.accent)
        .background { if let theme { theme.backdrop.fill(accent: theme.accent).ignoresSafeArea() } }
        .sheet(isPresented: $showModelPicker) {
            if let theme {
                CloudModelEffortSheet(title: "\(theme.name) 的模型",
                                      current: (CloudBotService.instanceId(forCredential: theme.credential), theme.model,
                                                CloudEffort(rawValue: theme.effort) ?? CloudEffort.globalDefault)) { option, effort in
                    Task {
                        do {
                            try await CloudBotService.setModelChoice(theme.botId, option: option, effort: effort)
                            await CloudBotHomeModel.shared.refresh()
                        } catch {
                            errorMessage = "切换模型失败：\(error.localizedDescription)"
                        }
                    }
                }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: call.active)
        .modifier(CloudRetractToast(item: $retractable, onUndo: undoSend))
        .overlay(alignment: .bottom) { CloudFollowUpToast(text: $voiceProblem, icon: "waveform.badge.exclamationmark") }
        .sheet(isPresented: $showPins) { if let theme { CloudPinsSheet(botId: theme.botId, botName: theme.name) } }
        .modifier(CloudSessionExtras(followUp: $followUpNotice, outboxCount: outboxCount, privacyHits: $privacyHits,
                                     onDiscard: discardOutbox, onRedact: sendRedacted, onSend: sendAnyway,
                                     onAppear: resumeOutbox, onDisappear: pauseOutbox))
        .onAppear {
            callDividers = CloudCallDivider.load(sessionId)
            if !CloudE2E.attachWhenBusy { injectE2EAttachments() }
        }
        .onChange(of: activeTaskId) { tid in if tid != nil, CloudE2E.attachWhenBusy { injectE2EAttachments() } }
        .modifier(CloudDraftKeeper(sessionId: sessionId, text: $inputPrompt))
        .modifier(CloudReplyChatChrome(sessionId: sessionId, instant: replyPlan?.isInstant == true, status: replyStatus,
                                       onPlan: { applyReplyPlan($0) }))
        // 通话中途断开等：也走去处面板（不再往消息列表底下塞灰字，那里还会压住滚动箭头）
        .onChange(of: call.error) { e in if let e, !call.active { reportVoiceProblem(e) } }
        .sheet(isPresented: Binding(get: { voiceRoute != nil }, set: { if !$0 { voiceRoute = nil } })) {
            CloudVoiceRouteSheet(problem: voiceRoute ?? "", botId: theme?.botId,
                                 onRetry: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if let theme { startFloatingCall(theme, pushToTalk: false) } } },
                                 onTurns: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { openTurnsVoice() } })
        }
        .sheet(isPresented: $showRealtimeSettings) { RealtimeVoiceSettingsSheet(botId: theme?.botId) }
        .sheet(isPresented: $showPhotos) { CloudPhotoPicker { attachments.append(contentsOf: $0) }.ignoresSafeArea() }
        .fullScreenCover(isPresented: $showCamera) { CloudCameraPicker { attachments.append($0) }.ignoresSafeArea() }
        .fullScreenCover(isPresented: $showScanner) { CloudDocumentScanner { attachments.append($0) }.ignoresSafeArea() }
        .sheet(isPresented: $showCaseNote) { CloudCaseNoteSheet { inputPrompt = $0 } }
        .sheet(isPresented: $showFiles) { CloudFilePicker { attachments.append(contentsOf: $0) }.ignoresSafeArea() }
        .fullScreenCover(isPresented: $showVoiceCall) {
            if let theme {
                if voiceMode == "realtime" {
                    CloudBotRealtimeCallView(botName: theme.name, persona: botPersona(theme.botId), sessionId: sessionId,
                                             history: realtimeHistory(), delegate: { prompt in await delegateFromRealtime(prompt) },
                                             onSaved: { problem in
                                                 realtimeNotice = problem
                                                 loadSessionDetail()
                                             },
                                             onFallback: { voiceMode = "turns" })
                } else {
                    CloudBotVoiceCallView(theme: theme, isWorking: activeTaskStatus == "running" || activeTaskStatus == "waiting_user" || isSubmitting,
                                          progress: CloudBotProgress.summarize(taskEvents, status: activeTaskStatus).0,
                                          onRealtime: { CloudBotSpeaker.stop(); voiceMode = "realtime" }) { text in
                        inputPrompt = text
                        sendTask()
                    }
                }
            }
        }
        .onChange(of: messages.count) { _ in
            // 语音对话中（轮流模式）：Bot 回复后按它的语音设置朗读；实时模式由实时模型转述
            guard showVoiceCall, voiceMode == "turns", let theme, let last = messages.last, last["role"] as? String == "assistant",
                  let text = last["content"] as? String, !text.isEmpty else { return }
            CloudBotSpeaker.speak(CloudMessageText.display(text).text, botId: theme.botId)
        }
        .onChange(of: dictation.transcript) { text in
            guard dictation.isRecording else { return }
            inputPrompt = dictationBase.isEmpty ? text : dictationBase + " " + text
        }
        .navigationTitle(sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showComputer) {
            CloudComputerView(botId: mentionBots.isEmpty ? nil : CloudBotHomeModel.shared.botId(forSession: sessionId),
                              sessionId: sessionId, reason: takeoverReason)
        }
        .onAppear {
            CloudLinkSupervisor.shared.visibleSessionId = sessionId
            CloudLinkSupervisor.shared.pageOpened()
            loadSessionDetail()
            warmUp()
            if CloudComputerHandoff.consume(sessionId) { sendFinished() }
            if let theme, let p = CloudBotHomeModel.shared.takePrompt(for: theme.botId) {
                inputPrompt = p.text
                attachments.append(contentsOf: p.attachments)
                if p.send {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        sendTask()
                    }
                }
            }
        }
        .onChange(of: inputPrompt.isEmpty) { empty in
            if !empty { warmUp() }
        }
        .onChange(of: activeTaskStatus) { status in
            // 多 Bot 任务也进灵动岛 / 锁屏实时活动（与本地模式同一套）
            guard let theme else { return }
            // 上锁的 Bot：灵动岛 / 锁屏不显示名字、工具和回复内容
            let locked = CloudBotLock.isLockedStored(theme.botId)
            switch status {
            case "running", "queued", "waiting_user":
                CloudBotLiveActivity.began(sessionId: sessionId, botName: locked ? "已上锁的 Bot" : theme.name)
                if status == "waiting_user" { CloudBotLiveActivity.progress(sessionId: sessionId, toolName: "", status: "等你确认") }
            case "completed":
                let summary = turns.last(where: { $0.message.role == .assistant })?.message.content ?? liveText
                CloudBotLiveActivity.finished(sessionId: sessionId, summary: locked ? "已完成" : CloudMessageText.display(summary).text, succeeded: true)
            case "failed", "cancelled", "interrupted", "limit_reached":
                CloudBotLiveActivity.finished(sessionId: sessionId, summary: "", succeeded: false)
            default:
                break
            }
        }
        .onChange(of: taskEvents.count) { _ in
            guard let theme, !CloudBotLock.isLockedStored(theme.botId), let ev = taskEvents.last(where: { ($0["type"] as? String) == "tool_call" }) else { return }
            let payload = ev["payload"] as? [String: Any] ?? [:]
            let name = payload["tool"] as? String ?? payload["name"] as? String ?? ""
            let args = payload["arguments"] as? [String: Any] ?? [:]
            let detail = (args["action"] as? String) ?? (args["path"] as? String) ?? (args["command"] as? String).map { String($0.prefix(40)) } ?? ""
            CloudBotLiveActivity.progress(sessionId: sessionId, toolName: name, status: detail)
        }
        .onDisappear {
            if CloudLinkSupervisor.shared.visibleSessionId == sessionId { CloudLinkSupervisor.shared.visibleSessionId = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudComputerHandoff.finished)) { note in
            guard note.userInfo?["session_id"] as? String == sessionId else { return }
            _ = CloudComputerHandoff.consume(sessionId)
            sendFinished()
        }
        .onReceive(timer) { _ in
            if activeTaskStatus == "running" || activeTaskStatus == "waiting_user", let tid = activeTaskId, !isPolling, !isStreaming {
                pollTaskStatus(taskId: tid)
            }
        }
    }

    /// 读请求静默重试：短暂断线、隧道重建时不打扰用户，连续失败约 10 秒后才交给调用方显示
    private func quietly(_ path: String) async throws -> [String: Any] {
        var lastError: Error?
        for delay in [0, 1_500_000_000, 3_000_000_000, 5_000_000_000] as [UInt64] {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            do {
                try await connection.ensureConnected()
                return try await connection.request(method: "GET", path: path)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    private var taskIsLive: Bool { ["running", "waiting_user", "queued"].contains(activeTaskStatus) && activeTaskId != nil }

    /// 历史 → 回合。任务进行中时这次任务的几轮只由实时事件那一份显示，避免同一段话、同一步工具画两遍
    private func rebuildTurns() {
        let rows: [[String: Any]]
        if taskIsLive, serverTracksReplyTurns, replyPlan?.isInstant == true, let tid = activeTaskId {
            rows = messages.filter { $0["front_task_id"] as? String != tid }
        } else {
            let roles = messages.map { $0["role"] as? String ?? "" }
            let stamps = messages.map { $0["timestamp"] as? Double }
            let n = CloudEventLedger.visibleHistoryCount(roles: roles, timestamps: stamps, liveShown: taskIsLive, taskStartedAt: activeTaskCreatedAt)
            rows = Array(messages.prefix(n))
        }
        historyHidesTask = taskIsLive && rows.count < messages.count
        let users = turns.reduce(into: [String: CloudHistoryAdapter.Turn]()) { result, turn in
            if turn.message.role == .user, let nonce = turn.raw["client_nonce"] as? String { result[nonce] = turn }
        }
        turns = CloudHistoryAdapter.turns(from: rows).map { turn in
            guard turn.message.role == .user, let nonce = turn.raw["client_nonce"] as? String,
                  let previous = users[nonce] else { return turn }
            if CloudHistoryPager.pendingNonce(turn.raw) != nil { return previous }
            turn.message.adoptedMark = previous.message.adoptedMark
            return turn
        }
    }

    /// 新事件只用一次：追加到事件列表并画进实时那一份
    private func ingest(_ events: [[String: Any]]) -> [[String: Any]] {
        let fresh = ledger.fresh(events)
        guard !fresh.isEmpty else { return [] }
        taskEvents.append(contentsOf: fresh)
        for ev in fresh {
            let type = ev["type"] as? String ?? ""
            let payload = ev["payload"] as? [String: Any] ?? [:]
            if let nonce = payload["nonce"] as? String {
                switch type {
                case "user_message_applied", "user_message_withdrawn":
                    delivery.remoteQueue[nonce] = nil
                    finishPendingSend(nonce)
                    if type == "user_message_withdrawn" { removePendingBubble(nonce) }
                default:
                    break
                }
            }
            if type == "user_message_applied", payload["separate_reply"] as? Bool == true {
                if !liveMessage.blocks.isEmpty || liveMessage.error != nil {
                    completedLiveReplies.append(.init(nonce: liveReplyNonce, message: liveMessage))
                }
                liveReplyNonce = payload["nonce"] as? String
                liveMessage = ChatMessage(role: .assistant, content: "")
                liveText = ""
                liveReasoning = ""
                liveTool = nil
            }
            CloudEventApplier.apply(liveMessage, type: type, payload: payload,
                                    eventId: CloudEventLedger.eventId(ev))
            if type == "tool_call" {
                let tool = payload["tool"] as? String ?? ""
                let args = payload["arguments"] as? [String: Any] ?? [:]
                if let note = CloudReplyFrontAction.note(tool: tool, args: args) {
                    replyStatus.noteDecision(note.line, action: note.action.rawValue)
                }
            }
            if type == "tool_result" {
                let callId = payload["id"] as? String ?? ""
                let isErr = (payload["is_error"] as? Bool) ?? ((payload["result"] as? [String: Any])?["error"] != nil)
                if !isErr {
                    let block = callId.isEmpty
                        ? liveMessage.blocks.last(where: { $0.toolUseId != nil })
                        : liveMessage.blocks.first(where: { $0.toolUseId == callId })
                    if let block, CloudEventApplier.toolName(block) == "task_message" {
                        markUserAdopted()
                    }
                }
            }
        }
        eventCursor = max(eventCursor, fresh.compactMap { CloudEventLedger.eventId($0) }.max() ?? 0)
        return fresh
    }

    private func loadSessionDetail() {
        isLoading = true
        let taskAtRequest = activeTaskId
        // 先画手机上缓存的对话（不等连接），网络回来再静默替换
        if messages.allSatisfy({ CloudHistoryPager.pendingNonce($0) != nil }),
           theme != nil, let cached = CloudChatCache.load(sessionId) {
            messages = CloudHistoryPager.merge(current: messages, fresh: cached.messages, preservePending: true)
            if tasks.isEmpty { tasks = cached.tasks }
            rebuildTurns()
        }
        Task {
            do {
                let res = try await quietly(CloudHistoryPager.firstPath(sessionId))
                await MainActor.run {
                    guard !CloudBotService.deletedSessions.contains(self.sessionId) else { return }
                    let fresh = res["messages"] as? [[String: Any]] ?? []
                    let freshTasks = res["tasks"] as? [[String: Any]] ?? []
                    self.canStoreOutbox = (res["incognito"] as? Bool) != true
                        && (self.theme.map { !CloudBotLock.isLockedStored($0.botId) } ?? true)
                    if self.theme != nil, self.canStoreOutbox {
                        CloudChatCache.save(self.sessionId, messages: fresh, tasks: freshTasks)
                    }
                    // 分页：之前翻出来的更早消息留着；旧服务器不认 limit 时 has_more 缺省为 false
                    self.serverTracksReplyTurns = res["ordered_reply_turns"] as? Bool == true
                    self.messages = CloudHistoryPager.merge(current: self.messages, fresh: fresh,
                                                            preservePending: self.serverTracksReplyTurns)
                    if self.messages.count == fresh.count { self.hasOlderHistory = res["has_more"] as? Bool ?? false }
                    self.tasks = freshTasks
                    self.isLoading = false
                    self.applyReplyPlan(CloudReplyPlan(json: res["reply"] as? [String: Any]))
                    if self.activeTaskId != taskAtRequest, self.taskIsLive,
                       self.tasks.first?["task_id"] as? String != self.activeTaskId {
                        self.rebuildTurns()
                        return
                    }
                    if !self.isStreaming { self.liveText = "" }
                    if let latestTask = self.tasks.first,
                       let tid = latestTask["task_id"] as? String,
                       let status = latestTask["status"] as? String {
                        let needsEvents = self.loadedTaskId != tid
                        self.initialReplyNonce = latestTask["client_nonce"] as? String
                        if self.activeTaskId != tid { self.liveReplyNonce = self.initialReplyNonce }
                        self.activeTaskId = tid
                        self.activeTaskStatus = status
                        self.activeTaskCreatedAt = latestTask["created_at"] as? Double
                        self.rebuildTurns()
                        if status == "running" || status == "waiting_user" || needsEvents { pollTaskStatus(taskId: tid) }
                    } else {
                        self.activeTaskId = nil
                        self.activeTaskStatus = "idle"
                        self.activeTaskCreatedAt = nil
                        self.taskEvents = []
                        self.ledger.reset()
                        self.rebuildTurns()
                    }
                    if self.theme != nil { self.loadThreadRows() }
                }
            } catch {
                await MainActor.run {
                    // 持续失败才提示，且用温和的说法（状态点同时显示连接状态）
                    if self.messages.isEmpty { self.errorMessage = "暂时连不上云电脑，正在自动重试…" }
                    self.isLoading = false
                }
            }
        }
    }

    /// 输入框最后一个词以 @ 开头时，列出名称或 ID 匹配的 Bot。
    private var mentionCandidates: [CloudBot] {
        guard !mentionBots.isEmpty, let last = inputPrompt.split(separator: " ", omittingEmptySubsequences: false).last,
              last.hasPrefix("@") || last.hasPrefix("＠") else { return [] }
        let q = String(last.dropFirst()).lowercased()
        return mentionBots.filter { q.isEmpty || $0.name.lowercased().hasPrefix(q) || $0.id.hasPrefix(q) }
    }

    private func insertMention(_ bot: CloudBot) {
        var parts = inputPrompt.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if !parts.isEmpty { parts.removeLast() }
        parts.append("@\(bot.name) ")
        inputPrompt = parts.joined(separator: " ")
    }

    @ViewBuilder
    private func themedTaskArea(_ theme: CloudBotChatTheme) -> some View {
        let resolved = Set(taskEvents.compactMap { ev -> String? in
            guard ev["type"] as? String == "approval_resolved" else { return nil }
            return (ev["payload"] as? [String: Any])?["approval_id"] as? String
        })
        ForEach(Array(taskEvents.enumerated()), id: \.offset) { _, ev in
            let type = ev["type"] as? String ?? ""
            let payload = ev["payload"] as? [String: Any] ?? [:]
            if type == "takeover_request" {
                CloudTakeoverCard(reason: payload["reason"] as? String ?? "") { showComputer = true }
            } else if type == "approval_required", activeTaskStatus == "waiting_user",
                      let aid = payload["approval_id"] as? String, !resolved.contains(aid) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("需要你批准", systemImage: "hand.raised.fill").font(.subheadline.bold()).foregroundStyle(.orange)
                    Text(payload["reason"] as? String ?? (payload["tool"] as? String ?? "")).font(.callout)
                    HStack {
                        Button("拒绝") { decide(approvalId: aid, approve: false) }.buttonStyle(.bordered).tint(.red)
                        Button("批准") { decide(approvalId: aid, approve: true) }.buttonStyle(.borderedProminent).tint(theme.accent)
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.1)))
            }
        }
        let running = activeTaskStatus == "running" || activeTaskStatus == "waiting_user" || activeTaskStatus == "queued" || isSubmitting
        // 进行中，或刚结束、历史还没重新加载（这次任务的几轮还没出现在历史里）：由实时那一份显示
        let instant = replyPlan?.isInstant == true
        let hasLiveReply = instant ? CloudAssistantTurnView.hasVisibleInstantContent(liveMessage, liveText: liveText)
            : !liveMessage.blocks.isEmpty || liveMessage.error != nil || !liveText.isEmpty || !liveReasoning.isEmpty
        let detached = completedLiveReplies.filter {
            !hasReplyAnchor($0.nonce) && (!instant || CloudAssistantTurnView.hasVisibleInstantContent($0.message))
        }
        let detachedLive = hasLiveReply && !hasReplyAnchor(liveReplyNonce)
        if (running || historyHidesTask) && (!detached.isEmpty || detachedLive) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    CloudBotWatchingAvatar(spec: theme.spec, size: 22)
                    Text(theme.name).font(.subheadline.bold())
                }
                // 与本地模式同一条管线：事件 → liveMessage 的消息块，正在生成的文字接在后面
                ForEach(detached) { reply in
                    CloudAssistantTurnView(message: reply.message, spec: theme.spec, name: theme.name, accent: theme.accent, showHeader: false)
                }
                if detachedLive {
                    CloudAssistantTurnView(message: liveMessage, spec: theme.spec, name: theme.name, accent: theme.accent,
                                           showHeader: false, liveText: liveText, liveReasoning: liveReasoning)
                }
            }
        }
        if running, liveMessage.blocks.contains(where: { if case .browserTool = $0.kind { return true } else { return false } }) {
            // Bot 正在用浏览器 / 桌面：对话里实时显示小画面，点开进入「电脑」
            CloudDesktopPreview(botId: theme.botId) { showComputer = true }
        }
        if running {
            CloudTypingStatusRow(text: CloudBotCallText.typingStatus(taskStatus: activeTaskStatus == "" && isSubmitting ? "queued" : activeTaskStatus,
                                                                     tool: liveTool?.name) ?? "正在输入…",
                                 tint: theme.accent, avatar: CloudBotAvatarView(spec: theme.spec, size: 22, mood: .focused),
                                 onStop: activeTaskId == nil ? nil : { cancelActiveTask() })
        }
        if call.active {
            CloudCallLiveLines(lines: call.lines, tint: theme.accent)
        }
        if let streamNotice {
            Label(streamNotice, systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
        }
        if let realtimeNotice {
            Label(realtimeNotice, systemImage: "waveform.badge.exclamationmark").font(.caption).foregroundStyle(.secondary)
                .padding(.trailing, 48)   // 右下角有滚动箭头，别压住
                .onTapGesture { self.realtimeNotice = nil }
        }
    }

    @ViewBuilder
    private func themedComposer(_ theme: CloudBotChatTheme) -> some View {
        let working = activeTaskStatus == "running" || activeTaskStatus == "waiting_user"
        VStack(spacing: 6) {
            CloudReplyComposerSlot(instant: replyPlan?.isInstant == true, status: replyStatus, theme: theme,
                                   firstTextMs: replyLatency.firstTextMs)
            if replyPlan?.isInstant != true {
            // 与本地模式同一个步骤条（预览卡 + 状态胶囊 + N/M 翻页），数据来自 Bot 的实时工具事件
            CloudStepBar(message: liveMessage, liveToolId: liveTool?.id, liveOutput: liveTool?.output ?? "", working: working)
                // 步骤面板复用本地组件：标题写 Bot / 云电脑名字，CPU / 内存读云端，不读这台 iPhone
                .environment(\.cloudComputer, CloudComputerContext.current(actor: theme.name))
                .padding(.horizontal, 12)
            }
            if let r = replyTarget {
                CloudReplyBanner(excerpt: r.excerpt) { replyTarget = nil }
            }
            if !attachments.isEmpty {
                CloudAttachmentTray(attachments: $attachments, states: [:], onRetry: { sendTask() })
                if let kind = photoKind, attachments.contains(where: { $0.isImage }), let target = photoTarget(kind) {
                    // 识别后分给对应的 Bot：比如药品图交给药师 Bot，带着图片和要求过去
                    Button { handPhoto(to: target.id) } label: {
                        Label("交给「\(target.name)」处理（更对口）", systemImage: "arrowshape.turn.up.right.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(theme.accent.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
                }
                if attachments.contains(where: { $0.isImage }), inputPrompt.trimmingCharacters(in: .whitespaces).isEmpty {
                    // 拍照识别：选了图片还没写字时，一键填好常用的识别要求
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(CloudPhotoPrompts.all, id: \.0) { item in
                                Button { CloudHaptics.selection(); inputPrompt = item.1; photoKind = item.0 } label: {
                                    Text(item.0).font(.caption.weight(.medium))
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Capsule().fill(theme.accent.opacity(0.12)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                }
            }
            if let err = dictation.errorText { Text(err).font(.caption).foregroundStyle(.red) }
            let slash = CloudSlashCommand.matching(inputPrompt)
            if !slash.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(slash) { cmd in
                        Button { runSlash(cmd.id, theme: theme) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: cmd.icon).frame(width: 20).foregroundStyle(theme.accent)
                                Text(cmd.id).font(.subheadline.weight(.semibold))
                                Text(cmd.title).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
                .padding(.horizontal, 12)
            }
            if !dictation.isRecording {
                HStack {
                    Button { showModelPicker = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "cpu").font(.caption2)
                            Text(theme.chipText).font(.caption.weight(.medium)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color(.systemGray6)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("切换模型与思考深度：\(theme.chipText)")
                    CloudQuickCards(text: $inputPrompt)
                }
                .padding(.horizontal, 14)
            }
            if dictation.isRecording {
                // 听写中：输入栏展开成卡片（实时文字 + 停止 + 滚动波形 + 发送），照 Grok
                DictationCard(transcript: inputPrompt, partial: true, levels: dictation.levels,
                              onStop: { dictation.stop() },
                              onCancel: {
                                  dictation.stop()
                                  inputPrompt = dictationBase
                              },
                              onSend: {
                                  dictation.stop()
                                  sendTask()
                              })
                    .padding(.horizontal, 28)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    Menu {
                        Button { showPhotos = true } label: { Label("照片或视频", systemImage: "photo.on.rectangle") }
                        Button { showCamera = true } label: { Label("拍照", systemImage: "camera") }
                        if VNDocumentCameraViewController.isSupported {
                            Button { showScanner = true } label: { Label("扫描文档", systemImage: "doc.viewfinder") }
                        }
                        Button { showFiles = true } label: { Label("选择文件", systemImage: "folder") }
                        Button { showCaseNote = true } label: { Label("口述病例（脱敏后复盘）", systemImage: "stethoscope") }
                        Button { showPins = true } label: { Label("要点板", systemImage: "pin") }
                        Button { showRealtimeSettings = true } label: { Label("实时语音设置", systemImage: "waveform") }
                        Button { if !inputPrompt.hasPrefix("/") { inputPrompt = "/" } } label: { Label("斜杠命令", systemImage: "slash.circle") }
                        Picker("Bot 干活时发消息", selection: $steerInterrupt) {
                            Label("插话：直接告诉它", systemImage: "arrow.turn.up.right").tag(true)
                            Label("排队：这一轮做完再发", systemImage: "text.badge.plus").tag(false)
                        }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(.primary)
                            .frame(width: 40, height: 40).background(Circle().fill(Color(.systemGray6)))
                    }
                    .accessibilityLabel("添加附件")
                    HStack(alignment: .bottom, spacing: 4) {
                        TextField(CloudBotComposerAction.placeholder(botName: theme.name, localHint: false), text: $inputPrompt, axis: .vertical)
                            .font(.system(.body, design: typography?.design.swiftUI ?? .default))
                            .dynamicTypeSize(typography?.inputTypeSize ?? typeSize)
                            .accessibilityIdentifier("botComposerField")
                            .lineLimit(1...6)
                            .padding(.vertical, 10).padding(.leading, 14)
                            .disabled(false)
                        Button { toggleDictation() } label: {
                            Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic").font(.system(size: 17))
                                .foregroundStyle(dictation.isRecording ? Color.red : Color.secondary)
                                .frame(width: 34, height: 40)
                        }
                        .accessibilityLabel(dictation.isRecording ? "停止听写" : "听写")
                        .accessibilityIdentifier("botDictationButton")
                    }
                    .background(Capsule().fill(Color(.systemGray6)))
                    // 最右边一个会变形的圆按钮：没字 = 声波（实时语音，长按按住说话），有字 = 发送；干活时有字 = 插话 / 排队。底色是头像色
                    CloudMorphButton(action: CloudBotComposerAction.of(hasDraft: hasDraft, working: working,
                                                                       submitting: false, steerInterrupt: steerInterrupt),
                                     tint: theme.accent, inCall: call.active,
                                     onTap: {
                                         if dictation.isRecording { dictation.stop() }
                                         if call.active, hasDraft { sendTask(); return }
                                         if !hasDraft { openVoiceCall() } else { sendTask() }
                                     },
                                     onPushToTalk: { on in pushToTalk(on, theme: theme) })
                        .accessibilityIdentifier("composerVoiceButton")
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
        .background(theme.backdrop.fill(accent: theme.accent))
    }

    private func composerIcon(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(.primary)
                .frame(width: 32, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func runSlash(_ id: String, theme: CloudBotChatTheme) {
        CloudHaptics.selection()
        inputPrompt = ""
        switch id {
        case "/模型": showModelPicker = true
        case "/电脑": showComputer = true
        case "/通话": openVoiceCall()
        case "/照片": showPhotos = true
        case "/文件": showFiles = true
        case "/记住": inputPrompt = "记住："
        case "/总结": inputPrompt = "请总结一下我们这段对话的要点和待办"; sendTask()
        case "/停止": cancelActiveTask()
        case "/reset": resetContext()
        default: break
        }
    }

    /// 模拟器端到端测试：托盘里放 N 张生成的测试图（Debug + 环境变量才会有）
    private func injectE2EAttachments() {
        let n = CloudE2E.fakeAttachments
        guard n > 0, attachments.isEmpty else { return }
        let colors: [UIColor] = [.systemRed, .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemTeal, .systemPink, .systemYellow, .systemIndigo]
        for i in 0..<n {
            let img = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1200)).image { ctx in
                colors[i % colors.count].setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 1200))
                ("测试图 \(i + 1)" as NSString).draw(at: CGPoint(x: 60, y: 520), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 96), .foregroundColor: UIColor.white])
            }
            if let a = CloudAttachmentKit.image(img, name: "照片 \(i + 1).jpg") { attachments.append(a) }
        }
    }

    /// 运行中发消息：插话模式交给正在跑的任务（模型下一步就看到）；任务刚好结束或选了排队，就等它结束再普通发送
    private func steerOrQueue() {
        // 连发 / 插话都走乐观发送：气泡立刻上屏，网络在队列里按顺序投递（运行中则插话）。
        sendTask()
    }

    /// 排队：等当前任务结束（最多约 10 分钟）再走普通发送；输入框里的内容保留到发出为止
    private func queueAfterCurrent() {
        CloudHaptics.tap()
        // 以前这里不吭声地等最多 10 分钟，看起来像「点发送没反应」
        let n = attachments.filter(\.isImage).count
        voiceProblem = n > 0 ? "等这一步做完就发（\(n) 张图片已排队）" : "等这一步做完就发"
        Task { @MainActor in
            for _ in 0..<1200 {
                if !["running", "waiting_user", "queued"].contains(activeTaskStatus) && !isSubmitting { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            sendTask()
        }
    }

    /// /reset：先存对话快照，再清空模型上下文（旧消息留在屏幕上，下面一条分隔线可点开看快照）
    private func resetContext() {
        let sid = sessionId
        var body: [String: Any] = [:]
        if !botHasOwnModel, let inst = ProviderConfigStore.shared.instance(for: selectedInstanceId),
           inst.providerType == .openAI, inst.credentialType == .apiKey, !inst.azureMode,
           let key = ProviderKeychainHelper.loadAPIKey(instanceId: inst.id), !key.isEmpty {
            let resolved = inst.resolvedBaseURL(default: "https://api.openai.com")
            body = ["model": model, "provider": ["base_url": resolved.appendV1 ? "\(resolved.url)/v1" : resolved.url, "api_key": key]]
        }
        isSubmitting = true
        Task { @MainActor in
            do {
                _ = try await CloudQuiet.retry {
                    try await connection.request(method: "POST", path: "/v1/sessions/\(sid)/reset", body: body)
                }
                CloudHaptics.success()
                activeTaskId = nil
                activeTaskStatus = "idle"
                liveMessage = ChatMessage(role: .assistant, content: "")
                completedLiveReplies = []
                liveText = ""
                liveReasoning = ""
                liveTool = nil
            } catch {
                errorMessage = "重置失败：\(error.localizedDescription)"
            }
            isSubmitting = false
            loadSessionDetail()
        }
    }

    private var hasDraft: Bool {
        !inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private func toggleDictation() {
        if dictation.isRecording {
            dictation.stop()
        } else {
            dictationBase = inputPrompt
            dictation.start(language: theme.map { CloudBotVoiceSettings.load($0.botId).language } ?? "")
        }
    }

    /// 有附件时先上传（文件存到工作区，图片同时作为图片消息发给模型），再提交任务
    /// 打开通话：选好了实时语音服务就用实时双向，否则轮流模式
    private func openVoiceCall() {
        // 点了就先给手感，接不通也一定说原因（真机：键盘开着点声波「没反应」——接通失败只写在消息列表底下看不见的小字里）
        CloudHaptics.tap()
        CloudE2E.reapplyRealtimeProvider()
        // 配好了实时语音：顶部浮动胶囊通话，对话留在下面；没配好：轮流通话全屏页
        guard let theme, CloudBotRealtimeAvailability.isConfigured(botId: theme.botId) else { openTurnsVoice(); return }
        // 选过「以后这个模型都直接用普通语音」
        if CloudVoicePrecheck.remembersTurns(botId: theme.botId) { openTurnsVoice(); return }
        // 协议对不上（如普通 Gemini 名字）：在按钮这儿弹出去处面板，不再只留一行看不见的灰字
        if let problem = CloudVoicePrecheck.problem(botId: theme.botId) { reportVoiceProblem(problem); return }
        startFloatingCall(theme, pushToTalk: false)
    }

    /// 普通语音：录音→识别→回复→朗读（轮流通话全屏页）
    private func openTurnsVoice() {
        voiceMode = "turns"
        showVoiceCall = true
    }

    /// 接不通：警告震动 + 去处面板（换模型 / 普通语音 / 仍然尝试 / 去设置）
    private func reportVoiceProblem(_ text: String) {
        guard voiceRoute != text else { return }   // 接通流程和 call.error 可能报同一句
        CloudHaptics.warning()
        voiceRoute = text
    }

    private func startFloatingCall(_ theme: CloudBotChatTheme, pushToTalk: Bool) {
        guard !call.active else { withAnimation { voiceProblem = CloudVoiceStart.alreadyInCall }; return }
        CloudBotSpeaker.stop()
        let sid = sessionId
        call.onEnded = { start, seconds in
            CloudCallDivider.add(sid, start: start, seconds: seconds)
            callDividers = CloudCallDivider.load(sid)
        }
        Task {
            await call.startCloudBot(botName: theme.name, persona: botPersona(theme.botId), sessionId: sessionId,
                                     history: realtimeHistory(), delegate: { prompt in await delegateFromRealtime(prompt) },
                                     onSaved: { problem in
                                         realtimeNotice = problem
                                         loadSessionDetail()
                                     }, pushToTalk: pushToTalk, botId: theme.botId)
            if let problem = CloudVoiceStart.problem(active: call.active, error: call.error) {
                reportVoiceProblem(problem)
                return
            }
            if pushToTalk && pttHeld { call.setTalking(true) }
        }
    }

    /// 长按声波：按住说话（没在通话就先以「按住说话」模式接通）
    private func pushToTalk(_ on: Bool, theme: CloudBotChatTheme) {
        pttHeld = on
        if call.active { call.setTalking(on) }
        else if on, CloudBotRealtimeAvailability.isConfigured(botId: theme.botId), CloudVoicePrecheck.problem(botId: theme.botId) == nil {
            startFloatingCall(theme, pushToTalk: true)
        }
        // 实时语音用不了时，长按声波 = 打开「实时语音设置」（以前什么都不发生）
        else if on { CloudHaptics.selection(); showRealtimeSettings = true }
    }

    /// 实时通话的派单和通话中的文字输入走不同入口。
    private func delegateFromRealtime(_ prompt: String) async -> String? {
        do {
            let id = try await CloudVoiceBridge.startBotTask(sessionId: sessionId, prompt: prompt, model: model,
                                                            providerID: botHasOwnModel ? nil : selectedInstanceId)
            replyStatus.kick()
            return id
        } catch {
            voiceProblem = "云电脑未确认接收任务：\(error.localizedDescription)"
            return nil
        }
    }

    /// 实时通话开场带上的对话历史（只要可见文字）
    private func realtimeHistory() -> [[String: String]] {
        messages.compactMap { row in
            guard let role = row["role"] as? String, role == "user" || role == "assistant",
                  let text = row["content"] as? String, !text.isEmpty else { return nil }
            return ["role": role, "text": CloudMessageText.display(text).text]
        }
    }

    /// 消息列表（从 body 拆出来，免得类型检查超时）
    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if hasOlderHistory {
                        Button { loadOlder() } label: {
                            HStack(spacing: 6) {
                                if loadingOlder { ProgressView().controlSize(.small) }
                                Text(loadingOlder ? "正在加载…" : "加载更早的消息").font(.footnote)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderless)
                        .disabled(loadingOlder)
                    }
                    if let theme, messages.isEmpty, !isSubmitting, liveText.isEmpty {
                        VStack(spacing: 12) {
                            CloudBotAliveAvatar(spec: theme.spec, size: 120)
                            Text("和 \(theme.name) 说点什么").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                    let shownItems = theme == nil
                        ? CloudTaskFailure.display(messages.filter { ($0["role"] as? String) != "user" || !CloudInternalPrompt.isInternal($0) })
                        : []
                    if let theme {
                        Color.clear.frame(height: 1).id("chat-top")
                        let timestamps = threadRows.isEmpty && callDividers.isEmpty ? [] : turns.map { $0.raw["timestamp"] as? NSNumber }
                        let threadTimes = threadRows.isEmpty ? [] : timestamps.map { $0.map { Date(timeIntervalSince1970: $0.doubleValue) } }
                        let dividerTimes = callDividers.isEmpty ? [] : timestamps.map { $0?.doubleValue ?? 0 }
                        let threads = Dictionary(grouping: threadRows) { CloudBotThreadRules.anchor(firstAt: $0.firstAt, turnTimes: threadTimes) }
                        let dividers = Dictionary(grouping: callDividers) { CloudCallDivider.anchor($0, timestamps: dividerTimes) }
                        ForEach(threads[-1] ?? []) { CloudBotThreadCollapsedRow(item: $0) }
                        ForEach(dividers[-1] ?? []) { CloudCallDividerRow(seconds: $0.seconds) }
                        ForEach(Array(turns.enumerated()), id: \.element.presentationID) { idx, turn in
                            let msg = turn.message
                            if let outcome = turn.workerOutcome {
                                CloudWorkerOutcomeRow(outcome: outcome)
                                    .id(turn.presentationID)
                            } else if msg.role == .user {
                                cloudUserTurn(turn, theme: theme)
                                    .id(turn.presentationID)
                                anchoredReplies(after: turn, theme: theme)
                            } else {
                                let prevAssistant = idx > 0 && turns[idx - 1].message.role == .assistant
                                    && turns[idx - 1].workerOutcome == nil
                                let extras = reactionExtras(CloudMessageExtras(turn.textRaw))
                                CloudInstantFooterGate(turn:
                                    CloudAssistantTurnView(message: msg, spec: theme.spec, name: theme.name, accent: theme.accent,
                                                           showHeader: !prevAssistant, collapsible: true)
                                        .modifier(CloudAssistantLongPress(text: msg.content, extras: extras,
                                                                          onReact: reactToBot, onReply: { replyTarget = $0 },
                                                                          botId: theme.botId, onAsk: quickSend)),
                                    footer:
                                    CloudAssistantFooter(text: msg.content, latency: CloudLatency.line(for: turn.raw, tasks: tasks),
                                                         extras: extras, selfId: theme.botId,
                                                         onReact: { reactToBot($0, $1) }, onReply: { replyTarget = $0 }))
                                    .id(turn.presentationID)
                            }
                            if idx == turns.count - 1, msg.role == .assistant, turn.workerOutcome == nil, activeTaskStatus != "running" {
                                CloudSmartReplyBar(text: msg.content, accent: theme.accent, onPick: quickSend)
                            }
                            ForEach(threads[idx] ?? []) { CloudBotThreadCollapsedRow(item: $0) }
                            ForEach(dividers[idx] ?? []) { CloudCallDividerRow(seconds: $0.seconds) }
                        }
                    }
                    ForEach(Array(shownItems.enumerated()), id: \.offset) { _, item in
                        let msg = item.message
                        let role = msg["role"] as? String ?? "user"
                        let content = msg["content"] as? String ?? ""
                        if !item.steps.isEmpty {
                            CloudStepsLine(steps: item.steps)
                        }
                        Group {
                            if let theme {
                                CloudThemedBubble(role: role, content: content, accent: theme.accent)
                            } else {
                                CloudMessageBubble(role: role, content: content)
                            }
                        }
                        .contextMenu {
                            Button { UIPasteboard.general.string = content } label: { Label("复制", systemImage: "doc.on.doc") }
                            if role == "assistant", let line = CloudLatency.line(for: msg, tasks: tasks) {
                                Text(line)
                            }
                        }
                    }
                    if theme == nil && !liveText.isEmpty {
                        CloudMessageBubble(role: "assistant", content: liveText)
                    }
                    if theme == nil && isSubmitting {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在发送，云端准备中…").font(.caption).foregroundStyle(.secondary) }
                    }

                    if let theme {
                        themedTaskArea(theme)
                    }
                    Color.clear.frame(height: 1).id("chat-bottom")

                    if theme == nil && !taskEvents.isEmpty {
                        Divider()
                        Text("当前/最新任务实时日志").font(.caption).bold().foregroundColor(.secondary)
                        let resolvedApprovals = Set(taskEvents.compactMap { ev -> String? in
                            guard ev["type"] as? String == "approval_resolved" else { return nil }
                            return (ev["payload"] as? [String: Any])?["approval_id"] as? String
                        })
                        ForEach(Array(taskEvents.enumerated()), id: \.offset) { _, ev in
                            let type = ev["type"] as? String ?? "event"
                            let payload = ev["payload"] as? [String: Any] ?? [:]
                            CloudTaskEventRow(type: type, payload: payload)
                            if type == "takeover_request" {
                                CloudTakeoverCard(reason: payload["reason"] as? String ?? "") { showComputer = true }
                            }
                            if type == "approval_required", activeTaskStatus == "waiting_user",
                               let aid = payload["approval_id"] as? String, !resolvedApprovals.contains(aid) {
                                HStack {
                                    Button("拒绝") { decide(approvalId: aid, approve: false) }
                                        .buttonStyle(.bordered).tint(.red)
                                    Button("批准执行") { decide(approvalId: aid, approve: true) }
                                        .buttonStyle(.borderedProminent).tint(.orange)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .padding()
            }
            .modifier(CloudChatScrollTracking(followLatest: $followLatest, isUserScrolling: $isUserScrolling))
            .environment(\.cloudChatActions, chatActions)
            // 往下拖消息收起键盘（和信息 App 一样）；以前键盘只能点别处收，拖动时键盘一直顶着，叠放卡片被挤到导航栏下面
            .scrollDismissesKeyboard(.interactively)
            // 病区语音：打开「双击消息区开语音」后，戴手套也能双击屏幕任意处开始和 Bot 说话（只在 Bot 对话里）
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                let drafting = !inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if theme != nil, CloudWardVoice.shouldOpenVoice(enabled: doubleTapVoice, submitting: isSubmitting, editing: drafting) {
                    CloudHaptics.tap(); openVoiceCall()
                }
            })
            .overlay(alignment: .bottomTrailing) {
                if theme != nil && messages.count > 4 {
                    CloudScrollButtons(onTop: {
                        followLatest = false
                        withAnimation { proxy.scrollTo("chat-top", anchor: .top) }
                    }, onBottom: {
                        followLatest = true
                        withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                    })
                }
            }
            .onChange(of: messages.count) { _ in
                if let anchor = historyScrollAnchor {
                    historyScrollAnchor = nil
                    proxy.scrollTo(anchor, anchor: .top)
                    return
                }
                guard followLatest, !isUserScrolling else { return }
                withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard followLatest, !isUserScrolling else { return }
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
        }
        // 看图页「问问这张图」：图片放回附件，输入框起个头
        .environment(\.cloudAskImage, askAboutImage)
        .environment(\.cloudAttachmentSession, sessionId)
    }

    /// 往前翻一页：接在最前面
    private func loadOlder() {
        guard hasOlderHistory, !loadingOlder, let oldest = CloudHistoryPager.oldestId(messages) else { return }
        loadingOlder = true
        Task {
            let res = try? await quietly(CloudHistoryPager.olderPath(sessionId, before: oldest))
            await MainActor.run {
                loadingOlder = false
                guard let res else { return }
                let page = res["messages"] as? [[String: Any]] ?? []
                hasOlderHistory = (res["has_more"] as? Bool ?? false) && !page.isEmpty
                guard !page.isEmpty else { return }
                let merged = CloudHistoryPager.prepend(page, to: messages)
                guard merged.count != messages.count else { return }
                if theme != nil {
                    followLatest = false
                    historyScrollAnchor = turns.first?.presentationID
                }
                messages = merged
                rebuildTurns()
            }
        }
    }

    private func askAboutImage(_ img: UIImage) {
        if let a = CloudAttachmentKit.image(img, name: "引用的图片.jpg") { attachments.append(a) }
        if inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { inputPrompt = "关于这张图片：" }
    }

    private func photoTarget(_ kind: String) -> CloudPhotoRouter.Candidate? {
        let bots = CloudBotHomeModel.shared.bots.filter { !CloudBotLock.shared.isLocked($0.id) }.map {
            CloudPhotoRouter.Candidate(id: $0.id, name: $0.name,
                                       text: $0.summary + " " + String($0.instructions.prefix(300)) + " " + ($0.skills ?? []).joined(separator: " "))
        }
        return CloudPhotoRouter.best(kind: kind, current: theme?.botId ?? "", bots: bots)
    }

    /// 把选好的图片和识别要求原样带到那个 Bot 的对话里（不自动发送，用户看一眼再发）
    private func handPhoto(to botId: String) {
        CloudHaptics.selection()
        let home = CloudBotHomeModel.shared
        home.pendingPrompt = CloudBotPendingPrompt(botId: botId, text: inputPrompt, send: false, attachments: attachments)
        attachments = []
        inputPrompt = ""
        photoKind = nil
        home.pendingOpen = botId
    }

    /// 实时通话用的完整设定：灵魂设定 + 指令 + 这个 Bot 的语音设置（语速、语言）
    private func botPersona(_ botId: String) -> String {
        guard let bot = CloudBotHomeModel.shared.bots.first(where: { $0.id == botId }) else { return "" }
        let voice = CloudBotVoiceSettings.load(botId)
        return CloudRealtimePersona.compose(botName: bot.name, instructions: bot.instructions, soul: bot.soul,
                                            speed: voice.speed, language: voice.language)
    }

    /// 卡片用的动作：选项卡点选后作为下一条消息发出（带 choice_answer，服务器标记卡片已答）
    private var chatActions: CloudChatActions {
        CloudChatActions(answerChoice: { mid, selected, custom, dismissed, text in
            var ans: [String: Any] = ["message_id": mid, "selected": selected, "dismissed": dismissed]
            if let custom { ans["custom"] = custom }
            pendingExtras = ["choice_answer": ans]
            inputPrompt = text
            sendTask()
        }, sessionId: sessionId)
    }

    /// 用户给 Bot 的消息点表情（nil = 取消）
    /// 先在本地显示（带弹出动画），再同步到服务器；失败就撤回本地显示
    private func reactToBot(_ messageId: Int, _ emoji: String?) {
        CloudHaptics.selection()
        localReactions[messageId] = .some(emoji)
        Task {
            do {
                try await CloudRunModelService.react(sessionId: sessionId, messageId: messageId, emoji: emoji)
            } catch {
                localReactions[messageId] = nil
                CloudHaptics.warning()
            }
            loadSessionDetail()
        }
    }

    private func loadThreadRows() {
        let sid = sessionId
        Task {
            if let rows = try? await CloudBotThreadService.collapsed(sessionId: sid) { threadRows = rows }
        }
    }

    private func reactionExtras(_ e: CloudMessageExtras) -> CloudMessageExtras {
        guard let id = e.id, let local = localReactions[id] else { return e }
        var out = e
        out.userReaction = local
        return out
    }

    private func cloudUserTurn(_ turn: CloudHistoryAdapter.Turn, theme: CloudBotChatTheme) -> some View {
        let nonce = CloudHistoryPager.pendingNonce(turn.raw)
        let queued = nonce.flatMap { delivery.canWithdraw($0) ? $0 : nil }
        let label = nonce != nil && nonce == delivery.uploadingNonce
            ? "正在上传附件"
            : queued.map { delivery.remoteQueue[$0] == nil ? "待发送" : "等待回复" }
        return CloudUserTurnRow(message: turn.message, accent: theme.accent, extras: reactionExtras(CloudMessageExtras(turn.raw)),
                                onReply: { replyTarget = $0 }, onReact: reactToBot, botId: theme.botId, onAsk: quickSend,
                                onRetry: { retryUserSend(turn.message) },
                                pendingLabel: label, onWithdraw: queued.map { id in { withdrawQueuedSend(id) } })
    }

    private var usesReplyAnchors: Bool {
        (taskIsLive || historyHidesTask) && serverTracksReplyTurns && replyPlan?.isInstant == true
    }

    private func hasReplyAnchor(_ nonce: String?) -> Bool {
        guard usesReplyAnchors, let nonce else { return false }
        return userTurn(nonce: nonce) != nil
    }

    @ViewBuilder
    private func anchoredReplies(after turn: CloudHistoryAdapter.Turn, theme: CloudBotChatTheme) -> some View {
        if usesReplyAnchors, let nonce = turn.raw["client_nonce"] as? String {
            ForEach(completedLiveReplies.filter { $0.nonce == nonce }) { reply in
                CloudAssistantTurnView(message: reply.message, spec: theme.spec, name: theme.name, accent: theme.accent)
            }
            if liveReplyNonce == nonce, !liveMessage.blocks.isEmpty || liveMessage.error != nil || !liveText.isEmpty || !liveReasoning.isEmpty {
                CloudAssistantTurnView(message: liveMessage, spec: theme.spec, name: theme.name, accent: theme.accent,
                                       liveText: liveText, liveReasoning: liveReasoning)
            }
        }
    }

    private func submitPrepared(content: String, body rawBody: [String: Any], providerInstanceId: String? = nil) {
        var body = rawBody
        let nonce = body["client_nonce"] as? String ?? UUID().uuidString
        body["client_nonce"] = nonce
        let items = attachments
        attachments = []
        inputPrompt = ""
        followLatest = true
        showPendingSend(content: content, nonce: nonce)
        CloudHaptics.tap()
        NotificationCenter.default.post(name: CloudReplyService.kick, object: nil)
        if let r = replyTarget {
            body["reply_to"] = r.id      // 引用回复
            replyTarget = nil
        }
        for (k, v) in pendingExtras { body[k] = v }
        pendingExtras = [:]
        // 思考深度：Bot 自己设置了就由服务器使用；否则带上手机默认
        let effort = theme.flatMap { CloudEffort(rawValue: $0.effort) } ?? CloudEffort.globalDefault
        if effort != .off { body["reasoning_effort"] = effort.rawValue }
        errorMessage = nil
        sendStartedAt = Date()
        replyLatency.sent()
        let item = CloudDeliveryBox.Item(content: content, nonce: nonce, body: body, attachments: items,
                                         providerInstanceId: providerInstanceId)
        persistSend(item)
        delivery.items.append(item)
        pumpDelivery()
    }

    /// 用户在「电脑」页点了「我完成了」：把控制权交回 Bot
    private func sendFinished() {
        guard activeTaskStatus != "running", !isSubmitting else { return }
        inputPrompt = "我完成了：已在云电脑上完成手动操作（登录 / 验证码等），请截图确认后继续。"
        sendTask()
    }

    /// 撤回刚发的消息：服务器停任务并删掉这条，文字放回输入框
    private func undoSend(_ r: CloudRetract) {
        Task { @MainActor in
            do {
                _ = try await connection.request(method: "POST", path: "/v1/tasks/\(r.taskId)/retract", body: [:])
                messages.removeAll { $0["client_nonce"] as? String == r.nonce }
                turns.removeAll { $0.raw["client_nonce"] as? String == r.nonce }
                if activeTaskId == r.taskId {
                    activeTaskStatus = "cancelled"
                    historyHidesTask = false
                    completedLiveReplies = []
                    liveMessage = ChatMessage(role: .assistant, content: "")
                    liveText = ""
                    liveReasoning = ""
                }
                if inputPrompt.isEmpty { inputPrompt = r.content }
                CloudHaptics.success()
            } catch {
                errorMessage = "撤回失败：\(error.localizedDescription)"
            }
        }
    }

    /// 快捷回复 / 翻译：直接发（Bot 正在跑时不发，免得打断）
    private func quickSend(_ text: String) {
        guard activeTaskStatus != "running", !isSubmitting else { return }
        inputPrompt = text
        sendTask()
    }

    private func sendRedacted() {
        inputPrompt = CloudPrivacyScan.redact(inputPrompt)
        sendAnyway()
    }

    private func sendAnyway() {
        privacyHits = []
        privacyConfirmed = true
        sendTask()
    }

    private func sendTask() {
        let content = inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty else { return }
        switch CloudInCallSend.route(inCall: call.active, text: content, hasAttachments: !attachments.isEmpty) {
        case .realtimeSpeak:
            inputPrompt = ""
            call.speakUserText(content)
            return
        case .blockAttachments:
            errorMessage = "正在实时通话，请先挂断再发图片或文件。"
            return
        case .textChat:
            break
        }
        if content == "/reset" && attachments.isEmpty {
            inputPrompt = ""
            resetContext()
            return
        }
        // 病区隐私自查：疑似身份信息先在手机上提醒（本地正则，不上传）
        if !privacyConfirmed, CloudPrivacyScan.enabled {
            let hits = CloudPrivacyScan.hits(content)
            if !hits.isEmpty {
                privacyHits = hits
                return
            }
        }
        privacyConfirmed = false
        let nonce = UUID().uuidString
        if botHasOwnModel {
            // Bot 已固定模型与加密保存的凭据：由服务器选择，不需要手机上的 Key
            submitPrepared(content: content, body: ["content": content, "model": model.isEmpty ? "bot" : model, "provider": [String: Any](), "client_nonce": nonce])
            return
        }

        guard !selectedInstanceId.isEmpty,
              let inst = ProviderConfigStore.shared.instance(for: selectedInstanceId),
              inst.isEnabled,
              inst.providerType == .openAI,
              inst.credentialType == .apiKey,
              !inst.azureMode else {
            errorMessage = "请先在设置中选择有效的 OpenAI API Key 服务商（不支持 Azure 或非 OpenAI 服务商）"
            return
        }

        guard let key = ProviderKeychainHelper.loadAPIKey(instanceId: inst.id), !key.isEmpty else {
            errorMessage = "所选服务商 \(inst.label) 未配置 API Key，请先在 Manage Providers 中配置"
            return
        }

        let resolved = inst.resolvedBaseURL(default: "https://api.openai.com")
        let finalBaseURL = resolved.appendV1 ? "\(resolved.url)/v1" : resolved.url

        let body: [String: Any] = [
            "content": content,
            "model": model,
            "provider": [
                "base_url": finalBaseURL,
                "api_key": key
            ],
            "instructions": "你是运行在用户指定 VPS 上的 OpenMinis 云端 Agent。使用中文回答，调用工具完成任务并根据真实输出核验结果。Shell 与文件操作均发生在 VPS 工作区，不具有手机照片、日历等本机工具。不要声称未执行的操作已经完成。",
            "client_nonce": nonce
        ]

        submitPrepared(content: content, body: body, providerInstanceId: inst.id)
    }

    private func showPendingSend(content: String, nonce: String, createdAt: Double = Date().timeIntervalSince1970) {
        guard !messages.contains(where: { $0["client_nonce"] as? String == nonce }) else { return }
        let text = content.isEmpty ? "附件" : content
        let msg = ChatMessage(role: .user, content: text)
        let row: [String: Any] = ["role": "user", "content": text, "timestamp": createdAt, "client_nonce": nonce]
        messages.append(row)
        turns.append(CloudHistoryAdapter.Turn(message: msg, raw: row))
    }

    private func userTurn(nonce: String) -> CloudHistoryAdapter.Turn? {
        turns.last { $0.message.role == .user && $0.raw["client_nonce"] as? String == nonce }
    }

    private func markUserSent(nonce: String) {
        guard let t = userTurn(nonce: nonce), t.message.sendTick == .failed else { return }
        t.message.sendTick = nil
        failedSends[t.message.id] = nil
    }

    private func markUserFailed(item: CloudDeliveryBox.Item) {
        guard let t = userTurn(nonce: item.nonce) else { return }
        t.message.sendTick = .failed
        failedSends[t.message.id] = item
    }

    private func retryUserSend(_ message: ChatMessage) {
        guard let item = failedSends.removeValue(forKey: message.id) else { return }
        message.sendTick = nil
        delivery.items.append(item)
        pumpDelivery()
    }

    private func markUserAdopted() {
        if let nonce = liveReplyNonce {
            userTurn(nonce: nonce)?.message.adoptedMark = true
        } else if !usesReplyAnchors {
            turns.last { $0.message.role == .user }?.message.adoptedMark = true
        }
    }

    private enum DeliveryResult {
        case sent, queued, retry, cancelled
        case failed(String)
    }

    private func pumpDelivery() {
        guard !delivery.running, !delivery.paused, !delivery.items.isEmpty else { return }
        delivery.running = true
        Task { @MainActor in
            defer { delivery.running = false }
            var attempt = 0
            while !delivery.paused, !delivery.items.isEmpty {
                var item = delivery.items.removeFirst()
                delivery.inFlightNonce = item.nonce
                var result: DeliveryResult
                do {
                    if !item.attachments.isEmpty {
                        delivery.uploadingNonce = item.nonce
                        let lines = try await CloudAttachmentKit.upload(item.attachments, sessionId: sessionId)
                        delivery.uploadingNonce = nil
                        let text = item.content.isEmpty ? CloudAttachmentLines.placeholderText : item.content
                        item.body["content"] = text + "\n\n" + lines.joined(separator: "\n")
                        item.body.removeValue(forKey: "message_parts")
                        item.attachments = []
                        persistSend(item)
                    }
                    result = try await deliver(item)
                } catch let error where CloudOutbox.isTransient(error) {
                    result = .retry
                } catch {
                    result = .failed(error.localizedDescription)
                }
                delivery.uploadingNonce = nil
                delivery.inFlightNonce = nil
                if delivery.cancelled.remove(item.nonce) != nil { result = .cancelled }

                switch result {
                case .retry:
                    persistSend(item)
                    delivery.retrying.insert(item.nonce)
                    delivery.items.insert(item, at: 0)
                    let retryAt = Date().addingTimeInterval(CloudOutbox.retryDelay(attempt: attempt))
                    attempt += 1
                    while !delivery.paused, delivery.items.first?.nonce == item.nonce, Date() < retryAt {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                case .queued:
                    delivery.retrying.remove(item.nonce)
                    attempt = 0
                case .sent, .cancelled:
                    finishPendingSend(item.nonce)
                    attempt = 0
                case .failed(let reason):
                    finishPendingSend(item.nonce)
                    errorMessage = reason
                    markUserFailed(item: item)
                    attempt = 0
                }
            }
        }
    }

    private func deliver(_ item: CloudDeliveryBox.Item) async throws -> DeliveryResult {
        if let tid = activeTaskId, taskIsLive {
            if CloudReplyDeliveryPolicy.canInterrupt(enabled: steerInterrupt, body: item.body) {
                if let result = await injectMessage(item, taskId: tid) { return result }
            } else if let result = try await waitForDeliverySlot(taskId: tid, nonce: item.nonce) {
                return result
            }
        }
        return try await postSessionMessage(item)
    }

    private func injectMessage(_ item: CloudDeliveryBox.Item, taskId: String) async -> DeliveryResult? {
        let content = item.body["content"] as? String ?? item.content
        switch await CloudInjector.inject(taskId: taskId, content: content, nonce: item.nonce) {
        case .injected(let state):
            if state == "withdrawn" {
                removePendingBubble(item.nonce)
            } else if state == "queued" {
                let finalEvent = taskEvents.last {
                    ($0["payload"] as? [String: Any])?["nonce"] as? String == item.nonce
                        && ["user_message_applied", "user_message_rejected", "user_message_withdrawn"].contains($0["type"] as? String ?? "")
                }?["type"] as? String
                if finalEvent == "user_message_rejected" {
                    return .retry
                }
                if finalEvent == "user_message_withdrawn" { removePendingBubble(item.nonce) }
                if finalEvent == nil {
                    delivery.remoteQueue[item.nonce] = .init(taskId: taskId, item: item)
                    persistSend(item)
                    markUserSent(nonce: item.nonce)
                    if replyPlan?.isInstant == true { replyStatus.kick() }
                    return .queued
                }
            }
            markUserSent(nonce: item.nonce)
            if replyPlan?.isInstant == true { replyStatus.kick() }
            return .sent
        case .notRunning:
            return nil
        case .retryable:
            return .retry
        case .failed(let reason):
            return .failed(reason)
        }
    }

    private func postSessionMessage(_ item: CloudDeliveryBox.Item, retryBusy: Bool = true) async throws -> DeliveryResult {
        var body = item.body
        if let instanceId = item.providerInstanceId,
           var provider = body["provider"] as? [String: Any], provider["api_key"] == nil {
            guard let inst = ProviderConfigStore.shared.instance(for: instanceId), inst.isEnabled,
                  inst.providerType == .openAI, inst.credentialType == .apiKey, !inst.azureMode,
                  let key = ProviderKeychainHelper.loadAPIKey(instanceId: instanceId), !key.isEmpty else {
                return .failed("原服务商的 API Key 不可用，恢复配置后可重试这条消息")
            }
            let resolved = inst.resolvedBaseURL(default: "https://api.openai.com")
            provider["base_url"] = resolved.appendV1 ? "\(resolved.url)/v1" : resolved.url
            provider["api_key"] = key
            body["provider"] = provider
        }
        do {
            try await connection.ensureConnected()
            let res = try await connection.request(method: "POST", path: "/v1/sessions/\(sessionId)/messages", body: body)
            markUserSent(nonce: item.nonce)
            if res["idempotent_replayed"] as? Bool == true {
                if res["state"] as? String == "withdrawn" { removePendingBubble(item.nonce) }
                loadSessionDetail()
            } else if let tid = res["task_id"] as? String {
                await accepted(taskId: tid, content: item.content, nonce: item.nonce)
            }
            return .sent
        } catch let busy as CloudSessionBusyError where retryBusy {
            if CloudReplyDeliveryPolicy.canInterrupt(enabled: steerInterrupt, body: body),
               let result = await injectMessage(item, taskId: busy.taskId) { return result }
            if let result = try await waitForDeliverySlot(taskId: busy.taskId, nonce: item.nonce) { return result }
            return try await postSessionMessage(item, retryBusy: false)
        }
    }

    private func waitForDeliverySlot(taskId: String, nonce: String) async throws -> DeliveryResult? {
        delivery.waitingNonce = nonce
        defer { delivery.waitingNonce = nil }
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            if delivery.cancelled.contains(nonce) { return .cancelled }
            let status: String
            let watchesTask = taskId == activeTaskId
            if watchesTask {
                status = activeTaskStatus
            } else {
                let response = try await connection.request(method: "GET", path: "/v1/tasks/\(taskId)")
                status = response["status"] as? String ?? "unknown"
            }
            if !["running", "waiting_user", "queued"].contains(status) {
                return delivery.cancelled.contains(nonce) ? .cancelled : nil
            }
            try await Task.sleep(nanoseconds: watchesTask ? 350_000_000 : 800_000_000)
        }
        return .failed("排队发送未完成，点消息旁的按钮重试")
    }

    /// 服务器收下了这条消息：进入「运行中」并开始拉进度
    private func accepted(taskId tid: String, content: String, nonce: String) async {
        await MainActor.run {
            self.activeTaskId = tid
            self.activeTaskStatus = "running"
            self.watchedTasks.insert(tid)
            self.liveMessage = ChatMessage(role: .assistant, content: "")
            self.completedLiveReplies = []
            self.initialReplyNonce = nonce
            self.liveReplyNonce = nonce
            self.taskEvents = []
            self.ledger.reset()
            self.eventCursor = 0
            self.liveText = ""
            self.liveSeq = -1
            self.activeTaskCreatedAt = nil
            self.historyHidesTask = true
            self.retractable = CloudRetract(taskId: tid, content: content, nonce: nonce)
        }
        let botId = theme?.botId, sid = sessionId
        Task { @MainActor in
            let locked = botId.map { CloudBotLock.isLockedStored($0) } ?? false
            if let note = await CloudFollowUpScheduler.schedule(text: content, sessionId: sid, botId: botId, botLocked: locked) {
                followUpNotice = note
            }
        }
        if replyPlan?.isInstant == true { await MainActor.run { replyStatus.kick() } }
        pollTaskStatus(taskId: tid)
    }

    private func persistSend(_ item: CloudDeliveryBox.Item) {
        guard canStoreOutbox, item.attachments.isEmpty,
              theme.map({ !CloudBotLock.isLockedStored($0.botId) }) ?? true,
              let data = CloudOutbox.encode(item.body, providerInstanceId: item.providerInstanceId) else { return }
        CloudOutbox.shared.add(.init(nonce: item.nonce, sessionId: sessionId, content: item.content, body: data,
                                    createdAt: item.createdAt, providerInstanceId: item.providerInstanceId))
    }

    private func finishPendingSend(_ nonce: String) {
        CloudOutbox.shared.remove(nonce)
        delivery.retrying.remove(nonce)
    }

    private func removePendingBubble(_ nonce: String) {
        messages.removeAll { CloudHistoryPager.pendingNonce($0) == nonce }
        turns.removeAll { CloudHistoryPager.pendingNonce($0.raw) == nonce }
    }

    private func withdrawQueuedSend(_ nonce: String) {
        if delivery.waitingNonce == nonce {
            delivery.cancelled.insert(nonce)
        } else if let index = delivery.items.firstIndex(where: { $0.nonce == nonce }) {
            delivery.items.remove(at: index)
        } else if let received = delivery.remoteQueue[nonce] {
            Task { @MainActor in
                do {
                    _ = try await connection.request(method: "POST", path: "/v1/tasks/\(received.taskId)/messages/withdraw",
                                                     body: ["nonce": nonce])
                    delivery.remoteQueue[nonce] = nil
                    finishPendingSend(nonce)
                    removePendingBubble(nonce)
                    CloudHaptics.success()
                } catch {
                    errorMessage = "撤回失败：\(error.localizedDescription)"
                }
            }
            return
        } else {
            return
        }
        finishPendingSend(nonce)
        removePendingBubble(nonce)
        CloudHaptics.success()
    }

    private func resumeOutbox() {
        if let theme, CloudBotEntry.pendingVoiceBot == theme.botId {
            CloudBotEntry.pendingVoiceBot = nil
            openVoiceCall()
        }
        delivery.paused = false
        let queued = Set(delivery.items.map(\.nonce))
        let restored = CloudOutbox.shared.items(for: sessionId).compactMap { item -> CloudDeliveryBox.Item? in
            guard item.nonce != delivery.inFlightNonce, !queued.contains(item.nonce), delivery.remoteQueue[item.nonce] == nil,
                  let body = CloudOutbox.decode(item.body) else { return nil }
            showPendingSend(content: item.content, nonce: item.nonce, createdAt: item.createdAt)
            return .init(content: item.content, nonce: item.nonce, body: body,
                         providerInstanceId: item.providerInstanceId, createdAt: item.createdAt)
        }
        delivery.items.insert(contentsOf: restored, at: 0)
        pumpDelivery()
    }

    private func pauseOutbox() { delivery.paused = true }

    private var outboxCount: Int {
        delivery.retrying.isEmpty ? 0 : delivery.items.count
    }

    private func discardOutbox() {
        for nonce in delivery.items.map(\.nonce) {
            withdrawQueuedSend(nonce)
        }
    }

    private func retryUnappliedSends(taskId: String) {
        let pending = delivery.remoteQueue.values.filter { $0.taskId == taskId }
            .sorted { $0.item.createdAt < $1.item.createdAt }
        guard !pending.isEmpty else { return }
        for received in pending { delivery.remoteQueue[received.item.nonce] = nil }
        delivery.items.insert(contentsOf: pending.map(\.item), at: 0)
        pumpDelivery()
    }

    private func pollTaskStatus(taskId: String) {
        guard !isPolling else { return }
        isPolling = true
        Task {
            do {
                let res = try await quietly("/v1/tasks/\(taskId)")
                await MainActor.run {
                    self.isPolling = false
                    guard self.activeTaskId == taskId else {
                        if let current = self.activeTaskId { self.pollTaskStatus(taskId: current) }
                        return
                    }
                    if let status = res["status"] as? String {
                        self.activeTaskStatus = status
                    }
                    if let events = res["events"] as? [[String: Any]] {
                        if self.loadedTaskId != taskId || self.liveMessage.blocks.isEmpty {
                            // 换了任务（或第一次打开）：从全量事件重建一份
                            self.liveMessage = ChatMessage(role: .assistant, content: "")
                            self.completedLiveReplies = []
                            self.liveReplyNonce = self.initialReplyNonce
                            self.taskEvents = []
                            self.ledger.reset()
                            self.eventCursor = 0
                        }
                        // 同一个任务：只补上还没用过的事件（之前这里整份重建，又和长轮询的事件叠在一起，文字和步骤会重复）
                        _ = self.ingest(events)
                    }
                    self.loadedTaskId = taskId
                    self.errorMessage = nil
                    if ["running", "waiting_user", "queued"].contains(self.activeTaskStatus) {
                        self.streamEvents(taskId: taskId)
                    }
                    if ["running", "waiting_user", "queued"].contains(self.activeTaskStatus) {
                        self.watchedTasks.insert(taskId)
                    } else {
                        self.retryUnappliedSends(taskId: taskId)
                        // 只对「这次在界面上看着它跑」的任务提示失败；打开对话时看到的旧任务结果不再弹横幅
                        if self.watchedTasks.contains(taskId), ["failed", "interrupted", "limit_reached"].contains(self.activeTaskStatus) {
                            self.errorMessage = CloudTaskFailure.text(status: self.activeTaskStatus, events: self.taskEvents)
                        }
                        loadSessionDetail()
                    }
                }
            } catch {
                await MainActor.run {
                    self.isPolling = false
                    // 静默：任务在云端继续，稍后再接上
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if let current = self.activeTaskId { self.pollTaskStatus(taskId: current) }
                    }
                }
            }
        }
    }

    /// 打开对话或开始输入时让服务器预热到模型服务商的连接（最多一分钟一次，失败无影响）
    private func warmUp() {
        guard Date().timeIntervalSince(lastWarm) > 60, connection.isConnected else { return }
        lastWarm = Date()
        let sid = sessionId
        Task { _ = try? await connection.request(method: "POST", path: "/v1/sessions/\(sid)/warm", body: [:]) }
    }

    /// 长轮询任务事件：服务器有新事件或新生成的文字时立刻返回，边生成边显示；旧版服务器不支持 wait 时退化为每秒轮询
    /// 与本地模式共用 CloudTaskPump：长轮询 + 正在生成的文字；出错静默退避重试，不退出、不拆隧道
    private func streamEvents(taskId: String) {
        guard !isStreaming else { return }
        isStreaming = true
        let started = sendStartedAt
        sendStartedAt = nil
        Task { @MainActor in
            let final = await CloudTaskPump.run(
                taskId: taskId,
                after: eventCursor,
                options: .init(mode: "bot", wait: 15, live: true, startedAt: started),
                liveSeq: { self.liveSeq },
                shouldStop: { self.activeTaskId != taskId },
                onBatch: { batch in
                    guard self.activeTaskId == taskId else { return }
                    let fresh = self.ingest(batch.events)
                    if !fresh.isEmpty {
                        // Bot 需要你登录 / 接管：自动打开这个 Bot 的「电脑」页（每个任务只自动打开一次）
                        if batch.events.contains(where: { $0["type"] as? String == "takeover_request" }), !self.autoOpenedComputer.contains(taskId) {
                            self.autoOpenedComputer.insert(taskId)
                            CloudHaptics.warning()
                            self.showComputer = true
                        }
                        // 一段话写进了事件或模型开始调用工具：正在生成的那段文字已经结束
                        if fresh.contains(where: { ["tool_call", "thought", "final", "error"].contains($0["type"] as? String ?? "") }) { self.liveText = "" }
                        if fresh.contains(where: { ["reasoning", "tool_call", "thought", "final", "error"].contains($0["type"] as? String ?? "") }) { self.liveReasoning = "" }
                    }
                    if let live = batch.live, let t = live["text"] as? String, let s = live["seq"] as? Int {
                        self.liveText = t
                        self.liveReasoning = live["reasoning"] as? String ?? ""
                        self.liveTool = CloudLiveTool(live["tool"])
                        self.liveSeq = s
                    } else if !fresh.isEmpty, fresh.contains(where: { $0["type"] as? String == "tool_result" }) {
                        self.liveTool = nil
                    }
                    if let s = batch.rawStatus { self.activeTaskStatus = s }
                    if !self.liveText.isEmpty || fresh.contains(where: { ["thought", "text", "content", "final"].contains($0["type"] as? String ?? "")
                        && !((($0["payload"] as? [String: Any])?["content"] as? String) ?? "").isEmpty }) { self.replyLatency.sawText() }
                    // 结束了：正在生成的那段文字已经写进最后一轮，别再单独画一遍
                    if batch.status?.isTerminal == true { self.liveText = ""; self.liveReasoning = ""; self.liveTool = nil }
                },
                onTrouble: { text in self.streamNotice = text })
            self.isStreaming = false
            self.streamNotice = nil
            guard self.activeTaskId == taskId else {
                if let current = self.activeTaskId { self.pollTaskStatus(taskId: current) }
                return
            }
            guard let final else { return }
            self.retryUnappliedSends(taskId: taskId)
            if self.watchedTasks.contains(taskId), [.failed, .interrupted, .limitReached].contains(final) {
                self.errorMessage = CloudTaskFailure.text(status: final.rawValue, events: self.taskEvents)
            }
            self.loadSessionDetail()
        }
    }

    /// 服务器说这个对话现在是秒回还是详细：秒回就开始看后台任务（老服务器没有这个字段 = 详细，和以前一样）
    private func applyReplyPlan(_ plan: CloudReplyPlan?) {
        replyPlan = plan
        guard let theme else { return }
        if plan?.isInstant == true {
            replyStatus.botName = theme.name
            replyStatus.locked = CloudBotLock.isLockedStored(theme.botId)
            replyStatus.onWorkerFinished = { loadSessionDetail() }
            replyStatus.start(sessionId: sessionId)
        } else {
            replyStatus.stopPolling()
        }
    }

    private func decide(approvalId: String, approve: Bool) {
        if approve { CloudHaptics.success() } else { CloudHaptics.tap() }
        guard let tid = activeTaskId else { return }
        Task {
            do {
                _ = try await connection.request(method: "POST", path: "/v1/tasks/\(tid)/approvals/\(approvalId)",
                                                 body: ["decision": approve ? "approve" : "deny"])
                pollTaskStatus(taskId: tid)
            } catch {
                await MainActor.run { self.errorMessage = "提交审批失败: \(error.localizedDescription)" }
            }
        }
    }

    private func cancelActiveTask() {
        guard let tid = activeTaskId else { return }
        Task {
            do {
                _ = try await connection.request(method: "POST", path: "/v1/tasks/\(tid)/cancel", body: nil)
                await MainActor.run {
                    self.activeTaskStatus = "cancelled"
                }
                loadSessionDetail()
            } catch {
                await MainActor.run {
                    self.errorMessage = "取消任务失败: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Helper Subviews
struct CloudMessageBubble: View {
    let role: String
    let content: String

    var body: some View {
        HStack {
            if role == "user" { Spacer() }
            VStack(alignment: role == "user" ? .trailing : .leading, spacing: 2) {
                Text(role == "user" ? "我" : "云端 Agent")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                let shown = CloudMessageText.display(content)
                if shown.images > 0 { CloudMessageImages(content: content, alignment: role == "user" ? .trailing : .leading) }
                Text(shown.text)
                    .padding(10)
                    .background(role == "user" ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground))
                    .cornerRadius(10)
            }
            if role != "user" { Spacer() }
        }
    }
}

struct CloudTaskEventRow: View {
    let type: String
    let payload: [String: Any]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("[\(type)]")
                    .font(.caption2)
                    .bold()
                    .foregroundColor(colorForType(type))
                Spacer()
            }
            if type == "thought", let text = payload["content"] as? String {
                Text(text).font(.footnote).italic()
            } else if type == "tool_call", let tool = payload["tool"] as? String, let args = payload["arguments"] {
                Text("调用工具: \(tool) -> \(String(describing: args))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.purple)
            } else if type == "approval_required" {
                Text("需要审批：\(payload["reason"] as? String ?? "") — \(payload["tool"] as? String ?? "")\n\(String(describing: payload["arguments"] ?? ""))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.orange)
            } else if type == "tool_result", let tool = payload["tool"] as? String, let res = payload["result"] {
                Text("工具结果 [\(tool)]: \(String(describing: res))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.green)
            } else {
                Text(payload.description)
                    .font(.caption2)
            }
        }
        .padding(8)
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(6)
    }

    private func colorForType(_ t: String) -> Color {
        switch t {
        case "thought": return .blue
        case "tool_call": return .purple
        case "tool_result": return .green
        case "error": return .red
        case "cancelled", "approval_required": return .orange
        default: return .secondary
        }
    }
}


/// 聊天显示规则与任务失败说明
enum CloudTaskFailure {
    /// 只显示用户与助手的文字消息：工具结果（role=tool）、只有工具调用没有文字的助手消息、空消息都不显示
    static func visible(_ messages: [[String: Any]]) -> [[String: Any]] {
        display(messages).map(\.message)
    }

    struct Item {
        let message: [String: Any]
        let steps: [CloudStep]
    }

    /// 把工具调用 / 工具结果折叠成下一条可见消息上方的「执行了 N 步」
    static func display(_ messages: [[String: Any]]) -> [Item] {
        var out: [Item] = []
        var pending: [CloudStep] = []
        var byId: [String: Int] = [:]
        for m in messages {
            let role = m["role"] as? String ?? ""
            let content = (m["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if role == "assistant", let calls = toolCalls(m) {
                for c in calls {
                    let fn = c["function"] as? [String: Any] ?? [:]
                    let name = fn["name"] as? String ?? "工具"
                    let args = fn["arguments"] as? String ?? ""
                    byId[c["id"] as? String ?? UUID().uuidString] = pending.count
                    pending.append(CloudStep(tool: name, detail: summarize(name, args), result: ""))
                }
            } else if role == "tool" {
                let id = m["tool_call_id"] as? String ?? ""
                if let i = byId[id], i < pending.count {
                    pending[i].result = String(content.prefix(2000))
                }
                continue
            }
            guard role == "user" || role == "assistant", !content.isEmpty else { continue }
            out.append(Item(message: m, steps: role == "assistant" ? pending : []))
            if role == "assistant" || role == "user" { pending = []; byId = [:] }
        }
        return out
    }

    private static func toolCalls(_ m: [String: Any]) -> [[String: Any]]? {
        if let a = m["tool_calls"] as? [[String: Any]], !a.isEmpty { return a }
        if let s = m["tool_calls"] as? String, let d = s.data(using: .utf8),
           let a = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]], !a.isEmpty { return a }
        return nil
    }

    private static func summarize(_ tool: String, _ args: String) -> String {
        guard let d = args.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "" }
        for k in ["command", "query", "url", "path", "content", "task", "action", "name"] {
            if let v = o[k] as? String, !v.isEmpty { return String(v.replacingOccurrences(of: "\n", with: " ").prefix(80)) }
        }
        return ""
    }

    /// 失败横幅：状态 + 任务日志里最后一条错误的中文原因
    static func text(status: String, events: [[String: Any]]) -> String {
        let head: String
        switch status {
        case "failed": head = "任务失败"
        case "interrupted": head = "任务被中断（服务器重启或断电）"
        case "limit_reached": head = "达到单次任务的轮数上限，已停下"
        default: head = "任务状态：\(status)"
        }
        let raw = events.reversed().first(where: { ($0["type"] as? String) == "error" })
            .flatMap { ($0["payload"] as? [String: Any])?["error"] as? String } ?? ""
        let reason = explain(raw)
        return reason.isEmpty ? head + "。可以直接再发一次。" : head + "：" + reason
    }

    static func explain(_ raw: String) -> String {
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return "" }
        let l = r.lowercased()
        if l.contains("401") || l.contains("unauthorized") || l.contains("invalid api key") { return "服务商拒绝了 API Key（401），请检查 Key 是否有效" }
        if l.contains("402") || l.contains("insufficient") || l.contains("quota") || l.contains("余额") { return "服务商额度不足，请充值或换一个服务商" }
        if l.contains("429") || l.contains("rate limit") { return "服务商限流（429），稍等片刻再试" }
        if l.contains("timed out") || l.contains("timeout") { return "调用模型超时，可能是服务商或网络慢，可以再试一次" }
        if l.contains("reasoning_content") { return "这个模型的思考模式要求回传思考内容，已在新版服务器修复，请更新服务器 Agent" }
        if l.contains("model") && (l.contains("not found") || l.contains("does not exist") || l.contains("404")) { return "服务商没有这个模型，请换一个模型" }
        if l.contains("50") && (l.contains("http 5") || l.contains("bad gateway") || l.contains("service unavailable")) { return "服务商临时故障（5xx），稍后再试" }
        return String(r.prefix(160))
    }
}


struct CloudStep {
    let tool: String
    let detail: String
    var result: String

    var label: String {
        switch tool {
        case "shell_execute": return "运行命令"
        case "file_read": return "读取文件"
        case "file_write", "file_edit": return "写文件"
        case "browser_action": return "操作浏览器"
        case "desktop_action": return "操作桌面"
        case "memory_search": return "查记忆"
        case "memory_write": return "记住"
        case "skill_load": return "加载技能"
        case "skill_save": return "保存技能"
        case "delegate_task", "send_to_bot": return "交给其他 Bot"
        case "subagent_task": return "子任务"
        case "page_write": return "写页面"
        case "image_generate": return "生成图片"
        default: return tool
        }
    }
}

/// 一行「执行了 N 步」，点开看每一步与结果
struct CloudStepsLine: View {
    let steps: [CloudStep]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checklist").font(.caption)
                    Text("执行了 \(steps.count) 步：" + steps.prefix(3).map(\.label).joined(separator: "、") + (steps.count > 3 ? "…" : ""))
                        .font(.caption).lineLimit(1)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if open {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, st in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(st.label + (st.detail.isEmpty ? "" : "：" + st.detail)).font(.caption.weight(.medium))
                        if !st.result.isEmpty {
                            Text(st.result).appTextFont(size: 11, design: .monospaced, relativeTo: .caption).foregroundStyle(.secondary).lineLimit(6)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

/// 图片识别的常用要求（选图后输入框上方的小标签）
enum CloudPhotoPrompts {
    static let all: [(String, String)] = [
        ("识别药品", "识别图中的药品：通用名、规格、常用剂量、主要禁忌与相互作用；看不清的地方直接说明，不要猜。"),
        ("读化验单", "读这张化验单：列出异常项（数值、参考范围、偏高/偏低），按临床意义排序，给出需要关注或复查的点。"),
        ("看心电图", "描述这张心电图：心率、节律、电轴、间期与 ST-T 改变，给出可能的判读；图像不清楚时说明哪里看不清。"),
        ("提取文字", "把图中的文字完整提取出来，保持原有分段和表格结构。"),
        ("这是什么", "这是什么？简单说明并告诉我需要注意什么。"),
    ]
}
