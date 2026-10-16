import Foundation
import AVFoundation
import Combine
import UIKit

struct PracticeSource:Decodable,Identifiable {var source_id:String;var title:String;var kind:String;var id:String {source_id}}
struct PracticeContext:Decodable {var scenario:String;var goal:String;var persona:String;var workspace_id:String?;var sources:[PracticeSource]}
struct PracticeTurn:Decodable,Identifiable {var id:String;var role:String;var text:String;var generation:Int?}
struct PracticeCorrection:Decodable {var turn_id:String;var quote:String;var reason:String;var suggested_text:String}
struct PracticeReview:Decodable {var summary:String;var strengths:[String];var improvements:[PracticeCorrection]}
struct PracticeSession:Decodable,Identifiable {
    var id:String;var scenario:String;var goal:String;var persona:String;var state:String;var generation:Int;var stage:String
    var turns:[PracticeTurn];var review:PracticeReview?;var hint:String?;var error:String?;var sources:[PracticeSource]
    var item_id:String?;var item_version:Int?;var workspace_id:String?;var created_at:String
}
struct PracticeList:Decodable {var data:[PracticeSession]}
private final class PracticeInput {
    let id=UUID();var segments:[VoiceASRSegment]=[];var finals:[UUID:String]=[:];var previews:[UUID:String]=[:]
    var current:VoiceASRSegment?;var lastSample=0;var resolving=false
    var text:String {segments.map{finals[$0.id] ?? previews[$0.id] ?? ""}.joined()}
}

