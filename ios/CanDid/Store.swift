import Foundation
import Combine
import AVFoundation
import UserNotifications

@MainActor final class Store: ObservableObject {
    @Published var assets: [Asset] = []
    @Published var occasions: [Occasion] = []
    @Published var sessions: [Session] = []
    @Published var diagnoses: [Diagnosis] = []
    @Published var onboarding = false
    @Published var personalState = OnboardingState()
    @Published var personalSaveError: String?
    @Published var personalSyncError: String?
    @Published var personalImportError: String?
    @Published var personalSyncing = false
    var personalEditing = false
    @Published var personalRemoteProfile: PersonalProfile?
    var personalRemoteVersion = 0
    @Published var remote = false
    @Published var connecting = false
    @Published var connectionReady = false
    @Published var connectionError: String?
    @Published var cloudStorageAllowed = false
    @Published var capabilities: Capabilities?
    @Published var companion:CompanionSnapshot?
    @Published var companionRecordings:[RecordingRecord]=[]
    @Published var companionMemory:CompanionMemorySnapshot?
    var productScopeGeneration=UUID()
    @Published var products:[ProductProject]=[]
    @Published var productDetails:[ProductDetail]=[]
    @Published var personalDiscoveries:[PersonalDiscovery]=[]
    @Published var projectSpaces: [ProjectSpace] = []
    @Published var chatReadPosition: String?
    @Published var chatThreads: [ChatThread] = []
    @Published var chatThread: ChatThread?
    @Published var chatMessages: [ChatMessage] = []
    @Published var chatBusy = false
    @Published var chatError: String?
    @Published var chatActivity: [ChatToolStep] = []
    @Published var chatTasks: [AgentTask] = []
    @Published var chatTask: AgentTask?
    @Published var chatPartial = ""
    @Published var chatLoading = false
    @Published var chatReconnecting = false
    @Published var chatControlBusy = false
    @Published var chatDraft = ""
    var chatObserverGeneration = UUID()
    var chatForeground = true
    var chatRequest: Task<Void, Never>?
    var chatPending: (text: String, requestID: String)?
    @Published var busy = false
    @Published var error: String?
    @Published var message: String?
    @Published var retention = 90
    @Published var base = BackendConfiguration.baseURL
    var api: API { API(base: base, token: TokenVault.read()) }
    private var player: AVPlayer?
    let soundcore = Soundcore()
    let speech = SpeechController()
    let audio = AudioResources()
    let voice = VoiceSessionController()
    private var playbackLease: UUID?
    let recordingNavigation = RecordingNavigation()
    @Published var recordingPlaybackID: String?
    @Published var recordingPlaybackPlaying = false
    @Published var recordingPlaybackPositionMS = 0
    @Published var recordingPlaybackStartMS = 0
    @Published var recordingPlaybackEndMS = 0
    private var recordingPlaybackObserver: Any?
    private var recordingPlaybackEndObserver: NSObjectProtocol?
    private var localFiles: [String: String] = UserDefaults.standard.dictionary(forKey: "local-recordings") as? [String: String] ?? [:]
    let demoURL: URL
    static var isolatedTestRun: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let env=ProcessInfo.processInfo.environment
        if acceptanceDirectory != nil,env["CANDID_LOCAL_BACKEND"]=="1" || env["CANDID_CLOUD_ACCEPTANCE"]=="1" {return false}
        #endif
        // Unit-test hosts must stay offline in Release as well. Launch flags
        // remain Debug-only; a normal installed Release app cannot opt out of auth.
        if NSClassFromString("XCTestCase") != nil { return true }
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-candid-ui-testing")
        #else
        return false
        #endif
    }
    static var acceptanceDirectory:URL? {
        #if DEBUG && targetEnvironment(simulator)
        if let value=ProcessInfo.processInfo.environment["CANDID_ACCEPTANCE_CACHE"],let id=UUID(uuidString:value){return FileManager.default.temporaryDirectory.appendingPathComponent("CanDidHTTPAcceptance/"+id.uuidString)}
        #endif
        return nil
    }
    init(localDirectory: URL? = nil) {
        if let localDirectory {
            try? FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
            demoURL = localDirectory.appendingPathComponent("candid-demo.json")
        } else if Self.isolatedTestRun {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CanDidUITests/" + (ProcessInfo.processInfo.environment["CANDID_ONBOARDING_TEST_ID"].flatMap { UUID(uuidString:$0)?.uuidString } ?? UUID().uuidString))
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            demoURL = folder.appendingPathComponent("candid-demo.json")
        } else if let cache=Self.acceptanceDirectory {
            try? FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
            demoURL=cache.appendingPathComponent("candid-demo.json")
        } else { demoURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("candid-demo.json") }
        retention = UserDefaults.standard.object(forKey: "retention-days") as? Int ?? 90
        if Self.isolatedTestRun || localDirectory != nil {
            loadDemo(); connectionReady = true
        } else {
            // Cloud mode never silently displays or writes the fixture database.
            remote = true
            let saved = TokenVault.read(account: BackendConfiguration.credentialAccount)
            try? TokenVault.save(saved)
        }
        loadOnboarding(); purgeLocalExpired();loadProductCache()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-candid-ui-testing") && ProcessInfo.processInfo.arguments.contains("-candid-surface-review") {onboarding=true;seedProducts()}
        if Self.isolatedTestRun && ProcessInfo.processInfo.arguments.contains("-candid-v2-populated") {onboarding=true;seedCompanionPreview()}
        #endif
    }
    func purgeLocalExpired() {
        guard !remote else { return }
        for i in sessions.indices {
            guard sessions[i].audio_purged_at == nil, let start = sessions[i].started_at,
                  let date = ISO8601DateFormatter().date(from: start) else { continue }
            let days = sessions[i].retention_days
            let due = days == 0 ? sessions[i].pipeline_status == "done" : date.addingTimeInterval(Double(days) * 86400) <= Date()
            if due {
                if let path = sessions[i].local_audio { try? FileManager.default.removeItem(atPath: path) }
                sessions[i].local_audio = nil; sessions[i].audio_purged_at = ISO8601DateFormatter().string(from: Date())
            }
        }
        persist()
    }
    func loadDemo() {
        pauseChatObservation(); projectSpaces = []; chatReadPosition = nil; chatTask = nil; chatTasks = []; chatBusy = false; chatPartial = ""; chatDraft = ""
        remote = false; capabilities = nil
        chatThread = nil; chatThreads = []; chatMessages = []; chatError = nil
        if let data = try? Data(contentsOf: demoURL), let snapshot = try? JSONDecoder().decode(LocalSnapshot.self, from: data) {
            assets = snapshot.assets; occasions = snapshot.occasions; sessions = snapshot.sessions; diagnoses = snapshot.diagnoses
        } else { seed() }
    }
    func seed() {
        let oid = UUID().uuidString, sid = UUID().uuidString
        occasions = [Occasion(id: oid, scenario: "sales", title: "华味餐饮 · 采购沟通", status: "active", fields: OccasionFields(tags: ["需求确认"], goal: "推进试点"), template_version: "sales@1")]
        let evidence = Evidence(session_id: sid, start_ms: 0, end_ms: 30000)
        let segment = Segment(id: UUID().uuidString, session_id: sid, speaker: "self", start_ms: 0, end_ms: 30000, text: "示例：我先确认门店数量、接口与数据准备，再给出明确排期。")
        sessions = [Session(id: sid, occasion_id: oid, scenario: "sales", kind: "practice", consent: "yes", pipeline_status: "done", duration_ms: 30000, retention_days: 90, audio_purged_at: nil, started_at: ISO8601DateFormatter().string(from: Date()), fixture: true, rubric_version: "sales@1.2", transcript_segments: [segment], local_audio: nil, pipeline_error: nil)]
        assets = [Asset(id: UUID().uuidString, title: "先确认交付范围", body: BodyText(text: segment.text), kind: "phrasing", scenario: "sales", status: "draft", trust: "L2_inferred", version: 1, tags: ["需求确认"], producer: "fixture@1", rubric_version: "sales@1.2", evidence_refs: [evidence], confirmed_at: nil, source_session_id: sid)]
        diagnoses = [Diagnosis(id: UUID().uuidString, session_id: sid, dimension: "scope", finding: "示例分析：把未核实承诺改为确认路径", suggestion: "沿用这种讲法，并补充可以核实的范围。", evidence_refs: [evidence], rubric_version: "sales@1.2", producer: "fixture@1")]
        persist()
    }
    func persist() {
        guard !remote else { return }
        do {
            let value = LocalSnapshot(assets: assets, occasions: occasions, sessions: sessions, diagnoses: diagnoses, onboarding: onboarding)
            try JSONEncoder().encode(value).write(to: demoURL, options: [.atomic, .completeFileProtection])
        } catch { self.error = "本机保存失败：" + error.localizedDescription }
    }
    func perform(_ operation: () async throws -> Void) async {
        busy = true; defer { busy = false }
        do { try await operation() } catch { self.error = error.localizedDescription }
    }
    func connect(token: String, backend: String? = nil) async throws {
        let address = backend ?? base
        #if !DEBUG
        guard URL(string: address)?.scheme == "https" else { throw PrototypeError.message("发布构建只允许 HTTPS 后端") }
        #endif
        // Validate the candidate before replacing a working connection or its credential.
        let candidate = API(base: address, token: token)
        _ = try await candidate.raw("/v1/profile")
        _ = try await candidate.raw("/v1/profile", method: "PATCH", body: ["product_use_consent": true])
        pauseChatObservation()
        let oldToken = TokenVault.read(); let draft = personalState
        try TokenVault.save(token); base = address; UserDefaults.standard.set(base, forKey: "api-base")
        loadOnboarding(migrating: oldToken.isEmpty ? draft : nil)
        remote = true
        UserDefaults.standard.set(true, forKey: "remote-enabled")
        await restorePersonalProfile()
        try await reload()
        try await reloadChats(); try await restoreWorkspaceSelection()
        message = "已连接持久化记忆后端"
    }
    func reload() async throws {
        guard remote else { return }
        capabilities = try await api.call("/v1/capabilities")
        let a: [Asset] = try await api.all("/v1/assets")
        let o: [Occasion] = try await api.all("/v1/occasions")
        let s: [Session] = try await api.all("/v1/sessions")
        assets = a; occasions = o; sessions = s
        try await reloadProducts()
    }
    func setCloudStorageAllowed(_ allowed: Bool) async throws {
        _ = try await api.raw("/v1/profile", method: "PATCH", body: ["product_use_consent": allowed, "cross_border_consent": allowed])
        cloudStorageAllowed = allowed
        if allowed { await syncPersonalProfile() }
    }
    func addOccasion(title: String, scenario: Scenario, goal: String) async throws {
        if remote {
            let _: Occasion = try await api.call("/v1/occasions", method: "POST", body: ["client_request_id": UUID().uuidString, "title": title, "scenario": scenario.rawValue, "fields": ["goal": goal, "tags": []]])
            try await reload()
        } else {
            occasions.insert(Occasion(id: UUID().uuidString, scenario: scenario.rawValue, title: title, status: "active", fields: OccasionFields(tags: [], goal: goal), template_version: scenario.rawValue+"@1"), at: 0); persist()
        }
    }
    func addAsset(title: String, text: String, scenario: Scenario) async throws {
        if remote { let _: Asset = try await api.call("/v1/assets", method: "POST", body: ["title": title, "body": ["text": text], "scenario": scenario.rawValue, "tags": [], "kind": "story"]); try await reload() }
        else { assets.insert(Asset(id: UUID().uuidString, title: title, body: BodyText(text: text), kind: "story", scenario: scenario.rawValue, status: "confirmed", trust: "L3_confirmed", version: 1, tags: [], producer: nil, rubric_version: nil, evidence_refs: [], confirmed_at: ISO8601DateFormatter().string(from: Date()), source_session_id: nil), at: 0); persist() }
    }
    func confirm(_ asset: Asset, text: String) async throws {
        if remote {
            let _: Asset = try await api.call("/v1/assets/"+asset.id+"/confirm", method: "POST", body: ["version": asset.version, "body": ["text": text]])
            try await reload()
        } else {
            guard let i = assets.firstIndex(where: { $0.id == asset.id }), assets[i].version == asset.version else { throw PrototypeError.message("VERSION_CONFLICT：请刷新素材") }
            assets[i].body.text = text; assets[i].version += 1; assets[i].status = "confirmed"; assets[i].trust = "L3_confirmed"; assets[i].confirmed_at = ISO8601DateFormatter().string(from: Date()); persist()
        }
    }
    func archive(_ asset: Asset) async throws {
        if remote { _ = try await api.raw("/v1/assets/"+asset.id+"/archive", method: "POST", body: ["version": asset.version]); try await reload() }
        else { if let i = assets.firstIndex(where: { $0.id == asset.id }) { assets[i].status = "archived"; assets[i].version += 1; persist() } }
    }
    func beginSession(occasion: Occasion, kind: String, agreed: Bool, recordingSource: String? = nil, deviceFileID: Int32? = nil) async throws -> Session {
        if kind == "live" && !agreed { throw PrototypeError.message("请先确认已告知对方并取得同意，或选择口述复盘。") }
        if remote {
            var body: [String: Any] = ["client_request_id": UUID().uuidString, "occasion_id": occasion.id, "kind": kind, "consent": kind == "live" ? "yes" : kind == "practice" ? "yes" : "unknown", "consent_ack_text_version": "recording-notice@1", "retention_days": retention]
            if let recordingSource { body["recording_source"] = recordingSource }
            if let deviceFileID { body["device_file_id"] = Int(deviceFileID) }
            let s: Session = try await api.call("/v1/sessions", method: "POST", body: body)
            sessions.insert(s, at: 0); return s
        }
        let s = Session(id: UUID().uuidString, occasion_id: occasion.id, scenario: occasion.scenario, kind: kind, consent: kind == "oral_debrief" ? "unknown" : "yes", pipeline_status: "created", duration_ms: 0, retention_days: retention, audio_purged_at: nil, started_at: ISO8601DateFormatter().string(from: Date()), fixture: false, rubric_version: occasion.scenario+"@1.2", transcript_segments: [], local_audio: nil, pipeline_error: nil, recording_source: recordingSource, device_file_id: deviceFileID.map(Int.init))
        sessions.insert(s, at: 0); persist(); return s
    }
    func finish(_ session: Session, url: URL, seconds: Int, durationMS: Int? = nil) async throws {
        let milliseconds = durationMS ?? seconds * 1000
        if remote { localFiles[session.id] = url.path; UserDefaults.standard.set(localFiles, forKey: "local-recordings") }
        if let i = sessions.firstIndex(where: { $0.id == session.id }) { sessions[i].local_audio = url.path; sessions[i].duration_ms = milliseconds; sessions[i].pipeline_status = "recorded_local"; persist() }
        if remote {
            try await api.upload(url, session: session.id, durationMS: milliseconds)
            try FileManager.default.removeItem(at: url)
            localFiles.removeValue(forKey: session.id); UserDefaults.standard.set(localFiles, forKey: "local-recordings")
            try await reload(); message = "音频已校验入库，本机副本已删除。语音转写尚未配置；可通过口述复盘提交文字给 DeepSeek 分析。"
        }
        else { message = "真实录音已保存在本机。未配置语音转写与模型，不生成虚构复盘。" }
    }
    func submitOral(_ session: Session, text: String, analyze: Bool = false) async throws {
        if remote { _ = try await api.raw("/v1/sessions/"+session.id+"/transcript", method: "POST", body: ["analyze": analyze, "segments": [["speaker": "self", "start_ms": 0, "end_ms": 1000, "text": text]]]); try await reload() }
        else {
            if let i = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[i].transcript_segments = [Segment(id: UUID().uuidString, session_id: session.id, speaker: "self", start_ms: 0, end_ms: 1000, text: text)]
                sessions[i].pipeline_status = "awaiting_model"; persist()
            }
        }
        message = remote && analyze ? "本人复述已保存，DeepSeek 正在分析。可到场次详情查看进度和结果。" : "本人复述已保存为证据，未发送给 DeepSeek。"
    }
    func addMark(_ session: Session, milliseconds: Int) async throws {
        if remote { _ = try await api.raw("/v1/sessions/"+session.id+"/marks", method: "POST", body: ["marks": [["t_ms": milliseconds, "user_label": "unlabeled"]]]) }
        message = remote ? "时间标记已保存" : "离线示例模式暂不保存设备标记"
    }
    func detail(_ session: Session) async throws -> Review {
        if remote {
            var review: Review = try await api.call("/v1/sessions/"+session.id+"/review")
            let full: Session = try await api.call("/v1/sessions/"+session.id)
            review.session = full; return review
        }
        let current = sessions.first(where: { $0.id == session.id }) ?? session
        return Review(session: current, diagnoses: diagnoses.filter { $0.session_id == session.id }, draft_assets: assets.filter { $0.source_session_id == session.id && $0.status == "draft" }, audio_note: current.audio_purged_at == nil ? nil : "原音频已删除，用户原文仍保留")
    }
    func fixture(_ occasion: Occasion) async throws {
        if remote { let _: Session = try await api.call("/v1/demo/fixture", method: "POST", body: ["occasion_id": occasion.id]); try await reload(); message = "示例已入队，稍后刷新查看复盘" }
        else { message = "离线示例在记忆库与场次列表中；连接后端后可重复运行示例管线。" }
    }
    func context(_ occasion: Occasion) async throws -> ContextPack {
        if remote { return try await api.call("/v1/context-preview", method: "POST", body: ["purpose": "prep", "occasion_id": occasion.id]) }
        let rows = assets.filter { $0.status == "confirmed" && ($0.scenario == occasion.scenario || $0.scenario == nil) }
        return ContextPack(purpose: "prep", sections: [ContextSection(key: "confirmed_assets", items: rows.map { ContextItem(trust: "FACT", ref: "asset:"+$0.id, text: $0.body.text) })], token_count: 0, truncated: [])
    }
    func feedback(_ diagnosis: Diagnosis, verdict: String) async throws {
        if remote { _ = try await api.raw("/v1/diagnoses/"+diagnosis.id+"/feedback", method: "POST", body: ["verdict": verdict, "note": "来自 iOS 用户反馈"]) }
        message = remote ? "反馈已保存" : "离线示例反馈不写入后端"
    }
    func play(_ session: Session) async throws {
        guard !audio.voiceActive,!speech.activeMeeting,soundcore.recordStatus==0 else{throw PrototypeError.message("请先结束现有语音或录音，再回听。") }
        speech.stopPlayback();stopPlayback();let lease=try audio.acquire(.recordingPlayback);playbackLease=lease
        defer {if player==nil {audio.release(lease);playbackLease=nil}}
        if remote {
            let link: Link = try await api.call("/v1/sessions/"+session.id+"/audio")
            guard let path = link.url else { throw PrototypeError.message("没有音频链接") }
            guard audio.owns(lease) else {throw PrototypeError.message("音频模式已变化。") }
            player = AVPlayer(url: try api.url(path))
        } else {
            guard let path = session.local_audio else { throw PrototypeError.message("示例没有原始音频。真实录音完成后可以回听。") }
            player = AVPlayer(url: URL(fileURLWithPath: path))
        }
        try AVAudioSession.sharedInstance().setCategory(.playback); try AVAudioSession.sharedInstance().setActive(true)
        player?.play()
    }
    func stopPlayback() {
        if let playbackLease {audio.release(playbackLease)};playbackLease=nil
        player?.pause()
        if let observer=recordingPlaybackObserver { player?.removeTimeObserver(observer) }
        recordingPlaybackObserver=nil
        if let observer=recordingPlaybackEndObserver { NotificationCenter.default.removeObserver(observer) }
        recordingPlaybackEndObserver=nil;player=nil
        recordingPlaybackID=nil;recordingPlaybackPlaying=false
    }
    func purge(_ session: Session) async throws {
        stopPlayback()
        if remote { _ = try await api.raw("/v1/sessions/"+session.id+"/audio", method: "DELETE"); try await reload() }
        else { if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            if let path = sessions[i].local_audio { try FileManager.default.removeItem(atPath: path) }
            sessions[i].local_audio = nil; sessions[i].audio_purged_at = ISO8601DateFormatter().string(from: Date()); persist()
        } }
        if let path = localFiles[session.id] { try? FileManager.default.removeItem(atPath: path); localFiles.removeValue(forKey: session.id); UserDefaults.standard.set(localFiles, forKey: "local-recordings") }
        message = "音频已删除，原文和已确认素材保留"
    }
    func setRetention(_ days: Int) async throws {
        if remote { _ = try await api.raw("/v1/profile", method: "PATCH", body: ["preferences": ["audio_retention_days": days]]) }
        else {
            let old = UserDefaults.standard.object(forKey: "retention-days") as? Int ?? 90
            if days < old { for i in sessions.indices where sessions[i].retention_days > days { sessions[i].retention_days = days } }
            purgeLocalExpired()
        }
        retention = days; UserDefaults.standard.set(days, forKey: "retention-days")
    }
    func export() async throws -> URL {
        let data: Data
        if remote { data = try await api.raw("/v1/memory/export") }
        else { data = try JSONEncoder().encode(LocalSnapshot(assets: assets, occasions: occasions, sessions: sessions, diagnoses: diagnoses, onboarding: onboarding)) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CanDid-memory.json"); try data.write(to: url, options: .atomic); return url
    }
    func deleteMemory() async throws {
        stopPlayback()
        voice.exit()
        try? FileManager.default.removeItem(at:productCacheURL)
        products=[];productDetails=[];personalDiscoveries=[]
        let pending=await UNUserNotificationCenter.current().pendingNotificationRequests()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers:pending.map(\.identifier).filter{$0.hasPrefix("candid-action-")})
        if remote { _ = try await api.raw("/v1/memory", method: "DELETE") }
        else {
            let folder = demoURL.deletingLastPathComponent().appendingPathComponent("Recordings")
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        }
        if remote { for path in localFiles.values { try? FileManager.default.removeItem(atPath: path) }; localFiles = [:]; UserDefaults.standard.removeObject(forKey: "local-recordings") }
        soundcore.resetAuthorization()
        clearChatRecovery(); projectSpaces = []; chatReadPosition = nil; chatTask = nil; chatTasks = []; chatBusy = false; chatPartial = ""; chatDraft = ""
        for item in personalState.documents { if let path = item.localPath { try? FileManager.default.removeItem(atPath: path) } }
        personalState = OnboardingState(); persistOnboarding()
        assets = []; occasions = []; sessions = []; diagnoses = []; onboarding = false
        chatThread = nil; chatMessages = []; chatThreads = []; chatPending = nil
        if !remote { persist() }
        if remote && base == BackendConfiguration.baseURL && !Self.isolatedTestRun {
            try TokenVault.save("", account: BackendConfiguration.installationAccount)
            try TokenVault.save("", account: BackendConfiguration.credentialAccount)
            try TokenVault.save("")
            cloudStorageAllowed = false; connectionReady = false
            Task { await self.restoreConnection(force: true) }
        }
        message = "记忆已删除"
    }
}


