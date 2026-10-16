import SwiftUI
import Combine
import CryptoKit

enum CandidSection: Hashable { case chat, memory, occasions, recordings }

@MainActor final class RecordingNavigation: ObservableObject {
    @Published var section: CandidSection = .chat
    @Published var showRecorder = false
    @Published var newMeeting = false
    @Published var visibleDetails:Set<UUID>=[]
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CANDID_INITIAL_TAB"]=="recordings" { section = .recordings }
        if ProcessInfo.processInfo.environment["CANDID_INITIAL_SCREEN"]=="recorder" {showRecorder=true;newMeeting=true}
        #endif
    }
}

enum RecordingFormat {
    static let secondary = Color(red:0.44,green:0.44,blue:0.40)
    static func clock(_ seconds: Int, hours: Bool = false) -> String {
        let value=max(0,seconds)
        return hours || value>=3600 ? String(format:"%02d:%02d:%02d",value/3600,value/60%60,value%60) : String(format:"%02d:%02d",value/60,value%60)
    }
    static func date(_ record: RecordingRecord) -> Date? {
        if record.recording_source=="soundcore",let file=record.device_file_id,file>0,file<=Int(UInt32.max) { return Date(timeIntervalSince1970:Double(file)) }
        guard let text=record.started_at else { return nil }
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        return formatter.date(from:text) ?? ISO8601DateFormatter().date(from:text)
    }
    static func timestamp(_ record: RecordingRecord) -> String {
        guard let date=date(record) else { return "沟通录音" }
        return date.formatted(.dateTime.month().day().hour().minute())
    }
    static func title(_ record: RecordingRecord) -> String {
        if let title=record.title,!title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return title }
        let tags=(record.tags ?? []).filter{$0.kind=="client" || $0.kind=="project"}.prefix(2).map(\.label)
        return tags.isEmpty ? "沟通录音" : tags.joined(separator:" · ")
    }
    static func status(_ record: RecordingRecord) -> String {
        if (record.jobs ?? []).contains(where:{["failed","interrupted","cancelled"].contains($0.status)}) && record.pipeline_status != "done" { return "处理未完成" }
        switch record.pipeline_status {
        case "done": return "已整理"
        case "transcribed": return "正在整理资料"
        case "queued": return "等待精转写"
        case "created": return "等待保存音频"
        default: return "音频已保留"
        }
    }
    static func speaker(_ id: String?) -> String {
        guard let id else { return "未知说话人" }
        let parts=id.split(separator:":")
        if parts.count==2,parts[0].hasPrefix("part"),let part=Int(parts[0].dropFirst(4)) {
            let label=Int(parts[1]).map { "说话人 \($0+1)" } ?? String(parts[1])
            return "\(label) · 第\(part+1)段"
        }
        return "说话人 \(id)"
    }
    static func speakerName(_ line: RecordingSentence) -> String {
        let name=line.speaker_name?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        return name.isEmpty ? (line.speaker=="self" ? "本人":speaker(line.speaker_id)) : name
    }
}

/// Identity stays local to this recording and its diarization revision.
struct RecordingSpeakerDraft {
    let ids:[String]
    var names:[String:String]
    var selfIDs:Set<String>
    private let originalNames:[String:String]
    private let originalSelfIDs:Set<String>
    init(_ lines:[RecordingSentence]) {
        var seen=Set<String>()
        ids=lines.compactMap(\.speaker_id).filter{!$0.isEmpty && seen.insert($0).inserted}
        var values:[String:String]=[:]
        for line in lines {if let id=line.speaker_id {values[id]=line.speaker_name?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""}}
        names=values;originalNames=values
        selfIDs=Set(lines.filter{$0.speaker=="self"}.compactMap(\.speaker_id));originalSelfIDs=selfIDs
    }
    var changes:[[String:Any]] {
        ids.compactMap {id in
            let name=(names[id] ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            guard name != originalNames[id] || selfIDs.contains(id) != originalSelfIDs.contains(id) else{return nil}
            return ["speaker_id":id,"name":name,"is_self":selfIDs.contains(id)]
        }
    }
    var invalidName:Bool {names.values.contains{$0.trimmingCharacters(in:.whitespacesAndNewlines).count>100}}
}

struct RecordingPrimary: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold)).frame(maxWidth:.infinity).frame(minHeight:50)
            .foregroundStyle(Warm.ink).background(Warm.orange,in:RoundedRectangle(cornerRadius:16))
            .opacity(configuration.isPressed ? 0.8:1)
            .opacity(enabled ? 1:0.45)
    }
}

struct RecordingShell: View {
    @EnvironmentObject var store: Store
    @ObservedObject var navigation: RecordingNavigation
    @ObservedObject var speech: SpeechController
    @ObservedObject var device: Soundcore
    let onSettings: () -> Void
    @State private var keyboardVisible=false
    var body: some View {
        ZStack {
            destination(.chat) {CompanionHome(onSettings:onSettings)}
            destination(.memory) {CompanionMemory()}
            destination(.recordings) {CompanionRecordings()}
        }
        .fullScreenCover(isPresented:$navigation.showRecorder) {
            NavigationStack { LiveRecordingView(speech:speech,device:device,navigation:navigation).environmentObject(store) }
                .preferredColorScheme(.light).tint(Warm.purple).fontDesign(.rounded).foregroundStyle(Warm.ink)
        }
        .onChange(of:device.recordStatus) { old,value in
            speech.devicePaused=value==2
            if old==0 && value != 0 { navigation.newMeeting=false }
            if old != 0 && value==0 {
                let realEnd=device.connected != nil
                Task { await speech.deviceDidEnd(store:store,device:device,realEnd:realEnd);await speech.syncEndedDeviceIfReady(store:store,device:device) }
            } else { coordinateDevice() }
        }
        .onChange(of:device.currentFileID) { _,_ in coordinateDevice() }
        .onChange(of:device.fileMarkers) {_,values in
            guard store.remote,let connected=device.connected else{return}
            for (fileID,times) in values {
                if let sid=DeviceRecordingMap.get(api:store.api,fileID:fileID,deviceID:connected.uuid) {Task {try? await speech.saveMarkers(times,sessionID:sid,api:store.api)}}
            }
        }
        .onChange(of:device.realtimeReady) { _,_ in coordinateDevice() }
        .onChange(of:device.durationMS) { _,value in
            if speech.meetingSource=="soundcore",device.recordStatus != 0,speech.meetingMatches(store.api) { speech.seconds=value/1000 }
        }
        .onChange(of:device.files.map(\.id)) { _,_ in Task { await speech.syncEndedDeviceIfReady(store:store,device:device) } }
        .onChange(of:speech.finishing) { _,value in if !value { coordinateDevice();Task { await speech.syncEndedDeviceIfReady(store:store,device:device) } } }
        .onChange(of:store.remote) { _,value in if value { coordinateDevice() } }
        .onReceive(NotificationCenter.default.publisher(for:UIResponder.keyboardWillShowNotification)){_ in keyboardVisible=true}
        .onReceive(NotificationCenter.default.publisher(for:UIResponder.keyboardWillHideNotification)){_ in keyboardVisible=false}
        .task { coordinateDevice() }
        .task { await store.observeDeviceActions() }
    }
    @ViewBuilder private func destination<Content:View>(_ section:CandidSection,@ViewBuilder content:()->Content)->some View {
        NavigationStack {content().safeAreaInset(edge:.bottom,spacing:0){if !keyboardVisible && navigation.visibleDetails.isEmpty {CompanionTabBar(navigation:navigation)}}}
            .opacity(navigation.section==section ? 1:0).allowsHitTesting(navigation.section==section)
            .accessibilityHidden(navigation.section != section)
    }
    private func coordinateDevice() {
        guard device.recordStatus != 0,store.remote,!speech.meetingPreparing,!speech.finishing else { return }
        guard speech.hasMeetingConsent(store.api) else {return}
        Task {
            await speech.prepareDevice(store:store,device:device)
            if device.realtimeReady { await speech.startDevice(store:store,device:device) }
        }
    }
}

