import SwiftUI
import AVFoundation
import Combine
import CryptoKit
import UniformTypeIdentifiers

struct BusinessJob: Decodable, Identifiable {
    var id: String; var kind: String; var object_id: String; var status: String
    var progress: String?; var error: String?; var result: BusinessResult?
}
struct BusinessResult: Decodable { var clip_ids: [String]?; var memory_count: Int? }
struct RecordingTag: Codable, Identifiable {
    var id: String; var label: String; var kind: String; var workspace_id: String?
    var revision: Int; var active: Bool; var source: String
}
struct RecordingSentence: Decodable, Identifiable {
    var id: String; var text: String; var start_ms: Int; var end_ms: Int
    var speaker: String; var speaker_id: String?
}
struct RecordingKnowledge: Decodable, Identifiable { var id: String; var title: String; var text: String }
struct RecordingRecord: Decodable, Identifiable {
    var id: String; var started_at: String?; var pipeline_status: String; var recording_source: String?
    var tags: [RecordingTag]?; var segments: [RecordingSentence]?; var knowledge: [RecordingKnowledge]?
    var jobs: [BusinessJob]?; var transcript_revision: Int?
}
struct PendingRecording: Codable, Identifiable {
    var id: String; var path: String; var milliseconds: Int; var backendIdentity: String
}

