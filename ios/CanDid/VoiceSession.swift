import Foundation
import Combine
import AVFoundation
import CryptoKit
import UIKit

struct VoiceRecovery: Codable,Identifiable {
    var id:String;var path:String;var created:Date;var backend:String;var thread:String;var workspace:String;var text:String;var requestID:String?;var unknown:Bool
}
private struct VoiceScope {let api:API;let thread:String;let workspace:String;let backend:String;let session:UUID;let continuous:Bool}
private struct VoiceQuestion {let task:String;let input:String;let attempt:Int}
private final class VoiceInput {
    let id=UUID();let request=UUID();let generation=UUID()
    var segments:[VoiceASRSegment]=[];var results:[UUID:String]=[:];var previews:[UUID:String]=[:]
    var current:VoiceASRSegment?;var committed=false;var failed=false;var lastEndSample=0
    let path:URL;let handle:FileHandle;var bytes=0;var lastWrittenSample=0;var question:VoiceQuestion?;var requestBody:[String:Any]?
    init() throws {
        let folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VoiceInputs")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        path=folder.appendingPathComponent(id.uuidString+".pcm")
        guard FileManager.default.createFile(atPath:path.path,contents:nil,attributes:[.protectionKey:FileProtectionType.complete]) else{throw PrototypeError.message("无法保留这句话。")}
        handle=try FileHandle(forWritingTo:path)
    }
    deinit {try? handle.close()}
    var preview:String {segments.map{results[$0.id] ?? previews[$0.id] ?? ""}.joined()}
    func write(_ pcm:Data) throws {guard bytes+pcm.count<=20_000_000 else{throw PrototypeError.message("这段发言过长，已保留输入，请分段说。")};try handle.write(contentsOf:pcm);bytes+=pcm.count}
    func clear() {try? handle.close();try? FileManager.default.removeItem(at:path)}
}