struct RecordingStatusBar: View {
    @EnvironmentObject var store: Store
    @ObservedObject var speech: SpeechController
    @ObservedObject var device: Soundcore
    var body: some View {
        if device.recordStatus != 0 || ((speech.activeMeeting || speech.deviceRecordingUncertain) && speech.meetingMatches(store.api)) {
            Button { store.recordingNavigation.newMeeting=false;store.recordingNavigation.showRecorder=true } label: {
                HStack(spacing:8) {
                    Circle().fill(Warm.purple).frame(width:7,height:7)
                    Text(speech.deviceRecordingUncertain ? "设备连接中断":device.recordStatus==2 || speech.phonePaused ? "录音已暂停" : speech.meetingSyncing || speech.uploading ? "正在保存录音":"正在录音")
                    Text(RecordingFormat.clock(device.recordStatus != 0 ? device.durationMS/1000:speech.seconds)).monospacedDigit()
                    Spacer();Text("查看字幕").font(.caption2);Image(systemName:"chevron.right").font(.caption2)
                }.font(.caption).foregroundStyle(Warm.purple).padding(.horizontal,14).frame(minHeight:46)
                    .background(Warm.lavender,in:RoundedRectangle(cornerRadius:15))
                    .overlay(RoundedRectangle(cornerRadius:15).stroke(Warm.purple.opacity(0.22)))
            }.buttonStyle(.plain).padding(.horizontal,22).padding(.vertical,6)
                .accessibilityLabel("本场录音，\(RecordingFormat.clock(speech.seconds))，查看实时原文")
        }
    }
}

private struct LiveBottomPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat,nextValue:()->CGFloat) { value=nextValue() }
}