@MainActor final class SpeechController: ObservableObject {
    @Published var recording = false
    @Published var voiceMessage = false
    @Published var seconds = 0
    @Published var preview = ""
    @Published var notice: String?
    @Published var uploading = false
    @Published var finishing = false
    @Published var playing = false
    @Published var pending: [PendingRecording] = []
    private var engine: AVAudioEngine?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void,Never>?
    private var sendTail: Task<Void,Never>?
    private var clock: Task<Void,Never>?
    private var player: AVAudioPlayer?
    private var playback: Task<Void,Never>?
    private var ttsJob:(API,String)?
    private var speechCancel:Task<Void,Never>?
    private var connection: API?
    private var sessionID: String?
    private var fileURL: URL?
    private var finalSentences: [String:String] = [:]
    private var partial = ""
    private var streamID = UUID()
    private var nextSequence = 0
    private var liveReady = false
    private var liveFinished = false
    private var started = Date()
    private var interruptedObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    var voiceThreadID: String?
    private var voiceRequestID=UUID().uuidString
    private var bufferCount = 0
    private var completedClips: Set<String> = []
    private var clipQueue: [String] = []
    private var finishedPlaying = false
    private var paused = false
    private var pendingPath: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("PendingRecordings.json")
    }
    init() {
        pending = (try? Data(contentsOf: pendingPath)).flatMap { try? JSONDecoder().decode([PendingRecording].self,from:$0) } ?? []
        interruptedObserver=NotificationCenter.default.addObserver(forName:AVAudioSession.interruptionNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.stopPlayback()
                if self.recording { await self.finishCapture(); self.notice="录音被系统打断，已保存本机文件，可继续上传。" }
            }
        }
        routeObserver=NotificationCenter.default.addObserver(forName:AVAudioSession.routeChangeNotification,object:nil,queue:.main) { [weak self] notification in
            let reason=(notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.stopPlayback() }
            }
        }
    }
    private func identity(_ api: API) -> String { SHA256.hash(data:Data((api.base+"\n"+api.token).utf8)).map { String(format:"%02x",$0) }.joined() }
    private func persistPending() {
        try? FileManager.default.createDirectory(at:pendingPath.deletingLastPathComponent(),withIntermediateDirectories:true)
        if let data=try? JSONEncoder().encode(pending) { try? data.write(to:pendingPath,options:[.atomic,.completeFileProtection]) }
    }
    func start(store: Store, voice: Bool) async {
        guard !recording,!finishing,!uploading, store.remote else { notice="请先连接后端。"; return }
        if !voice && store.capabilities?.recording_mode == "device" { notice="正式沟通录音请连接安克设备并按设备按钮开始。"; return }
        store.stopPlayback();stopPlayback(); notice=nil; preview=""; finalSentences=[:]; liveOrder=[];liveText=[]; partial=""; seconds=0
        let permitted=await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning:$0) }
        }
        guard permitted else { notice="麦克风权限未开启，请到系统设置允许录音。"; return }
        let api=store.api
        do {
            connection=api; voiceMessage=voice;voiceRequestID=UUID().uuidString; voiceThreadID=store.chatThread?.id
            if voice {
                guard voiceThreadID != nil else { throw PrototypeError.message("请先新建或选择项目空间。") }
                sessionID=nil
            } else {
                let session: RecordingRecord=try await api.call("/v1/recordings",method:"POST",body:[
                    "client_request_id":UUID().uuidString,"recording_source":"iphone","consent":"yes","consent_ack_text_version":"recording-consent@1"])
                sessionID=session.id
            }
            let identifier=sessionID ?? UUID().uuidString
            let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("Recordings")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let url=folder.appendingPathComponent(identifier+".m4a");fileURL=url
            let audio=AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord,mode:.default,options:[.defaultToSpeaker,.allowBluetoothHFP])
            try audio.setActive(true)
            let engine=AVAudioEngine();let input=engine.inputNode;let format=input.outputFormat(forBus:0)
            guard format.sampleRate>0, let target=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:true),
                  let converter=AVAudioConverter(from:format,to:target) else { throw PrototypeError.message("麦克风音频格式不可用。") }
            let file=try AVAudioFile(forWriting:url,settings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:format.sampleRate,AVNumberOfChannelsKey:format.channelCount,AVEncoderBitRateKey:64000],commonFormat:format.commonFormat,interleaved:format.isInterleaved)
            try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.path)
            self.engine=engine;recording=true;started=Date()
            if let sid=sessionID {
                pending.append(PendingRecording(id:sid,path:url.path,milliseconds:0,backendIdentity:identity(api)));persistPending()
            }
            input.installTap(onBus:0,bufferSize:4096,format:format) { [weak self] buffer,_ in
                do { try file.write(from:buffer) }
                catch { DispatchQueue.main.async { self?.notice="本机写入失败，已保存部分录音。"; Task { await self?.finishCapture() } }; return }
                let count=AVAudioFrameCount(Double(buffer.frameLength)*16000/format.sampleRate)+32
                guard let output=AVAudioPCMBuffer(pcmFormat:target,frameCapacity:count) else { return }
                var supplied=false;var error: NSError?
                converter.convert(to:output,error:&error) { _,status in
                    if supplied { status.pointee = .noDataNow;return nil }
                    supplied=true;status.pointee = .haveData;return buffer
                }
                guard error == nil, let bytes=output.int16ChannelData?[0],output.frameLength>0 else { return }
                let pcm=Data(bytes:bytes,count:Int(output.frameLength)*2)
                DispatchQueue.main.async { self?.sendFrame(pcm) }
            }
            try engine.start();await openLive(api:api,sid:sessionID)
            clock=Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for:.seconds(1))
                    guard let self,self.recording else { return }
                    self.seconds=Int(Date().timeIntervalSince(self.started))
                    if let sid=self.sessionID,let i=self.pending.firstIndex(where:{$0.id==sid}) { self.pending[i].milliseconds=self.seconds*1000; self.persistPending() }
                }
            }
        } catch { notice=error.localizedDescription; await finishCapture() }
    }
    private func openLive(api: API,sid: String?) async {
        receiver?.cancel();socket?.cancel(with:.goingAway,reason:nil)
        let epoch=UUID();streamID=epoch;nextSequence=0;liveReady=false;liveFinished=false;bufferCount=0
        do {
            var components=URLComponents(url:try api.url("/v1/speech/live"),resolvingAgainstBaseURL:false)!
            components.scheme=components.scheme=="https" ? "wss":"ws"
            let task=URLSession.shared.webSocketTask(with:components.url!);socket=task;task.resume()
            var hello:[String:Any]=["token":api.token,"offset_ms":seconds*1000]
            if let sid { hello["session_id"]=sid }
            try await task.send(.string(String(data:JSONSerialization.data(withJSONObject:hello),encoding:.utf8)!))
            receiver=Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let value=try await task.receive()
                        let raw:Data
                        switch value { case .data(let data):raw=data;case .string(let text):raw=Data(text.utf8);@unknown default:continue }
                        guard let event=try JSONSerialization.jsonObject(with:raw) as? [String:Any],let self,self.streamID==epoch else { return }
                        let type=event["type"] as? String
                        if type=="ready" { self.liveReady=true }
                        if type=="finished" { self.liveFinished=true;return }
                        if type=="error" { self.notice=event["message"] as? String;self.liveReady=false }
                        if type=="transcript",let sentence=event["sentence"] as? [String:Any],let text=sentence["text"] as? String {
                            let key=epoch.uuidString+":"+String(describing:sentence["sentence_id"] ?? sentence["begin_time"] ?? 0)
                            if sentence["sentence_end"] as? Bool == true || (sentence["end_time"] != nil && !(sentence["end_time"] is NSNull)) {
                                self.finalSentences[key]=text;self.partial=""
                            } else { self.partial=text }
                            // Dictionary insertion order is not a timing contract; store a separate ordered text list below.
                            if let index=self.liveOrder.firstIndex(of:key) { self.liveText[index]=text }
                            else { self.liveOrder.append(key);self.liveText.append(text) }
                            self.preview=self.liveText.joined(separator:"")
                        }
                    }
                } catch {
                    guard let self,self.streamID==epoch else { return }
                    self.liveReady=false;self.liveFinished=true;self.notice="实时字幕已断开，完整录音仍在本机保存。"
                    if self.recording {
                        try? await Task.sleep(for:.seconds(2))
                        if self.recording && self.streamID==epoch { await self.openLive(api:api,sid:sid) }
                    }
                }
            }
        } catch { notice="实时字幕连接失败，完整录音仍在保存。" }
    }
    private var liveOrder:[String]=[]
    private var liveText:[String]=[]
    private func sendFrame(_ data:Data) {
        guard liveReady,let task=socket,recording else { return }
        guard bufferCount<32 else { notice="网络发送较慢，部分实时字幕缺失；录后精转写会使用完整文件。";return }
        let seq=nextSequence;nextSequence+=1;bufferCount+=1
        let epoch=streamID;let previous=sendTail
        sendTail=Task { [weak self] in
            await previous?.value
            guard let self,self.streamID==epoch else { return }
            defer { self.bufferCount=max(0,self.bufferCount-1) }
            do { try await task.send(.string(String(data:JSONSerialization.data(withJSONObject:["seq":seq,"audio":data.base64EncodedString()]),encoding:.utf8)!)) }
            catch { self.liveReady=false;self.notice="实时音频发送中断，文件仍保留。" }
        }
    }
    func finishCapture() async {
        guard !finishing else { return };finishing=true;defer{finishing=false}
        engine?.inputNode.removeTap(onBus:0);engine?.stop();engine=nil
        let wasRecording=recording;recording=false;clock?.cancel();clock=nil
        if wasRecording { seconds=Int(Date().timeIntervalSince(started)) }
        await sendTail?.value
        if let task=socket,liveReady {
            try? await task.send(.string("{\"type\":\"finish\"}"))
            for _ in 0..<40 { if liveFinished { break };try? await Task.sleep(for:.milliseconds(500)) }
        }
        liveReady=false;receiver?.cancel();socket?.cancel(with:.normalClosure,reason:nil);socket=nil
        try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)
        if let sid=sessionID,let i=pending.firstIndex(where:{$0.id==sid}) { pending[i].milliseconds=max(1,seconds*1000);persistPending() }
    }
    func finishAndUpload() async {
        await finishCapture()
        if !voiceMessage,let api=connection,let sid=sessionID,let item=pending.first(where:{$0.id==sid}) { await upload(item,api:api) }
    }
    func sendVoice(store:Store) async {
        await finishCapture()
        guard let api=connection,let threadID=voiceThreadID,!preview.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { notice="没有识别到可发送的文字；录音已保存，可用文字继续。";return }
        guard identity(api)==identity(store.api) else { notice="请返回语音开始时的后端连接再发送。";return }
        guard preview.count<=12000 else { notice="语音文字较长，请分段发送；原文已保留。";return }
        do {
            let _:AgentTask=try await api.call("/v1/chat/threads/"+threadID+"/tasks",method:"POST",body:["content":preview,"client_request_id":voiceRequestID])
            if store.chatThread?.id==threadID { try await store.loadChat(threadID) }
            notice="语音已发送到开始说话时的项目空间。"
        } catch { notice=error.localizedDescription }
    }
    func upload(_ item:PendingRecording,api:API) async {
        guard !uploading,identity(api)==item.backendIdentity else { notice="请连接录音创建时的后端账号后上传。";return }
        uploading=true;defer { uploading=false }
        do {
            try await api.upload(URL(fileURLWithPath:item.path),session:item.id,durationMS:item.milliseconds)
            pending.removeAll { $0.id==item.id };persistPending();notice="音频已入库，正在精转写和整理。"
        } catch { notice=error.localizedDescription }
    }
    func stopPlayback() { if let (api,id)=ttsJob { speechCancel=Task { _=try? await api.raw("/v1/business-jobs/"+id+"/cancel",method:"POST") };ttsJob=nil };playback?.cancel();playback=nil;player?.stop();player=nil;playing=false;paused=false }
    func pausePlayback() { paused.toggle();if paused { player?.pause() } else { player?.play() } }
    func speak(_ message:ChatMessage,api:API) {
        stopPlayback();notice=nil;completedClips=[]
        playback=Task { [weak self] in
            guard let self else { return }
            do {
                await self.speechCancel?.value
                try Task.checkCancellation()
                let job:BusinessJob=try await api.call("/v1/chat/messages/"+message.id+"/speak",method:"POST")
                self.ttsJob=(api,job.id)
                for _ in 0..<600 {
                    try Task.checkCancellation()
                    let current:BusinessJob=try await api.call("/v1/business-jobs/"+job.id)
                    if current.status=="failed" || current.status=="interrupted" || current.status=="cancelled" { throw PrototypeError.message(current.error ?? "播报处理未完成，文字仍可阅读。") }
                    let outputs:[SpeechClip]=try await api.all("/v1/speech-clips?job_id="+job.id)
                    for clip in outputs.sorted(by:{$0.part<$1.part}) where !self.completedClips.contains(clip.id) {
                        try Task.checkCancellation()
                        let raw=try await api.raw("/v1/speech/"+clip.id)
                        let session=AVAudioSession.sharedInstance();try session.setCategory(.playback,mode:.spokenAudio);try session.setActive(true)
                        self.player=try AVAudioPlayer(data:raw);self.player?.play();self.playing=true
                        while self.player?.isPlaying == true || self.paused { try Task.checkCancellation();try await Task.sleep(for:.milliseconds(100)) }
                        self.completedClips.insert(clip.id)
                    }
                    if current.status=="completed" { self.ttsJob=nil;self.playing=false;return }
                    try await Task.sleep(for:.milliseconds(500))
                }
                throw PrototypeError.message("播报处理超时，文字仍可阅读。")
            } catch is CancellationError { self.playing=false }
            catch { self.notice=error.localizedDescription;self.playing=false }
        }
    }
}
struct SpeechClip:Decodable,Identifiable { var id:String;var part:Int }