extension Store {
    func playRecording(_ id:String,startMS:Int=0,endMS:Int?=nil) async throws {
        guard !speech.activeMeeting,soundcore.recordStatus==0 else { throw PrototypeError.message("请先暂停回听，完成本场录音后再播放。") }
        guard !audio.voiceActive else {throw PrototypeError.message("请先暂停或结束语音对话，再回听录音。") }
        guard startMS>=0,endMS==nil || endMS!>startMS else {throw PrototypeError.message("这句原文没有有效的音频时间范围。") }
        speech.stopPlayback();stopPlayback()
        let lease=try audio.acquire(.recordingPlayback);playbackLease=lease
        defer {if recordingPlaybackID != id && audio.owns(lease) {audio.release(lease);playbackLease=nil}}
        let api=self.api
        let playbackIdentity=DeviceRecordingMap.identity(api)
        let range="/v1/sessions/"+id+"/audio?start_ms="+String(startMS)+(endMS.map{"&end_ms="+String($0)} ?? "")
        let link:Link=try await api.call(range)
        guard let path=link.url else { throw PrototypeError.message("原音频不可用") }
        guard audio.owns(lease) else {throw PrototypeError.message("音频模式已变化。") }
        let item=AVPlayerItem(url:try api.url(path))
        if let endMS { item.forwardPlaybackEndTime=CMTime(seconds:Double(endMS)/1000,preferredTimescale:1000) }
        player=AVPlayer(playerItem:item)
        try AVAudioSession.sharedInstance().setCategory(.playback,mode:.spokenAudio);try AVAudioSession.sharedInstance().setActive(true)
        await player?.seek(to:CMTime(seconds:Double(startMS)/1000,preferredTimescale:1000),toleranceBefore:.zero,toleranceAfter:.zero)
        guard audio.owns(lease) else {throw PrototypeError.message("回听已停止或切换。") }
        guard DeviceRecordingMap.identity(api)==playbackIdentity else { stopPlayback();throw PrototypeError.message("后端连接已变化，请重新打开录音。") }
        recordingPlaybackID=id;recordingPlaybackStartMS=startMS;recordingPlaybackEndMS=endMS ?? 0
        recordingPlaybackPositionMS=startMS;recordingPlaybackPlaying=true
        recordingPlaybackObserver=player?.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.25,preferredTimescale:1000),queue:.main) { [weak self] time in
            Task { @MainActor in
                guard let self,self.recordingPlaybackID==id,self.audio.owns(lease) else { return }
                if time.seconds.isFinite { self.recordingPlaybackPositionMS=max(0,Int(time.seconds*1000)) }
                if endMS==nil,let duration=self.player?.currentItem?.duration.seconds,duration.isFinite,duration>0 { self.recordingPlaybackEndMS=Int(duration*1000) }
                self.recordingPlaybackPlaying=self.player?.rate != 0
            }
        }
        recordingPlaybackEndObserver=NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:item,queue:.main) { [weak self] _ in
            Task { @MainActor in
                guard let self,self.recordingPlaybackID==id,self.audio.owns(lease) else{return}
                self.recordingPlaybackPlaying=false
                if let endMS{self.recordingPlaybackPositionMS=endMS}
            }
        }
        player?.play()
    }
    func toggleRecordingPlayback() {
        if recordingPlaybackPlaying { player?.pause();recordingPlaybackPlaying=false }
        else {
            if recordingPlaybackEndMS>0 && recordingPlaybackPositionMS>=recordingPlaybackEndMS-200 { player?.seek(to:CMTime(seconds:Double(recordingPlaybackStartMS)/1000,preferredTimescale:1000)) }
            player?.play();recordingPlaybackPlaying=true
        }
    }
    func seekRecordingPlayback(_ milliseconds: Double) {
        let value=max(recordingPlaybackStartMS,min(Int(milliseconds),recordingPlaybackEndMS))
        player?.seek(to:CMTime(seconds:Double(value)/1000,preferredTimescale:1000),toleranceBefore:.zero,toleranceAfter:.zero)
        recordingPlaybackPositionMS=value
    }
}