struct LiveRecordingView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var speech: SpeechController
    @ObservedObject var device: Soundcore
    @ObservedObject var navigation: RecordingNavigation
    @State private var followsLatest=true
    @State private var userScrolling=false
    @State private var bottomPosition:CGFloat=0
    @State private var deviceSheet=false
    @State private var connectionSheet=false
    @State private var consent=false
    @State private var consentForDevice=false
    @State private var consentIdentity=""
    @State private var askedDeviceConsent=false
    @State private var liveQuestion=""
    @State private var askingLive=false
    @State private var liveAnswer=""
    @State private var liveRequestID=UUID().uuidString
    @State private var liveBody:[String:Any]?
    @State private var captionPreview=false
    @State private var record:RecordingRecord?
    @State private var detailID:String?
    @State private var issue:String?
    private var sameConnection: Bool { speech.meetingSource != nil && speech.meetingMatches(store.api) && !navigation.newMeeting }
    private var deviceActive: Bool { device.recordStatus != 0 }
    private var phoneActive: Bool { speech.recording && !speech.voiceMessage && speech.meetingSource=="iphone" && sameConnection }
    private var isPaused: Bool { deviceActive ? device.recordStatus==2:speech.phonePaused }
    private var hasLiveMeeting: Bool { deviceActive || phoneActive }
    private var title: String { hasLiveMeeting ? "本场沟通" : record.map(RecordingFormat.title) ?? "沟通录音" }
    private var duration: Int { deviceActive ? device.durationMS/1000 : sameConnection ? speech.seconds:0 }
    private var captionText: String {
        if isPaused { return "录音已暂停，继续后恢复字幕" }
        if !hasLiveMeeting { return speech.meetingProgress ?? "录音由设备按钮开始和结束" }
        if !sameConnection { return "实时字幕尚未开启 · 录音仍保存在设备" }
        switch speech.captionState {
        case .ready: return "字幕已连接 · 完整录音保存在\(deviceActive ? "设备":"本机")"
        case .connecting: return "正在连接实时字幕 · 录音仍在保存"
        case .reconnecting: return "字幕正在重连 · 录音仍在保存"
        case .unavailable: return "实时字幕暂不可用 · 录后使用完整音频"
        case .finished: return "实时字幕已结束 · 完整录音仍保留"
        case .idle: return deviceActive ? "等待设备实时音频 · 完整录音保存在设备":"等待开始录音"
        }
    }
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Button { dismiss() } label: { Label("收起",systemImage:"chevron.down").font(.subheadline) }.frame(minHeight:44)
                Spacer()
                Menu {
                    Button("设备连接与同步",systemImage:"waveform") { deviceSheet=true }
                    Button("打开全部录音",systemImage:"tray") { store.recordingNavigation.section = .recordings;dismiss() }
                    if deviceActive && !speech.hasMeetingConsent(store.api) {Button("开启实时转写") {askDeviceConsent()}}
                    if sameConnection && hasLiveMeeting && speech.captionState != .ready {
                        Button("重试实时字幕",systemImage:"arrow.clockwise") { Task { await speech.retryLive(store:store,device:device) } }
                    }
                } label: { Image(systemName:"ellipsis").frame(width:44,height:44).accessibilityLabel("录音更多操作") }
            }.padding(.horizontal,22)
            VStack(alignment:.leading,spacing:8) {
                Text(title).font(.system(size:27,weight:.bold,design:.rounded)).lineLimit(2)
                Text(record.map(RecordingFormat.timestamp) ?? (hasLiveMeeting ? "沟通录音 · 全局录音库":"每一场沟通，都可以变成用得上的资料"))
                    .font(.caption).foregroundStyle(RecordingFormat.secondary)
                HStack {
                    HStack(spacing:6) {
                        Circle().fill(isPaused ? Color.brown:hasLiveMeeting ? Color(red:0.28,green:0.42,blue:0.27):Warm.purple).frame(width:7,height:7)
                        Text(sameConnection && speech.deviceRecordingUncertain ? "设备状态待重新连接核对":deviceActive ? "安克录音豆 · \(isPaused ? "已暂停":"正在录音")" : phoneActive ? "手机录音 · 备用":"\(sameConnection && speech.meetingID != nil ? "录音已结束":"安克录音豆")")
                    }.font(.caption).foregroundStyle(RecordingFormat.secondary)
                    Spacer()
                    Text(RecordingFormat.clock(duration,hours:true)).font(.system(size:23,weight:.semibold,design:.rounded)).monospacedDigit()
                }.padding(.top,8)
            }.padding(.horizontal,23).padding(.top,8).padding(.bottom,17)
            if !hasLiveMeeting,let record,sameConnection {
                HStack(alignment:.top,spacing:8) {
                    Image(systemName:record.pipeline_status=="done" ? "checkmark.circle":"arrow.triangle.2.circlepath")
                    Text(record.pipeline_status=="done" ? "总结与原文已就绪" : speech.meetingProgress ?? RecordingFormat.status(record))
                        .font(.caption).lineSpacing(3)
                    Spacer()
                }.foregroundStyle(Warm.ink).padding(13).background(Warm.sage,in:RoundedRectangle(cornerRadius:12)).padding(.horizontal,16).padding(.bottom,12)
            }
            transcript
            if hasLiveMeeting && store.remote {
                VStack(alignment:.leading,spacing:8){
                    HStack {TextField("问问 Candid，录音会继续",text:$liveQuestion).textFieldStyle(.roundedBorder)
                        Button("发送"){Task{await askDuringRecording()}}.frame(minHeight:44).disabled(askingLive || liveQuestion.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
                    Text("结合已有资料与当前收到的字幕；实时原文尚未校准。").font(.caption2).foregroundStyle(RecordingFormat.secondary)
                    if askingLive {ProgressView("Candid 正在思考…")}
                    if !liveAnswer.isEmpty {ScrollView{Text(liveAnswer).font(.subheadline).textSelection(.enabled).lineSpacing(4)}.frame(maxHeight:100)}
                }.padding(.horizontal,22).padding(.top,12)
            }
            VStack(spacing:10) {
                Label(captionText,systemImage:speech.captionState == .reconnecting ? "wifi":"checkmark.shield")
                    .font(.caption2).foregroundStyle(RecordingFormat.secondary).frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)
                if let text=issue ?? (sameConnection ? speech.notice:nil) {
                    Text(text).font(.caption).foregroundStyle(RecordingFormat.secondary).frame(maxWidth:.infinity,alignment:.leading).lineLimit(3)
                }
                if hasLiveMeeting {Button("标记这一刻",systemImage:"bookmark.fill") {Task {await speech.markCurrent(store:store,device:device)}}.frame(minHeight:44).disabled(!store.remote)}
                if deviceActive {
                    Button { device.pauseOrResume() } label: { Label(isPaused ? "继续录音":"暂停录音",systemImage:isPaused ? "play.fill":"pause.fill") }
                        .buttonStyle(RecordingPrimary()).disabled(device.transferring || device.connected==nil)
                    Text("按设备按钮结束本场录音").font(.caption2).foregroundStyle(RecordingFormat.secondary)
                } else if phoneActive {
                    HStack(spacing:10) {
                        Button { Task { await speech.togglePhonePause() } } label: { Label(isPaused ? "继续":"暂停",systemImage:isPaused ? "play.fill":"pause.fill") }
                            .frame(maxWidth:.infinity,minHeight:50).background(Warm.lavender,in:RoundedRectangle(cornerRadius:16)).foregroundStyle(Warm.purple)
                        Button("结束录音") { Task { await speech.finishAndUpload();await reloadRecord() } }.buttonStyle(RecordingPrimary())
                    }.disabled(speech.finishing || speech.uploading)
                } else if sameConnection && (speech.finishing || speech.uploading || speech.meetingSyncing || speech.meetingPreparing) {
                    HStack { ProgressView();Text(speech.meetingProgress ?? "正在保存本场录音").font(.subheadline) }.frame(minHeight:44)
                } else if sameConnection,let id=speech.meetingID {
                    Button("查看总结与原文") { detailID=id }.buttonStyle(RecordingPrimary())
                    if let pending=speech.pendingFor(store.api).first(where:{$0.id==id}) {
                        Button("继续上传已保留的音频") { Task { await speech.upload(pending,api:store.api);await reloadRecord() } }.frame(minHeight:44)
                    }
                } else {
                    if store.remote {
                        Button { deviceSheet=true } label: { Label("\(device.connected==nil ? "连接录音豆":"查看设备")",systemImage:"waveform") }.buttonStyle(RecordingPrimary())
                        Text("连接后，按录音豆按钮开始本场沟通").font(.caption2).foregroundStyle(RecordingFormat.secondary)
                        Button("手机录音（备用）") { beginPhone() }.font(.subheadline.weight(.semibold)).frame(minHeight:44).accessibilityIdentifier("phone-recording-fallback").disabled(speech.meetingPreparing || speech.finishing || speech.uploading || speech.meetingSyncing)
                    } else { Button("连接后端") { connectionSheet=true }.buttonStyle(RecordingPrimary()) }
                }
            }.padding(.horizontal,23).padding(.top,13).padding(.bottom,18)
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-candid-ui-testing") && ProcessInfo.processInfo.arguments.contains("-candid-surface-review") && ProcessInfo.processInfo.environment["CANDID_CAPTION_PREVIEW"]=="1" {speech.prepareCaptionPreview(api:store.api);captionPreview=true}
            #endif
        }
        .foregroundStyle(Warm.ink).background(Warm.paper.ignoresSafeArea()).toolbar(.hidden,for:.navigationBar)
        .sheet(isPresented:$deviceSheet) { NavigationStack { RecordingDeviceLibrary(speech:speech,device:device).environmentObject(store) } }
        .sheet(isPresented:$connectionSheet) { SettingsView().environmentObject(store) }
        .alert(consentForDevice ? "开启本场转写":"开始沟通录音",isPresented:$consent) {
            Button("已告知并同意") {
                guard consentIdentity==DeviceRecordingMap.identity(store.api) else{issue="连接已变化，请重新开始。";return}
                Task {
                    do {
                        if !store.cloudStorageAllowed { try await store.setCloudStorageAllowed(true) }
                        speech.allowMeetingTranscription(store.api)
                        if consentForDevice { await speech.prepareDevice(store:store,device:device); await speech.startDevice(store:store,device:device) }
                        else { startPhone() }
                    } catch { issue = error.localizedDescription }
                }
            }
            Button("取消",role:.cancel) {}
        } message: {Text("请确保参与者知情并同意。音频会保存到 Candid 云端（新加坡），用于转写和整理。")}
        .task(id:String(describing:device.currentFileID)+String(device.recordStatus)+String(store.remote)) {
            if deviceActive && store.remote && !askedDeviceConsent && !speech.hasMeetingConsent(store.api) {askDeviceConsent()}
        }
        .navigationDestination(item:$detailID) { id in CompanionRecordingPage(id:id).environmentObject(store) }
        .task(id:DeviceRecordingMap.identity(store.api)+String(store.remote)+String(describing:speech.meetingID)+String(navigation.newMeeting)) {
            record=nil
            while !Task.isCancelled { await reloadRecord();do {try await Task.sleep(for:.seconds(3))} catch {break} }
        }
    }
    private var transcript: some View {
        VStack(spacing:0) {
            HStack { Text("实时原文").font(.subheadline.weight(.semibold));Spacer();Text("录后校准与分人").font(.caption2).foregroundStyle(RecordingFormat.secondary) }
                .padding(.horizontal,18).padding(.vertical,15)
            Divider().overlay(Warm.ink.opacity(0.12))
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment:.leading,spacing:22) {
                            if (sameConnection || captionPreview) && !speech.liveSentences.isEmpty {
                                ForEach(speech.liveSentences) { line in
                                    VStack(alignment:.leading,spacing:7) {
                                        Text(RecordingFormat.clock(line.startMS/1000)).font(.caption2).monospacedDigit().foregroundStyle(RecordingFormat.secondary)
                                        Text(line.text+(line.stable ? "":" ▏")).font(.body).lineSpacing(6).foregroundStyle(line.stable ? Warm.ink:Warm.purple)
                                            .textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                                    }.id(line.id)
                                }
                                if speech.hasCaptionGap { Text("实时字幕曾有缺段，录后会使用完整音频补齐。").font(.caption).foregroundStyle(RecordingFormat.secondary).padding(.vertical,8) }
                            } else {
                                VStack(alignment:.leading,spacing:12) {
                                    Text(hasLiveMeeting ? "在这里，慢慢记下每一句。":"从一场沟通开始。").font(.headline)
                                    Text(hasLiveMeeting ? "收到实际音频后会显示实时字幕；录后再校准时间戳和说话人。":"录音开始后，这里会显示实时原文。结束后自动整理，不需要先填写客户或项目。")
                                        .font(.subheadline).lineSpacing(6).foregroundStyle(RecordingFormat.secondary)
                                }.padding(.top,25)
                            }
                            Color.clear.frame(height:1).id("live-bottom")
                                .background(GeometryReader { bottom in Color.clear.preference(key:LiveBottomPreference.self,value:bottom.frame(in:.named("live-caption-scroll")).maxY) })
                        }.padding(18)
                    }.coordinateSpace(name:"live-caption-scroll")
                        .simultaneousGesture(DragGesture().onChanged {_ in userScrolling=true}.onEnded {_ in followsLatest=bottomPosition<=geometry.size.height+25;userScrolling=false})
                        .onPreferenceChange(LiveBottomPreference.self) { value in bottomPosition=value;if userScrolling {followsLatest=value<=geometry.size.height+25} }
                        .onChange(of:speech.liveRevision) { _,_ in if followsLatest {proxy.scrollTo("live-bottom",anchor:.bottom)} }
                        .overlay(alignment:.bottom) {
                            if !followsLatest {
                                Button { followsLatest=true;proxy.scrollTo("live-bottom",anchor:.bottom) } label: { Label("回到最新",systemImage:"arrow.down").font(.caption).padding(.horizontal,14).frame(minHeight:44) }
                                    .background(Warm.lavender,in:Capsule()).foregroundStyle(Warm.purple).padding(.bottom,10)
                            }
                        }
                        .onAppear { if followsLatest {proxy.scrollTo("live-bottom",anchor:.bottom)} }
                }
            }
        }.background(Warm.white,in:RoundedRectangle(cornerRadius:22))
            .overlay(RoundedRectangle(cornerRadius:22).stroke(Warm.ink.opacity(0.08))).padding(.horizontal,16)
    }
    private func askDuringRecording() async {
        guard let sid=speech.meetingID,!askingLive else{return}
        askingLive=true;defer{askingLive=false}
        if liveBody==nil {liveBody=["question":liveQuestion,"client_request_id":liveRequestID,"recording_id":sid,"sentences":speech.liveSentences.suffix(30).map{["text":$0.text,"start_ms":$0.startMS] as [String:Any]}]}
        do {
            let task:AgentTask=try await store.api.call("/v1/companion/live-ask",method:"POST",body:liveBody!)
            liveQuestion="";liveBody=nil;liveRequestID=UUID().uuidString
            for _ in 0..<180 {
                try Task.checkCancellation()
                let state:AgentTask=try await store.api.call("/v1/agent/tasks/"+task.id)
                if let text=state.partial_text,!text.isEmpty{liveAnswer=text}
                if !state.active {
                    if state.status=="completed"{let detail:ChatDetail=try await store.api.call("/v1/chat/threads/"+task.thread_id);liveAnswer=detail.messages.last(where:{$0.task_id==task.id && $0.role=="assistant"})?.content ?? liveAnswer}
                    else{liveAnswer=state.error?.message ?? "本次问答尚未完成，可回到 Candid 对话继续。"}
                    break
                }
                try await Task.sleep(for:.seconds(1))
            }
        } catch{liveAnswer=error.localizedDescription}
    }
    private func beginPhone() {
        if speech.hasMeetingConsent(store.api) && store.cloudStorageAllowed {startPhone()}
        else {consentForDevice=false;consentIdentity=DeviceRecordingMap.identity(store.api);consent=true}
    }
    private func startPhone() {
        Task {await speech.start(store:store,voice:false);if speech.recording && !speech.voiceMessage {navigation.newMeeting=false;issue=nil} else {issue=speech.notice}}
    }
    private func askDeviceConsent() {askedDeviceConsent=true;consentForDevice=true;consentIdentity=DeviceRecordingMap.identity(store.api);consent=true}
    private func reloadRecord() async {
        guard store.remote,sameConnection,let id=speech.meetingID else {return}
        let api=store.api
        do {
            let value:RecordingRecord=try await api.call("/v1/recordings/"+id)
            guard !Task.isCancelled,DeviceRecordingMap.identity(api)==DeviceRecordingMap.identity(store.api),id==speech.meetingID else{return}
            record=value;issue=nil
        } catch is CancellationError {} catch {issue=error.localizedDescription}
    }
}

