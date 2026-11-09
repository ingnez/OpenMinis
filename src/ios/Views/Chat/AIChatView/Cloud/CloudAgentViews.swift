//
//  CloudAgentViews.swift
//  Minis - VPS Cloud Agent UI
//

import SwiftUI
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
                TextField("连接名称 (如: 我的云端VPS)", text: $connection.name)
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
                Text("VPS 服务器配置")
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
                        Text("已连接 (端口 18765)")
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
                    #endif
                }
            }

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
        .navigationTitle("VPS 云端 Agent")
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

            Section("VPS 会话列表") {
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

    @ObservedObject private var connection = CloudConnection.shared
    @State private var messages: [[String: Any]] = []
    @State private var tasks: [[String: Any]] = []
    @State private var inputPrompt: String = ""
    @State private var activeTaskId: String? = nil
    @State private var activeTaskStatus: String = "idle"
    @State private var taskEvents: [[String: Any]] = []
    @State private var isLoading = false
    @State private var isSubmitting = false
    @State private var isPolling = false
    @State private var loadedTaskId: String? = nil
    @State private var errorMessage: String? = nil

    private let timer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

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
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.1))
            }

            // Messages & Event Log area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { _, msg in
                            let role = msg["role"] as? String ?? "user"
                            let content = msg["content"] as? String ?? ""
                            CloudMessageBubble(role: role, content: content)
                        }

                        if !taskEvents.isEmpty {
                            Divider()
                            Text("当前/最新任务实时日志").font(.caption).bold().foregroundColor(.secondary)
                            ForEach(Array(taskEvents.enumerated()), id: \.offset) { _, ev in
                                let type = ev["type"] as? String ?? "event"
                                let payload = ev["payload"] as? [String: Any] ?? [:]
                                CloudTaskEventRow(type: type, payload: payload)
                            }
                        }
                    }
                    .padding()
                }
            }

            Divider()

            // Active Task Status Bar if running
            if activeTaskStatus == "running" {
                HStack {
                    ProgressView()
                        .padding(.trailing, 4)
                    Text("云端任务执行中 [\(activeTaskId ?? "")]")
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

            // Input Composer Bar
            HStack(spacing: 8) {
                TextField("给云端 Agent 发送任务...", text: $inputPrompt)
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
        .navigationTitle(sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadSessionDetail()
        }
        .onReceive(timer) { _ in
            if activeTaskStatus == "running", let tid = activeTaskId, !isPolling {
                pollTaskStatus(taskId: tid)
            }
        }
    }

    private func loadSessionDetail() {
        isLoading = true
        Task {
            do {
                let res = try await connection.request(method: "GET", path: "/v1/sessions/\(sessionId)")
                await MainActor.run {
                    self.messages = res["messages"] as? [[String: Any]] ?? []
                    self.tasks = res["tasks"] as? [[String: Any]] ?? []
                    self.isLoading = false
                    if let latestTask = self.tasks.first,
                       let tid = latestTask["task_id"] as? String,
                       let status = latestTask["status"] as? String {
                        let needsEvents = self.loadedTaskId != tid
                        self.activeTaskId = tid
                        self.activeTaskStatus = status
                        if status == "running" || needsEvents { pollTaskStatus(taskId: tid) }
                    } else {
                        self.activeTaskId = nil
                        self.activeTaskStatus = "idle"
                        self.taskEvents = []
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

    private func sendTask() {
        let content = inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !isSubmitting else { return }

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

        isSubmitting = true
        errorMessage = nil

        Task {
            do {
                let res = try await connection.request(method: "POST", path: "/v1/sessions/\(sessionId)/messages", body: body)
                if let tid = res["task_id"] as? String {
                    await MainActor.run {
                        self.inputPrompt = "" // 仅在成功接收后清空输入框
                        self.isSubmitting = false
                        self.activeTaskId = tid
                        self.activeTaskStatus = "running"
                        self.taskEvents = []
                        self.messages.append(["role": "user", "content": content, "timestamp": Date().timeIntervalSince1970])
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
                let res = try await connection.request(method: "GET", path: "/v1/tasks/\(taskId)")
                await MainActor.run {
                    self.isPolling = false
                    self.loadedTaskId = taskId
                    if let status = res["status"] as? String {
                        self.activeTaskStatus = status
                    }
                    if let events = res["events"] as? [[String: Any]] {
                        self.taskEvents = events
                    }
                    self.errorMessage = nil
                    if self.activeTaskStatus != "running" {
                        if ["failed", "interrupted", "limit_reached"].contains(self.activeTaskStatus) {
                            self.errorMessage = "云端任务状态：\(self.activeTaskStatus)。请查看任务日志；修复原因后可发送新任务继续。"
                        }
                        loadSessionDetail()
                    }
                }
            } catch {
                await MainActor.run {
                    self.isPolling = false
                    self.errorMessage = "轮询任务状态失败: \(error.localizedDescription)"
                }
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
        case "cancelled": return .orange
        default: return .secondary
        }
    }
}
