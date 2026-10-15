import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import CryptoKit
import UIKit

struct PersonalProfile: Codable, Equatable {
    var display_name = ""
    var introduction = ""
    var scenarios: [String] = []
    var isEmpty: Bool { display_name.isEmpty && introduction.isEmpty && scenarios.isEmpty }
}
struct OnboardingDocument: Codable, Identifiable {
    var id: String
    var title: String
    var status: String
    var error: String?
    var job_id: String?
    var localPath: String?
    var serverID: String?
    var statusTitle: String {
        switch status {
        case "completed": return "已整理 · 可按需读取"
        case "queued", "running": return "已保存 · 正在整理"
        case "failed", "interrupted", "cancelled": return "整理未完成 · 可重试"
        case "upload_failed": return "尚未上传 · 可重试"
        default: return "已保存在本机 · 连接后同步"
        }
    }
}
struct OnboardingState: Codable {
    var completed = false
    var step = 0
    var profile = PersonalProfile()
    var version = 0
    var profileDirty = false
    var completionPending = false
    var requestID = UUID().uuidString
    var documents: [OnboardingDocument] = []
    var removedDocumentIDs: [String] = []
    static func restore(_ data: Data) throws -> OnboardingState {
        var value = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(OnboardingState())) as! [String: Any]
        for (key, item) in defaults where value[key] == nil { value[key] = item }
        return try JSONDecoder().decode(OnboardingState.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
struct OnboardingResponse: Decodable {
    var profile: PersonalProfile
    var version: Int
    var completed: Bool
    var documents: [OnboardingDocument]
}

extension Store {
    var personalStateURL: URL {
        let identity = base + "\n" + TokenVault.read()
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return demoURL.deletingLastPathComponent().appendingPathComponent("onboarding-" + key + ".json")
    }
    func loadOnboarding(migrating draft: OnboardingState? = nil) {
        personalSyncError = nil; personalRemoteProfile = nil; personalRemoteVersion = 0
        if let bytes = try? Data(contentsOf: personalStateURL), let saved = try? OnboardingState.restore(bytes) {
            personalState = saved
        } else if let draft {
            personalState = draft
        } else {
            // Existing completed users keep their history; only new/reset users see first use.
            let legacy = (try? Data(contentsOf: demoURL)).flatMap { try? JSONDecoder().decode(LocalSnapshot.self, from: $0) }
            personalState = OnboardingState(completed: legacy?.onboarding ?? false)
        }
        onboarding = personalState.completed
        persistOnboarding()
    }
    func persistOnboarding() {
        do {
            try FileManager.default.createDirectory(at: personalStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(personalState).write(to: personalStateURL, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: personalStateURL.path)
            personalSaveError = nil
        } catch { personalSaveError = "本机保存失败，请检查可用空间后重试。" }
    }
    func changePersonalProfile(_ value: PersonalProfile) {
        var value = value
        value.display_name = String(value.display_name.prefix(40))
        value.introduction = String(value.introduction.prefix(2000))
        guard value != personalState.profile else { return }
        personalState.profile = value
        personalState.profileDirty = true
        personalState.requestID = UUID().uuidString
        persistOnboarding()
    }
    func completeOnboarding() {
        personalEditing = false
        personalState.completed = true
        personalState.step = 0
        personalState.completionPending = true
        personalState.requestID = UUID().uuidString
        persistOnboarding()
        guard personalSaveError == nil else { return }
        onboarding = true
        // Persist before attempting the network; a failed sync never blocks first value.
        Task { await syncPersonalProfile() }
    }
    func restorePersonalProfile() async {
        guard remote else { return }
        let connection = api
        let identity = DeviceRecordingMap.identity(connection)
        let localRequest = personalState.requestID
        do {
            let value: OnboardingResponse = try await connection.call("/v1/onboarding")
            guard identity == DeviceRecordingMap.identity(api), remote else { return }
            if !personalState.profileDirty, localRequest == personalState.requestID, value.version >= personalState.version {
                personalState.profile = value.profile
                personalState.version = value.version
            }
            mergePersonalDocuments(value.documents)
            // Server connectivity and its completion flag never fast-forward an open flow.
            persistOnboarding()
            await syncPersonalProfile()
        } catch { if identity == DeviceRecordingMap.identity(api) { personalSyncError = error.localizedDescription } }
    }
    func readLatestPersonalProfile() async {
        guard remote else { return }
        do {
            let connection = api
            let value: OnboardingResponse = try await connection.call("/v1/onboarding")
            guard DeviceRecordingMap.identity(connection) == DeviceRecordingMap.identity(api) else { return }
            // Keep local edits. A new save is explicitly based on this latest server version.
            personalRemoteProfile = value.profile; personalRemoteVersion = value.version
            if !personalState.profileDirty { personalState.version = value.version; personalState.profile = value.profile }
            personalState.requestID = UUID().uuidString
            mergePersonalDocuments(value.documents)
            personalSyncError = nil
            persistOnboarding()
        } catch { personalSyncError = error.localizedDescription }
    }
    func mergePersonalDocuments(_ rows: [OnboardingDocument]) {
        for var row in rows {
            guard !personalState.removedDocumentIDs.contains(row.id) else { continue }
            row.serverID = row.id
            if let index = personalState.documents.firstIndex(where: { $0.serverID == row.id }) {
                row.localPath = personalState.documents[index].localPath
                personalState.documents[index] = row
            } else { personalState.documents.append(row) }
        }
    }
    func syncPersonalProfile() async {
        guard remote, cloudStorageAllowed || Store.isolatedTestRun, !personalSyncing else { return }
        personalSyncing = true
        let connection = api
        let identity = DeviceRecordingMap.identity(connection)
        let requestID = personalState.requestID
        defer {
            personalSyncing = false
            if remote, identity == DeviceRecordingMap.identity(api), requestID != personalState.requestID { Task { await self.syncPersonalProfile() } }
        }
        do {
            if !personalEditing && personalRemoteProfile == nil && (personalState.profileDirty || personalState.completionPending) {
                var body: [String: Any] = ["client_request_id": requestID, "completed": personalState.completed]
                if personalState.profileDirty {
                    body["profile"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(personalState.profile))
                    body["expected_version"] = personalState.version
                }
                let saved: OnboardingResponse = try await connection.call("/v1/onboarding", method: "PATCH", body: body)
                guard identity == DeviceRecordingMap.identity(api), remote else { return }
                personalState.version = saved.version
                if personalState.requestID == requestID { personalState.profileDirty = false; personalState.completionPending = false }
                mergePersonalDocuments(saved.documents)
                persistOnboarding()
            }
            for item in personalState.documents.filter({ $0.serverID == nil && $0.localPath != nil }) {
                guard identity == DeviceRecordingMap.identity(api), remote, !Task.isCancelled else { return }
                do {
                    var receipt = try await connection.uploadOnboarding(URL(fileURLWithPath: item.localPath!), title: item.title)
                    guard identity == DeviceRecordingMap.identity(api), remote else { return }
                    if let duplicate = personalState.documents.firstIndex(where: { $0.serverID == receipt.id && $0.id != item.id }) {
                        let retainedPath = personalState.documents[duplicate].localPath
                        receipt.serverID = receipt.id; receipt.localPath = retainedPath
                        personalState.documents[duplicate] = receipt
                        personalState.documents.removeAll { $0.id == item.id }
                        if let path = item.localPath, path != retainedPath { try? FileManager.default.removeItem(atPath: path) }
                    } else if let index = personalState.documents.firstIndex(where: { $0.id == item.id }) {
                        receipt.serverID = receipt.id; receipt.localPath = item.localPath
                        personalState.documents[index] = receipt
                    } else { personalState.removedDocumentIDs.append(receipt.id); _ = try? await connection.raw("/v1/onboarding/documents/" + receipt.id, method: "DELETE") }
                    persistOnboarding()
                } catch {
                    guard identity == DeviceRecordingMap.identity(api), remote else { return }
                    if let index = personalState.documents.firstIndex(where: { $0.id == item.id }) {
                        personalState.documents[index].status = "upload_failed"
                        personalState.documents[index].error = error.localizedDescription
                        persistOnboarding()
                    }
                }
            }
            personalSyncError = nil
        } catch { if identity == DeviceRecordingMap.identity(api) { personalSyncError = error.localizedDescription } }
    }
    func addOnboardingFiles(_ urls: [URL]) async {
        for url in urls {
            do {
                guard ["pdf", "docx", "txt", "md"].contains(url.pathExtension.lowercased()) else { throw PrototypeError.message("请选择 PDF、DOCX、TXT 或 Markdown 文件。") }
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 25_000_000 else { throw PrototypeError.message("请选择 25 MB 以内的非空文件。") }
                let folder = demoURL.deletingLastPathComponent().appendingPathComponent("OnboardingFiles")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
                try FileManager.default.copyItem(at: url, to: target)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete, .posixPermissions: 0o600], ofItemAtPath: target.path)
                personalState.documents.append(OnboardingDocument(id: UUID().uuidString, title: url.lastPathComponent, status: "local", localPath: target.path))
                persistOnboarding()
            } catch { personalSyncError = error.localizedDescription }
        }
        if remote { await syncPersonalProfile() }
    }
    func removePersonalDocument(_ item: OnboardingDocument) async {
        do {
            if let id = item.serverID {
                guard remote else { throw PrototypeError.message("请连接后端后移除已同步资料。") }
                _ = try await api.raw("/v1/onboarding/documents/" + id, method: "DELETE")
            }
            if let id = item.serverID { personalState.removedDocumentIDs.append(id) }
            personalState.documents.removeAll { $0.id == item.id }
            if let path = item.localPath { try? FileManager.default.removeItem(atPath: path) }
            persistOnboarding()
        } catch { personalSyncError = error.localizedDescription }
    }
    func retryPersonalDocument(_ item: OnboardingDocument) async {
        guard remote else { personalSyncError = "请先连接后端；资料已保留在本机。"; return }
        if let id = item.serverID {
            do { _ = try await api.raw("/v1/onboarding/documents/" + id + "/retry", method: "POST"); await restorePersonalProfile() }
            catch { personalSyncError = error.localizedDescription }
        } else { await syncPersonalProfile() }
    }
}

extension API {
    func uploadOnboarding(_ file: URL, title: String) async throws -> OnboardingDocument {
        var parts = URLComponents(url: try url("/v1/onboarding/documents"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "filename", value: title)]
        var request = URLRequest(url: parts.url!); request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (raw, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let error = try? JSONDecoder().decode(APIError.self, from: raw)
            throw PrototypeError.message(error?.error.message ?? "资料上传失败，本机文件已保留。")
        }
        return try JSONDecoder().decode(OnboardingDocument.self, from: raw)
    }
}

@MainActor final class OnboardingDictation: ObservableObject {
    @Published var active = false
    @Published var finishing = false
    @Published var permissionPending = false
    @Published var ready = false
    @Published var text = ""
    @Published var error: String?
    private var segment: VoiceASRSegment?
    private var lease: UUID?
    private var resource: AudioResources?
    private var generation = UUID()
    func start(store: Store) async {
        guard !active else { return }
        guard store.remote, store.capabilities?.asr_configured == true else { error = "语音服务暂时不可用，现在可以直接打字。"; return }
        generation = UUID(); let stamp = generation
        active = true; ready = false; finishing = false; error = nil; text = ""
        do {
            permissionPending = true
            let allowed = await withCheckedContinuation { c in AVAudioApplication.requestRecordPermission { c.resume(returning: $0) } }
            permissionPending = false
            guard stamp == generation else { return }
            guard allowed else { throw PrototypeError.message("麦克风尚未允许，可到系统设置开启，或直接打字。") }
            let foregroundDeadline = Date().addingTimeInterval(2)
            while UIApplication.shared.applicationState != .active && Date() < foregroundDeadline && stamp == generation { try await Task.sleep(for: .milliseconds(40)) }
            guard stamp == generation else { return }
            guard UIApplication.shared.applicationState == .active else { throw PrototypeError.message("收音已暂停，回来后点击“用说的”继续。") }
            lease = try store.audio.acquire(.manualSpeech); resource = store.audio
            let stream = VoiceASRSegment(api: store.api, session: UUID(), turn: UUID(), epoch: UUID(), startSample: 0)
            segment = stream
            stream.onText = { [weak self] value in guard self?.generation == stamp else { return }; self?.text = value }
            stream.onFailure = { [weak self] message in guard self?.generation == stamp else { return }; self?.error = message; self?.cancel() }
            stream.open(); try await stream.waitUntilReady()
            guard stamp == generation else { return }
            VoiceCapture.shared.onFrame = { [weak self] pcm in Task { @MainActor in guard self?.generation == stamp else { return }; stream.append(pcm) } }
            VoiceCapture.shared.onError = { [weak self] in Task { @MainActor in self?.error = "收音中断，已有文字保留，可编辑后继续。"; self?.cancel() } }
            try VoiceCapture.shared.start(); ready = true
        } catch { guard stamp == generation else { return }; self.error = error.localizedDescription; cancel() }
    }
    func finish() async {
        guard active, let stream = segment else { return }
        let stamp = generation
        finishing = true; VoiceCapture.shared.stop()
        if let lease { resource?.release(lease); self.lease = nil }
        stream.seal()
        do { let value = try await stream.result(); guard stamp == generation else { return }; text = value }
        catch { guard stamp == generation else { return }; self.error = "最终转写未完成，已有文字已保留，请核对后继续。" }
        guard stamp == generation else { return }; cancel()
    }
    func cancel() {
        generation = UUID(); segment?.abort(); segment = nil
        if lease != nil { VoiceCapture.shared.stop() }
        if let lease { resource?.release(lease) }; lease = nil
        active = false; finishing = false; ready = false; permissionPending = false
    }
}

struct OnboardingView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var dictation = OnboardingDictation()
    @State private var step = 0
    @State private var importer = false
    @State private var settings = false
    @State private var prefix = ""
    @State private var loaded = false
    @ScaledMetric(relativeTo: .body) private var introductionHeight = 148.0
    private enum Input: Hashable { case name, introduction }
    @FocusState private var focusedInput: Input?
    let editing: Bool
    init(editing: Bool = false) { self.editing = editing }
    private var profile: PersonalProfile { store.personalState.profile }
    private var note: Color { RecordingFormat.secondary }
    private func field(_ key: WritableKeyPath<PersonalProfile, String>) -> Binding<String> {
        Binding(get: { store.personalState.profile[keyPath: key] }, set: { value in var p = profile; p[keyPath: key] = value; store.changePersonalProfile(p) })
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if step == 0 { welcome }
                    else if step == 1 { purposes }
                    else if step == 2 { introduction }
                    else { materials }
                    if let error = store.personalSaveError { Text(error).foregroundStyle(.red).font(.footnote) }
                    if let error = store.personalSyncError { Text(error + "。本机内容仍保留，可稍后在记忆库重试。").foregroundStyle(.red).font(.footnote) }
                }.padding(24).frame(maxWidth: 550).frame(maxWidth: .infinity)
            }
            .background(Warm.paper.ignoresSafeArea()).scrollDismissesKeyboard(.never)
            .onChange(of: focusedInput) { _, input in
                guard let input else { return }
                withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo(input == .name ? "name-input" : "introduction-input", anchor: .bottom) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                guard let input = focusedInput else { return }
                withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo(input == .name ? "name-input" : "introduction-input", anchor: .bottom) }
            }
            }.frame(maxHeight: .infinity)
            actions.fixedSize(horizontal: false, vertical: true)
            }
            .background(Warm.paper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step > 0 { Button { move(to: step - 1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.foregroundStyle(Warm.purple).accessibilityLabel("返回上一步") }
                    else { Button { settings = true } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }.foregroundStyle(Warm.purple).accessibilityLabel("设置与隐私") }
                }
                ToolbarItem(placement: .principal) {
                    if step > 0 { HStack(spacing: 8) { ForEach(1...3, id: \.self) { n in Capsule().fill(n <= step ? Warm.purple : Warm.ink.opacity(0.15)).frame(width: 26, height: 4) }; Text("\(step) / 3").font(.caption).foregroundStyle(note) }.accessibilityElement(children: .ignore).accessibilityLabel("第 \(step) 步，共三步") }
                }
                ToolbarItem(placement: .topBarTrailing) { Button(editing ? "完成" : step == 0 ? "先体验" : "先进入首页") { complete() }.font(.subheadline.weight(.semibold)).foregroundStyle(Warm.purple).frame(minHeight: 44) }
            }
        }.tint(Warm.purple).fontDesign(.rounded).foregroundStyle(Warm.ink)
            .onAppear { store.personalEditing = true; guard !loaded else { return }; loaded = true; step = editing ? 2 : min(3, max(0, store.personalState.step)) }
            .onDisappear { dictation.cancel(); store.personalEditing = false; if editing { Task { await store.syncPersonalProfile() } } }
            .task(id: step) { guard step == 3 else { return }; while !Task.isCancelled { if store.remote { await store.restorePersonalProfile() }; try? await Task.sleep(for: .seconds(4)) } }
            .onChange(of: scenePhase) { _, phase in if phase == .background || (phase == .inactive && !dictation.permissionPending) { dictation.cancel() } }
            .onChange(of: dictation.text) { _, value in var p = profile; p.introduction = prefix + value; store.changePersonalProfile(p) }
            .sheet(isPresented: $settings) { SettingsView() }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.pdf, UTType(filenameExtension: "docx") ?? .data, .plainText, UTType(filenameExtension: "md") ?? .plainText], allowsMultipleSelection: true) { result in
                switch result { case .success(let urls): Task { await store.addOnboardingFiles(urls) }; case .failure(let error): store.personalSyncError = error.localizedDescription }
            }
    }
    private var actions: some View {
        VStack(spacing: 3) {
            Button(step == 0 && !store.cloudStorageAllowed ? "同意并认识一下" : step == 0 ? "认识一下" : step == 3 ? (editing ? "保存资料" : "开始使用") : "继续", systemImage: "arrow.right") {
                advance(skip: false)
            }.buttonStyle(RecordingPrimary()).accessibilityIdentifier("onboarding-next")
            HStack {
                Button(step == 0 ? "直接开始，之后再介绍" : step == 3 ? "资料稍后再补" : "这一步先跳过") {
                    advance(skip: true)
                }.frame(maxWidth: .infinity, minHeight: 44)
                if focusedInput != nil { Button("收起键盘") { dismissKeyboard() }.frame(minHeight: 44) }
            }.font(.subheadline.weight(.semibold)).foregroundStyle(Warm.purple)
        }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 5).frame(maxWidth: 550).frame(maxWidth: .infinity).background(Warm.paper)
    }
    private var welcome: some View {
        VStack(spacing: 24) {
            Mascot(size: 170).padding(.top, 32).accessibilityHidden(true)
            Text("下一次开口，\n有我一起准备。").font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text("记得你的背景，也记得每次沟通。\n让上一次的经验，帮上下一次的忙。").foregroundStyle(note).multilineTextAlignment(.center)
            WarmCard { Text("先认识一下就好。").font(.headline); Text("选个用途，聊聊你自己。资料以后补也可以。").font(.subheadline).foregroundStyle(note) }
            Text("继续即同意将你主动提交的资料和录音保存到 Candid 云端并按需进行 AI 处理，服务位于新加坡。可在设置中撤回许可。").font(.footnote).foregroundStyle(note)
            privacy
        }.frame(maxWidth: .infinity)
    }
    private func heading(_ title: String) -> some View {
        HStack(spacing: 14) { Mascot(size: 68).accessibilityHidden(true); Text(title).font(.title.bold()).fixedSize(horizontal: false, vertical: true) }.padding(.top, 12)
    }
    private var purposes: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("你想先准备\n哪种沟通？")
            Text("可以多选，也可以先看看。\n以后随时能切换，不会限制你。").foregroundStyle(note)
            ForEach(["sales", "interview"], id: \.self) { type in
                let selected = profile.scenarios.contains(type)
                Button {
                    var p = profile; if selected { p.scenarios.removeAll { $0 == type } } else { p.scenarios.append(type) }; store.changePersonalProfile(p)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: type == "sales" ? "briefcase" : "person.text.rectangle").font(.title2).foregroundStyle(Warm.purple).frame(width: 44, height: 44).background(Warm.lavender, in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 7) { Text(type == "sales" ? "销售 BD" : "面试").font(.headline); Text(type == "sales" ? "客户沟通、产品介绍与跟进" : "准备经历、练习表达与复盘").font(.subheadline).foregroundStyle(selected ? Warm.purple : note) }
                        Spacer(minLength: 0)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(selected ? Warm.purple : note)
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(selected ? Warm.lavender : Warm.white, in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(selected ? Warm.purple : Warm.ink.opacity(0.15), lineWidth: 1))
                }.buttonStyle(.plain).accessibilityLabel(type == "sales" ? "销售 BD" : "面试").accessibilityValue(selected ? "已选择" : "未选择")
            }
            Text("这只是让我知道从哪里开始。每个项目仍有独立上下文，录音统一保存在录音库。").font(.footnote).padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Warm.sage, in: RoundedRectangle(cornerRadius: 18))
        }
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("我该怎么\n认识你？")
            Text("几句话就够了。你的工作、常见沟通对象，或最近想推进的事。").foregroundStyle(note)
            VStack(alignment: .leading, spacing: 10) {
                Text("怎么称呼你 · 选填").font(.headline)
                TextField("你希望我怎么称呼你", text: field(\.display_name)).textContentType(.nickname).focused($focusedInput, equals: .name).padding(14).background(Warm.white, in: RoundedRectangle(cornerRadius: 16)).accessibilityIdentifier("onboarding-name").id("name-input")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("简单介绍一下自己 · 选填").font(.headline)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: field(\.introduction))
                        .focused($focusedInput, equals: .introduction)
                        .scrollContentBackground(.hidden).frame(height: introductionHeight)
                        .disabled(dictation.active).accessibilityLabel("简单介绍一下自己")
                        .accessibilityIdentifier("onboarding-introduction")
                    if profile.introduction.isEmpty {
                        Text(placeholder).foregroundStyle(note).padding(.horizontal, 5).padding(.top, 8)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }.padding(10).background(Warm.white, in: RoundedRectangle(cornerRadius: 16)).id("introduction-input")
                Button {
                    if dictation.active { if dictation.ready { Task { await dictation.finish() } } else { dictation.cancel() } }
                    else { prefix = profile.introduction.isEmpty ? "" : profile.introduction + "\n"; Task { await dictation.start(store: store) } }
                } label: { Label(dictation.finishing ? "正在整理文字" : dictation.active ? (dictation.ready ? "结束说话" : "取消连接") : "用说的", systemImage: dictation.active ? "stop.circle" : "mic").font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: 44).background(Warm.white, in: RoundedRectangle(cornerRadius: 14)) }.disabled(dictation.finishing)
                if dictation.active { Text(dictation.ready ? "在听，文字会显示在上方。结束后可以修改。" : "正在连接语音服务…").font(.footnote).foregroundStyle(Warm.purple) }
                if let error = dictation.error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            Text("你写下的内容会直接保留，之后可在“我”里修改。不用再重复确认一遍。").font(.footnote).foregroundStyle(note)
        }
    }
    private var placeholder: String {
        if profile.scenarios == ["sales"] { return "例如：我做餐饮软件销售，常和采购、运营负责人沟通，想把方案价值讲清楚。" }
        if profile.scenarios == ["interview"] { return "例如：我做产品设计，正在找新的岗位，想把项目经历讲得更具体。" }
        return "例如：我做产品设计，最近在准备面试，也会向客户介绍方案。"
    }
    private var materials: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("把熟悉的资料，\n也介绍给我。")
            Text("简历、岗位 JD、产品介绍或项目材料。\n先给一份就好，没有也能开始。").foregroundStyle(note)
            Button { importer = true } label: {
                VStack(spacing: 12) { Image(systemName: "square.and.arrow.up").font(.largeTitle); Text("添加资料").font(.headline); Text("PDF · Word · TXT · Markdown").font(.footnote).foregroundStyle(note) }.padding(24).frame(maxWidth: .infinity).background(Warm.white, in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(Warm.purple.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4])))
            }.buttonStyle(.plain).accessibilityLabel("添加资料")
            PersonalDocumentRows()
            Text("资料会先保存，随后整理。缺少报价、排期或经历的地方，我会留空，不会替你编。").font(.footnote).padding(18).background(Warm.sage, in: RoundedRectangle(cornerRadius: 18))
            privacy
        }
    }
    private var privacy: some View {
        DisclosureGroup { Text("你主动提供的背景会成为个人资料，并同步到 Candid 云端（新加坡）。导入文件先提取文字，后续按需使用 AI 整理；AI 产生的新跨场个人结论仍会集中请你核对。录音权限在开始录音时申请，原音频默认保留 90 天，可在设置修改。").font(.footnote).foregroundStyle(note).padding(.top, 8) } label: { Label("资料与录音怎么处理？", systemImage: "lock").font(.footnote).frame(minHeight: 44) }.tint(Warm.purple)
    }
    private func dismissKeyboard() {
        focusedInput = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    private func move(to value: Int) { dismissKeyboard(); dictation.cancel(); step = value; if !editing { store.personalState.step = value; store.persistOnboarding() } }
    private func advance(skip: Bool) {
        let proceed = {
            if self.step == 3 || (self.step == 0 && skip) { self.complete() }
            else { self.move(to: self.step + 1) }
        }
        if step == 0 && store.remote && !store.cloudStorageAllowed {
            Task { await store.perform { try await store.setCloudStorageAllowed(true); proceed() } }
        } else { proceed() }
    }
    private func complete() {
        dismissKeyboard()
        dictation.cancel()
        if editing { store.personalEditing = false; store.persistOnboarding(); Task { await store.syncPersonalProfile() }; dismiss() }
        else { store.completeOnboarding() }
    }
}