struct RecordingLibrary: View {
    @EnvironmentObject var store: Store
    @ObservedObject var speech: SpeechController
    @ObservedObject var device: Soundcore
    @State private var rows:[RecordingRecord]=[]
    @State private var search=""
    @State private var issue:String?
    @State private var deviceSheet=false
    @State private var settings=false
    private var filtered:[RecordingRecord] {
        let query=search.trimmingCharacters(in:.whitespacesAndNewlines)
        return rows.filter {query.isEmpty || (RecordingFormat.title($0)+" "+($0.tags ?? []).map(\.label).joined(separator:" ")).localizedCaseInsensitiveContains(query)}
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                HStack {
                    Text("录音").font(.system(size:29,weight:.bold,design:.rounded));Spacer()
                    Button {deviceSheet=true} label: {Image(systemName:"waveform").frame(width:44,height:44).background(Warm.white,in:Circle())}
                        .accessibilityLabel("设备连接与同步")
                }
                Text("每一场沟通，都可以慢慢变成用得上的资料。").font(.caption).foregroundStyle(RecordingFormat.secondary)
                HStack(spacing:9) {
                    Image(systemName:"magnifyingglass").foregroundStyle(RecordingFormat.secondary)
                    TextField("搜索标题、客户或主题标签",text:$search).font(.subheadline).frame(minHeight:46)
                }.padding(.horizontal,13).background(Warm.white,in:RoundedRectangle(cornerRadius:15))
                    .overlay(RoundedRectangle(cornerRadius:15).stroke(Warm.ink.opacity(0.08)))
                if device.recordStatus != 0 || (speech.activeMeeting || speech.deviceRecordingUncertain) && speech.meetingMatches(store.api) {
                    Button {store.recordingNavigation.newMeeting=false;store.recordingNavigation.showRecorder=true} label: {
                        HStack(spacing:12) {
                            Image(systemName:"waveform").font(.title3)
                            VStack(alignment:.leading,spacing:6) {
                                Text(speech.deviceRecordingUncertain ? "设备连接中断":device.recordStatus==2 || speech.phonePaused ? "本场沟通已暂停":speech.meetingSyncing || speech.uploading ? "本场沟通正在保存":"本场沟通正在录音").font(.subheadline.weight(.semibold))
                                Text("\(device.recordStatus != 0 || speech.meetingSource=="soundcore" ? "安克录音豆":"手机录音") · \(RecordingFormat.clock(device.recordStatus != 0 ? device.durationMS/1000:speech.seconds))").font(.caption)
                            }
                            Spacer();Image(systemName:"chevron.right").font(.caption)
                        }.padding(16).foregroundStyle(Warm.purple).background(Warm.lavender,in:RoundedRectangle(cornerRadius:18))
                    }.buttonStyle(.plain)
                } else if store.remote {
                    Button {store.recordingNavigation.newMeeting=true;store.recordingNavigation.showRecorder=true} label: {Label("开始新一场沟通",systemImage:"record.circle")}.buttonStyle(RecordingPrimary())
                }
                if !speech.pendingFor(store.api).isEmpty {
                    VStack(alignment:.leading,spacing:10) {
                        Text("本机待上传 · 文件已保留").font(.subheadline.weight(.semibold))
                        ForEach(speech.pendingFor(store.api)) { item in
                            HStack {Text("\(item.milliseconds/60000) 分钟录音").font(.subheadline);Spacer();Button("继续上传") {Task {await speech.upload(item,api:store.api);await reload()}}.frame(minHeight:44).disabled(speech.uploading)}
                        }
                    }.padding(16).background(Warm.sage,in:RoundedRectangle(cornerRadius:18))
                }
                if let issue {
                    VStack(alignment:.leading,spacing:8) {Text(issue).font(.caption).foregroundStyle(RecordingFormat.secondary);Button("重新获取录音") {Task {await reload()}}.frame(minHeight:44)}
                }
                if store.remote {
                    if filtered.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "从一场沟通开始":"没有找到匹配录音",systemImage:"waveform",description:Text(search.isEmpty ? "连接录音豆并按设备按钮开始；不需要选择项目空间。":"试试标题或其他标签。"))
                        if search.isEmpty {Button("连接录音豆") {deviceSheet=true}.buttonStyle(RecordingPrimary())}
                    } else {
                        Text("最近录音").font(.caption).foregroundStyle(RecordingFormat.secondary)
                        VStack(spacing:0) {
                            ForEach(Array(filtered.enumerated()),id:\.element.id) { index,row in
                                NavigationLink {
                                    if row.kind=="oral_debrief",let legacy=store.sessions.first(where:{$0.id==row.id}) {SessionDetailView(session:legacy)}
                                    else {RecordingDetail(recordID:row.id).environmentObject(store)}
                                } label: {recordRow(row)}.buttonStyle(.plain)
                                if index<filtered.count-1 {Divider().padding(.horizontal,16)}
                            }
                        }.background(Warm.white,in:RoundedRectangle(cornerRadius:22)).overlay(RoundedRectangle(cornerRadius:22).stroke(Warm.ink.opacity(0.08)))
                    }
                } else {
                    ContentUnavailableView("连接后端查看录音",systemImage:"waveform",description:Text("已有的录音、原文和资料会统一出现在这里。"))
                    Button("连接后端") {settings=true}.buttonStyle(RecordingPrimary())
                    ForEach(store.sessions.filter {$0.fixture==true}) { session in
                        NavigationLink {SessionDetailView(session:session)} label: {Label("查看本机示例 · 不是真实录音",systemImage:"book")}.font(.caption).frame(minHeight:44)
                    }
                }
                Text("全部录音统一保存，通过标签关联空间。").font(.caption2).foregroundStyle(RecordingFormat.secondary)
                Button("手机录音（备用）") {store.recordingNavigation.newMeeting=true;store.recordingNavigation.showRecorder=true}.font(.subheadline.weight(.semibold)).frame(minHeight:44).accessibilityIdentifier("phone-recording-fallback").disabled(!store.remote)
            }.padding(22)
        }.background(Warm.paper.ignoresSafeArea()).toolbar(.hidden,for:.navigationBar)
            .refreshable {await reload()}
            .sheet(isPresented:$deviceSheet) {NavigationStack {RecordingDeviceLibrary(speech:speech,device:device).environmentObject(store)}}
            .sheet(isPresented:$settings) {SettingsView().environmentObject(store)}
            .task(id:DeviceRecordingMap.identity(store.api)+String(store.remote)) {
                rows=[]
                while !Task.isCancelled {await reload();do {try await Task.sleep(for:.seconds(5))} catch {break}}
            }
    }
    private func recordRow(_ row:RecordingRecord) -> some View {
        VStack(alignment:.leading,spacing:9) {
            Text(RecordingFormat.title(row)).font(.subheadline.weight(.semibold)).foregroundStyle(Warm.ink).lineLimit(2)
            HStack {Text("\(RecordingFormat.timestamp(row)) · \(RecordingFormat.clock((row.duration_ms ?? 0)/1000))");Spacer();Text(RecordingFormat.status(row))}.font(.caption2).foregroundStyle(RecordingFormat.secondary)
            if !(row.tags ?? []).isEmpty {
                RecordingTagWrap(labels:(row.tags ?? []).prefix(4).map(\.label))
            }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(16)
    }
    private func reload() async {
        guard store.remote else{return}
        let api=store.api
        do {
            let value:[RecordingRecord]=try await api.all("/v1/recordings")
            guard !Task.isCancelled,DeviceRecordingMap.identity(api)==DeviceRecordingMap.identity(store.api) else{return}
            rows=value;issue=nil
        } catch is CancellationError {} catch {issue=error.localizedDescription}
    }
}

