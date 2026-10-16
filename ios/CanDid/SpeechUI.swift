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
    var speaker: String; var speaker_id: String?;var speaker_name:String?
}
struct RecordingKnowledge: Decodable, Identifiable {
    var id: String; var title: String; var text: String
    var review: RecordingReview?; var evidence_refs: [RecordingEvidence]?
}
struct RecordingReview: Decodable {
    var strengths: [String] = []; var improvements: [String] = []; var open_questions: [String] = []; var next_steps: [String] = []
    enum CodingKeys: String, CodingKey { case strengths, improvements, open_questions, next_steps }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func strings(_ key: CodingKeys) -> [String] {
            if let rows = try? values.decode([String].self, forKey: key) { return rows }
            if let rows = try? values.decode([[String:String]].self, forKey: key) {
                return rows.compactMap { $0["text"] ?? $0["suggestion"] ?? $0["content"] }
            }
            return []
        }
        strengths = strings(.strengths); improvements = strings(.improvements); open_questions = strings(.open_questions);next_steps = strings(.next_steps)
    }
}
struct RecordingEvidence: Decodable { var source_id: String; var start_ms: Int?; var end_ms: Int? }
struct RecordingRecord: Decodable, Identifiable {
    var id: String; var started_at: String?; var pipeline_status: String; var recording_source: String?
    var tags: [RecordingTag]?; var segments: [RecordingSentence]?; var knowledge: [RecordingKnowledge]?
    var jobs: [BusinessJob]?; var transcript_revision: Int?
    var marks:[RecordingMark]?
    var duration_ms: Int?; var title: String?; var kind: String?; var fixture: Bool?; var device_file_id: Int?
    var customer_workspace_id:String?;var customer_confirmed_at:String?;var customer_assignment_revision:Int?
}
struct RecordingMark:Decodable,Identifiable {var id:String;var t_ms:Int;var user_label:String?}
struct LiveRecordingSentence: Identifiable {
    var id: String; var text: String; var startMS: Int; var stable: Bool
}
enum LiveCaptionState { case idle, connecting, ready, reconnecting, unavailable, finished }
struct DeviceCaptureReference: Codable {
    var sessionID: String; var fileID: Int32; var deviceID: String; var backendIdentity: String
}
struct PendingRecording: Codable, Identifiable {
    var id: String; var path: String; var milliseconds: Int; var backendIdentity: String
}

enum SpeechPlaybackState:String {case idle,preparing,playing,paused,failed}

