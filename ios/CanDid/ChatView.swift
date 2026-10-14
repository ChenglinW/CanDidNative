import SwiftUI
import CryptoKit

struct ChatToolStep: Codable, Identifiable {
    var id: String; var name: String; var title: String; var status: String; var count: Int
}
struct ChatSource: Codable, Identifiable {
    var ref: String; var title: String; var text: String; var trust: String; var citation: String
    var session_id: String?; var start_ms: Int?; var end_ms: Int?
    var url:String?;var page:Int?;var offset:Int?;var confirmation_mode:String?
    var id: String { ref }
}
struct ChatThread: Codable, Identifiable {
    var id: String; var title: String; var occasion_id: String?; var status: String
    var activity: [ChatToolStep]; var message_count: Int; var updated_at: String
    var workspace_id: String?
    var active_task_id: String?; var last_task_id: String?
}
struct ChatMessage: Codable, Identifiable {
    var id: String; var role: String; var content: String
    var sources: [ChatSource]; var tool_steps: [ChatToolStep]; var created_at: String
    var model: String?
    var incomplete: Bool?; var task_id: String?
}
struct ChatDetail: Decodable { var thread: ChatThread; var messages: [ChatMessage]; var tasks: [AgentTask]? }
struct ChatReply: Decodable { var message: ChatMessage; var thread: ChatThread }
struct AgentTask: Decodable, Identifiable {
    var id: String; var thread_id: String; var turn_id: String; var status: String; var attempt: Int
    var accepted_action_ids: [String]?
    var client_request_id: String?
    var event_seq: Int?; var partial_text: String?; var tool_steps: [ChatToolStep]
    var error: AgentTaskError?
    var input: AgentTaskInput?; var input_request: AgentInputRequest?
    var active: Bool { ["queued", "running", "waiting_input"].contains(status) }
}
struct AgentTaskInput: Decodable { var content: String }
struct AgentInputRequest: Decodable { var id: String; var question: String; var options: [String] }
struct AgentTaskError: Decodable { var code: String; var message: String; var retryable: Bool }
struct AgentEvent: Decodable {
    var task_id: String; var thread_id: String; var turn_id: String; var attempt: Int; var seq: Int; var kind: String
    var data: AgentEventData
}
struct AgentEventData: Decodable {
    var text: String?; var status: String?; var phase: String?; var steps: [ChatToolStep]?
    var error: AgentTaskError?
    var input_request: AgentInputRequest?
}
struct ChatRecovery: Codable {
    var readPosition: String?
    var taskID: String?; var cursor = 0; var attempt = 0; var partial = ""
    var pendingText: String?; var requestID: String?; var draft = ""
    var actionTaskID: String?
    var actionAttempt: Int?
    var actionID: String?; var actionKind: String?; var inputID: String?; var actionText: String?
}