struct RecordingTagWrap: View {
    var labels:[String]
    var body: some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:6) {ForEach(Array(labels.enumerated()),id:\.offset) { _,label in Text(label).font(.caption2).lineLimit(1).padding(.horizontal,8).padding(.vertical,5).foregroundStyle(Warm.purple).background(Warm.lavender,in:RoundedRectangle(cornerRadius:8))}}
            Text(labels.joined(separator:" · ")).font(.caption).foregroundStyle(Warm.purple).lineLimit(2)
        }
    }
}

struct RecordingDetail: View {
    @EnvironmentObject var store: Store
    let recordID:String
    var focusMS:Int?=nil
    @State private var record:RecordingRecord?
    @State private var issue:String?
    @State private var content="总结"
    @State private var editingTag:RecordingTag?
    @State private var addTag=false
    @State private var chooseSpeaker=false
    @State private var focusedSpeaker:String?
    @State private var editTranscript=false
    @State private var focusSentence:String?
    @State private var readingIssue:String?
    var body: some View {
        VStack(spacing:0) {
            if let record {
                VStack(alignment:.leading,spacing:9) {
                    Text(RecordingFormat.title(record)).font(.system(size:24,weight:.bold,design:.rounded)).lineLimit(3)
                    Text("\(RecordingFormat.timestamp(record)) · \(RecordingFormat.clock((record.duration_ms ?? 0)/1000)) · \(RecordingFormat.status(record))")
                        .font(.caption).foregroundStyle(RecordingFormat.secondary)
                    ScrollView(.horizontal,showsIndicators:false) {
                        HStack(spacing:7) {
                            ForEach(record.tags ?? []) { tag in
                                Button {editingTag=tag} label: {Text(tag.label).font(.caption).padding(.horizontal,10).frame(minHeight:44).background(Warm.lavender,in:RoundedRectangle(cornerRadius:10))}.foregroundStyle(Warm.purple)
                                    .accessibilityLabel("修改\(tag.source=="ai" ? "自动":"手动")标签：\(tag.label)")
                                    .contextMenu {Button("移除标签",role:.destructive) {Task {await updateTag(tag,label:tag.label,active:false,workspace:tag.workspace_id)}}}
                            }
                            Button {addTag=true} label: {Image(systemName:"plus").frame(width:44,height:44).overlay(RoundedRectangle(cornerRadius:10).stroke(Warm.purple.opacity(0.35),style:StrokeStyle(lineWidth:1,dash:[3])))}.accessibilityLabel("添加标签")
                        }
                    }
                }.padding(.horizontal,22).padding(.top,8).padding(.bottom,14)
                Picker("录音内容",selection:$content) {Text("总结").tag("总结");Text("原文").tag("原文")}.pickerStyle(.segmented).padding(.horizontal,22).padding(.bottom,15)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment:.leading,spacing:18) {
                            if let issue {Text(issue).font(.caption).foregroundStyle(RecordingFormat.secondary)}
                            if content=="总结" {summary(record)} else {raw(record)}
                            jobProgress(record)
                        }.padding(.horizontal,22).padding(.bottom,24)
                    }
                    .onChange(of:focusSentence) { _,value in if let value {proxy.scrollTo(value,anchor:.top)} }
                    .onChange(of:content) { _,value in if value=="原文",let focusSentence {DispatchQueue.main.async {proxy.scrollTo(focusSentence,anchor:.top)}} }
                }
            } else if let issue {
                ContentUnavailableView("暂时无法读取录音",systemImage:"wifi.exclamationmark",description:Text(issue))
                Button("重新获取") {Task {await reload()}}.frame(minHeight:44)
            } else {ProgressView("正在读取录音").frame(maxWidth:.infinity,maxHeight:.infinity)}
        }
        .foregroundStyle(Warm.ink).tint(Warm.purple).preferredColorScheme(.light)
        .environment(\.colorScheme,.light)
        .toolbarColorScheme(.light,for:.navigationBar)
        .toolbarBackground(Warm.paper,for:.navigationBar)
        .background(Warm.paper.ignoresSafeArea()).navigationTitle("沟通录音").navigationBarTitleDisplayMode(.inline)
        .toolbar {ToolbarItem(placement:.topBarTrailing) {Menu {
            Button("回听完整录音",systemImage:"play") {Task {await play()}}
            Button("修正转写",systemImage:"square.and.pencil") {editTranscript=true}.disabled((record?.segments ?? []).isEmpty)
            Button("说话人认领",systemImage:"person.crop.rectangle") {focusedSpeaker=nil;chooseSpeaker=true}.disabled((record?.segments ?? []).isEmpty)
        } label: {Image(systemName:"ellipsis").frame(width:44,height:44).accessibilityLabel("录音详情更多操作")}}}
        .safeAreaInset(edge:.bottom) {
            if store.recordingPlaybackID==recordID {RecordingPlayerBar().environmentObject(store)}
            else {RecordingStatusBar(speech:store.speech,device:store.soundcore)}
        }
        .sheet(item:$editingTag,onDismiss:{Task {await reload()}}) {tag in
            TagEditor(tag:tag,save:{name,wid in Task {await updateTag(tag,label:name,active:true,workspace:wid)}},spaces:store.projectSpaces)
        }
        .sheet(isPresented:$addTag,onDismiss:{Task {await reload()}}) {RecordingTagCreation(recordID:recordID).environmentObject(store)}
        .sheet(isPresented:$chooseSpeaker,onDismiss:{Task {await reload()}}) {if let record {RecordingSpeakerPicker(record:record,focusedSpeaker:focusedSpeaker).environmentObject(store)}}
        .sheet(isPresented:$editTranscript,onDismiss:{Task {await reload()}}) {if let record {TranscriptEditor(record:record).environmentObject(store)}}
        .task(id:DeviceRecordingMap.identity(store.api)+recordID) {
            record=nil
            while !Task.isCancelled {await reload();do {try await Task.sleep(for:.seconds(4))} catch {break}}
        }
        .onDisappear {if store.recordingPlaybackID==recordID {store.stopPlayback()}}
        .alert("回听未能开始",isPresented:Binding(get:{readingIssue != nil},set:{if !$0 {readingIssue=nil}})) {Button("知道了",role:.cancel){}} message:{Text(readingIssue ?? "")}
    }
    @ViewBuilder private func summary(_ record:RecordingRecord) -> some View {
        let knowledge=record.knowledge ?? []
        VStack(alignment:.leading,spacing:20) {
            Text("这场谈清楚了什么").font(.headline)
            if knowledge.isEmpty {Text("音频保存后会自动生成总结、复盘与标签。已有原文可以先查看。").font(.subheadline).foregroundStyle(RecordingFormat.secondary).lineSpacing(6)}
            ForEach(knowledge) { item in
                Text(item.text).font(.body).lineSpacing(6).textSelection(.enabled)
                let available=(item.evidence_refs ?? []).filter {ref in (record.segments ?? []).contains(where:{"transcript:"+$0.id==ref.source_id})}
                if !available.isEmpty {
                    ScrollView(.horizontal,showsIndicators:false) {
                        HStack {ForEach(Array(available.prefix(4).enumerated()),id:\.offset) { _,ref in
                            Button("查看 \(RecordingFormat.clock((ref.start_ms ?? 0)/1000)) 原文") {focusSentence=ref.source_id.replacingOccurrences(of:"transcript:",with:"");content="原文"}.font(.caption).frame(minHeight:44)
                        }}
                    }
                }
            }
            let steps=knowledge.flatMap {$0.review?.next_steps ?? []}
            if !steps.isEmpty {Text("下一步").font(.headline).padding(.top,5);RecordingChecklist(recordID:recordID,revision:record.transcript_revision ?? 1,steps:steps).environmentObject(store)}
            let strengths=knowledge.flatMap {$0.review?.strengths ?? []}
            let improvements=knowledge.flatMap {$0.review?.improvements ?? []}
            if !strengths.isEmpty || !improvements.isEmpty {
                Text("沟通复盘").font(.headline).padding(.top,5)
                if !strengths.isEmpty {Text("这次有效的表达").font(.subheadline.weight(.semibold));ForEach(Array(strengths.enumerated()),id:\.offset) { _,text in Text(text).font(.subheadline).lineSpacing(6).textSelection(.enabled)}}
                if !improvements.isEmpty {Text("下次可以补齐").font(.subheadline.weight(.semibold));ForEach(Array(improvements.enumerated()),id:\.offset) { _,text in Text(text).font(.subheadline).lineSpacing(6).textSelection(.enabled)}}
            }
            let questions=knowledge.flatMap {$0.review?.open_questions ?? []}
            if !questions.isEmpty {Text("待澄清的问题").font(.headline);ForEach(Array(questions.enumerated()),id:\.offset) { _,text in Text(text).font(.subheadline).lineSpacing(6).textSelection(.enabled)}}
            if !knowledge.isEmpty {Text("AI 根据这场原文整理；时间链接可以查看相关依据。").font(.caption2).foregroundStyle(RecordingFormat.secondary)}
        }.frame(maxWidth:.infinity,alignment:.leading).padding(18).background(Warm.white,in:RoundedRectangle(cornerRadius:22)).overlay(RoundedRectangle(cornerRadius:22).stroke(Warm.ink.opacity(0.08)))
    }
    @ViewBuilder private func raw(_ record:RecordingRecord) -> some View {
        HStack {Text("录后分人 · 时间戳已校准").font(.caption2).foregroundStyle(RecordingFormat.secondary);Spacer();Button("说话人认领") {focusedSpeaker=nil;chooseSpeaker=true}.font(.caption).frame(minHeight:44).disabled((record.segments ?? []).isEmpty)}
        if let marks=record.marks,!marks.isEmpty {
            ScrollView(.horizontal) {HStack {ForEach(marks) {mark in Button {Task {await store.perform {try await store.playRecording(record.id,startMS:mark.t_ms)}}} label:{Label("标记 "+RecordingFormat.clock(mark.t_ms/1000),systemImage:"bookmark.fill").font(.caption).frame(minHeight:44)}}}}
        }
        if (record.segments ?? []).isEmpty {ContentUnavailableView("原文还在准备",systemImage:"text.alignleft",description:Text("精转写完成后会显示逐句原文和回听入口。"))}
        else {
            LazyVStack(alignment:.leading,spacing:0) {
                ForEach(record.segments ?? []) { line in
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Text(RecordingFormat.clock(line.start_ms/1000,hours:true)).monospacedDigit().foregroundStyle(RecordingFormat.secondary)
                            Button {focusedSpeaker=line.speaker_id;chooseSpeaker=true} label: {
                                HStack(spacing:4) {Text(RecordingFormat.speakerName(line)).lineLimit(2);if line.speaker=="self" {Image(systemName:"person.fill")}}
                                    .frame(minHeight:44)
                            }.foregroundStyle(Warm.purple).buttonStyle(.plain).disabled(line.speaker_id==nil)
                                .accessibilityLabel("认领说话人："+RecordingFormat.speakerName(line))
                            Spacer()
                            Button {Task {await play(line)}} label: {Image(systemName:store.recordingPlaybackID==recordID && store.recordingPlaybackStartMS==line.start_ms && store.recordingPlaybackPlaying ? "pause.fill":"play.fill").font(.caption).frame(width:44,height:44).background(Warm.lavender,in:Circle())}
                                .accessibilityLabel("回听\(RecordingFormat.clock(line.start_ms/1000))的原文")
                        }.font(.caption2)
                        Text(line.text).font(.body).lineSpacing(6).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                    }.padding(.vertical,16).padding(.horizontal,16).id(line.id)
                        .background(focusSentence==line.id ? Warm.lavender:Color.clear)
                    if line.id != record.segments?.last?.id {Divider().padding(.horizontal,16)}
                }
            }.background(Warm.white,in:RoundedRectangle(cornerRadius:22)).clipShape(RoundedRectangle(cornerRadius:22))
        }
    }
    @ViewBuilder private func jobProgress(_ record:RecordingRecord) -> some View {
        let jobs=(record.jobs ?? []).filter {$0.status != "completed"}
        if !jobs.isEmpty {
            VStack(alignment:.leading,spacing:12) {
                Text("处理进度").font(.subheadline.weight(.semibold))
                ForEach(jobs) {job in
                    VStack(alignment:.leading,spacing:7) {
                        Text(job.progress ?? "处理中").font(.subheadline)
                        if let issue=job.error {Text(issue).font(.caption).foregroundStyle(RecordingFormat.secondary)}
                        HStack {
                            if ["failed","interrupted","cancelled"].contains(job.status) {Button("继续处理") {Task {await jobAction(job,"retry")}}.frame(minHeight:44)}
                            if ["queued","running"].contains(job.status) {Button("停止等待") {Task {await jobAction(job,"cancel")}}.frame(minHeight:44)}
                        }
                    }
                }
            }.padding(.top,10)
        }
    }
    private func reload() async {
        guard store.remote else{issue="请先连接录音所在的后端。";return}
        let api=store.api
        do {
            let value:RecordingRecord=try await api.call("/v1/recordings/"+recordID)
            guard !Task.isCancelled,DeviceRecordingMap.identity(api)==DeviceRecordingMap.identity(store.api) else{return}
            record=value;issue=nil
            if focusSentence==nil,let ms=focusMS {focusSentence=value.segments?.first(where:{$0.start_ms<=ms && $0.end_ms>=ms})?.id;content="原文"}
        } catch is CancellationError {} catch {issue=error.localizedDescription}
    }
    private func play(_ line:RecordingSentence?=nil) async {
        if let line,store.recordingPlaybackID==recordID,store.recordingPlaybackStartMS==line.start_ms {store.toggleRecordingPlayback();return}
        do {try await store.playRecording(recordID,startMS:line?.start_ms ?? 0,endMS:line?.end_ms)} catch {readingIssue=error.localizedDescription}
    }
    private func updateTag(_ tag:RecordingTag,label:String,active:Bool,workspace:String?) async {
        do {
            var body:[String:Any]=["label":label,"kind":tag.kind,"active":active,"expected_revision":tag.revision]
            body["workspace_id"]=workspace.map { $0 as Any } ?? NSNull()
            _=try await store.api.raw("/v1/recording-tags/"+tag.id,method:"PATCH",body:body);await reload()
        } catch {issue=error.localizedDescription}
    }
    private func jobAction(_ job:BusinessJob,_ action:String) async {
        do {_=try await store.api.raw("/v1/business-jobs/"+job.id+"/"+action,method:"POST");await reload()} catch {issue=error.localizedDescription}
    }
}