@MainActor final class SpeechController: ObservableObject {
    @Published var recording = false
    @Published var voiceMessage = false
    @Published var seconds = 0
    @Published var preview = ""
    @Published var notice: String?
    @Published var uploading = false
    @Published var finishing = false
    @Published var playing = false
    @Published private(set) var playbackState:SpeechPlaybackState = .idle
    @Published private(set) var spokenMessage:ChatMessage?
    var hasSpeechPlayback:Bool {playbackState != .idle}
    private var playbackGeneration=UUID()
    private var backgroundObserver:NSObjectProtocol?
    @Published var pending: [PendingRecording] = []
    @Published var liveSentences: [LiveRecordingSentence] = []
    @Published var liveRevision = 0
    @Published var captionState: LiveCaptionState = .idle
    @Published var hasCaptionGap = false
    @Published var meetingID: String?
    @Published var meetingSource: String?
    @Published var meetingPreparing = false
    @Published var meetingSyncing = false
    @Published var phonePaused = false
    @Published var devicePaused = false
    @Published var meetingProgress: String?
    @Published var deviceRecordingUncertain = false
    private var trackedDevice: DeviceCaptureReference?
    private var automaticDeviceSync = false
    private var totalPauseSeconds: TimeInterval = 0
    private var pausedAt: Date?
    private var streamOffsetMS = 0
    private var deviceLiveBlocked = false
    private var audioLease:UUID?
    private var playbackLease:UUID?
    private weak var audioResources:AudioResources?
    private var liveFatalError=false
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
    private var liveQueue:[Data]=[]
    private var liveQueueBytes=0
    private var liveStartupAllowance=0
    private var liveReconnects=0
    private var completedClips: Set<String> = []
    private var clipQueue: [String] = []
    private var finishedPlaying = false
    private var paused = false
    private var pendingPath: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("PendingRecordings.json")
    }
    init() {
        pending = (try? Data(contentsOf: pendingPath)).flatMap { try? JSONDecoder().decode([PendingRecording].self,from:$0) } ?? []
        if let data = UserDefaults.standard.data(forKey: "candid-device-capture") {
            trackedDevice = try? JSONDecoder().decode(DeviceCaptureReference.self, from: data)
        }
        interruptedObserver=NotificationCenter.default.addObserver(forName:AVAudioSession.interruptionNotification,object:nil,queue:.main) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                if (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) != AVAudioSession.InterruptionType.began.rawValue {return}
                self.pauseSpeechPlayback()
                if self.recording && self.meetingSource != "soundcore" {
                    await self.finishCapture(); self.notice="录音被系统打断，已保存本机文件，可继续上传。"
                }
            }
        }
        backgroundObserver=NotificationCenter.default.addObserver(forName:UIApplication.didEnterBackgroundNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.pauseSpeechPlayback() }
        }
        routeObserver=NotificationCenter.default.addObserver(forName:AVAudioSession.routeChangeNotification,object:nil,queue:.main) { [weak self] notification in
            let reason=(notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.pauseSpeechPlayback() }
            }
        }
    }
    private func identity(_ api: API) -> String { SHA256.hash(data:Data((api.base+"\n"+api.token).utf8)).map { String(format:"%02x",$0) }.joined() }
    private func persistPending() {
        try? FileManager.default.createDirectory(at:pendingPath.deletingLastPathComponent(),withIntermediateDirectories:true)
        if let data=try? JSONEncoder().encode(pending) { try? data.write(to:pendingPath,options:[.atomic,.completeFileProtection]) }
    }
    // The cloud migration preserves the signing key and owner database. Rebind
    // local upload/device references only after the same credential authenticates.
    func migrateCloudReferences(to api:API,previousToken:String) {
        guard !previousToken.isEmpty,previousToken==api.token else{return}
        let destination=identity(api)
        for base in BackendConfiguration.previousCloudBaseURLs where base != api.base {
            let old=identity(API(base:base,token:previousToken))
            for index in pending.indices where pending[index].backendIdentity==old {pending[index].backendIdentity=destination}
            if trackedDevice?.backendIdentity==old {
                trackedDevice?.backendIdentity=destination
                if let data=try? JSONEncoder().encode(trackedDevice) {UserDefaults.standard.set(data,forKey:"candid-device-capture")}
            }
            let prefix="device-recording-"+old
            for (key,value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix(prefix) {
                UserDefaults.standard.set(value,forKey:"device-recording-"+destination+String(key.dropFirst(prefix.count)))
            }
        }
        persistPending()
    }
    func start(store: Store, voice: Bool) async {
        guard !recording,!finishing,!uploading,!meetingPreparing,!meetingSyncing, store.remote else { notice="请先连接后端，或等待当前录音处理。"; return }
        guard voice || store.soundcore.recordStatus == 0 else { notice="设备正在录音，请使用设备完成本场录音。"; return }
        if !voice && !store.cloudStorageAllowed { notice="请先确认录音保存与处理许可。"; return }
        meetingPreparing=true;defer { meetingPreparing=false }
        if store.voice.active {store.voice.stopAnswer()};store.stopPlayback();stopPlayback(); notice=nil; preview=""; finalSentences=[:]; liveOrder=[];liveText=[]; partial=""; seconds=0
        liveSentences=[];liveRevision+=1;captionState = .idle;hasCaptionGap=false
        phonePaused=false;pausedAt=nil;totalPauseSeconds=0
        deviceRecordingUncertain=false
        let permitted=await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning:$0) }
        }
        guard permitted else { notice="麦克风权限未开启，请到系统设置允许录音。"; return }
        let api=store.api
        do {
            connection=api; voiceMessage=voice;voiceRequestID=UUID().uuidString; voiceThreadID=store.chatThread?.id
            if voice {
                guard voiceThreadID != nil else { throw PrototypeError.message("请先新建或选择项目空间。") }
                sessionID=nil;meetingSource=nil;meetingID=nil
            } else {
                let session: RecordingRecord=try await api.call("/v1/recordings",method:"POST",body:[
                    "client_request_id":UUID().uuidString,"recording_source":"iphone","consent":"yes","consent_ack_text_version":"recording-consent@1","customer_assignment_required":true])
                sessionID=session.id;meetingID=session.id;meetingSource="iphone";meetingProgress=nil
            }
            let identifier=sessionID ?? UUID().uuidString
            let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("Recordings")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let url=folder.appendingPathComponent(identifier+".m4a");fileURL=url
            audioResources=store.audio;audioLease=try store.audio.acquire(.meeting)
            let microphone=VoiceCapture.shared
            guard let format=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:true) else{throw PrototypeError.message("麦克风音频格式不可用。")}
            // AAC's supported bitrate range depends on sample rate and channel count.
            // 64 kbps at 16 kHz mono fails with kAudioCodecUnsupportedFormatError (!dat).
            let file:AVAudioFile
            do {
                file=try AVAudioFile(forWriting:url,settings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:16000,AVNumberOfChannelsKey:1,AVEncoderBitRateKey:32000],commonFormat:.pcmFormatInt16,interleaved:true)
            } catch {
                throw PrototypeError.message("手机录音文件无法初始化，请重试。错误码：\((error as NSError).code)")
            }
            try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.path)
            recording=true;started=Date();microphone.setMeetingPaused(false)
            if let sid=sessionID {pending.append(PendingRecording(id:sid,path:url.path,milliseconds:0,backendIdentity:identity(api)));persistPending()}
            microphone.onMeetingFrame={ [weak self] pcm in
                guard let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(pcm.count/2)),let ptr=buffer.int16ChannelData?[0] else{return}
                buffer.frameLength=AVAudioFrameCount(pcm.count/2)
                pcm.withUnsafeBytes{bytes in if let base=bytes.baseAddress {memcpy(ptr,base,pcm.count)}}
                do {try file.write(from:buffer)} catch {DispatchQueue.main.async {self?.notice="本机写入失败，已保留录音。";Task {await self?.finishCapture()}};return}
                DispatchQueue.main.async {self?.sendFrame(pcm)}
            }
            try microphone.start(voiceProcessing:voice || store.audio.voiceActive);await openLive(api:api,sid:sessionID)
            clock=Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for:.seconds(1))
                    guard let self,self.recording else { return }
                    if !self.phonePaused { self.seconds=self.phoneElapsedSeconds }
                    if self.seconds>=3 && VoiceCapture.shared.capturedPCMBytes==0 {
                        self.notice="麦克风没有送出音频，请结束后重试；空录音不会上传。"
                    }
                    if let sid=self.sessionID,let i=self.pending.firstIndex(where:{$0.id==sid}) { self.pending[i].milliseconds=self.seconds*1000; self.persistPending() }
                }
            }
        } catch { notice=error.localizedDescription; await finishCapture() }
    }
    private func openLive(api: API,sid: String?) async {
        receiver?.cancel();sendTail?.cancel();sendTail=nil;socket?.cancel(with:.goingAway,reason:nil)
        let epoch=UUID();streamID=epoch;nextSequence=0;liveReady=false;liveFinished=false;liveFatalError=false
        liveQueue=[];liveQueueBytes=0;liveStartupAllowance=0
        captionState = liveSentences.isEmpty ? .connecting : .reconnecting
        streamOffsetMS=seconds*1000
        let offsetMS=streamOffsetMS
        do {
            var components=URLComponents(url:try api.url("/v1/speech/live"),resolvingAgainstBaseURL:false)!
            components.scheme=components.scheme=="https" ? "wss":"ws"
            let task=URLSession.shared.webSocketTask(with:components.url!);socket=task;task.resume()
            var hello:[String:Any]=["token":api.token,"offset_ms":offsetMS]
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
                        if type=="ready" { self.liveReady=true;self.liveStartupAllowance=self.liveQueueBytes;self.liveReconnects=0;self.captionState = .ready;self.flushLive() }
                        if type=="finished" { self.liveFinished=true;if event["complete"] as? Bool != true {self.hasCaptionGap=true;self.notice="实时结果未完整，录后精转写会使用完整文件。"};self.captionState = .finished;return }
                        if type=="error" { self.notice=event["message"] as? String;self.liveReady=false;self.liveFatalError=event["retryable"] as? Bool != true;self.captionState = .unavailable }
                        if type=="transcript",let sentence=event["sentence"] as? [String:Any],let text=sentence["text"] as? String {
                            let key=epoch.uuidString+":"+String(describing:sentence["sentence_id"] ?? sentence["begin_time"] ?? 0)
                            let stable=sentence["sentence_end"] as? Bool == true || (sentence["end_time"] != nil && !(sentence["end_time"] is NSNull))
                            if stable {
                                self.finalSentences[key]=text;self.partial=""
                            } else { self.partial=text }
                            // Dictionary insertion order is not a timing contract; store a separate ordered text list below.
                            if let index=self.liveOrder.firstIndex(of:key) { self.liveText[index]=text }
                            else { self.liveOrder.append(key);self.liveText.append(text) }
                            self.preview=self.liveText.joined(separator:"")
                            let startMS=offsetMS+((sentence["begin_time"] as? NSNumber)?.intValue ?? 0)
                            if let index=self.liveSentences.firstIndex(where:{$0.id==key}) {
                                self.liveSentences[index]=LiveRecordingSentence(id:key,text:text,startMS:startMS,stable:stable)
                            } else { self.liveSentences.append(LiveRecordingSentence(id:key,text:text,startMS:startMS,stable:stable)) }
                            self.liveRevision+=1
                        }
                    }
                } catch {
                    guard let self,self.streamID==epoch else { return }
                    guard self.recording else {self.captionState = .finished;return}
                    if self.deviceLiveBlocked || self.liveFatalError || self.liveReconnects>=3 {self.captionState = .unavailable;self.notice="实时字幕已暂停，完整录音仍保留；可手动恢复。";return}
                    self.liveReady=false;self.liveFinished=true;self.captionState = .reconnecting;self.hasCaptionGap=true
                    self.notice=self.meetingSource == "soundcore" ? "实时字幕已断开，设备录音仍保留。":"实时字幕已断开，完整录音仍在本机保存。"
                    if self.recording && !self.phonePaused && !self.devicePaused {
                        self.liveReconnects+=1
                        try? await Task.sleep(for:.seconds(Double(1 << self.liveReconnects)))
                        if self.recording && self.streamID==epoch && !self.phonePaused && !self.devicePaused { await self.openLive(api:api,sid:sid) }
                    }
                }
            }
        } catch { captionState = .unavailable;notice="实时字幕连接失败，完整录音仍在保存。" }
    }
    private var liveOrder:[String]=[]
    private var liveText:[String]=[]
    private func sendFrame(_ data:Data) {
        guard recording,!liveFatalError,!liveFinished else{return}
        let limit=liveReady ? 64000+liveStartupAllowance:320000
        guard liveQueueBytes+data.count<=limit else {
            hasCaptionGap=true;liveFatalError=true;captionState = .unavailable
            notice="网络未能及时发送实时音频，字幕已暂停；录后精转写使用完整文件。"
            socket?.cancel(with:.goingAway,reason:nil);return
        }
        liveQueue.append(data);liveQueueBytes+=data.count;flushLive()
    }
    private func flushLive() {
        guard liveReady,sendTail==nil,!liveFatalError,let task=socket else{return}
        let epoch=streamID
        sendTail=Task { [weak self] in
            guard let self else{return};defer{if streamID==epoch {sendTail=nil}}
            do {
                while !liveQueue.isEmpty,streamID==epoch,!Task.isCancelled {
                    let data=liveQueue.removeFirst();let seq=nextSequence;nextSequence+=1
                    try await task.send(.string(String(data:JSONSerialization.data(withJSONObject:["seq":seq,"audio":data.base64EncodedString()]),encoding:.utf8)!))
                    guard streamID==epoch else{return}
                    liveQueueBytes-=data.count;liveStartupAllowance=max(0,liveStartupAllowance-data.count)
                }
            } catch {if streamID==epoch {liveReady=false;captionState = .reconnecting;hasCaptionGap=true;notice="实时音频发送中断，文件仍保留。";task.cancel(with:.goingAway,reason:nil)}}
        }
    }
    func finishCapture() async {
        guard !finishing else { return };finishing=true;defer{finishing=false}
        if meetingSource != "soundcore" {VoiceCapture.shared.stopMeeting()}
        engine=nil
        let wasRecording=recording;recording=false;clock?.cancel();clock=nil
        if wasRecording && meetingSource != "soundcore" { seconds=phoneElapsedSeconds }
        phonePaused=false;pausedAt=nil
        // A short recording can end while upstream readiness is still pending.
        for _ in 0..<160 {if liveReady || liveFinished || liveFatalError || socket==nil {break};try? await Task.sleep(for:.milliseconds(100))}
        flushLive();await sendTail?.value
        if let task=socket,liveReady,!liveFatalError {
            try? await task.send(.string("{\"type\":\"finish\",\"last_seq\":\(nextSequence-1)}"))
            for _ in 0..<40 { if liveFinished { break };try? await Task.sleep(for:.milliseconds(500)) }
        }
        liveReady=false;receiver?.cancel();sendTail?.cancel();sendTail=nil;socket?.cancel(with:.normalClosure,reason:nil);socket=nil;liveQueue=[];liveQueueBytes=0;liveStartupAllowance=0;liveReconnects=0;captionState = .finished
        if let audioLease {audioResources?.release(audioLease)};audioLease=nil
        if audioResources?.voiceActive != true && meetingSource=="soundcore" {try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)}
        if let sid=sessionID,let i=pending.firstIndex(where:{$0.id==sid}) { pending[i].milliseconds=max(1,seconds*1000);persistPending() }
    }
    func finishAndUpload() async {
        let emptyPhoneRecording=meetingSource=="iphone" && VoiceCapture.shared.capturedPCMBytes==0
        await finishCapture()
        if emptyPhoneRecording {notice="本次未采集到音频，无法转写，请重新录音。";return}
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
            let url=URL(fileURLWithPath:item.path)
            if url.pathExtension=="m4a" {
                let audio=try AVAudioFile(forReading:url)
                guard audio.length>0 else {throw PrototypeError.message("这段录音没有声音帧，无法上传和转写，请重新录音。")}
            }
            if item.id==meetingID { meetingProgress="音频正在上传" }
            try await api.upload(URL(fileURLWithPath:item.path),session:item.id,durationMS:item.milliseconds)
            pending.removeAll { $0.id==item.id };persistPending();notice="音频已入库，正在精转写和整理。"
            if item.id==meetingID { meetingProgress="音频已保存，正在精转写" }
        } catch { notice=error.localizedDescription;if item.id==meetingID {meetingProgress="音频已保留，上传未完成"} }
    }
    private var phoneElapsedSeconds: Int {
        max(0,Int(Date().timeIntervalSince(started)-totalPauseSeconds-(pausedAt.map { Date().timeIntervalSince($0) } ?? 0)))
    }
    var activeMeeting: Bool { !voiceMessage && (recording || finishing || uploading || meetingPreparing || meetingSyncing) }
    func meetingMatches(_ api: API) -> Bool { connection.map { identity($0)==identity(api) } ?? false }
    func pendingFor(_ api: API) -> [PendingRecording] { pending.filter { $0.backendIdentity==identity(api) } }
    func hasMeetingConsent(_ api: API) -> Bool { UserDefaults.standard.bool(forKey:"candid-recording-informed:"+identity(api)) }
    func allowMeetingTranscription(_ api: API) { UserDefaults.standard.set(true,forKey:"candid-recording-informed:"+identity(api)) }
    func togglePhonePause() async {
        guard recording,!voiceMessage,meetingSource=="iphone",!finishing else { return }
        if phonePaused {
            do {
                try VoiceCapture.shared.start();VoiceCapture.shared.setMeetingPaused(false)
                totalPauseSeconds += pausedAt.map { Date().timeIntervalSince($0) } ?? 0
                pausedAt=nil;phonePaused=false
                if !liveReady,let api=connection { await openLive(api:api,sid:sessionID) }
            } catch { notice=error.localizedDescription }
        } else { VoiceCapture.shared.setMeetingPaused(true);seconds=phoneElapsedSeconds;pausedAt=Date();phonePaused=true }
    }
    func retryLive(store: Store, device: Soundcore) async {
        guard meetingMatches(store.api),!finishing else { return }
        deviceLiveBlocked=false
        if meetingSource=="soundcore" {
            if recording { await finishCapture() }
            await startDevice(store:store,device:device)
        } else if recording,let api=connection { await openLive(api:api,sid:sessionID) }
    }
    func stopPlayback() {
        playbackGeneration=UUID()
        if let playbackLease {audioResources?.release(playbackLease)};playbackLease=nil
        if let (api,id)=ttsJob {speechCancel=Task {_=try? await api.raw("/v1/business-jobs/"+id+"/cancel",method:"POST")};ttsJob=nil}
        playback?.cancel();playback=nil;player?.stop();player=nil;playing=false;paused=false
        playbackState = .idle;spokenMessage=nil
    }
    func pauseSpeechPlayback() {
        guard [.preparing,.playing].contains(playbackState) else{return}
        paused=true;player?.pause();playbackState = .paused
    }
    func pausePlayback() {
        guard hasSpeechPlayback else{return}
        if playbackState == .paused {paused=false;playbackState = player == nil ? .preparing:.playing;player?.play()}
        else {pauseSpeechPlayback()}
    }
    func speak(_ message:ChatMessage,api:API,resources:AudioResources?=nil) {
        guard resources?.voiceActive != true else {notice="请先暂停或结束连续语音，再播放历史回答。";return}
        guard !activeMeeting else {notice="会议录音期间已暂停朗读，请录音结束后播放。";return}
        if spokenMessage?.id==message.id && [.preparing,.playing,.paused].contains(playbackState) {pausePlayback();return}
        stopPlayback()
        if let resources {do {audioResources=resources;playbackLease=try resources.acquire(.manualSpeech)} catch {notice=error.localizedDescription;return}}
        notice=nil;completedClips=[];spokenMessage=message;playbackState = .preparing
        let generation=playbackGeneration;let ownedLease=playbackLease
        playback=Task { [weak self] in
            guard let self else {return}
            defer {if let ownedLease {resources?.release(ownedLease)};if self.playbackLease==ownedLease {self.playbackLease=nil}}
            do {
                await self.speechCancel?.value
                try Task.checkCancellation()
                let job:BusinessJob=try await api.call("/v1/chat/messages/"+message.id+"/speak",method:"POST")
                // Stop may win while the submission is in flight. Cancel its receipt too.
                guard generation==self.playbackGeneration,!Task.isCancelled else {_=try? await api.raw("/v1/business-jobs/"+job.id+"/cancel",method:"POST");return}
                self.ttsJob=(api,job.id)
                for _ in 0..<600 {
                    try Task.checkCancellation()
                    let current:BusinessJob=try await api.call("/v1/business-jobs/"+job.id)
                    if current.status=="failed" || current.status=="interrupted" || current.status=="cancelled" {throw PrototypeError.message(current.error ?? "播报处理未完成，文字仍可阅读。")}
                    let outputs:[SpeechClip]=try await api.all("/v1/speech-clips?job_id="+job.id)
                    for clip in outputs.sorted(by:{$0.part<$1.part}) where !self.completedClips.contains(clip.id) {
                        let raw=try await api.raw("/v1/speech/"+clip.id)
                        try Task.checkCancellation()
                        guard generation==self.playbackGeneration else{return}
                        if let ownedLease,resources?.owns(ownedLease) != true {return}
                        self.player=try AVAudioPlayer(data:raw)
                        while self.paused {try Task.checkCancellation();try await Task.sleep(for:.milliseconds(50))}
                        try Task.checkCancellation()
                        let session=AVAudioSession.sharedInstance();try session.setCategory(.playback,mode:.spokenAudio);try session.setActive(true)
                        self.player?.play();self.playing=true;self.playbackState = .playing
                        while self.player?.isPlaying == true || self.paused {try Task.checkCancellation();try await Task.sleep(for:.milliseconds(50))}
                        self.completedClips.insert(clip.id);self.player=nil
                        self.playbackState = .preparing
                    }
                    if current.status=="completed" {
                        guard generation==self.playbackGeneration else{return}
                        self.ttsJob=nil;self.playing=false;self.playbackState = .idle;self.spokenMessage=nil;return
                    }
                    try await Task.sleep(for:.milliseconds(300))
                }
                throw PrototypeError.message("播报处理超时，文字仍可阅读。")
            } catch {
                guard generation==self.playbackGeneration else{return}
                if error is CancellationError {return}
                self.notice=error.localizedDescription;self.playing=false;self.playbackState = .failed
            }
        }
    }

}
struct SpeechClip:Decodable,Identifiable { var id:String;var part:Int }

