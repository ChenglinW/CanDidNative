import Foundation
import AVFoundation
import Combine

@MainActor final class AudioResources: ObservableObject {
    enum Owner { case voice, meeting, manualSpeech, recordingPlayback }
    @Published private(set) var owner: Owner?
    private var lease: UUID?
    func acquire(_ kind: Owner) throws -> UUID {
        guard owner == nil else { throw PrototypeError.message("当前音频正在使用，请先暂停或结束现有模式。") }
        let value=UUID();owner=kind;lease=value;return value
    }
    func release(_ value: UUID) { guard lease==value else{return};owner=nil;lease=nil }
    func owns(_ value: UUID) -> Bool { lease==value }
    var voiceActive: Bool { owner == .voice }
}

final class VoiceActivityDetector {
    private var handle: OpaquePointer?
    private var pending=Data()
    init() throws {
        handle=WebRtcVad_Create()
        guard let handle,WebRtcVad_Init(handle)==0,WebRtcVad_set_mode(handle,2)==0 else {throw PrototypeError.message("人声检测初始化失败。")}
    }
    deinit { if let handle {WebRtcVad_Free(handle)} }
    func frames(_ pcm: Data) throws -> [(Data,Bool,Float)] {
        pending.append(pcm);var result:[(Data,Bool,Float)]=[]
        while pending.count>=640 {
            let frame=Data(pending.prefix(640));pending.removeFirst(640)
            let values=frame.withUnsafeBytes { Array($0.bindMemory(to:Int16.self)) }
            let vad=values.withUnsafeBufferPointer { WebRtcVad_Process(handle,16000,$0.baseAddress,320) }
            guard vad>=0 else{throw PrototypeError.message("人声音频格式异常。")}
            let rms=sqrt(values.reduce(Float(0)) { $0+pow(Float($1)/32768,2) }/320)
            result.append((frame,vad==1,rms))
        }
        return result
    }
}

// Conversion is serialized on the input tap. UI/state crosses to MainActor only with owned bytes.
final class VoiceCapture {
    let engine=AVAudioEngine()
    let player=AVAudioPlayerNode()
    private var epoch=UUID()
    private var scheduled=0
    private var stopped=false
    private var tapInstalled=false
    private let stateLock=NSLock()
    var onFrame: ((Data)->Void)?
    var onError: (()->Void)?
    var onPlaybackChanged: ((Bool)->Void)?
    func start() throws {
        let session=AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,mode:.voiceChat,options:[.defaultToSpeaker,.allowBluetoothHFP])
        try session.setActive(true)
        try engine.inputNode.setVoiceProcessingEnabled(true)
        let input=engine.inputNode;let format=input.outputFormat(forBus:0)
        guard format.sampleRate>0,let target=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:true),let converter=AVAudioConverter(from:format,to:target) else {throw PrototypeError.message("麦克风格式不可用。")}
        engine.attach(player)
        engine.connect(player,to:engine.mainMixerNode,format:AVAudioFormat(standardFormatWithSampleRate:24000,channels:1))
        input.installTap(onBus:0,bufferSize:1024,format:format) { [weak self] buffer,_ in
            guard let self else{return};self.stateLock.lock();let active = !self.stopped;self.stateLock.unlock();guard active else{return}
            let capacity=AVAudioFrameCount(Double(buffer.frameLength)*16000/format.sampleRate)+32
            guard let output=AVAudioPCMBuffer(pcmFormat:target,frameCapacity:capacity) else{return}
            var supplied=false;var error:NSError?
            converter.convert(to:output,error:&error) { _,status in
                if supplied {status.pointee = .noDataNow;return nil};supplied=true;status.pointee = .haveData;return buffer
            }
            guard error==nil,let samples=output.int16ChannelData?[0] else{self.onError?();return}
            self.onFrame?(Data(bytes:samples,count:Int(output.frameLength)*2))
        }
        tapInstalled=true
        try engine.start()
    }
    @MainActor func play(_ pcm:Data,completion:@escaping ()->Void) throws {
        guard engine.isRunning,pcm.count%2==0,pcm.count>0,let format=AVAudioFormat(standardFormatWithSampleRate:24000,channels:1),let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(pcm.count/2)),let output=buffer.floatChannelData?[0] else {throw PrototypeError.message("播报音频不可用。")}
        let values=pcm.withUnsafeBytes {Array($0.bindMemory(to:Int16.self))}
        buffer.frameLength=AVAudioFrameCount(values.count)
        for i in values.indices {output[i]=Float(values[i])/32768}
        let stamp=epoch;scheduled+=1;onPlaybackChanged?(true)
        player.scheduleBuffer(buffer,completionCallbackType:.dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self,self.epoch==stamp else{return};self.scheduled=max(0,self.scheduled-1)
                if self.scheduled==0 {self.onPlaybackChanged?(false)};completion()
            }
        }
        if !player.isPlaying {player.play()}
    }
    @MainActor func stopPlayback() {epoch=UUID();scheduled=0;player.stop();onPlaybackChanged?(false)}
    @MainActor func pausePlayback() {player.pause();onPlaybackChanged?(false)}
    @MainActor func resumePlayback() {if scheduled>0 {player.play();onPlaybackChanged?(true)}}
    @MainActor func stop() {
        stateLock.lock();stopped=true;stateLock.unlock();stopPlayback();onFrame=nil;onError=nil
        if tapInstalled {engine.inputNode.removeTap(onBus:0);tapInstalled=false};engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)
    }
}