struct RecordingPlayerBar: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(spacing:8) {
            HStack(spacing:12) {
                Button {store.toggleRecordingPlayback()} label: {Image(systemName:store.recordingPlaybackPlaying ? "pause.fill":"play.fill").frame(width:44,height:44).background(Warm.lavender,in:Circle())}.accessibilityLabel(store.recordingPlaybackPlaying ? "暂停回听":"继续回听")
                VStack(alignment:.leading,spacing:4) {Text("录音回听").font(.caption.weight(.semibold));Text("\(RecordingFormat.clock(store.recordingPlaybackPositionMS/1000)) / \(RecordingFormat.clock(store.recordingPlaybackEndMS/1000))").font(.caption2).monospacedDigit().foregroundStyle(RecordingFormat.secondary)}
                Spacer();Button {store.stopPlayback()} label: {Image(systemName:"xmark").frame(width:44,height:44)}.accessibilityLabel("停止回听")
            }
            if store.recordingPlaybackEndMS>store.recordingPlaybackStartMS {
                Slider(value:Binding(get:{Double(max(store.recordingPlaybackStartMS,min(store.recordingPlaybackPositionMS,store.recordingPlaybackEndMS)))},set:{store.seekRecordingPlayback($0)}),in:Double(store.recordingPlaybackStartMS)...Double(store.recordingPlaybackEndMS)).accessibilityLabel("回听进度")
            }
        }.padding(.horizontal,22).padding(.vertical,10).background(Warm.white)
    }
}

