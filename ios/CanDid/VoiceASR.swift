import Foundation

@MainActor final class VoiceASRSegment {
    let id=UUID()
    let inputTurn:UUID
    let startSample:Int
    private let epoch:UUID
    private let session:UUID
    private let api:API
    private var socket:URLSessionWebSocketTask?
    private var receiver:Task<Void,Never>?
    private var sender:Task<Void,Never>?
    private var queue:[Data]=[]
    private var queueBytes=0
    private var startupAllowance=0
    private var nextSequence=0
    private var ready=false
    private var sealed=false
    private var finishSent=false
    private(set) var done=false
    private var failure:String?
    private var totalBytes=0
    private var sentBytes=0
    private var order:[String]=[]
    private var text:[String:String]=[:]
    private var finals:Set<String>=[]
    var onText:((String)->Void)?
    var onFailure:((String)->Void)?
    var onReady:(()->Void)?
    var onTiming:((String)->Void)?
    init(api:API,session:UUID,turn:UUID,epoch:UUID,startSample:Int) {self.api=api;self.session=session;self.inputTurn=turn;self.epoch=epoch;self.startSample=startSample}
    var preview:String {order.compactMap{text[$0]}.joined()}
    func open() {
        do {
            var components=URLComponents(url:try api.url("/v1/speech/live"),resolvingAgainstBaseURL:false)!
            components.scheme=components.scheme=="https" ? "wss":"ws"
            let task=URLSession.shared.webSocketTask(with:components.url!);socket=task;task.resume()
            receiver=Task { [weak self] in
                guard let self else{return}
                do {
                    try await task.send(.string(String(data:JSONSerialization.data(withJSONObject:["token":api.token,"voice_session_id":session.uuidString,"input_turn_id":inputTurn.uuidString,"segment_id":id.uuidString,"epoch":epoch.uuidString,"offset_ms":startSample/16]),encoding:.utf8)!))
                    while !Task.isCancelled && !done {
                        let message=try await task.receive();let data:Data
                        switch message {case .string(let value):data=Data(value.utf8);case .data(let value):data=value;@unknown default:continue}
                        guard let event=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{continue}
                        if event["type"] as? String=="error" {throw PrototypeError.message(event["message"] as? String ?? "转写不可用。") }
                        guard !done,!Task.isCancelled else{return}
                        guard (event["segment_id"] as? String)?.lowercased()==id.uuidString.lowercased(),(event["epoch"] as? String)?.lowercased()==epoch.uuidString.lowercased() else{throw PrototypeError.message("语音子段已变化。")}
                        switch event["type"] as? String {
                        case "ready":ready=true;startupAllowance=queueBytes;onTiming?("upstream_ready");onReady?();flush()
                        case "transcript":
                            if let sentence=event["sentence"] as? [String:Any],let value=sentence["text"] as? String {
                                let key=String(describing:sentence["sentence_id"] ?? sentence["begin_time"] ?? 0)
                                if text[key]==nil {order.append(key)};text[key]=value
                                if sentence["sentence_end"] as? Bool==true {finals.insert(key)}
                                onTiming?("asr_callback");onText?(preview)
                            }
                        case "finished":
                            guard event["complete"] as? Bool==true,event["audio_gap"] as? Bool != true,(event["audio_bytes"] as? Int)==totalBytes,(event["last_seq"] as? Int)==nextSequence-1,order.filter({!(text[$0] ?? "").isEmpty}).allSatisfy({finals.contains($0)}) else{throw PrototypeError.message("这句话的转写不完整，已保留输入。")}
                            done=true;onTiming?("asr_final");task.cancel(with:.normalClosure,reason:nil)
                        case "error":throw PrototypeError.message(event["message"] as? String ?? "转写连接中断，输入已保留。")
                        default:break
                        }
                    }
                } catch {if !done {fail(error.localizedDescription)}}
            }
        } catch {fail(error.localizedDescription)}
    }
    func append(_ pcm:Data) {
        guard !sealed,!done,failure==nil else{return}
        let limit=ready ? 64000+startupAllowance:320000
        guard queueBytes+pcm.count<=limit else{fail("网络未能及时发送这一句话，已保留输入，请重说或恢复。");return}
        totalBytes+=pcm.count;queueBytes+=pcm.count;queue.append(pcm);flush()
    }
    private func flush() {
        guard ready,sender==nil,!done,failure==nil,let task=socket else{return}
        sender=Task { [weak self] in
            guard let self else{return};defer{sender=nil}
            do {
                while !queue.isEmpty && !done {
                    let frame=queue.removeFirst();let seq=nextSequence;nextSequence+=1
                    try await task.send(.string(String(data:JSONSerialization.data(withJSONObject:["seq":seq,"audio":frame.base64EncodedString()]),encoding:.utf8)!))
                    sentBytes+=frame.count;queueBytes-=frame.count;startupAllowance=max(0,startupAllowance-frame.count);onTiming?("audio_sent")
                }
                if sealed && !finishSent && !done {
                    finishSent=true
                    try await task.send(.string(String(data:JSONSerialization.data(withJSONObject:["type":"finish","last_seq":nextSequence-1]),encoding:.utf8)!))
                }
            } catch {if !done {fail(error.localizedDescription)}}
        }
    }
    func waitUntilReady() async throws {
        let deadline=Date().addingTimeInterval(16)
        while !ready && failure==nil && Date()<deadline {try Task.checkCancellation();try await Task.sleep(for:.milliseconds(40))}
        if let failure {throw PrototypeError.message(failure)}
        guard ready else{throw PrototypeError.message("转写尚未就绪。") }
    }
    func seal() {sealed=true;flush()}
    func result() async throws -> String {
        let deadline=Date().addingTimeInterval(20)
        while !done && failure==nil && Date()<deadline {try Task.checkCancellation();try await Task.sleep(for:.milliseconds(40))}
        if let failure {throw PrototypeError.message(failure)}
        guard done else{fail("最终转写超时，输入已保留。");throw PrototypeError.message(failure!)}
        return preview
    }
    private func fail(_ message:String) {
        guard failure==nil else{return};failure=message;ready=false
        socket?.cancel(with:.goingAway,reason:nil);onFailure?(message)
    }
    func abort() {done=true;receiver?.cancel();sender?.cancel();socket?.cancel(with:.goingAway,reason:nil);queue=[];queueBytes=0}
}