struct SpeechToolbar:View {
    @EnvironmentObject var store:Store
    @ObservedObject var speech:SpeechController
    @State private var library=false
    @State private var consent=false
    @State private var modeVoice=false
    @State private var voicePreview=false
    private var phoneMeetingEnabled:Bool {
        #if DEBUG
        return store.capabilities?.recording_mode != "device"
        #else
        return false
        #endif
    }
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            if speech.finishing || speech.uploading { HStack { ProgressView();Text(speech.finishing ? "正在结束录音并接收最后字幕…":"正在保存音频到资料库…").font(.caption) } }
            if speech.recording {
                HStack {
                    Label(speech.voiceMessage ? "语音消息":"手机录音 · 开发入口",systemImage:"record.circle").foregroundStyle(Warm.purple)
                    Text("\(speech.seconds/60):\(String(format:"%02d",speech.seconds%60))").monospacedDigit()
                    Spacer()
                    Button("结束") { Task { if speech.voiceMessage { await speech.finishCapture();voicePreview=true } else { await speech.finishAndUpload() } } }.frame(minHeight:44)
                }.font(.caption)
                if !speech.preview.isEmpty { Text(speech.preview).font(.caption).lineLimit(2) }
            } else {
                HStack {
                    Button { library=true } label: { Label("录音库",systemImage:"waveform") }
                    Spacer()
                    Button { modeVoice=false;if UserDefaults.standard.bool(forKey:"recording-informed") && phoneMeetingEnabled { Task { await speech.start(store:store,voice:false) } } else { consent=true } } label: { Label(phoneMeetingEnabled ? "开始录音":"设备录音",systemImage:"record.circle") }
                    Button { modeVoice=true;Task { await speech.start(store:store,voice:true) } } label: { Image(systemName:"mic") }.accessibilityLabel("语音消息")
                }.font(.caption).frame(minHeight:44)
            }
            if speech.playing { HStack { Button("暂停/继续") { speech.pausePlayback() };Button("停止播报") { speech.stopPlayback() } }.font(.caption).frame(minHeight:44) }
            if let notice=speech.notice { Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
        }.padding(.horizontal,22).disabled(speech.finishing || speech.uploading)
        .sheet(isPresented:$library) { RecordingLibrary(speech:speech).environmentObject(store) }
        .sheet(isPresented:$voicePreview) { NavigationStack { VStack { TextEditor(text:$speech.preview).padding();Button("发送到原空间") { Task { await speech.sendVoice(store:store);voicePreview=false } }.buttonStyle(.borderedProminent).padding() }.navigationTitle("语音消息").toolbar { Button("保留文字") { store.saveVoiceDraft(speech.preview,threadID:speech.voiceThreadID);voicePreview=false } } } }
        .confirmationDialog("开始沟通录音前，请确保参与者知情并同意。音频将发送到已配置的模型服务进行转写和整理。",isPresented:$consent,titleVisibility:.visible) {
            if phoneMeetingEnabled { Button("已告知并同意，开始录音") { UserDefaults.standard.set(true,forKey:"recording-informed");Task { await speech.start(store:store,voice:modeVoice) } } }
            Button("连接安克设备") { library=true }
            Button("取消",role:.cancel) { }
        }
    }
}

