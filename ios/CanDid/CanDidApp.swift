import SwiftUI

@main struct CanDidApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).tint(Warm.purple)
                .preferredColorScheme(.light)
        }
    }
}
enum Warm {
    static let paper = Color(red: 0.969, green: 0.953, blue: 0.914)
    static let white = Color(red: 1, green: 0.996, blue: 0.984)
    static let ink = Color(red: 0.204, green: 0.208, blue: 0.18)
    static let purple = Color(red: 0.447, green: 0.314, blue: 0.631)
    static let lavender = Color(red: 0.933, green: 0.906, blue: 0.98)
    static let orange = Color(red: 1, green: 0.753, blue: 0.471)
    static let sage = Color(red: 0.91, green: 0.941, blue: 0.843)
}
struct WarmCard<Content: View>: View {
    var color: Color
    var content: Content
    init(color: Color = Warm.white, @ViewBuilder content: () -> Content) { self.color = color; self.content = content() }
    var body: some View { VStack(alignment: .leading, spacing: 12) { content }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(color, in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(Warm.ink.opacity(0.08))) }
}
struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.body, design: .rounded).weight(.semibold)).frame(maxWidth: .infinity).padding(15)
            .foregroundStyle(Warm.ink).background(Warm.orange, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .brown.opacity(0.3), radius: 0, y: configuration.isPressed ? 1 : 4)
            .offset(y: configuration.isPressed ? 2 : 0)
    }
}
struct Mascot: View {
    var size: CGFloat = 90
    var body: some View { Image("Mascot").resizable().scaledToFit().frame(width: size, height: size).accessibilityLabel("Candid 紫色双气泡") }
}
struct TrustBadge: View {
    var fact: Bool
    var body: some View { Label(fact ? "已确认事实" : "AI 推断 · 待确认", systemImage: fact ? "checkmark.seal" : "sparkles").font(.caption).foregroundStyle(fact ? Color.green : Warm.purple).padding(.horizontal, 10).padding(.vertical, 6).background(fact ? Warm.sage : Warm.lavender, in: Capsule()) }
}
struct RootView: View {
    @EnvironmentObject var store: Store
    @Environment(\.scenePhase) var phase
    @State private var settings = false
    var body: some View {
        Group {
            if store.onboarding {
                RecordingShell(navigation:store.recordingNavigation,speech:store.speech,device:store.soundcore,onSettings:{settings=true})
            } else { OnboardingView() }
        }
        .fontDesign(.rounded).foregroundStyle(Warm.ink)
        .sheet(isPresented: $settings) { SettingsView() }
        .alert("需要留意", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("知道了") { store.error = nil } } message: { Text(store.error ?? "") }
        .alert("Candid", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) { Button("好") { store.message = nil } } message: { Text(store.message ?? "") }
        .overlay { if store.busy { ProgressView().padding(22).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .onChange(of: phase) { _, value in
            store.chatSceneChanged(active: value == .active)
            if value == .active { store.purgeLocalExpired() }
            else { store.soundcore.stopScan() }
        }
        .task { await store.restoreConnection() }
        .modifier(VoicePresentation(voice:store.voice))
    }
}
struct CompanionView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            HStack { Mascot(size: 65); VStack(alignment: .leading) { Text("和你一起，准备下一次。").font(.title2.bold()); Text(store.remote ? "已连接动态记忆后端" : "离线示例 · 保存在本机").font(.caption).foregroundStyle(.secondary) } }
            WarmCard(color: Warm.lavender) {
                Text("记忆不只是存下来。 ").font(.headline)
                Text("每次复盘产生草稿，你可以核对、修改、确认。下一次准备会区分事实与推断，也会保留出处。")
                HStack { Label("\(store.assets.filter { $0.isFact && $0.status != "archived" }.count) 条已确认", systemImage: "checkmark.seal"); Spacer(); Label("\(store.assets.filter { $0.status == "draft" }.count) 条草稿", systemImage: "sparkles") }.font(.caption)
            }
            Text("下一场，想推进什么？").font(.title3.bold())
            if store.occasions.isEmpty { Text("先建立一个场合：岗位、融资、报告或客户机会。").foregroundStyle(.secondary) }
            ForEach(store.occasions.prefix(3)) { occasion in
                NavigationLink { OccasionDetailView(occasion: occasion) } label: {
                    WarmCard { Text(occasion.title).font(.headline); Text(Scenario(rawValue: occasion.scenario)?.title ?? occasion.scenario).font(.caption).foregroundStyle(.secondary); Label("打开准备与记录", systemImage: "arrow.right").foregroundStyle(Warm.purple) }
                }.buttonStyle(.plain)
            }
            WarmCard { Text("关于真实 AI 能力").font(.headline); Text("已接入 DeepSeek 本人文本复盘，连接后端后在口述复盘中选择分析。录音自动转写尚未配置；离线示例保持独立。").font(.subheadline).foregroundStyle(.secondary) }
        }.padding(20) }.background(Warm.paper.ignoresSafeArea()).navigationTitle("Candid")
    }
}
struct MemoryView: View {
    @EnvironmentObject var store: Store
    @State private var filter = "confirmed"
    @State private var adding = false
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            WarmCard(color: Warm.lavender) { Label("每一条，都有来处", systemImage: "leaf").font(.headline); Text("事实、推断和证据分开保存。确认是你做的决定，不会由 AI 自动代替。").font(.subheadline) }
            Picker("素材状态", selection: $filter) { Text("已确认").tag("confirmed"); Text("待确认").tag("draft"); Text("已归档").tag("archived") }.pickerStyle(.segmented)
            let rows = store.assets.filter { $0.status == filter }
            if rows.isEmpty { ContentUnavailableView("慢慢积累就好", systemImage: "leaf", description: Text(filter == "draft" ? "示例复盘可以产生待确认草稿。" : "可以手动添加你已确认的经历和表达。")) }
            ForEach(rows) { asset in NavigationLink { AssetDetailView(asset: asset) } label: {
                WarmCard { TrustBadge(fact: asset.isFact); Text(asset.title).font(.headline); Text(asset.body.text).font(.subheadline).lineLimit(3); Text("v\(asset.version) · \(Scenario(rawValue: asset.scenario ?? "")?.title ?? "跨场景")").font(.caption).foregroundStyle(.secondary) }
            }.buttonStyle(.plain) }
        }.padding(20) }.background(Warm.paper.ignoresSafeArea()).navigationTitle("记忆库")
            .toolbar { ToolbarItem(placement: .bottomBar) { Button("添加已确认素材", systemImage: "plus") { adding = true } } }
            .sheet(isPresented: $adding) { AddAssetView() }.refreshable { await store.perform { try await store.reload() } }
    }
}
struct AddAssetView: View {
    @EnvironmentObject var store: Store; @Environment(\.dismiss) var dismiss
    @State var title = ""; @State var text = ""; @State var scenario = Scenario.interview
    var body: some View { NavigationStack { Form {
        TextField("素材标题", text: $title); Picker("适用场景", selection: $scenario) { ForEach(Scenario.allCases) { Text($0.title).tag($0) } }
        TextEditor(text: $text).frame(minHeight: 160).accessibilityLabel("已确认的经历或表达")
        Text("这是你主动提供并确认的内容，将作为事实进入下一次准备。请只保存可以核实的信息。").font(.footnote)
        Button("我确认，保存为事实") { Task { await store.perform { try await store.addAsset(title: title, text: text, scenario: scenario); dismiss() } } }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }.navigationTitle("留下你的素材").toolbar { Button("取消") { dismiss() } } } }
}
struct AssetDetailView: View {
    @EnvironmentObject var store: Store
    let asset: Asset
    @State private var text = ""
    @State private var archiveConfirm = false
    var current: Asset { store.assets.first { $0.id == asset.id } ?? asset }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            TrustBadge(fact: current.isFact)
            Text(current.title).font(.title.bold())
            TextEditor(text: $text).frame(minHeight: 200).padding(10).background(Warm.white, in: RoundedRectangle(cornerRadius: 16)).accessibilityLabel("修改素材内容")
            Text("v\(current.version) · \(current.producer ?? "用户提供")").font(.caption).foregroundStyle(.secondary)
            ForEach(current.evidence_refs ?? [], id: \.self) { ref in
                if let session = store.sessions.first(where: { $0.id == ref.session_id }) {
                    NavigationLink { SessionDetailView(session: session) } label: { Label("原文依据 \(ref.start_ms/1000)–\(ref.end_ms/1000) 秒", systemImage: "link") }
                }
            }
            Button(current.isFact ? "确认并保存我的新版本" : "核对完毕，确认为事实") { Task { await store.perform { try await store.confirm(current, text: text) } } }.buttonStyle(PrimaryButton()).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || current.status == "archived")
            Text("确认绑定当前版本；冲突时需要刷新。后端保存旧版本，未来 AI 草稿不会覆盖这次确认。").font(.caption).foregroundStyle(.secondary)
            if current.status != "archived" { Button("归档这条素材", role: .destructive) { archiveConfirm = true } }
        }.padding(20) }.background(Warm.paper.ignoresSafeArea()).navigationTitle("表达与经历")
            .onAppear { text = current.body.text }
            .confirmationDialog("归档后不会进入准备上下文", isPresented: $archiveConfirm) { Button("归档", role: .destructive) { Task { await store.perform { try await store.archive(current) } } } }
    }
}
struct OccasionsView: View {
    @EnvironmentObject var store: Store; @State var adding = false
    var body: some View {
        ScrollView { VStack(spacing: 16) {
            if store.occasions.isEmpty { ContentUnavailableView("先认识这一场", systemImage: "rectangle.stack", description: Text("一个岗位、一轮融资、一场报告或一位客户。")) }
            ForEach(store.occasions) { item in NavigationLink { OccasionDetailView(occasion: item) } label: {
                WarmCard { Text(item.title).font(.headline); Text("\(Scenario(rawValue: item.scenario)?.title ?? item.scenario) · \(item.status == "active" ? "进行中" : "已回填结果")").font(.caption); Text(item.fields.goal ?? "目标待补充").font(.subheadline).foregroundStyle(.secondary) }
            }.buttonStyle(.plain) }
        }.padding(20) }.background(Warm.paper.ignoresSafeArea()).navigationTitle("场合")
            .toolbar { ToolbarItem(placement: .bottomBar) { Button("新建场合", systemImage: "plus") { adding = true } } }
            .sheet(isPresented: $adding) { AddOccasionView() }.refreshable { await store.perform { try await store.reload() } }
    }
}
struct AddOccasionView: View {
    @EnvironmentObject var store: Store; @Environment(\.dismiss) var dismiss
    @State var title = ""; @State var goal = ""; @State var scenario = Scenario.interview
    var body: some View { NavigationStack { Form {
        Picker("场景", selection: $scenario) { ForEach(Scenario.allCases) { Text($0.title).tag($0) } }
        TextField("场合名称", text: $title); TextField("这次想推进什么", text: $goal)
        Button("建立这次机会") { Task { await store.perform { try await store.addOccasion(title: title, scenario: scenario, goal: goal); dismiss() } } }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }.navigationTitle("认识下一场").toolbar { Button("取消") { dismiss() } } } }
}
struct OccasionDetailView: View {
    @EnvironmentObject var store: Store; let occasion: Occasion
    @State var context: ContextPack?; @State var recording = false; @State var outcome = false; @State var result = ""; @State var role = ""
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            Text(occasion.title).font(.title.bold()); Text(occasion.fields.goal ?? "目标待补充").foregroundStyle(.secondary)
            WarmCard(color: Warm.lavender) { Text("先带上可靠的记忆").font(.headline); Text("已确认素材可复用，原文是沟通证据；诊断和短板作为 AI 建议参考。"); Button("查看准备上下文") { Task { await store.perform { context = try await store.context(occasion) } } } }
            if let context {
                ForEach(context.sections) { section in
                    ForEach(section.items) { item in WarmCard { Text(item.trust == "FACT" ? "用户已确认" : item.trust == "EVIDENCE" ? "原始证据 · 用户原话" : "AI 推断 · 待核实").font(.caption).foregroundStyle(Warm.purple); Text(item.text).font(.subheadline).textSelection(.enabled) } }
                }
                if context.sections.allSatisfy({ $0.items.isEmpty }) { Text("还没有可用于准备的已确认记忆。先到记忆库确认一条素材。") }
                if !context.truncated.isEmpty { Text("低优先级内容已截断："+context.truncated.joined(separator: "、")).font(.caption) }
            }
            Button("开始沟通录音", systemImage: "mic") {
                store.recordingNavigation.newMeeting = !store.speech.activeMeeting && store.soundcore.recordStatus==0
                store.recordingNavigation.showRecorder=true
            }.buttonStyle(PrimaryButton())
            Button("练习与口述复盘") {recording=true}.frame(minHeight:44)
            Button("运行预处理示例闭环", systemImage: "sparkles") { Task { await store.perform { try await store.fixture(occasion) } } }
            Text("此按钮只产生单独的示例场次，不分析你的实际录音。").font(.caption).foregroundStyle(.secondary)
            if store.remote {
                WarmCard { TextField("听众角色，例如 hr 或 client_cautious", text: $role); Button("保存听众选择") { Task { await store.perform { _ = try await store.api.raw("/v1/occasions/"+occasion.id+"/audiences", method: "POST", body: ["role_key": role, "label": role]); store.message = "听众选择已保存；实时听众 Agent 未配置。" } } }.disabled(role.isEmpty) }
                Button("回填这次结果") { outcome = true }
            }
        }.padding(20) }.background(Warm.paper.ignoresSafeArea()).navigationTitle("这次机会")
            .sheet(isPresented: $recording) { RecordView(occasion: occasion) }
            .alert("结果只用于推进流程", isPresented: $outcome) { TextField("实际结果", text: $result); Button("保存") { Task { await store.perform { _ = try await store.api.raw("/v1/occasions/"+occasion.id+"/outcome", method: "POST", body: ["result": result, "note": "用户回填"]); try await store.reload() } } }; Button("取消", role: .cancel) { } }
    }
}
struct SessionsView: View {
    @EnvironmentObject var store: Store
    var body: some View { ScrollView { VStack(spacing: 16) {
        if store.sessions.isEmpty { ContentUnavailableView("从一场经验开始", systemImage: "mic", description: Text("到场合中开始练习、录音或口述复盘。")) }
        ForEach(store.sessions) { session in NavigationLink { SessionDetailView(session: session) } label: {
            WarmCard { HStack { Text(session.fixture == true ? "预处理示例" : session.kind == "oral_debrief" ? "口述复盘" : session.recording_source == "soundcore" ? "soundcore 录音" : "真实录音").font(.headline); Spacer(); Image(systemName: "chevron.right") }; Text(store.occasions.first { $0.id == session.occasion_id }?.title ?? "未关联场合").font(.subheadline); Text(session.pipeline_status).font(.caption).foregroundStyle(.secondary); Text("原音频：\(session.audio_purged_at == nil ? "保留 \(session.retention_days) 天" : "已删除")").font(.caption) }
        }.buttonStyle(.plain) }
    }.padding(20) }.background(Warm.paper.ignoresSafeArea()).navigationTitle("每一次开口").refreshable { await store.perform { try await store.reload() } } }
}
struct SessionDetailView: View {
    @EnvironmentObject var store: Store; let session: Session
    @State var review: Review?; @State var tab = "复盘"; @State var deleteAudio = false
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 18) {
        if let review {
            Text(review.session.fixture == true ? "预处理示例 · 非真实模型输出" : "你的实际场次").font(.caption).foregroundStyle(Warm.purple)
            WarmCard { Text(review.session.pipeline_status).font(.headline); Text(review.session.rubric_version).font(.caption); HStack { Button("播放原音频", systemImage: "play") { Task { await store.perform { try await store.play(review.session) } } }; Spacer(); Button("暂停回放") { store.stopPlayback() } }; if let note = review.audio_note { Text(note).font(.caption) } }
            if review.session.pipeline_status.hasPrefix("failed:") || review.session.pipeline_status == "awaiting_model" {
                Text(review.session.pipeline_error_message ?? "本人原文已保存，可选择发送给 DeepSeek 分析。仅有音频时仍需等待语音转写接入。").font(.subheadline)
                if store.remote && store.capabilities?.llm_configured == true && review.session.transcript_segments?.contains(where: { $0.speaker == "self" }) == true {
                    Button("同意发送本人原文给 DeepSeek 并分析") { Task { await store.perform {
                        _ = try await store.api.raw("/v1/sessions/"+session.id+"/analyze", method: "POST")
                        self.review = try await store.detail(session)
                    } } }
                }
            }
            Picker("内容", selection: $tab) { Text("复盘").tag("复盘"); Text("原文").tag("原文") }.pickerStyle(.segmented)
            if tab == "复盘" {
                ForEach(review.diagnoses) { d in WarmCard(color: Warm.lavender) {
                    Text("推断 · 之前的分析认为").font(.caption).foregroundStyle(Warm.purple); Text(d.finding).font(.headline); Text(d.suggestion)
                    Text("\(d.producer) · \(d.rubric_version)").font(.caption)
                    ForEach(d.evidence_refs, id: \.self) { ref in Button("查看 \(ref.start_ms/1000)–\(ref.end_ms/1000) 秒本人原文") { tab = "原文" } }
                    HStack {
                        Button("认可") { Task { await store.perform { try await store.feedback(d, verdict: "agree") } } }
                        Button("我不同意") { Task { await store.perform { try await store.feedback(d, verdict: "disagree") } } }
                    }
                }
                }
                ForEach(review.draft_assets) { asset in NavigationLink { AssetDetailView(asset: asset) } label: { WarmCard { Text("待确认素材").font(.caption); Text(asset.title).font(.headline); Text("查看、修改与确认 →").foregroundStyle(Warm.purple) } }.buttonStyle(.plain) }
                if review.diagnoses.isEmpty { ContentUnavailableView("暂时没有诊断", systemImage: "sparkles", description: Text("分析中会自动刷新；也可下拉刷新。只有本人原文才能生成有证据的诊断。")) }
            } else {
                ForEach(review.session.transcript_segments ?? []) { segment in WarmCard { Text("\(segment.speaker == "self" ? "本人" : "本场对方") · \(segment.start_ms/1000)–\(segment.end_ms/1000) 秒").font(.caption); Text(segment.text).textSelection(.enabled) } }
            }
            Button("立即删除本场原音频", role: .destructive) { deleteAudio = true }.disabled(review.session.audio_purged_at != nil)
        } else { ProgressView("读取这场记忆…") }
    }.padding(20) }.background(Warm.paper.ignoresSafeArea()).navigationTitle("场次复盘")
        .task {
            await store.perform { review = try await store.detail(session) }
            while store.remote && !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                    guard let status = review?.session.pipeline_status,
                          ["queued", "diagnosing", "segmenting", "aggregating", "transcribing"].contains(status) else { continue }
                    review = try await store.detail(session)
                    if review?.session.pipeline_status == "done" { try await store.reload() }
                } catch is CancellationError { break }
                catch { store.error = error.localizedDescription; break }
            }
        }
        .refreshable { await store.perform { review = try await store.detail(session); try await store.reload() } }
        .onDisappear { store.stopPlayback() }
        .confirmationDialog("删除后不能回听，原文与复盘保留", isPresented: $deleteAudio) { Button("删除原音频", role: .destructive) { Task { await store.perform { try await store.purge(session); review = try await store.detail(session) } } } }
    }
}
struct SettingsView: View {
    @EnvironmentObject var store: Store; @Environment(\.dismiss) var dismiss
    @State var token = ""; @State private var backendAddress = ""; @State var exportURL: URL?; @State var deleting = false; @State var allowBackend = false
    var body: some View { NavigationStack { Form {
        Section("个人资料") { NavigationLink("我的介绍与资料") { PersonalProfilePage() } }
        Section("运行模式") { Text(store.remote ? "已连接持久化 FastAPI 后端" : "离线示例 · 本机保存"); Button("切回离线示例") { UserDefaults.standard.set(false, forKey: "remote-enabled"); store.loadDemo() }.disabled(store.chatBusy) }
        Section("连接后端") {
            TextField("后端地址", text: $backendAddress).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            SecureField("本机令牌或 Supabase 用户 JWT", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("同意在填写的后端地址保存我的资料与音频", isOn: $allowBackend)
            Text("模拟器连接 http://127.0.0.1:8000。真机填写电脑局域网地址。默认本机令牌由后端生成，不包含服务端密钥。跨境云端部署需要另行同意流程。").font(.footnote)
            Button("连接并读取真实后端数据") { Task { await store.perform { try await store.connect(token: token, backend: backendAddress); dismiss() } } }.disabled(token.isEmpty || !allowBackend)
        }
        Section("文本 Agent") {
            if store.remote, let capability = store.capabilities {
                Text(capability.agent_configured == true ? "已连接安克模型网关" : "后端尚未配置文本 Agent")
                Text(capability.agent_model ?? "未配置").font(.caption)
                Text("发送的消息及按问题检索的资料会由后端交给模型。AI 回复可以保留为草稿，由你确认后进入长期记忆。").font(.footnote)
            } else { Text("连接本机后端后可以开始真实文本对话。模型 Key 仅保存在后端。") }
        }
        Section("录音文本分析模型") {
            if store.remote, let capability = store.capabilities {
                LabeledContent("服务", value: capability.llm_provider)
                LabeledContent("模型", value: capability.llm_model)
                Text(capability.llm_configured ? "后端已配置密钥。选择分析时仅发送本次本人原文。" : "后端尚未配置 DeepSeek 密钥。")
            } else { Text("连接后端后显示模型信息；密钥仅保存在后端。") }
        }
        Section("原音频保留") {
            Picker("默认保留", selection: $store.retention) { ForEach([0,7,30,90,180], id: \.self) { Text($0 == 0 ? "处理完即删" : "\($0) 天").tag($0) } }
            Button("应用保留设置") { Task { await store.perform { try await store.setRetention(store.retention); store.message = "保留设置已更新" } } }
            Text("后端持续运行时自动清理到期音频；缩短应用于已有场次，延长仅影响新场次。离线示例仅在 App 启动和回到前台时检查到期。").font(.footnote)
        }
        Section("你的数据") {
            Button("导出记忆 JSON") { Task { await store.perform { exportURL = try await store.export() } } }
            if let exportURL { ShareLink("分享导出文件", item: exportURL) }
            Button("删除全部记忆", role: .destructive) { deleting = true }
            Text("删除后会停止读取与处理，清理当前后端用户的全部记忆。离线示例数据独立保存。").font(.footnote)
        }
        Section("录音设备") { NavigationLink("soundcore 连接与授权") { SoundcoreDeviceView(device: store.soundcore) } }
        Section("原型范围") { Text("设备录音由硬件按键开始和结束；App 可以暂停、继续、查看实时字幕和同步完整文件。录音与资料由当前连接的后端管理。").font(.footnote) }
    }.onAppear { if backendAddress.isEmpty { backendAddress = store.base } }.navigationTitle("设置与隐私").toolbar { Button("完成") { dismiss() } }
        .confirmationDialog("永久删除当前模式的全部记忆？", isPresented: $deleting) { Button("删除全部记忆", role: .destructive) { Task { await store.perform { try await store.deleteMemory(); dismiss() } } } }
    } }
}