@MainActor final class VoiceSessionController:ObservableObject {
    enum Mode {case hold,continuous}
    enum Phase:String {case idle,connecting,listening,finalizing,submitting,thinking,speaking,paused,failed}
    @Published var showContinuous=false
    @Published private(set) var mode:Mode?
    @Published private(set) var phase:Phase = .idle
    @Published private(set) var preview=""
    @Published private(set) var response=""
    @Published private(set) var level:Float=0
    @Published private(set) var holding=false
    @Published var cancelling=false
    @Published private(set) var notice:String?
    @Published private(set) var recoveries:[VoiceRecovery]=[]
    @Published private(set) var microphonePaused=false
    private weak var store:Store?
    private var api:API?
    private var thread:String?
    private var workspace:String?
    private var backend=""
    private var session=UUID()
    private var epoch=UUID()
    private var lease:UUID?
    private var capture:VoiceCapture?
    private var vad:VoiceActivityDetector?
    private var input:VoiceInput?
    private var inflight:Set<UUID>=[]
    var visibleRecoveries:[VoiceRecovery] {recoveries.filter{$0.id != input?.id.uuidString && !inflight.contains(UUID(uuidString:$0.id) ?? UUID())}}
    private var preRoll=Data()
    private var sample=0
    private var voiced=0
    private var quiet=0
    private var lastSpeech=0
    private var candidatePaused=false
    private var beginTask:Task<Void,Never>?
    private var segments:[UUID:Task<Void,Never>]=[:]
    private var reply:(request:UUID,generation:UUID,epoch:UUID)?
    private var pendingCancel:Set<UUID>=[]
    private var cancelledRequests:Set<UUID>=[]
    private var lastGestureEnd=Date.distantPast
    var justEndedGesture:Bool {Date().timeIntervalSince(lastGestureEnd)<0.3}
    func gestureEnded() {lastGestureEnd=Date()}
    private var waitingQuestion:VoiceQuestion?
    private var consumedQuestions:Set<String>=[]
    private var recoveryTask:Task<Void,Never>?
    private var output:URLSessionWebSocketTask?
    private var outputTask:Task<Void,Never>?
    private var outputControl:Task<Void,Never>?
    private var isPlaying=false
    private var outputFinished=false
    private var audioBytes=0
    private var lastAudioSeq=0
    private var observer:NSObjectProtocol?
    private var routeObserver:NSObjectProtocol?
    private var timing:[String:Int]=[:]
    private var onsets:[String:TimeInterval]=[:]
    private let recoveryURL=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VoiceRecovery.json")
    var active:Bool {mode != nil}
    var canDiscard:Bool {mode == .hold && !holding && [.finalizing,.connecting,.failed].contains(phase)}
    init() {
        recoveries=(try? Data(contentsOf:recoveryURL)).flatMap{try? JSONDecoder().decode([VoiceRecovery].self,from:$0)} ?? []
        purgeRecoveries()
        #if DEBUG
        if ProcessInfo.processInfo.environment["CANDID_INITIAL_SCREEN"]=="voice" {showContinuous=true}
        #endif
        observer=NotificationCenter.default.addObserver(forName:AVAudioSession.interruptionNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.pause(reason:"语音被系统打断，点击继续后再说。") } }
        routeObserver=NotificationCenter.default.addObserver(forName:AVAudioSession.routeChangeNotification,object:nil,queue:.main) { [weak self] notification in
            let reason=(notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            if [AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue].contains(reason) {
                Task { @MainActor in self?.pause(reason:"音频设备已变化，点击继续后再说。") }
            }
        }
    }
    func identity(_ api:API)->String {SHA256.hash(data:Data((api.base+"\n"+api.token).utf8)).map{String(format:"%02x",$0)}.joined()}
    private func mark(_ name:String,segment:UUID?=nil,turn:UUID?=nil) {
        timing[name,default:0]+=1;onsets[name]=ProcessInfo.processInfo.systemUptime
        if timing[name]==1 || !["audio_sent","capture_frame","app_caption"].contains(name) || timing[name]!%50==0 {
            let folder=recoveryURL.deletingLastPathComponent();try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);let trace=folder.appendingPathComponent("VoiceTiming.jsonl")
            let row:[String:Any]=["event":name,"uptime":ProcessInfo.processInfo.systemUptime,"count":timing[name]!,"voice_session_id":session.uuidString,"epoch":epoch.uuidString,"segment_id":segment?.uuidString ?? "","input_turn_id":turn?.uuidString ?? input?.id.uuidString ?? ""]
            guard var bytes=try? JSONSerialization.data(withJSONObject:row) else{return};bytes.append(10)
            let size=(try? FileManager.default.attributesOfItem(atPath:trace.path)[.size] as? Int) ?? 0
            if size>1_000_000 {try? FileManager.default.removeItem(at:trace)}
            if !FileManager.default.fileExists(atPath:trace.path) {FileManager.default.createFile(atPath:trace.path,contents:nil,attributes:[.protectionKey:FileProtectionType.complete])}
            if let handle=try? FileHandle(forWritingTo:trace) {try? handle.seekToEnd();try? handle.write(contentsOf:bytes);try? handle.close()}
        }
    }
    private func scopeValid(_ stamp:UUID)->Bool {guard let store,let api else{return false};return stamp==epoch && store.remote && store.chatForeground && identity(store.api)==identity(api) && store.currentProjectSpace?.id==workspace && store.currentProjectSpace?.status=="active"}
    func captionObserved() {mark("caption_observed")}
    func enter(store:Store) {
        showContinuous=true;begin(store:store,continuous:true)
    }
    func beginHold(store:Store) {guard !holding,!active else{return};holding=true;cancelling=false;begin(store:store,continuous:false)}
    private func begin(store:Store,continuous:Bool) {
        guard !active || (mode == .continuous && microphonePaused) else{notice="请先结束当前语音。";return}
        guard store.remote,store.capabilities?.asr_configured==true,let thread=store.chatThread?.id,let space=store.currentProjectSpace,space.status=="active" else{holding=false;phase = .failed;notice="请先连接后端并选择可用项目空间。";return}

        self.store=store;self.api=store.api;self.thread=thread;workspace=space.id;backend=identity(store.api)
        epoch=UUID();session=UUID();reply=nil;waitingQuestion=nil;timing=[:];onsets=[:];let stamp=epoch
        mode=continuous ? .continuous:.hold;microphonePaused=false;phase = .connecting;notice=nil;preview="";response="";preRoll=Data();sample=0;lastSpeech=0;voiced=0;quiet=0
        beginTask=Task { [weak self] in
            guard let self else{return}
            do {
                let permitted=await withCheckedContinuation { c in AVAudioApplication.requestRecordPermission {c.resume(returning:$0)} }
                guard scopeValid(stamp),!Task.isCancelled,mode != nil else{return}
                guard permitted else{throw PrototypeError.message("麦克风权限未开启，请到系统设置允许录音。")}
                if mode == .hold && !holding {throw PrototypeError.message("权限已准备好，请重新按住说话。")}
                store.stopPlayback();store.speech.stopPlayback()
                lease=try store.audio.acquire(.voice)
                let microphone=VoiceCapture.shared;capture=microphone;vad=try VoiceActivityDetector()
                microphone.onFrame={ [weak self] bytes in Task { @MainActor in self?.consume(bytes,stamp:stamp) } }
                microphone.onError={ [weak self] in Task { @MainActor in if self?.epoch==stamp {self?.pause(reason:"音频接收失败，已保留输入。")}} }
                microphone.onPlaybackChanged={ [weak self] playing in
                    guard let self,self.epoch==stamp else{return};self.isPlaying=playing
                    if playing && input==nil {phase = .speaking}
                    else if !playing && outputFinished && input==nil && mode != nil {phase = .listening}
                }
                try microphone.start();UIImpactFeedbackGenerator(style:.light).impactOccurred();mark("capture_started")
                guard scopeValid(stamp) else{microphone.stop();releaseAudio();return}
                phase = .listening
                if !continuous {try startInput(preroll:Data(),stamp:stamp)}
            } catch {if epoch==stamp {notice=error.localizedDescription;phase = .failed;holding=false;capture?.stop();releaseAudio();if mode == .hold {mode=nil} else{microphonePaused=true}}}
        }
    }
    private func consume(_ bytes:Data,stamp:UUID) {
        guard scopeValid(stamp),capture != nil,!microphonePaused,let vad else{return}
        mark("capture_frame")
        do {
            for (frame,speech,rms) in try vad.frames(bytes) {
                sample+=320;level=min(1,rms*8)
                preRoll.append(frame);if preRoll.count>9600 {preRoll.removeFirst(preRoll.count-9600)}
                if mode == .hold {
                    if holding,let input,let current=input.current {try input.write(frame);input.lastWrittenSample=sample;current.append(frame);preview=input.preview}
                    continue
                }
                if speech {voiced+=1;quiet=0;lastSpeech=sample} else {quiet+=1;voiced=0}
                if speech && voiced==2 && isPlaying {candidatePaused=true;capture?.pausePlayback();mark("barge_candidate")}
                if speech && voiced>=6 {
                    if input==nil {interruptReply();try startInput(preroll:preRoll,stamp:stamp);mark("valid_speech")}
                    else if input?.current==nil {try startSegment(preroll:preRoll,stamp:stamp)}
                    candidatePaused=false
                }
                if let input,let current=input.current {
                    // The pre-roll for a newly-created segment includes this frame already.
                    if input.lastWrittenSample<sample {try input.write(frame);input.lastWrittenSample=sample;current.append(frame)}
                }
                if quiet>=50,input?.current != nil {sealCurrent(stamp:stamp)}
                if quiet>=18 && candidatePaused {candidatePaused=false;capture?.resumePlayback();trySubmit(stamp:stamp)}
                if quiet>=50,input?.current==nil {trySubmit(stamp:stamp)}
            }
        } catch {failInput(error.localizedDescription)}
    }
    private func startInput(preroll:Data,stamp:UUID) throws {
        let value=try VoiceInput();input=value;preview=""
        preserve(value,text:"",request:nil,unknown:false)
        if let question=waitingQuestion,!consumedQuestions.contains(question.input) {value.question=question}
        else if let task=store?.chatTask,task.status=="waiting_input",let question=task.input_request,!consumedQuestions.contains(question.id) {value.question=VoiceQuestion(task:task.id,input:question.id,attempt:task.attempt)}
        try startSegment(preroll:preroll,stamp:stamp)
    }
    private func startSegment(preroll:Data,stamp:UUID) throws {
        guard let input,let api else{return}
        let start=max(input.lastEndSample,sample-preroll.count/2)
        let available=max(0,sample-start)*2
        let prefix=Data(preroll.suffix(min(preroll.count,available)))
        let segment=VoiceASRSegment(api:api,session:session,turn:input.id,epoch:stamp,startSample:start)
        input.current=segment;input.segments.append(segment);let segmentID=segment.id;let turnID=input.id
        segment.onText={ [weak self,weak input] text in
            guard let self,let input,self.scopeValid(stamp),self.input===input else{return}
            input.previews[segmentID]=text;self.preview=input.preview;mark("app_caption");if let i=recoveries.firstIndex(where:{$0.id==input.id.uuidString}) {recoveries[i].text=input.preview;persistRecoveries()}
        }
        segment.onFailure={ [weak self,weak input] text in if let self,let input,self.scopeValid(stamp),self.input===input {self.failInput(text)} }
        segment.onReady={ [weak self] in if self?.scopeValid(stamp)==true {self?.mark("upstream_ready")} }
        segment.onTiming={ [weak self] name in if self?.scopeValid(stamp)==true {self?.mark(name,segment:segmentID,turn:turnID)} }
        segment.open()
        if !prefix.isEmpty {try input.write(prefix);input.lastWrittenSample=sample;segment.append(prefix)}
        phase = .listening
    }
    private func sealCurrent(stamp:UUID) {
        guard let input,let current=input.current else{return}
        input.current=nil;input.lastEndSample=sample;current.seal();phase = .finalizing;mark("endpoint_candidate")
        segments[current.id]=Task { [weak self,weak input] in
            guard let self,let input else{return};defer{segments[current.id]=nil}
            do {
                let text=try await current.result()
                guard scopeValid(stamp),self.input===input,!input.failed else{return}
                input.results[current.id]=text;preview=input.preview;trySubmit(stamp:stamp)
            } catch {if scopeValid(stamp),self.input===input {failInput(error.localizedDescription)}}
        }
    }
    func releaseHold(cancelled:Bool) {
        guard mode == .hold || holding else{return};holding=false
        if cancelled {discard();return}
        if capture==nil {epoch=UUID();beginTask?.cancel();mode=nil;phase = .idle;notice="尚未开始收音，请重新按住说话。";return}
        sealCurrent(stamp:epoch);capture?.stop();releaseAudio(keepCapture:true)
    }
    private func trySubmit(stamp:UUID) {
        guard scopeValid(stamp),let input,!input.committed,!input.failed,input.current==nil,input.segments.allSatisfy({input.results[$0.id] != nil}) else{return}
        if mode == .continuous && (voiced>0 || quiet<50) {return}
        let text=input.preview.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else{removeRecovery(input.id.uuidString);input.clear();self.input=nil;preview="";if mode == .hold {mode=nil};phase = .listening;notice="没有识别到可发送的文字。";return}
        guard text.count<=12000 else{failInput("这句话超过输入长度，请分段发送。");return}
        input.committed=true;inflight.insert(input.id);self.input=nil;mark("turn_committed");phase = .submitting
        if mode == .hold {capture=nil;mode=nil}
        guard let api,let thread,let workspace else{return}
        let scope=VoiceScope(api:api,thread:thread,workspace:workspace,backend:backend,session:session,continuous:capture != nil && mode == .continuous)
        if let question=input.question {consumedQuestions.insert(question.input);waitingQuestion=nil}
        preserve(input,text:text,request:input.request.uuidString,unknown:true,scope:scope)
        Task {await submit(input,text:text,stamp:stamp,scope:scope)}
    }
    private func submit(_ value:VoiceInput,text:String,stamp:UUID,scope:VoiceScope) async {
        defer {inflight.remove(value.id)}
        let api=scope.api;let thread=scope.thread;let continuous=scope.continuous
        var body:[String:Any]=["thread_id":thread,"content":text,"client_request_id":value.request.uuidString,"voice_session_id":scope.session.uuidString,"input_turn_id":value.id.uuidString,"generation_id":value.generation.uuidString,"continuous":continuous]
        if continuous && scopeValid(stamp) {reply=(value.request,value.generation,stamp)}
        do {
            if value.requestBody==nil {
                let tasks:[AgentTask]=try await api.all("/v1/agent/tasks?thread_id="+thread)
                let waiting=tasks.first(where:{$0.status=="waiting_input"})
                if let expected=value.question {
                    guard let waiting,waiting.id==expected.task,waiting.attempt==expected.attempt,waiting.input_request?.id==expected.input else{throw PrototypeError.message("VOICE_INPUT_CHANGED：等待的问题已变化，这句话已保留。")}
                    body["task_id"]=expected.task;body["input_id"]=expected.input;body["expected_attempt"]=expected.attempt
                } else if waiting != nil {throw PrototypeError.message("VOICE_INPUT_CHANGED：Candid 正在等另一个问题的回答，这句话已保留。")}
                value.requestBody=body;preserve(value,text:text,request:value.request.uuidString,unknown:true,scope:scope)
            }
            let task:AgentTask=try await api.call("/v1/voice/turns",method:"POST",body:value.requestBody!)
            if pendingCancel.contains(value.request) || cancelledRequests.contains(value.request) {
                _=try? await api.raw("/v1/voice/threads/"+thread+"/requests/"+value.request.uuidString+"/cancel",method:"POST")
                pendingCancel.remove(value.request)
            } else if continuous,scopeValid(stamp),reply?.generation==value.generation {startOutput(task:task,generation:value.generation,stamp:stamp)}
            removeRecovery(value.id.uuidString);value.clear()
            if let store,thread==store.chatThread?.id,scope.backend==identity(store.api) {try? await store.loadChat(thread)}
            if scopeValid(stamp),!continuous {phase = .idle;preview=""}
        } catch {
            if pendingCancel.contains(value.request) || cancelledRequests.contains(value.request) {removeRecovery(value.id.uuidString);value.clear();return}
            let definitive=error.localizedDescription.contains("VOICE_INPUT_CHANGED") || error.localizedDescription.contains("REQUEST_CONFLICT") || error.localizedDescription.contains("WORKSPACE_ARCHIVED")
            preserve(value,text:text,request:definitive ? nil:value.request.uuidString,unknown:!definitive,scope:scope)
            if epoch==stamp {notice="发送结果未确认，已保留这句话；请核对后继续。";phase = .failed}
        }
    }
    private func interruptReply() {
        stopOutput()
        guard let reply,reply.epoch==epoch,let api,let thread else{self.reply=nil;return}
        pendingCancel.insert(reply.request);cancelledRequests.insert(reply.request);if cancelledRequests.count>256 {cancelledRequests=[reply.request]};self.reply=nil;response="";mark("barge_stopped")
        Task {
            if (try? await api.raw("/v1/voice/threads/"+thread+"/requests/"+reply.request.uuidString+"/cancel",method:"POST")) != nil {pendingCancel.remove(reply.request)}
            else if epoch==reply.epoch {notice="本机已停止播报，服务器取消尚未确认；新输入仍会保留。"}
        }
    }
    private func startOutput(task:AgentTask,generation:UUID,stamp:UUID) {
        stopOutput();outputFinished=false;response="";phase = .thinking
        guard let api else{return}
        do {
            var components=URLComponents(url:try api.url("/v1/voice/output/"+task.id),resolvingAgainstBaseURL:false)!
            components.scheme=components.scheme=="https" ? "wss":"ws"
            let socket=URLSession.shared.webSocketTask(with:components.url!);output=socket;socket.resume();lastAudioSeq=0;audioBytes=0
            outputTask=Task { [weak self] in
                guard let self else{return}
                do {
                    try await socket.send(.string(String(data:JSONSerialization.data(withJSONObject:["token":api.token,"generation_id":generation.uuidString]),encoding:.utf8)!))
                    while scopeValid(stamp),reply?.generation==generation,!Task.isCancelled {
                        let value=try await socket.receive();guard scopeValid(stamp),reply?.generation==generation,!Task.isCancelled else{return};let data:Data
                        switch value {case .data(let bytes):data=bytes;case .string(let text):data=Data(text.utf8);@unknown default:continue}
                        guard let event=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{continue}
                        if event["type"] as? String=="error" {throw PrototypeError.message(event["message"] as? String ?? "播报已停止。")}
                        guard (event["generation_id"] as? String)?.lowercased()==generation.uuidString.lowercased(),event["task_id"] as? String==task.id else{throw PrototypeError.message("播报轮次已变化。")}
                        if event["type"] as? String=="text",let text=event["text"] as? String {response+=text;mark("tts_text");if event["kind"] as? String=="prompt",let input=event["input_id"] as? String,let attempt=event["attempt"] as? Int {waitingQuestion=VoiceQuestion(task:task.id,input:input,attempt:attempt)}}
                        if event["type"] as? String=="audio",let encoded=event["audio"] as? String,let audio=Data(base64Encoded:encoded),let seq=event["seq"] as? Int {
                            guard seq==lastAudioSeq+1,audioBytes+audio.count<=1_000_000 else{throw PrototypeError.message("播报连接未能及时播放，文字仍可查看。")}
                            lastAudioSeq=seq;audioBytes+=audio.count;mark("tts_audio")
                            try capture?.play(audio) { [weak self] in
                                guard let self,self.scopeValid(stamp),self.reply?.generation==generation else{return}
                                audioBytes=max(0,audioBytes-audio.count)
                                let previous=outputControl
                                outputControl=Task {await previous?.value;try? await socket.send(.string("{\"type\":\"played\",\"seq\":\(seq)}"))}
                            }
                        }
                        if event["type"] as? String=="finished" {outputFinished=true;if !isPlaying && input==nil {phase = .listening};return}
                    }
                } catch {if scopeValid(stamp),reply?.generation==generation {notice=error.localizedDescription;stopOutput();if input==nil {phase = .listening}}}
            }
        } catch {notice=error.localizedDescription}
    }
    private func stopOutput() {outputTask?.cancel();outputControl?.cancel();output?.cancel(with:.goingAway,reason:nil);output=nil;capture?.stopPlayback();isPlaying=false;candidatePaused=false;audioBytes=0}
    private func releaseAudio(keepCapture:Bool=false) {if let lease {store?.audio.release(lease)};lease=nil;if !keepCapture {capture=nil};vad=nil}
    func pause(reason:String?=nil) {
        guard active else{return};epoch=UUID();beginTask?.cancel();holding=false
        if let input,!input.committed {preserve(input,text:input.preview,request:nil,unknown:false);input.segments.forEach{$0.abort()};self.input=nil}
        segments.values.forEach{$0.cancel()};segments=[:];stopOutput();capture?.stop();releaseAudio();microphonePaused=true;phase = .paused;notice=reason
        if mode == .hold {mode=nil}
    }
    func resume() {guard let store,mode == .continuous,microphonePaused else{return};begin(store:store,continuous:true)}
    func discard() {
        epoch=UUID();beginTask?.cancel();input?.segments.forEach{$0.abort()};if let input {removeRecovery(input.id.uuidString);input.clear()};input=nil
        segments.values.forEach{$0.cancel()};segments=[:];stopOutput();capture?.stop();releaseAudio();holding=false;cancelling=false;preview="";phase = .idle
        if mode == .hold {mode=nil}
    }
    func exit() {pause();mode=nil;showContinuous=false;phase = .idle;microphonePaused=false;reply=nil}
    func contextChanged() {if active {exit();notice="已退出语音，开始时的消息仍保留在原空间。"}}
    private func failInput(_ text:String) {input?.failed=true;pause(reason:text);phase = .failed}
    private func preserve(_ value:VoiceInput,text:String,request:String?,unknown:Bool,scope:VoiceScope?=nil) {
        guard let thread=scope?.thread ?? thread,let workspace=scope?.workspace ?? workspace else{return}
        recoveries.removeAll{$0.id==value.id.uuidString}
        recoveries.append(VoiceRecovery(id:value.id.uuidString,path:value.path.path,created:Date(),backend:scope?.backend ?? backend,thread:thread,workspace:workspace,text:text,requestID:request,unknown:unknown))
        persistRecoveries();purgeRecoveries()
    }
    private func persistRecoveries() {try? FileManager.default.createDirectory(at:recoveryURL.deletingLastPathComponent(),withIntermediateDirectories:true);if let data=try? JSONEncoder().encode(recoveries) {try? data.write(to:recoveryURL,options:[.atomic,.completeFileProtection])}}
    func refreshRecoveries() {purgeRecoveries()}
    private func purgeRecoveries() {
        var bytes=0;var keep:[VoiceRecovery]=[]
        for item in recoveries.sorted(by:{$0.created>$1.created}) {
            let size=(try? FileManager.default.attributesOfItem(atPath:item.path)[.size] as? Int) ?? 0
            if Date().timeIntervalSince(item.created)<=86400 && bytes+size<=20_000_000 && keep.count<50 {keep.append(item);bytes+=size}
            else {try? FileManager.default.removeItem(atPath:item.path)}
        }
        let retained=Set(keep.map{$0.path})
        let folder=recoveryURL.deletingLastPathComponent().appendingPathComponent("VoiceInputs")
        for file in (try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? [] where file.pathExtension=="pcm" && !retained.contains(file.path) {try? FileManager.default.removeItem(at:file)}
        if keep.count<recoveries.count {notice="已清理过期或超出保留空间的未完成语音。"}
        recoveries=keep;persistRecoveries()
    }
    func retranscribe(_ row:VoiceRecovery,store:Store) {
        guard !active,row.requestID==nil,row.backend==identity(store.api),row.workspace==store.currentProjectSpace?.id else{notice="请先结束语音，并返回原空间后恢复。";return}
        recoveryTask?.cancel();let api=store.api;let captured=identity(api)
        recoveryTask=Task {
            let segment=VoiceASRSegment(api:api,session:UUID(),turn:UUID(),epoch:UUID(),startSample:0)
            defer {segment.abort();recoveryTask=nil}
            do {
                let data=try Data(contentsOf:URL(fileURLWithPath:row.path));guard !data.isEmpty else{removeRecovery(row.id);notice="没有可恢复的音频，请重新说。";return};notice="正在恢复这句话的转写…";segment.open()
                try await segment.waitUntilReady()
                for offset in stride(from:0,to:data.count,by:3200) {
                    try Task.checkCancellation()
                    guard identity(store.api)==captured,store.currentProjectSpace?.id==row.workspace else{throw CancellationError()}
                    segment.append(data.subdata(in:offset..<min(data.count,offset+3200)));try await Task.sleep(for:.milliseconds(100))
                }
                segment.seal();let text=try await segment.result()
                guard identity(store.api)==captured,store.currentProjectSpace?.id==row.workspace else{return}
                store.saveChatDraft(text);notice="恢复转写已完成，检查文字后即可发送。"
            } catch {notice="恢复未完成，原输入仍保留。"}
        }
    }
    func removeRecovery(_ id:String) {for row in recoveries where row.id==id {try? FileManager.default.removeItem(atPath:row.path)};recoveries.removeAll{$0.id==id};persistRecoveries()}
    func recoverText(_ row:VoiceRecovery,store:Store) async {
        guard row.backend==identity(store.api),row.workspace==store.currentProjectSpace?.id else {notice="请返回这句话原来的空间与后端后恢复。";return}
        do {
            if let request=row.requestID {
                let data=try await store.api.raw("/v1/voice/threads/"+row.thread+"/requests/"+request)
                let value=try JSONSerialization.jsonObject(with:data) as? [String:Any]
                if value?["status"] as? String=="accepted" {removeRecovery(row.id);try? await store.loadChat(row.thread);notice="已找到之前提交的消息。";return}
                if value?["status"] as? String=="cancelled" {removeRecovery(row.id);notice="这句话已经取消。";return}
                notice="尚未确认发送结果，请稍后再次核对；没有重新发送。";return
            }
            if !row.text.isEmpty {store.saveChatDraft(row.text);notice="已恢复可编辑文字，请核对后发送；原音频仍保留。"} else {notice="原音频仍保留，可选择重新转写或重说。"}
        } catch {notice="尚无法核对发送结果，请稍后再试。"}
    }
}