extension Store {
    private var recoveryKey: String {
        let identity = base + "\n" + TokenVault.read()
        return "chat-recovery-" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func recovery(_ id: String) -> ChatRecovery {
        let data = UserDefaults.standard.data(forKey: recoveryKey)
        return data.flatMap { try? JSONDecoder().decode([String: ChatRecovery].self, from: $0) }?[id] ?? ChatRecovery()
    }
    private func saveRecovery(_ id: String, _ value: ChatRecovery) {
        var rows = UserDefaults.standard.data(forKey: recoveryKey).flatMap {
            try? JSONDecoder().decode([String: ChatRecovery].self, from: $0)
        } ?? [:]
        rows[id] = value
        if let data = try? JSONEncoder().encode(rows) { UserDefaults.standard.set(data, forKey: recoveryKey) }
    }
    func saveVoiceDraft(_ text:String,threadID:String?) {
        guard let threadID else { return };var value=recovery(threadID);value.draft=text;saveRecovery(threadID,value)
        if chatThread?.id==threadID { chatDraft=text }
    }
    func saveChatDraft(_ text: String) {
        chatDraft = text
        if let id = chatThread?.id { var saved = recovery(id); saved.draft = text; saveRecovery(id, saved) }
    }
    func saveChatReadPosition(_ value: String?) {
        guard !chatLoading, let id = chatThread?.id,
              value == "chat-bottom" || chatMessages.contains(where: { $0.id == value }) else { return }
        chatReadPosition = value; var saved = recovery(id); saved.readPosition = value; saveRecovery(id, saved)
    }
    func clearChatRecovery() {
        UserDefaults.standard.removeObject(forKey: recoveryKey)
        UserDefaults.standard.removeObject(forKey: recoveryKey + "-last-space")
        UserDefaults.standard.removeObject(forKey: recoveryKey + "-new-space-request")
        pauseChatObservation()
    }
    func pauseChatObservation() {
        chatObserverGeneration = UUID(); chatRequest?.cancel(); chatRequest = nil
        chatReconnecting = false
    }
    func chatSceneChanged(active: Bool) {
        chatForeground = active
        if active { resumeChatObservation() } else { pauseChatObservation() }
    }
    func resumeChatObservation() {
        guard remote, chatForeground, chatRequest == nil, let id = chatThread?.id else { return }
        Task { try? await loadChat(id) }
    }
    func restoreConnection() async {
        var token = TokenVault.read()
        var shouldConnect = UserDefaults.standard.bool(forKey: "remote-enabled")
        #if DEBUG && targetEnvironment(simulator)
        let env = ProcessInfo.processInfo.environment
        if env["CANDID_LOCAL_BACKEND"] == "1", let supplied = env["CANDID_BACKEND_TOKEN"], !supplied.isEmpty {
            base = "http://127.0.0.1:" + (env["CANDID_BACKEND_PORT"] ?? "8000")
            token = supplied; shouldConnect = true
            do { try TokenVault.save(token); UserDefaults.standard.set(base, forKey: "api-base") }
            catch { chatError = error.localizedDescription; return }
        }
        #endif
        guard shouldConnect, !token.isEmpty else { return }
        do {
            _ = try await api.raw("/v1/profile")
            remote = true; onboarding = true
            UserDefaults.standard.set(true, forKey: "remote-enabled")
            try await reload(); try await reloadChats()
            var requestedID: String?
            #if DEBUG && targetEnvironment(simulator)
            requestedID = ProcessInfo.processInfo.environment["CANDID_CHAT_THREAD_ID"]
            #endif
            if let id = requestedID { try await loadChat(id) }
            else { try await restoreWorkspaceSelection() }
            #if DEBUG && targetEnvironment(simulator)
            if let message = ProcessInfo.processInfo.environment["CANDID_CHAT_MESSAGE"], !message.isEmpty { sendChat(message) }
            #endif
        } catch { chatError = error.localizedDescription }
    }
    func reloadChats() async throws {
        guard remote else { return }
        let rows: [ChatThread] = try await api.all("/v1/chat/threads")
        chatThreads = rows.sorted { $0.updated_at > $1.updated_at }
        try await reloadProjectSpaces()
    }
    func loadChat(_ id: String, observe: Bool = true) async throws {
        pauseChatObservation()
        let generation = chatObserverGeneration
        chatLoading = true
        defer { if generation == chatObserverGeneration { chatLoading = false } }
        let detail: ChatDetail = try await api.call("/v1/chat/threads/" + id)
        guard generation == chatObserverGeneration, remote else { return }
        applyChatDetail(detail)
        if observe { observeChat(id) }
    }
    private func applyChatDetail(_ detail: ChatDetail) {
        let id = detail.thread.id
        chatThread = detail.thread; chatTasks = detail.tasks ?? []
        let queuedIDs = Set(chatTasks.filter { $0.status == "queued" }.map(\.id))
        chatMessages = detail.messages.filter { $0.role != "user" || !queuedIDs.contains($0.task_id ?? "") }
        chatActivity = detail.thread.activity; chatDraft = recovery(id).draft
        chatReadPosition = recovery(id).readPosition
        chatTask = chatTasks.first { ["running", "waiting_input"].contains($0.status) }
            ?? chatTasks.first { $0.status == "queued" }
            ?? chatTasks.first { $0.id == detail.thread.last_task_id }
        chatBusy = chatTask?.active == true
        chatPartial = chatTask?.partial_text ?? ""; chatError = nil
        var saved = recovery(id)
        if let actionID = saved.actionID, let actionTaskID = saved.actionTaskID,
           chatTasks.first(where: { $0.id == actionTaskID })?.accepted_action_ids?.contains(actionID) == true {
            saved.actionID = nil; saved.actionTaskID = nil; saved.actionKind = nil; saved.actionAttempt = nil
            saved.actionText = nil; saved.inputID = nil; saveRecovery(id, saved)
        } else if saved.actionID != nil { chatError = "上次继续/补充的回执未确认，可沿用原请求重试。" }
        chatPending = saved.pendingText.flatMap { text in saved.requestID.map { (text, $0) } }
        if saved.pendingText != nil && saved.requestID != nil {
            if let accepted = chatTasks.first(where: { $0.client_request_id == saved.requestID }) {
                var updated = saved; updated.pendingText = nil; updated.requestID = nil
                saveRecovery(id, updated); chatPending = nil
                if !accepted.active { chatError = accepted.error?.message }
            } else { chatError = "上次消息是否已提交还未确认，点击重试会沿用原请求，不重复创建任务。" }
        }
        UserDefaults.standard.set(id, forKey: "last-chat-id")
        if let workspaceID = detail.thread.workspace_id { UserDefaults.standard.set(workspaceID, forKey: recoveryKey + "-last-space") }
    }
    private func observeChat(_ threadID: String) {
        guard chatForeground, let initial = chatTask, initial.active else { return }
        let generation = chatObserverGeneration
        let connection = api
        chatRequest = Task {
            defer { if generation == chatObserverGeneration { chatRequest = nil; chatReconnecting = false } }
            var failures = 0
            while !Task.isCancelled && generation == chatObserverGeneration && chatThread?.id == threadID {
                do {
                    let task: AgentTask = try await connection.call("/v1/agent/tasks/" + initial.id)
                    try Task.checkCancellation()
                    guard generation == chatObserverGeneration, chatThread?.id == threadID else { return }
                    chatTask = task; chatBusy = task.active; chatActivity = task.tool_steps
                    if !task.active || task.status == "waiting_input" {
                        let detail: ChatDetail = try await connection.call("/v1/chat/threads/" + threadID)
                        guard generation == chatObserverGeneration else { return }
                        applyChatDetail(detail)
                        if let next = chatTask, next.id != initial.id && next.active {
                            pauseChatObservation(); observeChat(threadID)
                        }
                        try? await reloadChats()
                        return
                    }
                    var saved = recovery(threadID)
                    if saved.taskID != task.id || saved.attempt != task.attempt || saved.cursor > (task.event_seq ?? 0) {
                        saved.taskID = task.id; saved.attempt = task.attempt
                        saved.cursor = task.event_seq ?? 0; saved.partial = task.partial_text ?? ""
                        saveRecovery(threadID, saved)
                    }
                    chatPartial = saved.partial; chatReconnecting = false
                    try await connection.events(taskID: task.id, after: saved.cursor) { event in
                        guard generation == self.chatObserverGeneration, self.chatThread?.id == threadID,
                              event.task_id == self.chatTask?.id, event.turn_id == self.chatTask?.turn_id else { return }
                        var state = self.recovery(threadID)
                        guard event.seq > state.cursor, event.attempt >= state.attempt else { return }
                        if event.attempt != state.attempt { state.partial = ""; state.attempt = event.attempt }
                        if event.kind == "text.reset" { state.partial = "" }
                        if event.kind == "text.delta" { state.partial += event.data.text ?? "" }
                        if let steps = event.data.steps { self.chatActivity = steps }
                        if let status = event.data.status { self.chatTask?.status = status; self.chatBusy = self.chatTask?.active == true }
                        if let question = event.data.input_request { self.chatTask?.input_request = question }
                        self.chatTask?.attempt = event.attempt
                        state.cursor = event.seq; self.saveRecovery(threadID, state); self.chatPartial = state.partial
                    }
                    failures = 0
                } catch {
                    if Task.isCancelled || generation != chatObserverGeneration { return }
                    failures += 1; chatReconnecting = true
                    if failures >= 5 {
                        chatError = "暂时连不上后端，任务和输入已保留。恢复连接后点击“重新连接”查看同一任务。"
                        return
                    }
                    do { try await Task.sleep(for: .seconds(min(8, failures * 2))) } catch { return }
                }
            }
        }
    }
    func newChat(occasion: Occasion? = nil) async {
        guard remote, !chatControlBusy else { return }
        do {
            var body: [String: Any] = [:]
            if let occasion { body["occasion_id"] = occasion.id }
            let thread: ChatThread = try await api.call("/v1/chat/threads", method: "POST", body: body)
            pauseChatObservation()
            chatThread = thread; chatMessages = []; chatTasks = []; chatTask = nil; chatBusy = false
            chatActivity = []; chatPartial = ""; chatError = nil; chatPending = nil; chatDraft = ""
            UserDefaults.standard.set(thread.id, forKey: "last-chat-id")
            try await reloadChats()
        } catch { chatError = error.localizedDescription }
    }
    func sendChat(_ text: String, retry: Bool = false) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !chatControlBusy, !chatLoading, currentProjectSpace?.status == "active" else { return }
        guard value.count <= 12000 else { chatError = "消息最多 12,000 字，请分段发送。"; return }
        guard remote, capabilities?.agent_configured == true else { chatError = "请先连接已配置文本模型的后端。"; return }
        if let task = chatTask, task.status == "waiting_input", !retry { answerChat(task, text: value); return }
        let requestID = retry ? (chatPending?.requestID ?? UUID().uuidString) : UUID().uuidString
        chatPending = (value, requestID); chatControlBusy = true; chatError = nil
        let connection = api
        Task {
            defer { chatControlBusy = false }
            do {
                if chatThread == nil {
                    let thread: ChatThread = try await connection.call("/v1/chat/threads", method: "POST", body: [:])
                    chatThread = thread
                }
                guard let id = chatThread?.id else { return }
                var saved = recovery(id); saved.pendingText = value; saved.requestID = requestID
                saved.draft = ""; saveRecovery(id, saved); chatDraft = ""
                let _: AgentTask = try await connection.call("/v1/chat/threads/" + id + "/tasks", method: "POST",
                    body: ["content": value, "client_request_id": requestID])
                saved = recovery(id); saved.pendingText = nil; saved.requestID = nil; saveRecovery(id, saved)
                if chatThread?.id == id { chatPending = nil; try await loadChat(id) }
                try await reloadChats()
            } catch { chatError = error.localizedDescription }
        }
    }
    func continueChat(_ task: AgentTask) { performChatAction(task, kind: "resume") }
    func answerChat(_ task: AgentTask, text: String) {
        guard let question = task.input_request else { return }
        performChatAction(task, kind: "input", text: text, inputID: question.id)
    }
    var chatHasPendingAction: Bool { chatThread.map { recovery($0.id).actionKind != nil } ?? false }
    func retryChatAction() {
        guard let id = chatThread?.id else { return }
        let saved = recovery(id)
        if let taskID = saved.actionTaskID, let task = chatTasks.first(where: { $0.id == taskID }), let kind = saved.actionKind {
            performChatAction(task, kind: kind, text: saved.actionText, inputID: saved.inputID)
        }
    }
    private func performChatAction(_ task: AgentTask, kind: String, text: String? = nil, inputID: String? = nil) {
        guard !chatControlBusy else { return }
        chatControlBusy = true; chatError = nil
        let connection = api; let id = task.thread_id
        var saved = recovery(id)
        if saved.actionKind != kind || saved.inputID != inputID || saved.actionText != text || saved.actionTaskID != task.id {
            saved.actionID = UUID().uuidString; saved.actionAttempt = task.attempt
        }
        saved.actionTaskID = task.id; saved.actionKind = kind; saved.actionText = text; saved.inputID = inputID
        saveRecovery(id, saved)
        let requestID = saved.actionID ?? UUID().uuidString
        let attempt = saved.actionAttempt ?? task.attempt
        Task {
            defer { chatControlBusy = false }
            do {
                var body: [String: Any] = ["client_request_id": requestID, "expected_attempt": attempt]
                if let text { body["content"] = text }; if let inputID { body["input_id"] = inputID }
                let _: AgentTask = try await connection.call("/v1/agent/tasks/" + task.id + "/" + kind, method: "POST", body: body)
                var stored = recovery(id); stored.actionID = nil; stored.actionKind = nil; stored.actionText = nil
                stored.inputID = nil; stored.actionAttempt = nil; stored.actionTaskID = nil; saveRecovery(id, stored)
                if chatThread?.id == id { saveChatDraft(""); try await loadChat(id) }
            } catch { if chatThread?.id == id { chatError = error.localizedDescription } }
        }
    }
    func stopChat(_ task: AgentTask) {
        guard !chatControlBusy else { return }
        chatControlBusy = true
        let connection = api; let id = task.thread_id
        Task {
            defer { chatControlBusy = false }
            do {
                let _: AgentTask = try await connection.call("/v1/agent/tasks/" + task.id + "/cancel", method: "POST",
                    body: ["expected_attempt":task.attempt])
                if chatThread?.id == id { try await loadChat(id) }
            } catch { if chatThread?.id == id { chatError = error.localizedDescription } }
        }
    }
}