@MainActor final class PracticeController:ObservableObject {
    @Published var session:PracticeSession?
    @Published var draft=""
    @Published var notice:String?
    @Published var listening=false
    @Published var speaking=false
    @Published var busy=false
    @Published var textMode=false
    @Published var hintPresented=false
    private weak var store:Store?
    private var api:API?
    private var lease:UUID?
    private var epoch=UUID()
    private var input:PracticeInput?
    private var vad:VoiceActivityDetector?
    private var output:URLSessionWebSocketTask?
    private var playback:Task<Void,Never>?
    private var interruption:Task<Void,Never>?
    private var inputTasks:[UUID:Task<Void,Never>]=[:]
    private var spoken:Set<String>=[]
    private var hasStarted=false
    private var candidatePaused=false
    private var sample=0,voiced=0,quiet=0
    private var preroll=Data()
    private var pendingRequest:String?
    private var observer:NSObjectProtocol?
    func configure(_ store:Store){self.store=store;api=store.api
        if observer==nil {observer=NotificationCenter.default.addObserver(forName:AVAudioSession.interruptionNotification,object:nil,queue:.main){[weak self] n in
            if (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)==AVAudioSession.InterruptionType.began.rawValue {Task {@MainActor in self?.pause()}}
        }}
    }
    private func valid(_ stamp:UUID)->Bool {guard let store,let api else{return false};return stamp==epoch && store.api.base==api.base && store.api.token==api.token}
    func accept(_ value:PracticeSession){if let current=session,current.id==value.id,value.generation<current.generation{return};session=value
        if value.state=="completed"{pause()}
        if let e=value.error {notice=e}
        if hasStarted && !listening{spoken.formUnion(value.turns.filter{$0.role=="assistant"}.map(\.id))}
        if value.hint != nil && hintPresented {pause()}
        if listening,!textMode,!busy,value.state=="active",let turn=value.turns.last,turn.role=="assistant",!spoken.contains(turn.id){spoken.insert(turn.id);speak(turn)}
    }
    func refresh() async {guard let api,let id=session?.id else{return};do{let value:PracticeSession=try await api.call("/v1/practice/sessions/"+id);accept(value)}catch{notice=error.localizedDescription}}
    func startVoice() async {
        guard !listening,let store,session?.state != "completed" else{return}
        guard !store.speech.activeMeeting,store.soundcore.recordStatus==0 else{notice="会议录音进行中，可以先用文字练习。";textMode=true;return}
        let stamp=epoch
        do {
            let allowed=await withCheckedContinuation {c in AVAudioApplication.requestRecordPermission{c.resume(returning:$0)}}
            guard valid(stamp),!Task.isCancelled else{return}
            guard allowed else{throw PrototypeError.message("麦克风未获允许，可以切换打字；也可到系统设置开启权限。")}
            store.voice.exit();store.stopPlayback();store.speech.stopPlayback()
            if hasStarted{spoken.formUnion(session?.turns.filter{$0.role=="assistant"}.map(\.id) ?? [])};hasStarted=true
            lease=try store.audio.acquire(.voice);vad=try VoiceActivityDetector();sample=0;voiced=0;quiet=0;preroll=Data();textMode=false
            VoiceCapture.shared.onFrame={[weak self] bytes in Task {@MainActor in self?.consume(bytes,stamp:stamp)}}
            VoiceCapture.shared.onError={[weak self] in Task {@MainActor in self?.notice="收音中断，请点击继续或改用打字。";self?.pause()}}
            VoiceCapture.shared.onPlaybackChanged={[weak self] playing in self?.speaking=playing}
            try VoiceCapture.shared.start();listening=true;notice=nil
            if let turn=session?.turns.last,turn.role=="assistant",!spoken.contains(turn.id){spoken.insert(turn.id);speak(turn)}
        } catch {notice=error.localizedDescription;pause();textMode=true}
    }
    private func consume(_ bytes:Data,stamp:UUID){guard valid(stamp),listening,let vad else{return}
        do {for (frame,speech,_) in try vad.frames(bytes){sample+=320;preroll.append(frame);if preroll.count>9600{preroll.removeFirst(preroll.count-9600)}
            if speech{voiced+=1;quiet=0}else{voiced=0;quiet+=1}
            if voiced==2 && speaking{candidatePaused=true;VoiceCapture.shared.pausePlayback()}
            if voiced>=6 {
                if input==nil{barge();input=PracticeInput();draft=""}
                if input?.current==nil{try startSegment(stamp)}
                candidatePaused=false
            }
            if let value=input,let segment=value.current,value.lastSample<sample {segment.append(frame);value.lastSample=sample;draft=value.text}
            if quiet>=18,candidatePaused{candidatePaused=false;VoiceCapture.shared.resumePlayback()}
            if quiet>=50,let value=input,let segment=value.current {
                value.current=nil;segment.seal();inputTasks[segment.id]=Task {[weak self,weak value] in
                    defer{self?.inputTasks[segment.id]=nil}
                    do{let text=try await segment.result();guard let self,let value,self.valid(stamp),self.input===value else{return};value.finals[segment.id]=text;self.draft=value.text;self.commitIfReady(stamp)}
                    catch{guard let self,self.valid(stamp) else{return};self.notice=error.localizedDescription;self.pause()}
                }
            }
            if quiet>=50{commitIfReady(stamp)}
        }}catch{notice=error.localizedDescription;pause()}
    }
    private func startSegment(_ stamp:UUID)throws{guard let api,let session,let value=input else{return}
        let start=max(0,sample-preroll.count/2)
        let segment=VoiceASRSegment(api:api,session:UUID(uuidString:session.id) ?? UUID(),turn:value.id,epoch:stamp,startSample:start)
        value.current=segment;value.segments.append(segment);value.lastSample=sample
        segment.onText={[weak self,weak value] text in guard let self,let value,self.valid(stamp),self.input===value else{return};value.previews[segment.id]=text;self.draft=value.text}
        segment.onFailure={[weak self] text in guard let self,self.valid(stamp) else{return};self.notice=text;self.pause()}
        segment.open();segment.append(preroll)
    }
    private func commitIfReady(_ stamp:UUID){guard valid(stamp),quiet>=50,let value=input,value.current==nil,!value.resolving,value.segments.allSatisfy({value.finals[$0.id] != nil}) else{return}
        value.resolving=true;input=nil;let text=value.text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else{draft="";return};draft=text;Task{await send(text)}
    }
    func barge(){stopOutput();guard let session,session.state != "completed",let api else{return}
        let old=interruption
        interruption=Task{await old?.value;do{let value:PracticeSession=try await api.call("/v1/practice/sessions/"+session.id+"/interrupt",method:"POST");accept(value)}catch{notice=error.localizedDescription}}
    }
    func send(_ text:String) async {guard !busy,let api,let id=session?.id,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return}
        busy=true;defer{busy=false};notice=nil
        barge();await interruption?.value
        guard let current=session else{return}
        let request=pendingRequest ?? UUID().uuidString;pendingRequest=request
        do {let value:PracticeSession=try await api.call("/v1/practice/sessions/"+id+"/turns",method:"POST",body:["client_request_id":request,"text":text,"generation":current.generation]);accept(value);pendingRequest=nil;if draft==text{draft=""}}
        catch{notice=error.localizedDescription;draft=text}
    }
    func pause(){epoch=UUID();input?.segments.forEach{$0.abort()};input=nil;inputTasks.values.forEach{$0.cancel()};inputTasks=[:];stopOutput()
        if listening || lease != nil {VoiceCapture.shared.stop();VoiceCapture.shared.onPlaybackChanged=nil}
        if let lease{store?.audio.release(lease)};lease=nil;vad=nil;listening=false
    }
    func toggleText(){textMode.toggle();if textMode{pause()}else{Task{await startVoice()}}}
    func command(_ name:String) async {guard let api,let id=session?.id,!busy else{return};busy=true;defer{busy=false};pause();barge();await interruption?.value
        do{let value:PracticeSession=try await api.call("/v1/practice/sessions/"+id+"/"+name,method:"POST");accept(value);if name=="hint"{hintPresented=true}}catch{notice=error.localizedDescription}
    }
    func retry() async{guard let api,let id=session?.id else{return};notice=nil;do{let value:PracticeSession=try await api.call("/v1/practice/sessions/"+id+"/retry",method:"POST");accept(value)}catch{notice=error.localizedDescription}}
    private func stopOutput(){playback?.cancel();output?.cancel(with:.goingAway,reason:nil);output=nil;if lease != nil{VoiceCapture.shared.stopPlayback()};speaking=false;candidatePaused=false}
    private func speak(_ turn:PracticeTurn){stopOutput();guard let api,let session,listening else{return};let stamp=epoch;let generation=session.generation
        do{var components=URLComponents(url:try api.url("/v1/practice/sessions/"+session.id+"/audio/"+turn.id),resolvingAgainstBaseURL:false)!;components.scheme=components.scheme=="https" ? "wss":"ws"
            let socket=URLSession.shared.webSocketTask(with:components.url!);output=socket;socket.resume()
            playback=Task{[weak self] in guard let self else{return}
                do{try await socket.send(.string(String(data:JSONSerialization.data(withJSONObject:["token":api.token,"generation":generation]),encoding:.utf8)!))
                    while valid(stamp),listening,!Task.isCancelled {
                        let message=try await socket.receive();let bytes:Data;switch message{case .string(let s):bytes=Data(s.utf8);case .data(let b):bytes=b;@unknown default:continue}
                        guard let event=try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else{continue}
                        if event["type"] as? String=="error"{throw PrototypeError.message(event["message"] as? String ?? "播报失败，可继续查看文字。")}
                        if event["type"] as? String=="finished"{return}
                        if event["type"] as? String=="audio",event["generation"] as? Int==generation,let seq=event["seq"] as? Int,let text=event["audio"] as? String,let pcm=Data(base64Encoded:text){
                            guard valid(stamp),!Task.isCancelled else{return}
                            try VoiceCapture.shared.play(pcm){[weak self] in guard let self,self.valid(stamp) else{return};Task{try? await socket.send(.string("{\"type\":\"played\",\"seq\":\(seq)}"))}}
                        }
                    }
                }catch{if valid(stamp),!Task.isCancelled{notice=error.localizedDescription}}
            }
        }catch{notice=error.localizedDescription}
    }
    func close(){pause();interruption?.cancel();if let observer{NotificationCenter.default.removeObserver(observer)};observer=nil}
}
