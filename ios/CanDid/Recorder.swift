import Foundation
import AVFoundation
import Combine

@MainActor final class Recorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var recording = false
    @Published var paused = false
    @Published var elapsed = 0
    @Published var interrupted = false
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    override init() {
        super.init()
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.interrupt() }
        }
    }
    func start(id: String) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw PrototypeError.message("麦克风权限未开启。请到系统设置开启，或使用文字口述复盘。") }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try audio.setActive(true)
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent(id+".m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        let value = try AVAudioRecorder(url: url, settings: settings); value.delegate = self; value.prepareToRecord()
        guard value.record() else { throw PrototypeError.message("无法开始录音") }
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        try? url.setResourceValues(resource)
        recorder = value; recording = true; paused = false; interrupted = false; elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: .5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = Int(self?.recorder?.currentTime ?? 0) }
        }
    }
    func pause() { if paused { recorder?.record(); paused = false } else { recorder?.pause(); paused = true } }
    func interrupt() { if recording { recorder?.pause(); paused = true; interrupted = true } }
    func stop() -> URL? {
        elapsed = Int(recorder?.currentTime ?? 0); recorder?.stop(); timer?.invalidate(); timer = nil
        recording = false; paused = false
        try? AVAudioSession.sharedInstance().setActive(false)
        return recorder?.url
    }
    func mark() -> Int { Int((recorder?.currentTime ?? 0) * 1000) }
    // No background audio entitlement: recording is paused when the app leaves foreground.
}
