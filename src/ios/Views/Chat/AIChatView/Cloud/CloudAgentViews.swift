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

                    NavigationLink(destination: CloudDesktopView()) {
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
struct CloudSessionView: View {
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
    @State private var activeTaskId: String? = nil
    @State private var activeTaskStatus: String = "idle"
    @State private var taskEvents: [[String: Any]] = []
    @State private var isLoading = false
    @State private var isSubmitting = false
    @State private var watchedTasks: Set<String> = []
    /// 与本地模式同一个消息模型：服务器历史转换后的回合、正在进行任务的那条助手消息
    @State private var turns: [CloudHistoryAdapter.Turn] = []
    @State private var liveMessage = ChatMessage(role: .assistant, content: "")
    /// 连续几次取不到进度时的一行温和提示（不是红色横幅），恢复后自动清除
    @State private var streamNotice: String?
    @State private var sendStartedAt: Date?
    @State private var autoOpenedComputer: Set<String> = []
    @State private var isPolling = false
    @State private var loadedTaskId: String? = nil
    @State private var errorMessage: String? = nil
    @State private var showComputer = false
    @State private var attachments: [CloudPendingAttachment] = []
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showScanner = false
    @State private var showFiles = false
    @State private var showVoiceCall = false
    @StateObject private var dictation = CloudDictation()
    @State private var dictationBase = ""
    @State private var showModelPicker = false
    /// 模型正在生成的文字（服务器流式推送，长轮询拿到）
    @State private var liveText = ""
    @State private var liveSeq = -1
    @State private var eventCursor = 0
    @State private var isStreaming = false
    @State private var lastWarm = Date.distantPast

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

            // Messages & Event Log area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let theme, messages.isEmpty, !isSubmitting, liveText.isEmpty {
                            VStack(spacing: 12) {
                                CloudBotAliveAvatar(spec: theme.spec, size: 120)
                                Text("和 \(theme.name) 说点什么").font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        }
                        let shownItems = CloudTaskFailure.display(messages)
                        if let theme {
                            Color.clear.frame(height: 1).id("chat-top")
                            ForEach(Array(turns.enumerated()), id: \.offset) { idx, turn in
                                let msg = turn.message
                                if msg.role == .user {
                                    CloudProseUser(content: msg.content, accent: theme.accent)
                                        .contextMenu {
                                            Button { UIPasteboard.general.string = CloudMessageText.display(msg.content).text } label: { Label("复制", systemImage: "doc.on.doc") }
                                        }
                                } else {
                                    let prevAssistant = idx > 0 && turns[idx - 1].message.role == .assistant
                                    CloudAssistantTurnView(message: msg, spec: theme.spec, name: theme.name, accent: theme.accent,
                                                           showHeader: !prevAssistant, collapsible: true)
                                    HStack(spacing: 12) {
                                        Button { UIPasteboard.general.string = msg.content; CloudHaptics.success() } label: {
                                            Image(systemName: "doc.on.doc").font(.caption2)
                                        }
                                        .accessibilityLabel("复制回复")
                                        if let line = CloudLatency.line(for: turn.raw, tasks: tasks) {
                                            Text(line).font(.caption2)
                                        }
                                    }
                                    .foregroundStyle(.tertiary)
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        ForEach(Array((theme == nil ? shownItems : []).enumerated()), id: \.offset) { _, item in
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
                .overlay(alignment: .bottomTrailing) {
                    if theme != nil && messages.count > 4 {
                        CloudScrollButtons(onTop: { withAnimation { proxy.scrollTo("chat-top", anchor: .top) } },
                                           onBottom: { withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) } })
                    }
                }
                .onChange(of: messages.count) { _ in
                    withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
            }

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
                    .disabled(activeTaskStatus == "running" || isSubmitting)

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
        .sheet(isPresented: $showPhotos) { CloudPhotoPicker { attachments.append(contentsOf: $0) }.ignoresSafeArea() }
        .fullScreenCover(isPresented: $showCamera) { CloudCameraPicker { attachments.append($0) }.ignoresSafeArea() }
        .fullScreenCover(isPresented: $showScanner) { CloudDocumentScanner { attachments.append($0) }.ignoresSafeArea() }
        .sheet(isPresented: $showFiles) { CloudFilePicker { attachments.append(contentsOf: $0) }.ignoresSafeArea() }
        .fullScreenCover(isPresented: $showVoiceCall) {
            if let theme {
                CloudBotVoiceCallView(theme: theme, isWorking: activeTaskStatus == "running" || activeTaskStatus == "waiting_user" || isSubmitting,
                                      progress: CloudBotProgress.summarize(taskEvents, status: activeTaskStatus).0) { text in
                    inputPrompt = text
                    sendTask()
                }
            }
        }
        .onChange(of: messages.count) { _ in
            // 语音对话中：Bot 回复后按它的语音设置朗读
            guard showVoiceCall, let theme, let last = messages.last, last["role"] as? String == "assistant",
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
        }
        .onChange(of: inputPrompt.isEmpty) { empty in
            if !empty { warmUp() }
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

    private func loadSessionDetail() {
        isLoading = true
        Task {
            do {
                let res = try await quietly("/v1/sessions/\(sessionId)")
                await MainActor.run {
                    self.messages = res["messages"] as? [[String: Any]] ?? []
                    self.turns = CloudHistoryAdapter.turns(from: self.messages)
                    self.tasks = res["tasks"] as? [[String: Any]] ?? []
                    self.isLoading = false
                    if !self.isStreaming { self.liveText = "" }
                    if let latestTask = self.tasks.first,
                       let tid = latestTask["task_id"] as? String,
                       let status = latestTask["status"] as? String {
                        let needsEvents = self.loadedTaskId != tid
                        self.activeTaskId = tid
                        self.activeTaskStatus = status
                        if status == "running" || status == "waiting_user" || needsEvents { pollTaskStatus(taskId: tid) }
                    } else {
                        self.activeTaskId = nil
                        self.activeTaskStatus = "idle"
                        self.taskEvents = []
                    }
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
        let running = activeTaskStatus == "running" || activeTaskStatus == "waiting_user" || isSubmitting
        if running && (!liveMessage.blocks.isEmpty || !liveText.isEmpty) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    CloudBotWatchingAvatar(spec: theme.spec, size: 22)
                    Text(theme.name).font(.subheadline.bold())
                }
                // 与本地模式同一条管线：事件 → liveMessage 的消息块，正在生成的文字接在后面
                CloudAssistantTurnView(message: liveMessage, spec: theme.spec, name: theme.name, accent: theme.accent,
                                       showHeader: false, liveText: liveText)
            }
        } else if !liveText.isEmpty {
            CloudProseAssistant(spec: theme.spec, name: theme.name, content: liveText, accent: theme.accent)
        }
        if running {
            CloudBotWorkingRow(spec: theme.spec, events: taskEvents, status: activeTaskStatus)
        }
        if let streamNotice {
            Label(streamNotice, systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func themedComposer(_ theme: CloudBotChatTheme) -> some View {
        let working = activeTaskStatus == "running" || activeTaskStatus == "waiting_user"
        VStack(spacing: 6) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { a in
                            HStack(spacing: 6) {
                                if let thumb = a.thumbnail {
                                    Image(uiImage: thumb).resizable().scaledToFill().frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 6))
                                } else {
                                    Image(systemName: "doc").frame(width: 28, height: 28)
                                }
                                Text(a.filename).font(.caption).lineLimit(1).frame(maxWidth: 120)
                                Button { attachments.removeAll { $0.id == a.id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                    .accessibilityLabel("移除 \(a.filename)")
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemGray6)))
                        }
                    }
                    .padding(.horizontal, 14)
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
                Spacer()
            }
            .padding(.horizontal, 14)
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button { showPhotos = true } label: { Label("照片或视频", systemImage: "photo.on.rectangle") }
                    Button { showCamera = true } label: { Label("拍照", systemImage: "camera") }
                    if VNDocumentCameraViewController.isSupported {
                        Button { showScanner = true } label: { Label("扫描文档", systemImage: "doc.viewfinder") }
                    }
                    Button { showFiles = true } label: { Label("选择文件", systemImage: "folder") }
                } label: {
                    Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(.primary)
                        .frame(width: 40, height: 40).background(Circle().fill(Color(.systemGray6)))
                }
                .accessibilityLabel("添加附件")
                HStack(alignment: .bottom, spacing: 4) {
                    TextField(mentionBots.isEmpty ? "发消息，/ 查看命令" : "发消息，@ 交给其他 Bot，/ 查看命令", text: $inputPrompt, axis: .vertical)
                        .lineLimit(1...6)
                        .padding(.vertical, 10).padding(.leading, 14)
                        .disabled(isSubmitting)
                    Button { toggleDictation() } label: {
                        Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic").font(.system(size: 17))
                            .foregroundStyle(dictation.isRecording ? Color.red : Color.secondary)
                            .frame(width: 34, height: 40)
                    }
                    .accessibilityLabel(dictation.isRecording ? "停止听写" : "听写")
                }
                .background(Capsule().fill(Color(.systemGray6)))
                composerIcon("slash.circle", label: "斜杠命令") {
                    if !inputPrompt.hasPrefix("/") { inputPrompt = "/" }
                }
                composerIcon("phone", label: "和 \(theme.name) 通话") { showVoiceCall = true }
                Button {
                    if working { cancelActiveTask() } else if hasDraft { if dictation.isRecording { dictation.stop() }; sendTask() }
                } label: {
                    Group {
                        if isSubmitting {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: working ? "stop.fill" : "arrow.up").font(.system(size: 16, weight: .bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(working || hasDraft ? theme.accent : Color(.systemGray3)))
                }
                .disabled(isSubmitting || (!working && !hasDraft))
                .accessibilityLabel(working ? "停止" : "发送")
                Button { showVoiceCall = true } label: {
                    Image(systemName: "waveform").font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.primary))
                }
                .accessibilityLabel("和 \(theme.name) 实时语音")
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
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
        case "/通话": showVoiceCall = true
        case "/照片": showPhotos = true
        case "/文件": showFiles = true
        case "/记住": inputPrompt = "记住："
        case "/总结": inputPrompt = "请总结一下我们这段对话的要点和待办"; sendTask()
        case "/停止": cancelActiveTask()
        default: break
        }
    }

    private var hasDraft: Bool {
        !inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private func toggleDictation() {
        if dictation.isRecording {
            dictation.stop()
        } else {
            dictationBase = inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            dictation.start(language: theme.map { CloudBotVoiceSettings.load($0.botId).language } ?? "")
        }
    }

    /// 有附件时先上传（文件存到工作区，图片同时作为图片消息发给模型），再提交任务
    private func submitPrepared(content: String, body rawBody: [String: Any]) {
        var body = rawBody
        // 思考深度：Bot 自己设置了就由服务器使用；否则带上手机默认
        let effort = theme.flatMap { CloudEffort(rawValue: $0.effort) } ?? CloudEffort.globalDefault
        if effort != .off { body["reasoning_effort"] = effort.rawValue }
        guard !attachments.isEmpty else {
            submit(content: content, body: body)
            return
        }
        let items = attachments
        isSubmitting = true
        Task {
            do {
                let lines = try await CloudAttachmentKit.upload(items, sessionId: sessionId)
                let text = (content.isEmpty ? "请查看附件。" : content) + "\n\n" + lines.joined(separator: "\n")
                var newBody = body
                newBody["content"] = text
                let images = items.filter { $0.isImage && $0.data.count < 1_400_000 }.prefix(4)
                if !images.isEmpty {
                    var parts: [[String: Any]] = [["type": "text", "text": text]]
                    for img in images {
                        parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + img.data.base64EncodedString()]])
                    }
                    newBody["message_parts"] = parts
                }
                attachments.removeAll()
                isSubmitting = false
                submit(content: text, body: newBody)
            } catch {
                isSubmitting = false
                errorMessage = "附件上传失败：\(error.localizedDescription)"
            }
        }
    }

    /// 用户在「电脑」页点了「我完成了」：把控制权交回 Bot
    private func sendFinished() {
        guard activeTaskStatus != "running", !isSubmitting else { return }
        inputPrompt = "我完成了：已在云电脑上完成手动操作（登录 / 验证码等），请截图确认后继续。"
        sendTask()
    }

    private func sendTask() {
        let content = inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty, !isSubmitting else { return }
        if botHasOwnModel {
            // Bot 已固定模型与加密保存的凭据：由服务器选择，不需要手机上的 Key
            submitPrepared(content: content, body: ["content": content, "model": model.isEmpty ? "bot" : model, "provider": [String: Any]()])
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
            "instructions": "你是运行在用户指定 VPS 上的 OpenMinis 云端 Agent。使用中文回答，调用工具完成任务并根据真实输出核验结果。Shell 与文件操作均发生在 VPS 工作区，不具有手机照片、日历等本机工具。不要声称未执行的操作已经完成。"
        ]

        submitPrepared(content: content, body: body)
    }

    private func submit(content: String, body: [String: Any]) {
        isSubmitting = true
        errorMessage = nil
        sendStartedAt = Date()   // 性能页「首字」实测起点，与本地模式同口径

        Task {
            do {
                try await connection.ensureConnected()
                let res = try await connection.request(method: "POST", path: "/v1/sessions/\(sessionId)/messages", body: body)
                if let tid = res["task_id"] as? String {
                    await MainActor.run {
                        self.inputPrompt = "" // 仅在成功接收后清空输入框
                        self.isSubmitting = false
                        self.activeTaskId = tid
                        self.activeTaskStatus = "running"
                        self.watchedTasks.insert(tid)
                        self.liveMessage = ChatMessage(role: .assistant, content: "")
                        self.taskEvents = []
                        self.eventCursor = 0
                        self.liveText = ""
                        self.liveSeq = -1
                        let row: [String: Any] = ["role": "user", "content": content, "timestamp": Date().timeIntervalSince1970]
                        self.messages.append(row)
                        self.turns.append(CloudHistoryAdapter.Turn(message: ChatMessage(role: .user, content: content), raw: row))
                    }
                    pollTaskStatus(taskId: tid)
                } else {
                    await MainActor.run {
                        self.isSubmitting = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "发送失败: \(error.localizedDescription)（输入已保留）"
                    self.isSubmitting = false
                }
            }
        }
    }

    private func pollTaskStatus(taskId: String) {
        guard !isPolling else { return }
        isPolling = true
        Task {
            do {
                let res = try await quietly("/v1/tasks/\(taskId)")
                await MainActor.run {
                    self.isPolling = false
                    self.loadedTaskId = taskId
                    if let status = res["status"] as? String {
                        self.activeTaskStatus = status
                    }
                    if let events = res["events"] as? [[String: Any]] {
                        self.taskEvents = events
                        self.eventCursor = events.compactMap { $0["id"] as? Int }.max() ?? 0
                        let rebuilt = ChatMessage(role: .assistant, content: "")
                        for ev in events {
                            CloudEventApplier.apply(rebuilt, type: ev["type"] as? String ?? "", payload: ev["payload"] as? [String: Any] ?? [:])
                        }
                        self.liveMessage = rebuilt
                    }
                    self.errorMessage = nil
                    if ["running", "waiting_user", "queued"].contains(self.activeTaskStatus) {
                        self.streamEvents(taskId: taskId)
                    }
                    if ["running", "waiting_user", "queued"].contains(self.activeTaskStatus) {
                        self.watchedTasks.insert(taskId)
                    } else {
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.pollTaskStatus(taskId: taskId) }
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
                    if !batch.events.isEmpty {
                        self.taskEvents.append(contentsOf: batch.events)
                        for ev in batch.events {
                            CloudEventApplier.apply(self.liveMessage, type: ev["type"] as? String ?? "", payload: ev["payload"] as? [String: Any] ?? [:])
                        }
                        // Bot 需要你登录 / 接管：自动打开这个 Bot 的「电脑」页（每个任务只自动打开一次）
                        if batch.events.contains(where: { $0["type"] as? String == "takeover_request" }), !self.autoOpenedComputer.contains(taskId) {
                            self.autoOpenedComputer.insert(taskId)
                            CloudHaptics.warning()
                            self.showComputer = true
                        }
                        // 一段话写进了事件或模型开始调用工具：正在生成的那段文字已经结束
                        if batch.events.contains(where: { ["tool_call", "thought"].contains($0["type"] as? String ?? "") }) { self.liveText = "" }
                        self.eventCursor = max(self.eventCursor, batch.events.compactMap { ($0["id"] as? Int) ?? ($0["monotonic_id"] as? Int) }.max() ?? 0)
                    }
                    if let live = batch.live, let t = live["text"] as? String, let s = live["seq"] as? Int {
                        self.liveText = t
                        self.liveSeq = s
                    }
                    if let s = batch.rawStatus { self.activeTaskStatus = s }
                },
                onTrouble: { text in self.streamNotice = text })
            self.isStreaming = false
            self.streamNotice = nil
            guard self.activeTaskId == taskId, let final else { return }
            if self.watchedTasks.contains(taskId), [.failed, .interrupted, .limitReached].contains(final) {
                self.errorMessage = CloudTaskFailure.text(status: final.rawValue, events: self.taskEvents)
            }
            self.loadSessionDetail()
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
                Text(content)
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
                            Text(st.result).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(6)
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