struct PersonalDocumentRows: View {
    @EnvironmentObject var store: Store
    var body: some View {
        ForEach(store.personalState.documents) { item in
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.text").foregroundStyle(Warm.purple).padding(.top, 10)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.subheadline.weight(.semibold)); Text(item.statusTitle).font(.caption).foregroundStyle(RecordingFormat.secondary)
                    if let error = item.error { Text(error).font(.caption).foregroundStyle(.red) }
                    if ["failed", "interrupted", "cancelled", "upload_failed", "local"].contains(item.status) { Button("重试同步与整理") { Task { await store.retryPersonalDocument(item) } }.font(.caption).frame(minHeight: 44) }
                }
                Spacer(minLength: 0)
                Button { Task { await store.removePersonalDocument(item) } } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("移除 " + item.title)
            }.padding(.vertical, 8)
        }
    }
}

struct PersonalProfilePage: View {
    @EnvironmentObject var store: Store
    @State private var edit = false
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            Text(store.personalState.profile.display_name.isEmpty ? "慢慢认识你" : store.personalState.profile.display_name).font(.title.bold())
            Text(store.personalState.profile.introduction.isEmpty ? "说说你的背景，让准备更贴近你。资料随时都能补。" : store.personalState.profile.introduction).lineSpacing(5)
            if !store.personalState.profile.scenarios.isEmpty { Text("常用场景：" + store.personalState.profile.scenarios.map { $0 == "sales" ? "销售 BD" : "面试" }.joined(separator: "、")).font(.subheadline).foregroundStyle(Warm.purple) }
            Button("编辑我的介绍与资料") { edit = true }.buttonStyle(RecordingPrimary())
            if let error = store.personalSyncError { Text(error).font(.footnote).foregroundStyle(.red); Button("读取最新版本，保留本机输入") { Task { await store.readLatestPersonalProfile() } }.frame(minHeight: 44) }
            if let latest = store.personalRemoteProfile {
                WarmCard { Text("后端最新介绍").font(.headline); Text(latest.display_name); Text(latest.introduction.isEmpty ? "尚未填写背景" : latest.introduction); Button("使用后端介绍") { store.personalState.profile = latest; store.personalState.version = store.personalRemoteVersion; store.personalState.profileDirty = false; store.personalRemoteProfile = nil; store.persistOnboarding() }; if store.personalState.profileDirty { Button("保存本机介绍") { store.personalState.version = store.personalRemoteVersion; store.personalRemoteProfile = nil; store.personalState.requestID = UUID().uuidString; store.persistOnboarding(); Task { await store.syncPersonalProfile() } } } }
            }
            if !store.remote { Text("资料已保存在本机，连接后端后同步。").font(.footnote).foregroundStyle(RecordingFormat.secondary) }
            else if store.personalState.profileDirty || store.personalState.completionPending { Button("同步个人资料") { Task { await store.syncPersonalProfile() } }.frame(minHeight: 44) }
            if !store.personalState.documents.isEmpty { Text("带入的资料").font(.headline); PersonalDocumentRows() }
            Text("用户主动提供的背景与 AI 跨场发现分别保存；新的个人推断仍集中核对。").font(.footnote).foregroundStyle(RecordingFormat.secondary)
        }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity) }.background(Warm.paper.ignoresSafeArea()).navigationTitle("个人资料").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $edit) { OnboardingView(editing: true) }
            .task { while !Task.isCancelled { await store.restorePersonalProfile(); try? await Task.sleep(for: .seconds(5)) } }
    }
}