struct SpeechMessageButton:View {
    @EnvironmentObject var store:Store
    @ObservedObject var speech:SpeechController
    let message:ChatMessage
    private var selected:Bool {speech.spokenMessage?.id==message.id && speech.hasSpeechPlayback}
    var body:some View {
        Button(selected ? (speech.playbackState == .paused ? "继续朗读":speech.playbackState == .failed ? "重试朗读":"暂停朗读") : "朗读回答",systemImage:selected ? "speaker.wave.2.fill":"speaker.wave.2") {
            store.stopPlayback();speech.speak(message,api:store.api,resources:store.audio)
        }.font(.caption).frame(minHeight:44).accessibilityIdentifier("speak-message-"+message.id)
    }
}

struct SpeechPlaybackBar:View {
    @EnvironmentObject var store:Store
    @ObservedObject var speech:SpeechController
    private var title:String {
        switch speech.playbackState {
        case .preparing:return "正在准备声音"
        case .playing:return "正在朗读回答"
        case .paused:return "朗读已暂停"
        case .failed:return "朗读失败，文字仍可查看"
        case .idle:return ""
        }
    }
    var body:some View {
        if speech.hasSpeechPlayback {
            HStack(spacing:8) {
                Image(systemName:"speaker.wave.2").foregroundStyle(Warm.purple).accessibilityHidden(true)
                Text(title).font(.caption).lineLimit(2)
                Spacer(minLength:0)
                if speech.playbackState == .failed {
                    Button("重试") {if let message=speech.spokenMessage {speech.speak(message,api:store.api,resources:store.audio)}}.frame(minWidth:44,minHeight:44)
                } else {
                    Button(speech.playbackState == .paused ? "继续":"暂停") {speech.pausePlayback()}.frame(minWidth:44,minHeight:44)
                }
                Button("停止",systemImage:"stop.fill") {speech.stopPlayback()}.labelStyle(.iconOnly).frame(minWidth:44,minHeight:44).accessibilityLabel("停止朗读")
            }.font(.caption).buttonStyle(.borderless).tint(Warm.purple).frame(minHeight:44)
                .padding(.horizontal,12).background(Warm.lavender,in:RoundedRectangle(cornerRadius:14))
                .accessibilityIdentifier("speech-playback-bar")
        }
    }
}