struct ChatView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var history = false
    @State private var editingSpace = false
    @State private var materials = false
    @State private var source: ChatSource?
    @State private var saved: Set<String> = []
    var onSettings: () -> Void

    private var followsLatest: Bool { store.chatReadPosition == nil || store.chatReadPosition == "chat-bottom" || store.chatReadPosition == store.chatMessages.last?.id }
    private var available: Bool { store.remote && store.capabilities?.agent_configured == true }
    var body: some View {
        VStack(spacing: 0) {
            header
            HStack {
                Text(store.currentProjectSpace?.name ?? "选择一个沟通方向")
                    .lineLimit(1)
                Spacer()
                Label(available ? "已连接" : "待连接", systemImage: available ? "circle.fill" : "circle")
                    .foregroundStyle(available ? Warm.purple : .secondary)
            }.font(.caption).padding(.horizontal, 22).padding(.bottom, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if store.chatMessages.isEmpty { emptyState }
                        ForEach(store.chatMessages) { message in messageView(message).id(message.id) }
                        if store.chatBusy {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    if store.chatTask?.status != "waiting_input" { ProgressView() }
                                    Text(store.chatReconnecting ? "正在恢复连接…" : store.chatTask?.status == "waiting_input" ? "等待你的补充" : store.chatTask?.status == "queued" ? "已排队，等待处理" : "Candid 正在回复…").font(.subheadline)
                                    Spacer()
                                    if let task = store.chatTask {
                                        Button("停止") { store.stopChat(task) }.frame(minHeight: 44).disabled(store.chatControlBusy)
                                    }
                                }
                                if !store.chatPartial.isEmpty { Text(store.chatPartial).textSelection(.enabled).lineSpacing(6) }
                                if let task = store.chatTask, let input = task.input_request, task.status == "waiting_input" {
                                    Text(input.question).font(.body)
                                    ForEach(input.options, id: \.self) { option in
                                        Button(option) { store.answerChat(task, text: option) }.frame(minHeight: 44).disabled(store.chatControlBusy)
                                    }
                                }
                                ForEach(store.chatActivity) { step in
                                    Label(step.title + (step.status == "done" ? " · \(step.count) 条" : "…"),
                                          systemImage: step.status == "done" ? "checkmark.circle" : "magnifyingglass")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(16).background(Warm.white, in: RoundedRectangle(cornerRadius: 20))
                        }
                        ForEach(store.chatTasks.filter { $0.id != store.chatTask?.id && $0.status == "queued" }) { task in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("已排队").font(.caption).foregroundStyle(.secondary)
                                    Text(task.input?.content ?? "补充内容").font(.subheadline).lineLimit(3)
                                }
                                Spacer()
                                Button("取消排队") { store.stopChat(task) }.frame(minHeight: 44).disabled(store.chatControlBusy)
                            }.padding(14).background(Warm.white, in: RoundedRectangle(cornerRadius: 16))
                        }
                        ForEach(store.chatTasks.filter { store.currentProjectSpace?.status == "active" && ["failed", "interrupted", "cancelled"].contains($0.status) }) { task in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(task.error?.message ?? "任务未完成").font(.subheadline)
                                Text(task.input?.content ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                if let partial = task.partial_text, !partial.isEmpty { Text("未完成的文字").font(.caption); Text(partial).textSelection(.enabled) }
                                Text("继续会重新请求模型；已完成的资料查询按保存进度恢复。").font(.caption).foregroundStyle(.secondary)
                                Button("重新发送原问题") { store.sendChat(task.input?.content ?? "") }.frame(minHeight: 44).disabled(store.chatControlBusy)
                                Button("继续这次任务", systemImage: "arrow.clockwise") { store.continueChat(task) }
                                    .frame(minHeight: 44).disabled(store.chatControlBusy || task.error?.retryable == false || store.chatTask?.status == "running" || store.chatTask?.status == "waiting_input")
                            }.padding(14).background(Warm.white, in: RoundedRectangle(cornerRadius: 16))
                        }
                        if let error = store.chatError {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(error).font(.subheadline).foregroundStyle(Color(red: 0.64, green: 0.27, blue: 0.20))
                                Button("重新连接", systemImage: "wifi") { store.resumeChatObservation() }.frame(minHeight: 44)
                                if store.chatHasPendingAction {
                                    Button("重试未确认的继续/补充") { store.retryChatAction() }.frame(minHeight: 44).disabled(store.chatControlBusy)
                                }
                                if let pending = store.chatPending {
                                    Button("重试这条消息", systemImage: "arrow.clockwise") { store.sendChat(pending.text, retry: true) }
                                        .disabled(store.chatControlBusy).frame(minHeight: 44)
                                } else if !available {
                                    Button("打开连接设置", action: onSettings).frame(minHeight: 44)
                                }
                            }.padding(16).background(Warm.white, in: RoundedRectangle(cornerRadius: 16))
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }.scrollTargetLayout().padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
                        .frame(maxWidth: 700, alignment: .leading).frame(maxWidth: .infinity)
                }.scrollDismissesKeyboard(.interactively)
                    .scrollPosition(id: Binding(get: { store.chatReadPosition }, set: { store.saveChatReadPosition($0) }), anchor: .top)
                    .id(store.chatThread?.id ?? "empty-chat")
                    .onChange(of: store.chatThread?.id) { _, _ in proxy.scrollTo(store.chatReadPosition ?? "chat-bottom", anchor: .top) }
                    .onChange(of: store.chatMessages.count) { _, _ in if followsLatest { scroll(proxy) } }
                    .onChange(of: store.chatPartial) { _, _ in if followsLatest { scroll(proxy) } }
                    .onChange(of: store.chatBusy) { _, _ in if followsLatest { scroll(proxy) } }
                    .onChange(of: focused) { _, value in if value { scroll(proxy) } }
            }
            WorkspaceCarousel(spaces: store.activeProjectSpaces, selectedID: store.currentProjectSpace?.id,
                compact: focused, disabled: !store.remote || store.chatControlBusy || store.chatLoading,
                select: { id in Task { await store.selectProjectSpace(id) } },
                create: { Task { await store.createProjectSpace() } })
            if store.currentProjectSpace?.status == "archived" {
                Text("空间已归档，Candid 会自动整理有依据的个人资料；历史仍可查看。").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 22)
                Button("恢复这个空间") { Task { await store.archiveProjectSpace(restore: true) } }.frame(minHeight: 44)
            }
            RecordingStatusBar(speech:store.speech,device:store.soundcore).environmentObject(store)
            SpeechToolbar(speech:store.speech).environmentObject(store)
            composer
        }
        .background(Warm.paper.ignoresSafeArea()).toolbar(.hidden, for: .navigationBar)

        .sheet(isPresented: $history) { historySheet }
        .sheet(isPresented: $editingSpace) { if let space = store.currentProjectSpace { WorkspaceEditor(space: space).environmentObject(store) } }
        .sheet(isPresented: $materials) { if let space = store.currentProjectSpace { WorkspaceMaterials(space: space).environmentObject(store) } }
        .sheet(item: $source) { value in sourceSheet(value) }
    }
    private var header: some View {
        HStack(spacing: 10) {
            Mascot(size: 47)
            VStack(alignment: .leading, spacing: 3) {
                Text("Candid").font(.title3.bold())
                Text("和你一起，准备下一次").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                Button("新建项目空间", systemImage: "square.and.pencil") { Task { await store.createProjectSpace() } }
                    .disabled(store.chatControlBusy)
                Button("空间列表与归档", systemImage: "square.stack") {
                    Task { try? await store.reloadChats(); history = true }
                }.disabled(store.chatControlBusy)
                if let space = store.currentProjectSpace, space.status == "active" {
                    Button("修改名称与方向", systemImage: "pencil") { editingSpace = true }.disabled(store.chatControlBusy)
                    Button("可读取的资料", systemImage: "books.vertical") { materials = true }
                    Button("归档这个空间", systemImage: "archivebox") { Task { await store.archiveProjectSpace() } }
                        .disabled(store.chatControlBusy || store.chatTasks.contains(where: { $0.active }))
                }
                Button("设置与后端连接", systemImage: "gearshape", action: onSettings)
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    .background(Warm.white, in: Circle()).overlay(Circle().stroke(Warm.ink.opacity(0.10)))
            }.accessibilityLabel("对话与设置")
        }.padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 14)
    }
    private var emptyState: some View {
        VStack(spacing: 14) {
            Mascot(size: 95).padding(.top, 55)
            Text(store.currentProjectSpace == nil ? "从一个新的方向开始。" : "下一场沟通，一起准备。").font(.title2.bold())
            Text("说说你要见谁，\n或聊聊上一次哪里还想说得更好。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if available && store.currentProjectSpace == nil { Button("新建项目空间") { Task { await store.createProjectSpace() } }.buttonStyle(PrimaryButton()) }
            if !available {
                Button("连接本机文本 Agent", action: onSettings).buttonStyle(PrimaryButton()).padding(.top, 16)
            }
        }.frame(maxWidth: .infinity).padding(.bottom, 35)
    }
    @ViewBuilder private func messageView(_ message: ChatMessage) -> some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 36)
                Text(message.content).font(.body).textSelection(.enabled).lineSpacing(5)
                    .padding(.horizontal, 15).padding(.vertical, 12)
                    .background(Warm.lavender, in: RoundedRectangle(cornerRadius: 20))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) { Mascot(size: 23); Text("Candid").font(.caption).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 14) {
                    if message.incomplete != true { Button("播报",systemImage:"speaker.wave.2") { store.stopPlayback();store.speech.speak(message,api:store.api) }.font(.caption).frame(minHeight:44) }
                    if message.incomplete == true { Label("未完成 · 已停止", systemImage: "stop.circle").font(.caption).foregroundStyle(.secondary) }
                    Text(LocalizedStringKey(message.content)).font(.body).lineSpacing(6).textSelection(.enabled)
                    if !message.tool_steps.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle")
                            Text(message.tool_steps.map(\.title).joined(separator: " · "))
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    if !message.sources.isEmpty {
                        DisclosureGroup("查看参考资料 · \(message.sources.count) 条") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(message.sources) { value in
                                    Button { source = value } label: {
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: value.session_id == nil ? "book.closed" : "text.quote")
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(value.citation + " " + value.title).font(.subheadline)
                                                Text(value.confirmation_mode == "archive_auto" ? "归档自动确认":trustLabel(value.trust)).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer(); Image(systemName: "chevron.right").font(.caption)
                                        }.frame(minHeight: 44).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.top, 8)
                        }.font(.caption).tint(Warm.purple)
                    }
                    Divider()
                    HStack {
                        Button(saved.contains(message.id) ? "已保留草稿" : "保留为表达草稿", systemImage: saved.contains(message.id) ? "checkmark" : "bookmark") {
                            Task { await store.perform {
                                let _: Asset = try await store.api.call("/v1/chat/messages/" + message.id + "/draft", method: "POST", body: [:])
                                try await store.reload(); saved.insert(message.id)
                            } }
                        }.disabled(saved.contains(message.id) || message.incomplete == true)
                        Spacer()
                        ShareLink(item: message.content) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
                            .accessibilityLabel("分享这条回答")
                    }.font(.caption).foregroundStyle(Warm.purple).frame(minHeight: 44)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    .background(Warm.white, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Warm.ink.opacity(0.08)))
            }
        }
    }
    private var composer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                quickAction("准备下一场", icon: "scope", prompt: "帮我准备下一场沟通。请先问我最关键的背景。")
                quickAction("复盘上一场", icon: "headphones", prompt: "帮我复盘上一场真实沟通。请先查找已有记忆和本人原文，没有资料就告诉我。")
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(store.chatTask?.status == "waiting_input" ? "补充后继续这次任务" : store.chatBusy ? "补充内容，会排队处理" : "有什么想一起想想的？", text: Binding(get: { store.chatDraft }, set: { store.saveChatDraft($0) }), axis: .vertical)
                    .lineLimit(1...5).focused($focused).font(.body).padding(.vertical, 9)
                    .accessibilityLabel("给 Candid 的消息").disabled(store.chatLoading)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.headline).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(Warm.purple, in: RoundedRectangle(cornerRadius: 12))
                }.disabled(store.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.chatControlBusy || store.chatLoading)
                    .opacity(store.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.chatControlBusy || store.chatLoading ? 0.45 : 1)
                    .accessibilityLabel(store.chatTask?.status == "waiting_input" ? "补充后继续" : store.chatBusy ? "加入队列" : "发送消息")
            }.padding(8).padding(.leading, 5).background(Warm.white, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Warm.ink.opacity(0.15)))
                .disabled(store.currentProjectSpace?.status != "active")
        }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 12)
    }
    private func quickAction(_ title: String, icon: String, prompt: String) -> some View {
        Button { focused = false; store.sendChat(prompt) } label: {
            Label(title, systemImage: icon).font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity).frame(minHeight: 44)
                .background(Warm.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Warm.ink.opacity(0.12)))
        }.buttonStyle(.plain).disabled(store.chatControlBusy || store.chatLoading || store.currentProjectSpace?.status != "active")
    }
    private func send() {
        let value = store.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        store.sendChat(value)
        if available && value.count <= 12000 { focused = false }
    }
    private func scroll(_ proxy: ScrollViewProxy) {
        if reduceMotion { proxy.scrollTo("chat-bottom", anchor: .bottom) }
        else { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("chat-bottom", anchor: .bottom) } }
    }
    private func trustLabel(_ trust: String) -> String {
        switch trust { case "CONFIRMED": return "用户已确认"; case "EVIDENCE": return "原始依据"; default: return "AI 推断 · 待核实" }
    }
    private var historySheet: some View {
        WorkspaceList().environmentObject(store)
    }
    private func sourceSheet(_ value: ChatSource) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(value.confirmation_mode == "archive_auto" ? "归档自动确认":trustLabel(value.trust)).font(.caption).foregroundStyle(Warm.purple)
                    Text(value.text).textSelection(.enabled).lineSpacing(6)
                    if let start = value.start_ms { Text("原文位置：\(start / 1000) 秒起").font(.caption).foregroundStyle(.secondary) }
                    if let page=value.page { Text("PDF第\(page)页").font(.caption).foregroundStyle(.secondary) }
                    if let offset=value.offset { Text("片段位置：第\(offset)字符起").font(.caption).foregroundStyle(.secondary) }
                    if let address=value.url,let url=URL(string:address),["http","https"].contains(url.scheme ?? "") { SwiftUI.Link("打开原始来源",destination:url) }
                    if let sid=value.session_id { NavigationLink("打开录音与原文") { RecordingDetail(recordID:sid).environmentObject(store) } }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
            }.background(Warm.paper).navigationTitle(value.title)
                .toolbar { Button("完成") { source = nil } }
        }
    }
}
struct ProjectSpace: Codable, Identifiable {
    var id: String; var name: String; var goal: String; var default_thread_id: String
    var version: Int; var context_version: Int; var status: String; var created_at: String
    var task_status: String; var message_count: Int; var last_message: String; var queued_count: Int
    var client_request_id: String?; var archive_analysis_status: String?
    var activityLabel: String {
        switch task_status { case "thinking": return queued_count > 1 ? "正在处理 · 有补充排队" : "正在处理"
        case "waiting_input": return "等待你的补充"; case "error": return "有任务待处理"
        default: return message_count == 0 ? "开始一个新的沟通方向" : "\(message_count) 条消息" }
    }
}
struct MaterialScope: Decodable { var mode: String; var workspace_ids: [String]; var revision: Int }
struct WorkspaceMaterial: Decodable, Identifiable {
    var id: String; var source_id: String; var kind: String; var title: String; var text_preview: String
    var linked: Bool; var trust: String; var can_share_personal: Bool; var scope: MaterialScope
}