struct RecordingChecklist: View {
    @EnvironmentObject var store: Store
    let recordID:String; let revision:Int; let steps:[String]
    @State private var completed:Set<Int>=[]
    private var key:String {
        let digest=SHA256.hash(data:Data(steps.joined(separator:"\n").utf8)).map {String(format:"%02x",$0)}.joined()
        return "candid-recording-todos:"+DeviceRecordingMap.identity(store.api)+":"+recordID+":"+String(revision)+":"+digest
    }
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            ForEach(Array(steps.enumerated()),id:\.offset) { index,text in
                Button {
                    if completed.contains(index) {completed.remove(index)} else {completed.insert(index)}
                    UserDefaults.standard.set(Array(completed),forKey:key)
                } label: {
                    HStack(alignment:.top,spacing:9) {Image(systemName:completed.contains(index) ? "checkmark.square.fill":"square").padding(.top,3).foregroundStyle(Warm.purple);Text(text).strikethrough(completed.contains(index)).font(.subheadline).lineSpacing(5).foregroundStyle(completed.contains(index) ? RecordingFormat.secondary:Warm.ink);Spacer(minLength:0)}.frame(minHeight:44,alignment:.topLeading)
                }.buttonStyle(.plain).accessibilityLabel(text).accessibilityValue(completed.contains(index) ? "已完成":"未完成")
            }
        }.task(id:key) {completed=Set(UserDefaults.standard.array(forKey:key) as? [Int] ?? [])}
    }
}

struct RecordingTagCreation: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let recordID:String
    @State private var label=""; @State private var workspace=""; @State private var issue:String?; @State private var saving=false
    var body: some View {
        NavigationStack {
            Form {
                TextField("标签名称",text:$label)
                Picker("关联空间（可选）",selection:$workspace) {Text("不关联").tag("");ForEach(store.projectSpaces) {space in Text(space.name).tag(space.id)}}
                Text("录音仍在全局库中；一个录音可以通过多个标签关联不同空间。").font(.caption).foregroundStyle(RecordingFormat.secondary)
                if let issue {Text(issue).font(.caption)}
            }.navigationTitle("添加标签").navigationBarTitleDisplayMode(.inline)
                .toolbar {ToolbarItem(placement:.cancellationAction) {Button("取消") {dismiss()}};ToolbarItem(placement:.confirmationAction) {Button("保存") {Task {await save()}}.disabled(saving || label.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}}
        }
    }
    private func save() async {
        saving=true;defer {saving=false}
        do {var body:[String:Any]=["label":label.trimmingCharacters(in:.whitespacesAndNewlines),"kind":"project"];if !workspace.isEmpty {body["workspace_id"]=workspace};_=try await store.api.raw("/v1/recordings/"+recordID+"/tags",method:"POST",body:body);dismiss()} catch {issue=error.localizedDescription}
    }
}