struct RecordingLibrary:View {
    @EnvironmentObject var store:Store
    @ObservedObject var speech:SpeechController
    @Environment(\.dismiss) private var dismiss
    @State private var rows:[RecordingRecord]=[]
    @State private var filter=""
    @State private var error:String?
    var body:some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink("连接安克设备") { SoundcoreDeviceView(device:store.soundcore) }
                    NavigationLink("设备录音与同步") { GlobalDeviceRecordings(device:store.soundcore,speech:speech).environmentObject(store) }
                    Text("全部录音统一保存，通过标签关联空间。正式会议录音使用安克设备。").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
                if !speech.pending.isEmpty {
                    Section("本机待上传 · 文件已保留") {
                        ForEach(speech.pending) { item in
                            VStack(alignment:.leading) {
                                Text("\(item.milliseconds/60000) 分钟录音").font(.subheadline)
                                Button("继续上传") { Task { await speech.upload(item,api:store.api); await reload() } }.disabled(speech.uploading)
                            }
                        }
                    }
                }
                if rows.isEmpty { Text("还没有录音。新录音不需要选择项目空间。").foregroundStyle(.secondary) }
                ForEach(rows) { row in
                    NavigationLink { RecordingDetail(recordID:row.id).environmentObject(store) } label: {
                        VStack(alignment:.leading,spacing:5) {
                            Text(row.started_at?.prefix(19).replacingOccurrences(of:"T",with:" ") ?? "沟通录音")
                            Text((row.tags ?? []).map(\.label).joined(separator:" · ")).font(.caption).foregroundStyle(Warm.purple)
                            Text(recordingStatus(row.pipeline_status)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.searchable(text:$filter,prompt:"客户、项目或主题标签")
                .navigationTitle("录音库").toolbar { Button("完成") { dismiss() } }
                .refreshable { await reload() }.onChange(of:filter) { _,_ in Task { await reload() } }
        }.task {
            while !Task.isCancelled { await reload();try? await Task.sleep(for:.seconds(5)) }
        }
    }
    private func reload() async {
        do { rows=try await store.api.all("/v1/recordings"+(filter.isEmpty ? "":"?tag="+filter.addingPercentEncoding(withAllowedCharacters:.urlQueryAllowed)!));error=nil }
        catch { self.error=error.localizedDescription }
    }
}
func recordingStatus(_ status:String) -> String {
    switch status { case "done":return "已整理";case "transcribed":return "转写完成，正在整理";case "queued":return "等待精转写";case "recording":return "正在录音";default:return "资料已保留，可查看处理进度" }
}
struct RecordingDetail:View {
    @EnvironmentObject var store:Store
    let recordID:String
    @State private var record:RecordingRecord?
    @State private var label=""
    @State private var workspace=""
    @State private var error:String?
    @State private var editing:RecordingTag?
    @State private var selectedSpeakers:Set<String>=[]
    @State private var editingTranscript=false
    var body:some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            if let record {
                Section {
                    Button("回听完整录音") { Task { do { try await store.playRecording(recordID) } catch { self.error=error.localizedDescription } } }
                    Button("停止回听") { store.stopPlayback() }
                }
                Section("资料") {
                    ForEach(record.knowledge ?? []) { item in Text(item.text).textSelection(.enabled) }
                    if (record.knowledge ?? []).isEmpty { Text("资料整理完成后，会显示总结、复盘和待核实事项。").foregroundStyle(.secondary) }
                }
                Section("标签 · 自动生效，可随时修改") {
                    ForEach(record.tags ?? []) { tag in
                        tagRow(tag)
                    }
                    TextField("添加标签",text:$label)
                    Picker("关联空间（可选）",selection:$workspace) { Text("不关联").tag("");ForEach(store.projectSpaces) { space in Text(space.name).tag(space.id) } }
                    Button("添加") { Task { do {
                        var body:[String:Any]=["label":label,"kind":"project"]
                        if !workspace.isEmpty { body["workspace_id"]=workspace }
                        _=try await store.api.raw("/v1/recordings/"+recordID+"/tags",method:"POST",body:body);label="";await reload()
                    } catch { self.error=error.localizedDescription } } }.disabled(label.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
                if !(record.segments ?? []).isEmpty {
                    Section("本人说话人 · 仅用于个人经历归属") {
                        Text("长录音跨段的编号分别保存；只有你选择的片段才归属于本人。").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(Set((record.segments ?? []).compactMap(\.speaker_id))).sorted(),id:\.self) { sid in
                            Toggle(sid,isOn:Binding(get:{selectedSpeakers.contains(sid)},set:{if $0 { selectedSpeakers.insert(sid) } else { selectedSpeakers.remove(sid) }}))
                        }
                        Button("保存本人身份") { Task { do {
                            _=try await store.api.raw("/v1/recordings/"+recordID+"/self-speaker",method:"PUT",body:["speaker_ids":Array(selectedSpeakers),"expected_revision":record.transcript_revision ?? 1]);await reload()
                        } catch { self.error=error.localizedDescription } } }.disabled(selectedSpeakers.isEmpty)
                    }
                    Section("转写原文") {
                        Button("修正转写") { editingTranscript=true }
                        ForEach(record.segments ?? []) { s in
                            VStack(alignment:.leading,spacing:4) {
                                Text("\(s.start_ms/1000)s – \(s.end_ms/1000)s · \(s.speaker == "self" ? "本人":s.speaker_id ?? "未知说话人")").font(.caption).foregroundStyle(.secondary)
                                Text(s.text).textSelection(.enabled)
                                Button("回听片段") { Task { do { try await store.playRecording(recordID,startMS:s.start_ms,endMS:s.end_ms) } catch { self.error=error.localizedDescription } } }.font(.caption)
                            }
                        }
                    }
                }
                Section("处理进度") {
                    ForEach(record.jobs ?? []) { job in
                        VStack(alignment:.leading) {
                            Text(job.progress ?? "处理中").font(.subheadline)
                            if let issue=job.error { Text(issue).font(.caption).foregroundStyle(.secondary) }
                            if ["failed","interrupted","cancelled"].contains(job.status) { Button("继续处理") { Task { do { _=try await store.api.raw("/v1/business-jobs/"+job.id+"/retry",method:"POST");await reload() } catch { self.error=error.localizedDescription } } } }
                            if ["queued","running"].contains(job.status) { Button("停止等待") { Task { do { _=try await store.api.raw("/v1/business-jobs/"+job.id+"/cancel",method:"POST");await reload() } catch { self.error=error.localizedDescription } } } }
                        }
                    }
                }
            } else { ProgressView() }
        }.navigationTitle("沟通录音")
            .sheet(item:$editing) { tag in TagEditor(tag:tag,save:{ name,wid in Task { await update(tag,label:name,active:true,workspace:wid) } },spaces:store.projectSpaces) }
            .sheet(isPresented:$editingTranscript) { if let record { TranscriptEditor(record:record).environmentObject(store) } }
            .task { while !Task.isCancelled { await reload();try? await Task.sleep(for:.seconds(4)) } }
    }
    private func tagRow(_ tag:RecordingTag) -> some View {
        HStack {
            VStack(alignment:.leading) { Text(tag.label);Text(tag.source == "ai" ? "AI 自动":"手动").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("修改") { editing=tag }
            Button("移除") { Task { await update(tag,label:tag.label,active:false,workspace:tag.workspace_id) } }.foregroundStyle(.secondary)
        }
    }
    private func reload() async {
        do {
            record=try await store.api.call("/v1/recordings/"+recordID)
            if selectedSpeakers.isEmpty { selectedSpeakers=Set((record?.segments ?? []).filter{$0.speaker=="self"}.compactMap(\.speaker_id)) }
        } catch { self.error=error.localizedDescription }
    }
    private func update(_ tag:RecordingTag,label:String,active:Bool,workspace:String?) async {
        do {
            var body:[String:Any]=["label":label,"kind":tag.kind,"active":active,"expected_revision":tag.revision]
            if let workspace { body["workspace_id"]=workspace } else { body["workspace_id"]=NSNull() }
            _=try await store.api.raw("/v1/recording-tags/"+tag.id,method:"PATCH",body:body);await reload()
        } catch { self.error=error.localizedDescription }
    }
}
struct TagEditor:View {
    let tag:RecordingTag;let save:(String,String?)->Void;let spaces:[ProjectSpace]
    @Environment(\.dismiss) private var dismiss
    @State private var name="";@State private var workspace=""
    var body:some View { NavigationStack { Form {
        TextField("标签名称",text:$name)
        Picker("空间",selection:$workspace) { Text("不关联").tag("");ForEach(spaces) { s in Text(s.name).tag(s.id) } }
    }.navigationTitle("修改标签").toolbar { Button("保存") { save(name,workspace.isEmpty ? nil:workspace);dismiss() }.disabled(name.isEmpty) } }.onAppear { name=tag.label;workspace=tag.workspace_id ?? "" } }
}
struct TranscriptEditor:View {
    @EnvironmentObject var store:Store
    @Environment(\.dismiss) private var dismiss
    let record:RecordingRecord
    @State private var texts:[String:String]=[:]
    @State private var error:String?
    var body:some View { NavigationStack { List {
        Text("修正会生成新版本，原始转写保留，录音资料重新整理。").font(.caption)
        if let error { Text(error).foregroundStyle(.red) }
        ForEach(record.segments ?? []) { s in TextField("原文",text:Binding(get:{texts[s.id] ?? s.text},set:{texts[s.id]=$0}),axis:.vertical) }
    }.navigationTitle("修正转写").toolbar { Button("保存") { Task { do {
        let segments=(record.segments ?? []).map { s -> [String:Any] in
            var body:[String:Any]=["text":texts[s.id] ?? s.text,"start_ms":s.start_ms,"end_ms":s.end_ms,"speaker":s.speaker]
            if let speakerID=s.speaker_id { body["speaker_id"]=speakerID };return body
        }
        _=try await store.api.raw("/v1/recordings/"+record.id+"/transcript",method:"PUT",body:["expected_revision":record.transcript_revision ?? 1,"segments":segments]);dismiss()
    } catch { self.error=error.localizedDescription } } } } } }
}
struct MaterialIntake:View {
    @EnvironmentObject var store:Store
    @Environment(\.dismiss) private var dismiss
    let workspaceID:String
    @State private var text="";@State private var link="";@State private var title=""
    @State private var importing=false;@State private var busy=false;@State private var error:String?
    var body:some View { NavigationStack { Form {
        TextField("标题（可选）",text:$title)
        TextEditor(text:$text).frame(minHeight:180).accessibilityLabel("资料正文")
        TextField("公开网页链接（可选）",text:$link).keyboardType(.URL).textInputAutocapitalization(.never)
        Text("链接先保存；Agent 可以按需通过已接入的调研工具读取。扫描PDF需要先转成文字版。").font(.caption)
        Button("导入 PDF") { importing=true }
        if busy { ProgressView() }
        if let error { Text(error).foregroundStyle(.red) }
    }.navigationTitle("补充资料").toolbar {
        Button("保存") { Task { busy=true;defer{busy=false};do {
            var body:[String:Any]=["workspace_id":workspaceID,"title":title.isEmpty ? "补充资料":title,"text":text]
            if !link.isEmpty { body["url"]=link }
            _=try await store.api.raw("/v1/materials",method:"POST",body:body);dismiss()
        } catch { self.error=error.localizedDescription } } }.disabled(busy || (text.isEmpty && link.isEmpty))
    }.fileImporter(isPresented:$importing,allowedContentTypes:[.pdf]) { result in
        Task { busy=true;defer{busy=false};do {
            let file=try result.get();let access=file.startAccessingSecurityScopedResource();defer { if access { file.stopAccessingSecurityScopedResource() } }
            _=try await store.api.uploadPDF(file,workspaceID:workspaceID,title:title.isEmpty ? file.lastPathComponent:title);dismiss()
        } catch { self.error=error.localizedDescription } }
    } } }
}
struct PersonalMemoryRecord:Decodable,Identifiable {
    var id:String;var title:String;var text:String;var version:Int;var status:String;var general_personal:Bool
    var archive_workspace_id:String;var confirmation_mode:String
    var evidence_refs:[PersonalMemoryEvidence]
}
struct PersonalMemoryEvidence:Decodable { var source_id:String;var quote:String? }
struct PersonalMemories:View {
    @EnvironmentObject var store:Store
    @State private var rows:[PersonalMemoryRecord]=[];@State private var editing:PersonalMemoryRecord?;@State private var error:String?
    var body:some View { List {
        Text("归档自动提取，有原文依据。通用个人内容可跨空间复用，客户资料保留范围。").font(.caption)
        if let error { Text(error).foregroundStyle(.red) }
        ForEach(rows.filter{$0.status=="confirmed"}) { row in
            VStack(alignment:.leading,spacing:8) {
                Text(row.title).font(.headline);Text(row.text).textSelection(.enabled)
                Text(row.general_personal ? "归档自动确认 · 通用个人资料":"归档自动确认 · 原空间资料").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("查看原始依据") {
                    ForEach(Array(row.evidence_refs.enumerated()),id:\.offset) { _,reference in
                        Text(reference.quote ?? "原始片段").font(.subheadline).textSelection(.enabled)
                    }
                    Text("来自空间："+(store.projectSpaces.first(where:{$0.id==row.archive_workspace_id})?.name ?? "已归档空间")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("修改") { editing=row }
                    Button("撤回") { Task { do { _=try await store.api.raw("/v1/personal-memories/"+row.id,method:"PATCH",body:["expected_version":row.version,"status":"withdrawn"]);await reload() } catch { self.error=error.localizedDescription } } }
                }
            }
        }
    }.navigationTitle("个人记忆").task { await reload() }.sheet(item:$editing,onDismiss:{Task{await reload()}}) { row in PersonalMemoryEditor(record:row).environmentObject(store) } }
    private func reload() async { do { rows=try await store.api.all("/v1/personal-memories") } catch { self.error=error.localizedDescription } }
}
struct PersonalMemoryEditor:View {
    @EnvironmentObject var store:Store;@Environment(\.dismiss) private var dismiss
    let record:PersonalMemoryRecord
    @State private var text="";@State private var error:String?
    var body:some View { NavigationStack { Form { TextEditor(text:$text).frame(minHeight:200);if let error {Text(error).foregroundStyle(.red)} }
        .navigationTitle("修改记忆").toolbar { Button("保存") { Task { do {
            _=try await store.api.raw("/v1/personal-memories/"+record.id,method:"PATCH",body:["expected_version":record.version,"text":text]);dismiss()
        } catch { self.error=error.localizedDescription } } }.disabled(text.isEmpty) } }.onAppear{text=record.text} }
}

struct GlobalDeviceRecordings:View {
    @EnvironmentObject var store:Store
    @ObservedObject var device:Soundcore
    @ObservedObject var speech:SpeechController
    @State private var error:String?
    @State private var working=false
    @State private var agreed=false
    @State private var fileID:Int32?
    var body:some View {
        List {
            Section {
                Text(device.status).font(.subheadline)
                Text("请按设备按钮开始或结束录音；App 支持暂停、继续和同步。实时字幕只在设备发出实时传输通知后开启。").font(.caption).foregroundStyle(.secondary)
                Toggle("参与者已知情并同意，允许转写和整理",isOn:$agreed)
                Button(device.recordStatus==2 ? "继续设备录音":"暂停设备录音") { device.pauseOrResume() }.disabled(device.recordStatus==0)
                Button("开启设备实时字幕") { Task { await speech.startDevice(store:store,device:device) } }.disabled(!agreed || !device.realtimeReady || speech.recording)
                Button("刷新设备文件") { device.refreshFiles() }.disabled(working)
            }
            if let error { Text(error).foregroundStyle(.red) }
            if working { ProgressView(value:device.progress) }
            ForEach(device.files) { file in
                HStack { VStack(alignment:.leading) { Text(file.title);Text("\(file.durationMS/60000) 分钟").font(.caption) };Spacer()
                    Button("同步") { importFile(file) }.disabled(!agreed || working || device.recordStatus != 0)
                }
            }
        }.navigationTitle("安克设备录音").onAppear { device.refreshFiles() }
    }
    private func importFile(_ file:SoundcoreFile) {
        working=true;error=nil
        Task { defer{working=false};do {
            let sid:String
            if let existing=DeviceRecordingMap.get(api:store.api,fileID:file.id,deviceID:device.connected?.uuid ?? "") { sid=existing }
            else {
                let session:RecordingRecord=try await store.api.call("/v1/recordings",method:"POST",body:["client_request_id":UUID().uuidString,
                    "recording_source":"soundcore","device_file_id":Int(UInt32(bitPattern:file.id)),"device_id":device.connected?.uuid ?? "",
                    "consent":"yes","consent_ack_text_version":"recording-consent@1"])
                sid=session.id;DeviceRecordingMap.set(sid,api:store.api,fileID:file.id,deviceID:device.connected?.uuid ?? "")
            }
            let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("Recordings")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let target=folder.appendingPathComponent(sid+".m4a")
            var duration=file.durationMS
            if !FileManager.default.fileExists(atPath:target.path) {
                let raw=try await device.download(file)
                duration=try await SoundcoreAudio.convert(raw:raw,destination:target)
                try? FileManager.default.removeItem(at:raw.deletingLastPathComponent())
            }
            speech.keepPending(id:sid,url:target,milliseconds:duration,api:store.api)
            await speech.upload(PendingRecording(id:sid,path:target.path,milliseconds:duration,backendIdentity:DeviceRecordingMap.identity(store.api)),api:store.api)
        } catch { self.error=error.localizedDescription } }
    }
}
enum DeviceRecordingMap {
    static func identity(_ api:API)->String { SHA256.hash(data:Data((api.base+"\n"+api.token).utf8)).map{String(format:"%02x",$0)}.joined() }
    static func key(api:API,fileID:Int32,deviceID:String)->String { "device-recording-"+identity(api)+deviceID+String(fileID) }
    static func get(api:API,fileID:Int32,deviceID:String)->String? { UserDefaults.standard.string(forKey:key(api:api,fileID:fileID,deviceID:deviceID)) }
    static func set(_ sid:String,api:API,fileID:Int32,deviceID:String) { UserDefaults.standard.set(sid,forKey:key(api:api,fileID:fileID,deviceID:deviceID)) }
}
final class DevicePCMDecoder {
    private var decoder:OpaquePointer?
    private var pending=Data()
    private var sequence:Int32?
    init() throws {
        var code:Int32=0;decoder=opus_decoder_create(16000,2,&code)
        guard decoder != nil,code==OPUS_OK else { throw PrototypeError.message("设备实时音频解码器不可用。") }
    }
    deinit { if let decoder { opus_decoder_destroy(decoder) } }
    func decode(_ raw:Data,sequence:Int32) throws -> (Data,Bool) {
        guard let decoder else { throw PrototypeError.message("设备解码器不可用") }
        if let previous=self.sequence,sequence<=previous { return (Data(),false) }
        let gap=self.sequence.map{sequence != $0+1} ?? false
        self.sequence=sequence
        if gap { pending.removeAll() }
        pending.append(raw);var mono=[Int16]()
        while pending.count>=160 {
            let packet=Data(pending.prefix(160));pending.removeFirst(160)
            var stereo=[Int16](repeating:0,count:640)
            let samples=packet.withUnsafeBytes { bytes in opus_decode(decoder,bytes.bindMemory(to:UInt8.self).baseAddress,160,&stereo,320,0) }
            guard samples==320 else { throw PrototypeError.message("设备实时音频格式与解码配置不一致，停止实时字幕；请同步完整录音。") }
            for i in 0..<320 { mono.append(Int16((Int32(stereo[i*2])+Int32(stereo[i*2+1]))/2)) }
        }
        return (mono.withUnsafeBytes{Data($0)},gap)
    }
}
extension SpeechController {
    func keepPending(id:String,url:URL,milliseconds:Int,api:API) {
        if !pending.contains(where:{$0.id==id}) { pending.append(PendingRecording(id:id,path:url.path,milliseconds:milliseconds,backendIdentity:identity(api)));persistPending() }
    }
    func startDevice(store:Store,device:Soundcore) async {
        guard !recording,!finishing,!uploading,device.realtimeReady,let fileID=device.currentFileID,let connected=device.connected else { notice="等待设备录音和实时传输通知后再开启。";return }
        store.stopPlayback();stopPlayback();preview="";liveOrder=[];liveText=[];notice=nil
        do {
            let api=store.api;let sid:String
            if let old=DeviceRecordingMap.get(api:api,fileID:fileID,deviceID:connected.uuid) { sid=old }
            else {
                let row:RecordingRecord=try await api.call("/v1/recordings",method:"POST",body:["client_request_id":UUID().uuidString,
                    "recording_source":"soundcore","device_file_id":Int(UInt32(bitPattern:fileID)),"device_id":connected.uuid,
                    "consent":"yes","consent_ack_text_version":"recording-consent@1"])
                sid=row.id;DeviceRecordingMap.set(sid,api:api,fileID:fileID,deviceID:connected.uuid)
            }
            let decoder=try DevicePCMDecoder();connection=api;sessionID=sid;voiceMessage=false;recording=true;started=Date();seconds=0
            await openLive(api:api,sid:sid)
            device.onLiveAudio={ [weak self] data,sequence in
                do {
                    let (pcm,gap)=try decoder.decode(data,sequence:sequence)
                    self?.seconds=device.durationMS/1000
                    if gap { self?.notice="设备实时传输有缺段，录后会使用完整同步文件。" }
                    if !pcm.isEmpty { self?.sendFrame(pcm) }
                } catch { self?.notice=error.localizedDescription;device.onLiveAudio=nil }
            }
            device.onRecordingEnded={ [weak self] in Task { await self?.finishCapture() } }
            try device.acquireLiveAudio()
        } catch { notice=error.localizedDescription;recording=false }
    }
}
struct DeviceLiveBanner:View {
    @ObservedObject var device:Soundcore
    @ObservedObject var speech:SpeechController
    var body:some View {
        if device.recordStatus != 0 {
            HStack { Label(device.recordStatus==2 ? "设备录音已暂停":"安克设备正在录音",systemImage:"waveform");Spacer();Text("\(device.durationMS/60000)分") }.font(.caption).padding(.horizontal,22)
        }
    }
}

struct PhoneDeviceAction:Decodable,Identifiable { var id:String;var action:String;var status:String }
extension Store {
    func observeDeviceActions() async {
        while !Task.isCancelled {
            if remote {
                let connection=api
                do {
                    let commands:[PhoneDeviceAction]=try await connection.all("/v1/device-actions")
                    for command in commands {
                        let claimed:PhoneDeviceAction=try await connection.call("/v1/device-actions/"+command.id+"/claim",method:"POST")
                        guard claimed.status=="running" else { continue }
                        var result="unavailable";var note="设备未连接或真机权限不可用"
                        if soundcore.connected != nil {
                            if command.action=="status" { result="executed";note="读取手机已收到的设备状态" }
                            else {
                                let desired:Int32=command.action=="pause" ? 2:1
                                let original:Int32=command.action=="pause" ? 1:2
                                if soundcore.recordStatus==desired { result="executed";note="设备已处于目标状态" }
                                else if soundcore.recordStatus==original {
                                    soundcore.pauseOrResume()
                                    for _ in 0..<50 { if soundcore.recordStatus==desired { break };try await Task.sleep(for:.milliseconds(100)) }
                                    result=soundcore.recordStatus==desired ? "executed":"failed"
                                    note=result=="executed" ? "已收到设备状态回执":"未收到目标状态，无法确认执行"
                                } else { result="failed";note="设备未在录音，动作无法执行" }
                            }
                        }
                        _=try await connection.raw("/v1/device-actions/"+command.id+"/receipt",method:"POST",body:["status":result,"recording_status":Int(soundcore.recordStatus),"note":note])
                    }
                } catch { /* Receipt loss never causes automatic replay of a claimed device command. */ }
            }
            try? await Task.sleep(for:.seconds(2))
        }
    }
}