extension Store {
    var activeProjectSpaces: [ProjectSpace] { projectSpaces.filter { $0.status == "active" } }
    var currentProjectSpace: ProjectSpace? {
        projectSpaces.first { $0.id == chatThread?.workspace_id || $0.default_thread_id == chatThread?.id }
    }
    func reloadProjectSpaces() async throws {
        guard remote else { return }
        let rows: [ProjectSpace] = try await api.all("/v1/project-spaces")
        projectSpaces = rows.sorted { ($0.created_at, $0.id) < ($1.created_at, $1.id) }
    }
    func restoreWorkspaceSelection() async throws {
        let saved = UserDefaults.standard.string(forKey: recoveryKey + "-last-space")
        if let space = activeProjectSpaces.first(where: { $0.id == saved }) { try await loadChat(space.default_thread_id) }
        else if let space = activeProjectSpaces.last { try await loadChat(space.default_thread_id) }
    }
    func selectProjectSpace(_ id: String) async {
        guard !chatControlBusy, let space = projectSpaces.first(where: { $0.id == id }), chatThread?.id != space.default_thread_id else { return }
        do { try await loadChat(space.default_thread_id) } catch { chatError = error.localizedDescription }
    }
    func createProjectSpace() async {
        guard remote, !chatControlBusy else { return }
        chatControlBusy = true; chatError = nil
        let key = recoveryKey + "-new-space-request"
        let requestID = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString
        UserDefaults.standard.set(requestID, forKey: key)
        defer { chatControlBusy = false }
        do {
            let space: ProjectSpace = try await api.call("/v1/project-spaces", method: "POST", body: ["client_request_id":requestID])
            UserDefaults.standard.removeObject(forKey: key)
            try await reloadProjectSpaces(); try await loadChat(space.default_thread_id); try await reloadChats()
        } catch { chatError = "新建暂未完成，重试会核对原请求。" + error.localizedDescription }
    }
    func updateProjectSpace(_ space: ProjectSpace, name: String, goal: String) async throws {
        let _: ProjectSpace = try await api.call("/v1/project-spaces/" + space.id, method: "PATCH",
            body: ["name":name.trimmingCharacters(in:.whitespacesAndNewlines), "goal":goal,
                   "expected_version":space.version])
        try await reloadProjectSpaces()
    }
    func archiveProjectSpace(restore: Bool = false, selected: ProjectSpace? = nil) async {
        guard !chatControlBusy, let space = selected ?? currentProjectSpace else { return }
        chatControlBusy = true; defer { chatControlBusy = false }
        do {
            let _: ProjectSpace = try await api.call("/v1/project-spaces/" + space.id + (restore ? "/restore" : "/archive"),
                method:"POST", body:["expected_version":space.version])
            try await reloadProjectSpaces()
            if restore { try await loadChat(space.default_thread_id) }
            else if currentProjectSpace?.id == space.id {
                if let next = activeProjectSpaces.first { try await loadChat(next.default_thread_id) }
                else {
                    pauseChatObservation(); chatThread = nil; chatMessages = []; chatTasks = []; chatTask = nil
                    chatBusy = false; chatPartial = ""; chatDraft = ""; chatReadPosition = nil
                }
            }
            try await reloadChats()
        } catch { chatError = error.localizedDescription }
    }
}

