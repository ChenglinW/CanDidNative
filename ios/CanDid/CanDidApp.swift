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
                TabView {
                    NavigationStack { CompanionView() }.tabItem { Label("Candid", systemImage: "bubble.left.and.bubble.right") }
                    NavigationStack { MemoryView() }.tabItem { Label("记忆库", systemImage: "book.closed") }
                    NavigationStack { OccasionsView() }.tabItem { Label("场合", systemImage: "rectangle.stack") }
                    NavigationStack { SessionsView() }.tabItem { Label("场次", systemImage: "mic") }
                }.toolbarBackground(Warm.white, for: .tabBar)
            } else { WelcomeView() }
        }
        .fontDesign(.rounded).foregroundStyle(Warm.ink)
        .sheet(isPresented: $settings) { SettingsView() }
        .alert("需要留意", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("知道了") { store.error = nil } } message: { Text(store.error ?? "") }
        .alert("Candid", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) { Button("好") { store.message = nil } } message: { Text(store.message ?? "") }
        .overlay(alignment: .topTrailing) {
            Button { settings = true } label: { Image(systemName: "gearshape").padding(12).background(Warm.paper, in: Circle()) }.padding(.trailing, 12).accessibilityLabel("设置与后端连接")
        }
        .overlay { if store.busy { ProgressView().padding(22).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .onChange(of: phase) { _, value in
            if value == .active { store.purgeLocalExpired() }
            else { store.soundcore.stopScan() }
        }
    }
}
struct WelcomeView: View {
    @EnvironmentObject var store: Store
    @State private var consent = false
    var body: some View {
        ScrollView { VStack(spacing: 24) {
            Mascot(size: 180).padding(.top, 60)
            Text("下一次开口，\n从上次的终点开始。").font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text("资料、场合、每次沟通，\n慢慢变成用得上的记忆。").foregroundStyle(.secondary).multilineTextAlignment(.center)
            WarmCard { Text("你来决定，哪些成为事实。").font(.headline); Text("AI 只能提出草稿。确认后的素材才会作为事实用于下一次准备；原始证据保持不变。").font(.subheadline) }
            WarmCard(color: Warm.sage) { Text("原音频默认保留 90 天").font(.headline); Text("用于同一机会周期内回听。可改为处理后删除、7／30／90／180 天，也可以随时删除。此原型不会发送到第三方 AI 服务。").font(.subheadline) }
            Toggle("同意本机保存我主动提供的资料与录音", isOn: $consent).font(.subheadline)
            Button("进入原生 App 示例") { store.onboarding = true; store.persist() }.buttonStyle(PrimaryButton()).disabled(!consent)
            Text("原生 SwiftUI · 示例与真实记录分别标识\n后端连接在右上角设置中配置").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(24) }.background(Warm.paper.ignoresSafeArea())
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
            WarmCard { Text("关于真实 AI 能力").font(.headline); Text("转写与诊断服务尚未配置。真实录音可保存、上传、回放和删除；演示分析只来自明确标识的预处理示例。").font(.subheadline).foregroundStyle(.secondary) }
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
            WarmCard(color: Warm.lavender) { Text("先带上可靠的记忆").font(.headline); Text("已确认素材和原文可以作为事实；诊断和短板只能作为推断参考。"); Button("查看准备上下文") { Task { await store.perform { context = try await store.context(occasion) } } } }
            if let context {
                ForEach(context.sections) { section in
                    ForEach(section.items) { item in WarmCard { Text(item.trust == "FACT" ? "事实" : "推断 · 之前的分析认为").font(.caption).foregroundStyle(Warm.purple); Text(item.text).font(.subheadline).textSelection(.enabled) } }
                }
                if context.sections.allSatisfy({ $0.items.isEmpty }) { Text("还没有可用于准备的已确认记忆。先到记忆库确认一条素材。") }
                if !context.truncated.isEmpty { Text("低优先级内容已截断："+context.truncated.joined(separator: "、")).font(.caption) }
            }
            Button("练习或记录这一场", systemImage: "mic") { recording = true }.buttonStyle(PrimaryButton())
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
                Text("真实转写／诊断服务尚未接入。原音频或本人原文已保存，当前没有分析结果。").font(.subheadline)
                if store.remote { Button("重试处理") { Task { await store.perform { _ = try await store.api.raw("/v1/sessions/"+session.id+"/retry", method: "POST", body: ["stage": "transcribing"]); self.review = try await store.detail(session) } } } }
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
                if review.diagnoses.isEmpty { ContentUnavailableView("暂时没有诊断", systemImage: "sparkles", description: Text("示例管线可以演示完整闭环；真实内容需要接入模型后处理。")) }
            } else {
                ForEach(review.session.transcript_segments ?? []) { segment in WarmCard { Text("\(segment.speaker == "self" ? "本人" : "本场对方") · \(segment.start_ms/1000)–\(segment.end_ms/1000) 秒").font(.caption); Text(segment.text).textSelection(.enabled) } }
            }
            Button("立即删除本场原音频", role: .destructive) { deleteAudio = true }.disabled(review.session.audio_purged_at != nil)
        } else { ProgressView("读取这场记忆…") }
    }.padding(20) }.background(Warm.paper.ignoresSafeArea()).navigationTitle("场次复盘")
        .task { await store.perform { review = try await store.detail(session) } }
        .refreshable { await store.perform { review = try await store.detail(session); try await store.reload() } }
        .onDisappear { store.stopPlayback() }
        .confirmationDialog("删除后不能回听，原文与复盘保留", isPresented: $deleteAudio) { Button("删除原音频", role: .destructive) { Task { await store.perform { try await store.purge(session); review = try await store.detail(session) } } } }
    }
}
struct SettingsView: View {
    @EnvironmentObject var store: Store; @Environment(\.dismiss) var dismiss
    @State var token = ""; @State var exportURL: URL?; @State var deleting = false; @State var allowBackend = false
    var body: some View { NavigationStack { Form {
        Section("运行模式") { Text(store.remote ? "已连接持久化 FastAPI 后端" : "离线示例 · 本机保存"); Button("切回离线示例") { store.loadDemo() } }
        Section("连接后端") {
            TextField("后端地址", text: $store.base).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            SecureField("本机令牌或 Supabase 用户 JWT", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("同意在填写的后端地址保存我的资料与音频", isOn: $allowBackend)
            Text("模拟器连接 http://127.0.0.1:8000。真机填写电脑局域网地址。默认本机令牌由后端生成，不包含服务端密钥。跨境云端部署需要另行同意流程。").font(.footnote)
            Button("连接并读取真实后端数据") { Task { await store.perform { try await store.connect(token: token); dismiss() } } }.disabled(token.isEmpty || !allowBackend)
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
        Section("原型范围") { Text("原生 SwiftUI，soundcore 设备录音同步与音频回放。设备录音由硬件按键开始和结束；SDK 授权及蓝牙连接需要真机验证。后端使用 SQLite，ASR、模型网关与 Supabase 云端尚未配置。").font(.footnote) }
    }.navigationTitle("设置与隐私").toolbar { Button("完成") { dismiss() } }
        .confirmationDialog("永久删除当前模式的全部记忆？", isPresented: $deleting) { Button("删除全部记忆", role: .destructive) { Task { await store.perform { try await store.deleteMemory(); dismiss() } } } }
    } }
}