struct SpeechToolbar: View {
    @EnvironmentObject var store: Store
    @ObservedObject var speech: SpeechController
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Button { store.recordingNavigation.section = .recordings } label:{Label("录音库",systemImage:"waveform")}
                Spacer()
                Button {store.recordingNavigation.newMeeting = !speech.activeMeeting && store.soundcore.recordStatus==0;store.recordingNavigation.showRecorder=true} label:{Label("沟通录音",systemImage:"record.circle")}
            }.font(.caption).frame(minHeight:44)
            SpeechPlaybackBar(speech:speech)
        }.padding(.horizontal,22)
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
            let file=try result.get()
            _=try await store.api.uploadPDF(file,workspaceID:workspaceID,title:title.isEmpty ? file.lastPathComponent:title);dismiss()
        } catch {if !ImportedDocumentFiles.isCancellation(error) {self.error=error.localizedDescription}} }
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

enum DeviceRecordingMap {
    static func identity(_ api:API)->String { SHA256.hash(data:Data((api.base+"\n"+api.token).utf8)).map{String(format:"%02x",$0)}.joined() }
    static func key(api:API,fileID:Int32,deviceID:String)->String { "device-recording-"+identity(api)+deviceID+String(fileID) }
    static func get(api:API,fileID:Int32,deviceID:String)->String? { UserDefaults.standard.string(forKey:key(api:api,fileID:fileID,deviceID:deviceID)) }
    static func set(_ sid:String,api:API,fileID:Int32,deviceID:String) { UserDefaults.standard.set(sid,forKey:key(api:api,fileID:fileID,deviceID:deviceID)) }
    static func requestID(api:API,fileID:Int32,deviceID:String) -> String {
        let hex=SHA256.hash(data:Data(key(api:api,fileID:fileID,deviceID:deviceID).utf8)).map {String(format:"%02x",$0)}.joined()
        let value=String(hex.prefix(32))
        return String(value.prefix(8))+"-"+String(value.dropFirst(8).prefix(4))+"-"+String(value.dropFirst(12).prefix(4))+"-"+String(value.dropFirst(16).prefix(4))+"-"+String(value.suffix(12))
    }
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
        if let index=pending.firstIndex(where:{$0.id==id && $0.backendIdentity==identity(api)}) {pending[index].milliseconds=max(pending[index].milliseconds,milliseconds);persistPending()}
        else { pending.append(PendingRecording(id:id,path:url.path,milliseconds:milliseconds,backendIdentity:identity(api)));persistPending() }
    }
    func prepareDevice(store: Store, device: Soundcore) async {
        guard store.remote,hasMeetingConsent(store.api),!meetingPreparing,!finishing,!uploading,!meetingSyncing,
              !voiceMessage || !recording,device.recordStatus != 0,
              let fileID=device.currentFileID,let connected=device.connected else { return }
        let api=store.api
        if let reference=trackedDevice,reference.fileID==fileID,reference.deviceID==connected.recordingID,
           reference.backendIdentity==identity(api) {
            if meetingID != reference.sessionID || meetingSource != "soundcore" {
                liveSentences=[];liveRevision+=1;preview="";liveOrder=[];liveText=[];captionState = .idle
            }
            meetingID=reference.sessionID;meetingSource="soundcore";connection=api;sessionID=reference.sessionID;voiceMessage=false
            deviceRecordingUncertain=false
            return
        }
        guard !recording else { return }
        meetingPreparing=true;defer { meetingPreparing=false }
        do {
            let sid: String
            if let old=DeviceRecordingMap.get(api:api,fileID:fileID,deviceID:connected.recordingID) { sid=old }
            else {
                let row: RecordingRecord=try await api.call("/v1/recordings",method:"POST",body:[
                    "client_request_id":DeviceRecordingMap.requestID(api:api,fileID:fileID,deviceID:connected.recordingID),"recording_source":"soundcore",
                    "device_file_id":Int(UInt32(bitPattern:fileID)),"device_id":connected.recordingID,
                    "consent":"yes","consent_ack_text_version":"recording-consent@1","customer_assignment_required":true])
                sid=row.id;DeviceRecordingMap.set(sid,api:api,fileID:fileID,deviceID:connected.recordingID)
            }
            guard identity(store.api)==identity(api),device.connected?.recordingID==connected.recordingID,
                  device.currentFileID==fileID,device.recordStatus != 0 else { return }
            trackedDevice=DeviceCaptureReference(sessionID:sid,fileID:fileID,deviceID:connected.recordingID,backendIdentity:identity(api))
            if let data=try? JSONEncoder().encode(trackedDevice) { UserDefaults.standard.set(data,forKey:"candid-device-capture") }
            connection=api;sessionID=sid;meetingID=sid;meetingSource="soundcore";voiceMessage=false
            preview="";liveOrder=[];liveText=[];liveSentences=[];finalSentences=[:];partial="";liveRevision+=1
            seconds=device.durationMS/1000;captionState = .idle;hasCaptionGap=false;meetingProgress=nil;notice=nil;deviceLiveBlocked=false;deviceRecordingUncertain=false
        } catch { notice=error.localizedDescription }
    }
    func startDevice(store:Store,device:Soundcore) async {
        await prepareDevice(store:store,device:device)
        if recording && meetingSource=="soundcore" && meetingMatches(store.api) {
            if device.recordStatus == 1 && !device.liveAudioRequested && device.onLiveAudio != nil {
                do { try device.acquireLiveAudio() } catch { notice = error.localizedDescription }
            }
            if device.recordStatus==1 && !liveReady && liveFinished && !deviceLiveBlocked,let api=connection {
                await openLive(api:api,sid:sessionID)
            }
            return
        }
        guard !recording,!finishing,!uploading,!meetingPreparing,!meetingSyncing,!deviceLiveBlocked,device.recordStatus==1,
              device.realtimeReady,let reference=trackedDevice,meetingMatches(store.api),
              device.currentFileID==reference.fileID,device.connected?.recordingID==reference.deviceID else { return }
        if store.voice.active {store.voice.stopAnswer()};store.stopPlayback();stopPlayback()
        do {
            audioResources=store.audio;audioLease=try store.audio.acquire(.meeting)
            let decoder=try DevicePCMDecoder();recording=true;started=Date();seconds=device.durationMS/1000
            await openLive(api:store.api,sid:reference.sessionID)
            guard recording,device.recordStatus != 0,device.currentFileID==reference.fileID else { await finishCapture();return }
            device.onLiveAudio={ [weak self,weak device] data,sequence in
                guard let self,let device,self.recording,self.sessionID==reference.sessionID else { return }
                do {
                    let (pcm,gap)=try decoder.decode(data,sequence:sequence)
                    self.seconds=device.durationMS/1000
                    if gap { self.hasCaptionGap=true;self.notice="设备实时传输有缺段，录后会使用完整同步文件。" }
                    if !pcm.isEmpty { self.sendFrame(pcm) }
                } catch { self.notice=error.localizedDescription;self.deviceLiveBlocked=true;self.hasCaptionGap=true;self.captionState = .unavailable;device.onLiveAudio=nil;self.socket?.cancel(with:.goingAway,reason:nil) }
            }
            device.onRecordingEnded={ [weak self] in Task {
                guard let self,self.meetingSource=="soundcore",self.sessionID==reference.sessionID,self.recording else{return}
                await self.finishCapture()
            } }
            try device.acquireLiveAudio()
        } catch { notice=error.localizedDescription;captionState = .unavailable;await finishCapture() }
    }
    #if DEBUG
    func prepareCaptionPreview(api:API) {
        connection=api
        liveSentences=[LiveRecordingSentence(id:"preview-stable",text:"示例 · 我们先确认接口和交付范围，再安排下一场沟通。",startMS:1000,stable:true),
            LiveRecordingSentence(id:"preview-provisional",text:"示例 · 这句话仍在实时识别中",startMS:7000,stable:false)]
        liveRevision+=1
    }
    #endif
    func saveMarkers(_ times:[Int],sessionID:String,api:API) async throws {
        guard !times.isEmpty else{return}
        _=try await api.raw("/v1/sessions/"+sessionID+"/marks",method:"POST",body:["marks":times.map{["t_ms":$0,"user_label":"unlabeled"] as [String:Any]}])
    }
    func markCurrent(store:Store,device:Soundcore) async {
        guard let sid=meetingID,meetingMatches(store.api) else{return}
        do {try await saveMarkers([meetingSource=="soundcore" ? device.durationMS:seconds*1000],sessionID:sid,api:store.api);notice="已标记，录后可从原文回听。"} catch {notice=error.localizedDescription}
    }
    func deviceDidEnd(store: Store, device: Soundcore, realEnd: Bool) async {
        guard meetingSource=="soundcore",meetingMatches(store.api) else { return }
        seconds=max(seconds,device.durationMS/1000)
        if recording { await finishCapture() }
        deviceRecordingUncertain = !realEnd
        if !realEnd {hasCaptionGap=true}
        if realEnd { automaticDeviceSync=true;meetingProgress="录音已结束，等待同步设备文件" }
        else { automaticDeviceSync=false;meetingProgress="设备连接已断开，原文件保留，重新连接后可继续同步" }
    }
    func syncEndedDeviceIfReady(store: Store, device: Soundcore) async {
        guard automaticDeviceSync,!finishing,!meetingSyncing,!uploading,
              let reference=trackedDevice,reference.backendIdentity==identity(store.api),
              device.recordStatus==0,device.connected?.recordingID==reference.deviceID,
              let file=device.files.first(where:{$0.id==reference.fileID}) else { return }
        automaticDeviceSync=false
        await syncDevice(file,store:store,device:device)
    }
    func syncDevice(_ file:SoundcoreFile,store:Store,device:Soundcore) async {
        guard store.remote,hasMeetingConsent(store.api),device.recordStatus==0,
              !recording,!finishing,!meetingPreparing,!meetingSyncing,!uploading,let connected=device.connected else { return }
        meetingSyncing=true;defer { meetingSyncing=false }
        let api=store.api
        do {
            let sid: String
            if let old=DeviceRecordingMap.get(api:api,fileID:file.id,deviceID:connected.recordingID) { sid=old }
            else {
                let row:RecordingRecord=try await api.call("/v1/recordings",method:"POST",body:[
                    "client_request_id":DeviceRecordingMap.requestID(api:api,fileID:file.id,deviceID:connected.recordingID),"recording_source":"soundcore",
                    "device_file_id":Int(UInt32(bitPattern:file.id)),"device_id":connected.recordingID,
                    "consent":"yes","consent_ack_text_version":"recording-consent@1","customer_assignment_required":true])
                sid=row.id;DeviceRecordingMap.set(sid,api:api,fileID:file.id,deviceID:connected.recordingID)
            }
            guard identity(store.api)==identity(api) else { throw PrototypeError.message("连接已变化，请返回录音创建时的后端再同步。") }
            meetingID=sid;meetingSource="soundcore";sessionID=sid;connection=api;voiceMessage=false
            meetingProgress="正在同步设备音频"
            let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("Recordings")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let target=folder.appendingPathComponent(sid+".m4a")
            var duration=file.durationMS
            if !FileManager.default.fileExists(atPath:target.path) {
                let raw=try await device.download(file)
                meetingProgress="设备文件已同步，正在准备音频"
                duration=try await SoundcoreAudio.convert(raw:raw,destination:target)
                try? FileManager.default.removeItem(at:raw.deletingLastPathComponent())
            }
            keepPending(id:sid,url:target,milliseconds:duration,api:api)
            guard identity(store.api)==identity(api) else { throw PrototypeError.message("连接已变化，本机文件已保留；请返回原连接上传。") }
            await upload(PendingRecording(id:sid,path:target.path,milliseconds:duration,backendIdentity:identity(api)),api:api)
            try await saveMarkers(device.fileMarkers[file.id] ?? [],sessionID:sid,api:api)
            if trackedDevice?.sessionID==sid && !pending.contains(where:{$0.id==sid}) {
                trackedDevice=nil;deviceRecordingUncertain=false;UserDefaults.standard.removeObject(forKey:"candid-device-capture")
            }
        } catch { notice=error.localizedDescription;meetingProgress="同步未完成，设备原文件仍保留" }
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