private struct WorkspaceCarousel: View {
    var spaces: [ProjectSpace]; var selectedID: String?; var compact: Bool; var disabled: Bool
    var select: (String) -> Void; var create: () -> Void
    @State private var position: String?
    @State private var interacting = false
    @State private var pending: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @ScaledMetric(relativeTo:.body) private var cardHeight = 112.0
    @ScaledMetric(relativeTo:.caption) private var compactHeight = 72.0
    private let newID = "__new-project-space"
    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                if #available(iOS 18.0, *) {
                    scroller(width:geometry.size.width).onScrollPhaseChange { _, phase in
                        interacting = phase != .idle
                        if !interacting { scheduleSelection() }
                    }
                } else {
                    scroller(width:geometry.size.width).simultaneousGesture(DragGesture()
                        .onChanged { _ in interacting = true; pending?.cancel() }
                        .onEnded { _ in interacting = false; scheduleSelection() })
                }
            }.frame(height:compact ? compactHeight : cardHeight)
            if !compact {
                HStack {
                    Text(position == newID ? "新建一个沟通方向" : "项目空间 · 左右滑动切换")
                    Spacer()
                    if let index = spaces.firstIndex(where: { $0.id == position }) { Text("\(index + 1) / \(spaces.count)").monospacedDigit() }
                }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal,22)
            }
        }.padding(.top,8)
        .onAppear { position = selectedID ?? spaces.first?.id ?? newID }
        .onChange(of:selectedID) { _, value in
            if let value, spaces.contains(where: { $0.id == value }), position != value {
                if reducedMotion { position = value } else { withAnimation(.easeOut(duration:0.2)) { position = value } }
            }
        }
        .onChange(of:position) { _, _ in scheduleSelection() }
        .onDisappear { pending?.cancel() }
        .accessibilityElement(children:.contain)
        .accessibilityLabel("项目空间切换")
        .accessibilityAdjustableAction { direction in
            let ids = spaces.map(\.id) + [newID]
            let current = ids.firstIndex(of:position ?? "") ?? 0
            let next = direction == .increment ? min(current+1,ids.count-1) : max(current-1,0)
            position = ids[next]
            if position != newID, let position { select(position) }
        }
    }
    private func scroller(width: CGFloat) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing:10) {
                ForEach(spaces) { space in
                    Button { position = space.id; select(space.id) } label: {
                        VStack(alignment:.leading,spacing:compact ? 4 : 7) {
                            HStack {
                                Text(space.name).font(.headline).lineLimit(1)
                                Spacer(minLength:4)
                                if space.id == selectedID { Image(systemName:"checkmark.circle.fill").foregroundStyle(Warm.purple).accessibilityHidden(true) }
                            }
                            if !compact { Text(space.goal.isEmpty ? space.last_message : space.goal).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            Text(space.activityLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,16).padding(.vertical,12)
                            .frame(height:compact ? compactHeight : cardHeight)
                            .background(space.id == selectedID ? Warm.lavender : Warm.white,in:RoundedRectangle(cornerRadius:18))
                            .overlay(RoundedRectangle(cornerRadius:18).stroke(space.id == selectedID ? Warm.purple.opacity(0.5) : Warm.ink.opacity(0.12)))
                    }.buttonStyle(.plain).frame(width:min(max(width-52,220),460)).id(space.id)
                        .accessibilityLabel(space.name).accessibilityValue(space.activityLabel)
                        .accessibilityAddTraits(space.id == selectedID ? .isSelected : [])
                }
                Button(action:create) {
                    HStack(spacing:12) {
                        Image(systemName:"plus").font(.title3).frame(width:40,height:40).background(Warm.lavender,in:Circle()).accessibilityHidden(true)
                        VStack(alignment:.leading,spacing:5) {
                            Text("新建空间").font(.headline)
                            if !compact { Text("换个方向，从这里聊起").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }.padding(16).frame(height:compact ? compactHeight : cardHeight)
                        .background(Warm.white,in:RoundedRectangle(cornerRadius:18))
                        .overlay(RoundedRectangle(cornerRadius:18).stroke(Warm.ink.opacity(0.22),style:StrokeStyle(lineWidth:1,dash:[5,4])))
                }.buttonStyle(.plain).frame(width:min(max(width-52,220),460)).id(newID).accessibilityLabel("新建项目空间，直接开始聊天")
            }.scrollTargetLayout()
        }.scrollIndicators(.hidden).contentMargins(.horizontal,18,for:.scrollContent)
            .scrollTargetBehavior(.viewAligned).scrollPosition(id:$position,anchor:.center).scrollDisabled(disabled)
            .disabled(disabled)
    }
    private func scheduleSelection() {
        pending?.cancel()
        guard !interacting, !disabled, let id = position, id != newID, id != selectedID else { return }
        pending = Task {
            do { try await Task.sleep(for:.milliseconds(220)) } catch { return }
            guard !Task.isCancelled, !interacting, position == id else { return }
            select(id)
        }
    }
}

private struct WorkspaceList: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("进行中的空间") {
                    if store.activeProjectSpaces.isEmpty { Text("还没有进行中的空间") }
                    ForEach(store.activeProjectSpaces) { space in
                        Button { Task { await store.selectProjectSpace(space.id); dismiss() } } label: {
                            VStack(alignment:.leading,spacing:5) { Text(space.name); Text(space.activityLabel).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Button("新建空间",systemImage:"plus") { Task { await store.createProjectSpace(); if store.chatError == nil { dismiss() } } }.disabled(store.chatControlBusy)
                }
                Section("已归档") {
                    ForEach(store.projectSpaces.filter { $0.status == "archived" }) { space in
                        VStack(alignment:.leading,spacing:8) {
                            Button(space.name) { Task { await store.selectProjectSpace(space.id); dismiss() } }
                            Text("历史已保留 · 归档资料自动整理").font(.caption).foregroundStyle(.secondary)
                            Button("恢复空间") { Task { await store.archiveProjectSpace(restore:true,selected:space); if store.chatError == nil { dismiss() } } }
                                .disabled(store.chatControlBusy).frame(minHeight:44)
                        }
                    }
                }
            }.navigationTitle("项目空间").toolbar { Button("完成") { dismiss() } }
        }.task { try? await store.reloadProjectSpaces() }
    }
}

