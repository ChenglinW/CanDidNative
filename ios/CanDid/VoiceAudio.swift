import Foundation
import AVFoundation
import Combine

@MainActor final class AudioResources: ObservableObject {
    enum Owner:Hashable { case voice, meeting, manualSpeech, recordingPlayback }
    @Published private(set) var owner: Owner?
    private var leases:[UUID:Owner]=[:]
    func acquire(_ kind:Owner)throws->UUID {
        let combined=Set(leases.values).union([kind])
        guard !leases.values.contains(kind),leases.isEmpty || combined.isSubset(of:[.voice,.meeting]) else {throw PrototypeError.message("当前播放正在使用音频，请先暂停播放。")}
        let value=UUID();leases[value]=kind;owner=kind;return value
    }
    func release(_ value:UUID) {leases.removeValue(forKey:value);owner=leases.values.first}
    func owns(_ value:UUID)->Bool {leases[value] != nil}
    var voiceActive:Bool {leases.values.contains(.voice)}

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
    static let shared=VoiceCapture()
    private var meetingHandler:((Data)->Void)?
    var onMeetingFrame:((Data)->Void)? {
        get {stateLock.lock();defer{stateLock.unlock()};return meetingHandler}
        set {stateLock.lock();meetingHandler=newValue;stateLock.unlock()}
    }
    private var meetingPaused=false
    func setMeetingPaused(_ paused:Bool){stateLock.lock();meetingPaused=paused;stateLock.unlock()}
    let engine=AVAudioEngine()
    let player=AVAudioPlayerNode()
    // Keep the input in the rendered graph, without monitoring the microphone.
    // A tap on an unconnected voice-processing input can start but deliver no buffers.
    private let captureSink=AVAudioMixerNode()
    private var capturedBytes=0
    var capturedPCMBytes:Int {stateLock.lock();defer{stateLock.unlock()};return capturedBytes}
    private var epoch=UUID()
    private var scheduled=0
    private var stopped=false
    private var tapInstalled=false
    private let stateLock=NSLock()
    private var frameHandler:((Data)->Void)?
    var onFrame:((Data)->Void)? {
        get {stateLock.lock();defer{stateLock.unlock()};return frameHandler}
        set {stateLock.lock();frameHandler=newValue;stateLock.unlock()}
    }
    var onError: (()->Void)?
    var onPlaybackChanged: ((Bool)->Void)?
    func start(voiceProcessing:Bool=true) throws {
        if engine.isRunning {return}
        stateLock.lock();stopped=false;capturedBytes=0;stateLock.unlock()
        let session=AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,mode:voiceProcessing ? .voiceChat:.measurement,options:voiceProcessing ? [.defaultToSpeaker,.allowBluetoothHFP]:[.defaultToSpeaker])
        if !voiceProcessing {
            try session.setPreferredSampleRate(48000)
            if let microphone=session.availableInputs?.first(where:{$0.portType == .builtInMic}) {try session.setPreferredInput(microphone)}
        }
        try session.setActive(true)
        try engine.inputNode.setVoiceProcessingEnabled(voiceProcessing)
        if voiceProcessing {engine.inputNode.isVoiceProcessingInputMuted=false}
        let input=engine.inputNode;let format=input.outputFormat(forBus:0)
        guard format.sampleRate>0,let target=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:true),let converter=AVAudioConverter(from:format,to:target) else {throw PrototypeError.message("麦克风格式不可用。")}
        if player.engine==nil {
            engine.attach(player)
            engine.connect(player,to:engine.mainMixerNode,format:AVAudioFormat(standardFormatWithSampleRate:24000,channels:1))
        }
        if captureSink.engine==nil {engine.attach(captureSink)}
        captureSink.outputVolume=0
        engine.connect(input,to:captureSink,format:format)
        engine.connect(captureSink,to:engine.mainMixerNode,format:format)
        print("CanDid capture start: rate=\(format.sampleRate) channels=\(format.channelCount) voiceProcessing=\(voiceProcessing) route=\(session.currentRoute.inputs.map(\.portType.rawValue))")
        var loggedInput=false;var loggedConversionError=false
        input.installTap(onBus:0,bufferSize:1024,format:format) { [weak self] buffer,_ in
            guard let self else{return};self.stateLock.lock();let active = !self.stopped;self.stateLock.unlock();guard active else{return}
            if !loggedInput {loggedInput=true;print("CanDid capture: first input frames=\(buffer.frameLength)")}
            let capacity=AVAudioFrameCount(Double(buffer.frameLength)*16000/format.sampleRate)+32
            guard let output=AVAudioPCMBuffer(pcmFormat:target,frameCapacity:capacity) else{return}
            var supplied=false;var error:NSError?
            converter.convert(to:output,error:&error) { _,status in
                if supplied {status.pointee = .noDataNow;return nil};supplied=true;status.pointee = .haveData;return buffer
            }
            guard error==nil,let samples=output.int16ChannelData?[0] else{if !loggedConversionError {loggedConversionError=true;print("CanDid capture conversion error: \(error?.code ?? 0)")};self.onError?();return}
            guard output.frameLength>0 else{return}
            let pcm=Data(bytes:samples,count:Int(output.frameLength)*2)
            self.stateLock.lock();let first=self.capturedBytes==0;self.capturedBytes+=pcm.count;self.stateLock.unlock()
            if first {print("CanDid capture: first PCM buffer bytes=\(pcm.count)")}
            self.onFrame?(pcm)
            self.stateLock.lock();let meetingEnabled = !self.meetingPaused;self.stateLock.unlock()
            if meetingEnabled {self.onMeetingFrame?(pcm)}
        }
        tapInstalled=true
        engine.prepare()
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
        stopPlayback();onFrame=nil;onError=nil
        if onMeetingFrame==nil {stopEngine()}
    }
    @MainActor func stopMeeting() {onMeetingFrame=nil;setMeetingPaused(false);if onFrame==nil {stopEngine()}}
    @MainActor private func stopEngine() {
        stateLock.lock();stopped=true;stateLock.unlock()
        if tapInstalled {engine.inputNode.removeTap(onBus:0);tapInstalled=false};engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)
    }
}