struct RecordingSpeakerPicker: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let record:RecordingRecord
    var focusedSpeaker:String?=nil
    @State private var current:RecordingRecord
    @State private var draft:RecordingSpeakerDraft
    @State private var issue:String?
    @State private var saving=false
    @State private var conflict=false
    @FocusState private var nameFocus:String?
    private var canSave:Bool {!saving && !draft.changes.isEmpty && !draft.invalidName && draft.changes.count<=100 && !conflict}
    init(record:RecordingRecord,focusedSpeaker:String?=nil) {
        self.record=record;self.focusedSpeaker=focusedSpeaker
        _current=State(initialValue:record);_draft=State(initialValue:RecordingSpeakerDraft(record.segments ?? []))
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader {proxy in
                Form {
                    Section {
                        Text("给每位说话人填上名字，原文中的姓名会一起更新。不确定的可以留空，以后再改。")
                            .font(.subheadline).foregroundStyle(RecordingFormat.secondary)
                    }
                    if draft.ids.isEmpty {
                        Section {Text("还没有可认领的说话人。录后分人完成后再来看看。").foregroundStyle(RecordingFormat.secondary)}
                    }
                    ForEach(draft.ids,id:\.self) {id in
                        Section {
                            TextField("姓名或称呼",text:Binding(get:{draft.names[id] ?? ""},set:{draft.names[id]=$0}),prompt:Text("姓名或称呼").foregroundColor(RecordingFormat.secondary))
                                .textContentType(.name).submitLabel(.done).focused($nameFocus,equals:id)
                                .onSubmit{nameFocus=nil}.frame(minHeight:44)
                                .accessibilityLabel(RecordingFormat.speaker(id)+"的姓名")
                                .accessibilityIdentifier("speaker-name-"+id)
                            if (draft.names[id] ?? "").trimmingCharacters(in:.whitespacesAndNewlines).count>100 {
                                Text("姓名请控制在 100 字以内。").font(.caption).foregroundStyle(.red)
                            }
                            Toggle("这是我",isOn:Binding(get:{draft.selfIDs.contains(id)},set:{if $0 {draft.selfIDs.insert(id)} else {draft.selfIDs.remove(id)}}))
                                .accessibilityIdentifier("speaker-self-"+id)
                            if let line=current.segments?.first(where:{$0.speaker_id==id}) {
                                VStack(alignment:.leading,spacing:6) {
                                    Text("原话参考 · "+RecordingFormat.clock(line.start_ms/1000,hours:true)).font(.caption)
                                    Text(line.text).font(.subheadline).lineLimit(3)
                                }.foregroundStyle(RecordingFormat.secondary).padding(.vertical,4)
                            }
                        } header: {Text(RecordingFormat.speaker(id))}
                        .listRowBackground(Warm.white).id(id)
                    }
                    Section {
                        Text("姓名仅用于这段录音；“这是我”用于识别你的个人经历。长录音跨段编号分别认领，同一个人可以填写相同名字。")
                            .font(.caption).foregroundStyle(RecordingFormat.secondary)
                        if draft.changes.count>100 {Text("本次请先修改不超过 100 个说话人，保存后可继续。").foregroundStyle(.red)}
                        if let issue {
                            Text(issue).font(.subheadline).foregroundStyle(.red).accessibilityIdentifier("speaker-save-error")
                            if conflict {
                                Button("放弃本次修改，载入最新原文") {Task {await refresh()}}
                                    .frame(minHeight:44)
                            }
                        }
                    }.listRowBackground(Warm.white)
                }
                .disabled(saving).scrollDismissesKeyboard(.interactively)
                .scrollContentBackground(.hidden).background(Warm.paper)
                .onAppear {if let focusedSpeaker {proxy.scrollTo(focusedSpeaker,anchor:.top)}}
            }
            .navigationTitle("说话人认领").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) {Button("取消") {dismiss()}.disabled(saving)}
                ToolbarItem(placement:.confirmationAction) {
                    Button {nameFocus=nil;Task {await save()}} label: {
                        if saving {ProgressView().accessibilityLabel("正在保存说话人")}
                        else {Text("保存").foregroundStyle(Warm.purple.opacity(canSave ? 1:0.4))}
                    }.disabled(!canSave)
                        .accessibilityIdentifier("speaker-save")
                }
                ToolbarItemGroup(placement:.keyboard) {Spacer();Button("收起键盘") {nameFocus=nil}}
            }
        }
        .foregroundStyle(Warm.ink).tint(Warm.purple).fontDesign(.rounded)
        .preferredColorScheme(.light).environment(\.colorScheme,.light)
        .interactiveDismissDisabled(saving)
    }
    private func save() async {
        guard !saving,!draft.changes.isEmpty,!draft.invalidName else{return}
        saving=true;issue=nil;defer {saving=false}
        do {
            _=try await store.api.raw("/v1/recordings/"+current.id+"/speakers",method:"PATCH",body:["speakers":draft.changes,"expected_revision":current.transcript_revision ?? 1])
            dismiss()
        } catch {
            conflict=error.localizedDescription.contains("VERSION_CONFLICT")
            issue=conflict ? "原文已更新，本次修改尚未保存。请载入最新原文后重新认领。" : "姓名尚未保存，填写内容仍保留。"+error.localizedDescription
        }
    }
    private func refresh() async {
        saving=true;defer {saving=false}
        do {
            let value:RecordingRecord=try await store.api.call("/v1/recordings/"+current.id)
            current=value;draft=RecordingSpeakerDraft(value.segments ?? []);issue=nil;conflict=false
        } catch {issue="未能载入最新原文，本次填写仍保留。"+error.localizedDescription}
    }
}

struct RecordingDeviceLibrary: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var speech: SpeechController
    @ObservedObject var device: Soundcore
    @State private var consent=false
    @State private var pendingFile:SoundcoreFile?
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                Text("安克录音豆").font(.title2.bold())
                Text(device.status).font(.subheadline).foregroundStyle(RecordingFormat.secondary)
                NavigationLink {SoundcoreDeviceView(device:device)} label: {Label(device.connected==nil ? "连接与授权":"管理设备连接",systemImage:"waveform")}.frame(minHeight:44)
                Text("按设备按钮开始和结束录音。App 支持暂停、继续、实时原文和文件同步；字幕只在设备实际提供实时音频时开启。").font(.subheadline).lineSpacing(5).foregroundStyle(RecordingFormat.secondary)
                if device.recordStatus != 0 {Button("查看本场录音") {store.recordingNavigation.newMeeting=false;store.recordingNavigation.showRecorder=true;dismiss()}.buttonStyle(RecordingPrimary())}
                if speech.meetingSyncing || device.transferring {
                    VStack(alignment:.leading,spacing:8) {Text(speech.meetingProgress ?? "正在同步设备音频").font(.subheadline);ProgressView(value:device.progress)}
                }
                if let issue=device.error ?? speech.notice {Text(issue).font(.caption).foregroundStyle(RecordingFormat.secondary)}
                Button("刷新设备录音") {device.refreshFiles()}.frame(minHeight:44).disabled(device.connected==nil || device.transferring)
                ForEach(device.files) {file in
                    HStack {
                        VStack(alignment:.leading,spacing:6) {Text(file.title).font(.subheadline.weight(.semibold));Text(RecordingFormat.clock(file.durationMS/1000)).font(.caption).foregroundStyle(RecordingFormat.secondary)}
                        Spacer();Button("同步") {beginSync(file)}.frame(minHeight:44).disabled(device.recordStatus != 0 || speech.meetingSyncing || speech.uploading)
                    }.padding(.vertical,8)
                }
            }.padding(22)
        }.background(Warm.paper.ignoresSafeArea()).navigationBarTitleDisplayMode(.inline)
            .toolbar {ToolbarItem(placement:.confirmationAction) {Button("完成") {dismiss()}}}
            .onAppear {device.refreshFiles()}
            .alert("转写与整理设备录音",isPresented:$consent) {
                Button("已告知并同意") {speech.allowMeetingTranscription(store.api);if let file=pendingFile {Task {await speech.syncDevice(file,store:store,device:device)}}}
                Button("取消",role:.cancel) {pendingFile=nil}
            } message: {Text("请确保参与者知情并同意。音频会发送到已配置的服务进行转写和整理。")}
    }
    private func beginSync(_ file:SoundcoreFile) {
        if speech.hasMeetingConsent(store.api) {Task {await speech.syncDevice(file,store:store,device:device)}}
        else {pendingFile=file;consent=true}
    }
}

#if DEBUG
struct RecordingSpeakerReviewHost: View {
    @State private var presented=true
    var body: some View {
        NavigationStack {Button("说话人认领") {presented=true}.frame(maxWidth:.infinity,maxHeight:.infinity).background(Warm.paper)}
            .sheet(isPresented:$presented) {RecordingSpeakerPicker(record:RecordingSpeakerFixture.record)}
    }
}
enum RecordingSpeakerFixture {
    static var record:RecordingRecord {
        let text = #"{"id":"speaker-review","pipeline_status":"done","transcript_revision":1,"segments":[{"id":"a","speaker":"self","speaker_id":"part0:0","speaker_name":"林晓","text":"我们先确认一下这次试点的目标和时间安排。","start_ms":1000,"end_ms":4000},{"id":"b","speaker":"unknown","speaker_id":"part0:1","text":"可以，我更关注接口能否配合我们的排期。","start_ms":4200,"end_ms":8000},{"id":"c","speaker":"unknown","speaker_id":"part1:0","text":"下一段我们具体讨论交付范围。","start_ms":60000,"end_ms":64000}]}"#
        return try! JSONDecoder().decode(RecordingRecord.self,from:Data(text.utf8))
    }
}
#endif