private struct WorkspaceEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let space: ProjectSpace
    @State private var name = ""; @State private var goal = ""; @State private var saving = false; @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("名称") { TextField("空间名称",text:$name).accessibilityLabel("空间名称") }
                Section("沟通方向") { TextEditor(text:$goal).frame(minHeight:120).accessibilityLabel("空间目标"); Text("平时直接聊天即可，需要时再修改方向。").font(.caption) }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("名称与方向").toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("保存") {
                    saving = true
                    Task { defer { saving = false }; do { try await store.updateProjectSpace(space,name:name,goal:goal); dismiss() } catch { self.error = error.localizedDescription } }
                }.disabled(saving || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || name.count>80 || goal.count>1200) }
            }
        }.onAppear { name = space.name; goal = space.goal }
    }
}

private struct WorkspaceMaterials: View {
    @EnvironmentObject var store: Store
    let space: ProjectSpace
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [WorkspaceMaterial] = []; @State private var error: String?; @State private var saving = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink("补充文字、链接或PDF") { MaterialIntake(workspaceID:space.id).environmentObject(store) }
                    NavigationLink("个人记忆") { PersonalMemories().environmentObject(store) }
                    Text("当前空间读取关联资料和通用个人资料。未标明范围的旧资料会保留在资料库中。").font(.subheadline) }
                if let error { Text(error).foregroundStyle(.red) }
                if rows.isEmpty { Text("还没有可关联的真实资料").foregroundStyle(.secondary) }
                ForEach(rows) { item in
                    VStack(alignment:.leading,spacing:6) {
                        Text(item.title).font(.headline).lineLimit(2)
                        Text(item.text_preview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        HStack {
                            Text(item.scope.mode == "personal" ? "通用个人资料" : item.linked ? "当前空间可读取" : "尚未关联当前空间").font(.caption)
                            Spacer()
                            Menu("调整范围") {
                                Button("关联当前空间") { change(item,mode:"spaces",ids:Array(Set(item.scope.workspace_ids+[space.id]))) }
                                if item.linked && item.scope.mode != "personal" {
                                    Button("从当前空间移除") { let ids = item.scope.workspace_ids.filter { $0 != space.id }; change(item,mode:ids.isEmpty ? "unassigned" : "spaces",ids:ids) }
                                }
                                if item.can_share_personal { Button("标为通用个人资料") { change(item,mode:"personal",ids:[]) } }
                                Button("设为未分配") { change(item,mode:"unassigned",ids:[]) }
                            }.frame(minHeight:44).disabled(saving)
                        }
                    }.padding(.vertical,5)
                }
            }.navigationTitle("可读取的资料").toolbar { Button("完成") { dismiss() } }
        }.task { await reload() }
    }
    private func reload() async {
        do { rows = try await store.api.all("/v1/project-spaces/" + space.id + "/materials") }
        catch { self.error = error.localizedDescription }
    }
    private func change(_ item: WorkspaceMaterial, mode: String, ids: [String]) {
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                _ = try await store.api.raw("/v1/agent/material-scope",method:"PUT",body:["source_id":item.source_id,"mode":mode,"workspace_ids":ids,"expected_revision":item.scope.revision])
                await reload()
            } catch { self.error = error.localizedDescription }
        }
    }
}
