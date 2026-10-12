import Foundation
import Combine
import UIKit
import module_spplinkKit

struct SoundcoreAuth: Codable {
    var userID = ""
    var deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    var token = ""
    var license = ""
    var signature = ""
    var production = false
    static func load() -> SoundcoreAuth {
        let saved = TokenVault.read(account: "soundcore-auth")
        return (try? JSONDecoder().decode(Self.self, from: Data(saved.utf8))) ?? Self()
    }
    var valid: Bool {
        !userID.isEmpty && !deviceID.isEmpty && (!token.isEmpty || (!license.isEmpty && !signature.isEmpty))
    }
    func save() throws {
        try TokenVault.save(String(decoding: JSONEncoder().encode(self), as: UTF8.self), account: "soundcore-auth")
    }
}

struct SoundcoreDevice: Identifiable {
    var name: String
    var mac: String
    var uuid: String
    var id: String { uuid }
}
struct SoundcoreFile: Identifiable {
    let info: FileInfoModel
    var id: Int32 { info.time }
    var durationMS: Int { Int(info.duration) }
    var title: String { Date(timeIntervalSince1970: Double(UInt32(bitPattern: id))).formatted(date: .abbreviated, time: .shortened) }
}

// The SDK exposes Objective-C callbacks which can arrive on a background thread.
// The bridge forwards them to this single main-actor owner.
@MainActor final class Soundcore: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var scanning = false
    @Published private(set) var connecting = false
    @Published private(set) var devices: [SoundcoreDevice] = []
    @Published private(set) var connected: SoundcoreDevice?
    @Published private(set) var files: [SoundcoreFile] = []
    @Published private(set) var status = "连接 soundcore 后同步设备录音"
    @Published private(set) var error: String?
    @Published private(set) var recordStatus: Int32 = 0
    @Published private(set) var durationMS = 0
    @Published private(set) var currentFileID: Int32?
    @Published private(set) var progress: Double = 0
    @Published private(set) var transferring = false
    private let sdk = SoundcoreSDK.companion.proxy
    private let callbacks = SoundcoreCallbacks()
    private var candidate: SoundcoreDevice?
    private var pendingFileID: Int32?
    private var transferFolder: URL?
    private var transfer: CheckedContinuation<URL, Error>?
    private var timeout: Task<Void, Never>?
    private var scanTimeout: Task<Void, Never>?
    private var authenticationTimeout: Task<Void, Never>?
    private var connectionTimeout: Task<Void, Never>?
    private var initializing = false

    static var simulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    init() {
        callbacks.event = { [weak self] event in Task { @MainActor in self?.handle(event) } }
    }
    func initialize(_ auth: SoundcoreAuth) throws {
        guard !Self.simulator else { throw PrototypeError.message("模拟器可验证页面和音频处理；请在 iPhone 真机上连接 soundcore。") }
        guard !initializing, !ready else { return }
        guard auth.valid else { throw PrototypeError.message("请填写与云端 token/license 匹配的用户 ID、设备 ID 和鉴权数据。app_id/app_key 需由鉴权服务换取 token。") }
        try auth.save()
        error = nil; initializing = true; status = "正在验证 soundcore 授权…"
        let config = SDKInitConfig(context: UIApplication.shared, userId: auth.userID, deviceId: auth.deviceID,
            token: auth.token, licenseJson: auth.license, license_signature: auth.signature,
            environment: auth.production ? .production : .development, isDebug: KotlinBoolean(bool: false),
            firmwareLogFilePath: nil, commandTimeOut: 5, fileTransferInterval: 200,
            isSPPSingleThread: false, androidUDPPingTimeIntval: 100, androidWIFIReceiveThreadSwitch: true)
        sdk.doInitSDK(logInterface: callbacks, config: config, authResultListener: callbacks)
        authenticationTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.initializing else { return }
            self.initializing = false; self.error = "soundcore 鉴权超时，请检查网络和授权数据。"
            self.status = "授权未完成"; self.sdk.close()
        }
    }
    func scan() throws {
        guard ready, !Self.simulator else { throw PrototypeError.message("请先在真机上完成 soundcore 授权。") }
        guard !scanning, !connecting, !transferring else { return }
        error = nil; scanning = true; devices = []; status = "正在查找 soundcore 设备…"
        sdk.startScan(bleScan: true, sppScan: false, filters: NSMutableArray(), onReceiveScanResult: callbacks)
        scanTimeout?.cancel()
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self else { return }
            self.stopScan()
        }
    }
    func stopScan() {
        scanTimeout?.cancel(); scanTimeout = nil
        if scanning { sdk.stopScan() }
        scanning = false
    }
    func connect(_ device: SoundcoreDevice) {
        guard ready, !connecting, !transferring, connected == nil else { return }
        stopScan(); error = nil; connecting = true; candidate = device
        status = "正在连接 \(device.name)…"
        sdk.connect(macAddress: device.mac, uuid: device.uuid, listener: callbacks)
        connectionTimeout?.cancel()
        connectionTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.connecting else { return }
            self.disconnect(); self.error = "soundcore 连接超时，请检查设备和蓝牙后重试。"
        }
    }
    func disconnect() {
        stopScan()
        connectionTimeout?.cancel(); connectionTimeout = nil
        if let device = connected ?? candidate { sdk.disconnect(macAddress: device.mac, uuid: device.uuid) }
        candidate = nil; connected = nil; connecting = false; files = []; recordStatus = 0; currentFileID = nil
        finishTransfer(.failure(PrototypeError.message("设备连接已断开；设备原文件保留，请重新连接后同步。")))
        status = "设备已断开"
    }
    func refreshFiles() {
        guard let device = connected, !transferring else { return }
        error = nil; status = "正在读取设备录音列表…"
        sdk.getAllAudioRecordFiles(macAddress: device.mac, uuid: device.uuid)
    }
    func pauseOrResume() {
        guard let device = connected, !transferring else { return }
        // The public SDK can pause/resume an existing recording; starting and stopping use device buttons.
        if recordStatus == 1 { sdk.pauseRecord(macAddress: device.mac, uuid: device.uuid) }
        else if recordStatus == 2 { sdk.resumeRecord(macAddress: device.mac, uuid: device.uuid) }
    }
    func download(_ file: SoundcoreFile) async throws -> URL {
        guard let device = connected, !transferring else { throw PrototypeError.message("请先连接 soundcore，等待上一份录音同步完成。") }
        guard recordStatus == 0, !sdk.isDataTransferring(macAddress: device.mac, uuid: device.uuid) else {
            throw PrototypeError.message("请先按设备停止键结束录音，并等待设备传输任务完成。")
        }
        guard file.id != currentFileID || recordStatus == 0 else { throw PrototypeError.message("请先按设备停止键结束这份录音，再同步完整文件。") }
        guard file.info.size > 0, file.info.size <= 25 * 1024 * 1024 else { throw PrototypeError.message("设备文件为空或超过 25MB，请选择其他录音。") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SoundcoreTransfers", isDirectory: true)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        transferFolder = folder; transferring = true; pendingFileID = file.id; progress = 0; error = nil
        status = "正在同步设备录音…"
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                transfer = continuation
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(300))
                    guard !Task.isCancelled, let self else { return }
                    self.disconnect()
                    self.error = "同步超时，设备原文件保留，请重新连接重试。"
                }
                do {
                    // BLE only for this first integration: avoids the MFi protocol mismatch in the supplied docs.
                    try sdk.startSyncAudioFile(macAddress: device.mac, uuid: device.uuid,
                        fileList: NSMutableArray(object: file.info), savaPath: folder.path, openBTTime: Int32.max)
                } catch { finishTransfer(.failure(error)) }
            }
        }, onCancel: { [weak self] in Task { @MainActor in self?.disconnect() } })
    }
    private func finishTransfer(_ result: Result<URL, Error>) {
        guard let transfer else { return }
        timeout?.cancel(); timeout = nil
        self.transfer = nil; pendingFileID = nil; transferring = false
        if case .failure = result, let folder = transferFolder { try? FileManager.default.removeItem(at: folder) }
        transferFolder = nil
        transfer.resume(with: result)
    }
    private func matches(_ mac: String, _ uuid: String) -> Bool { connected?.mac == mac && connected?.uuid == uuid }
    private func handle(_ event: SoundcoreEvent) {
        switch event {
        case .auth(let success, let code):
            guard initializing else { return }
            authenticationTimeout?.cancel(); authenticationTimeout = nil; initializing = false
            ready = success
            if success { sdk.registerBusinessCallback(callback: callbacks); status = "已授权，可以扫描设备" }
            else { error = "soundcore 鉴权失败（\(code)），请更新 token/license。"; status = "授权失败" }
        case .scan(let device):
            guard scanning, !devices.contains(where: { $0.id == device.id }) else { return }
            devices.append(device)
        case .scanError(let code):
            guard scanning else { return }; stopScan()
            if code != 1 && code != 2 { error = "设备扫描失败（\(code)），请检查蓝牙权限。" }
            status = devices.isEmpty ? "未发现设备，请检查蓝牙和设备状态" : "请选择设备连接"
        case .connected(let mac):
            guard let candidate, mac == nil || mac == candidate.mac else { return }
            connected = candidate; self.candidate = nil; connecting = false
            connectionTimeout?.cancel(); connectionTimeout = nil
            status = "已连接 \(candidate.name)，正在同步设备时间…"
            sdk.syncTime(macAddress: candidate.mac, uuid: candidate.uuid, timeStamp: UInt32(Date().timeIntervalSince1970))
            sdk.getDeviceInfo(macAddress: candidate.mac, uuid: candidate.uuid)
        case .disconnected(let mac):
            guard mac == nil || mac == connected?.mac || mac == candidate?.mac else { return }
            connected = nil; candidate = nil; connecting = false; files = []; recordStatus = 0; currentFileID = nil
            connectionTimeout?.cancel(); connectionTimeout = nil
            status = "设备已断开，请重新连接"
            finishTransfer(.failure(PrototypeError.message("同步期间设备断开，设备原文件保留。")))
        case .connectionError:
            connectionTimeout?.cancel(); connectionTimeout = nil
            connected = nil; candidate = nil; connecting = false; status = "设备连接失败"
            error = "无法连接 soundcore，请检查设备和蓝牙权限后重试。"
            finishTransfer(.failure(PrototypeError.message("设备连接失败，请重新同步。")))
        case .synced(let mac, let uuid, let success):
            guard matches(mac, uuid) else { return }
            if !success { error = "设备时间同步失败，新录音时间可能不准确，请重新连接后重试。" }
            refreshFiles()
        case .record(let mac, let uuid, let status, let duration, let fileID):
            guard matches(mac, uuid) else { return }
            recordStatus = status
            if status == 1 { currentFileID = fileID }
            if status == 0 { durationMS = max(0, Int(duration)); currentFileID = nil; refreshFiles() }
        case .info(let mac, let uuid, let recording, let fileID):
            guard matches(mac, uuid) else { return }
            if recording == 1 { recordStatus = 1; currentFileID = fileID }
        case .duration(let mac, let uuid, let value):
            guard matches(mac, uuid) else { return }; durationMS = max(0, Int(value))
        case .files(let mac, let uuid, let values):
            guard matches(mac, uuid) else { return }
            files = values.filter { $0.code == 0 && $0.size > 0 }.map { SoundcoreFile(info: $0) }.sorted { $0.id > $1.id }
            status = "已读取 \(files.count) 份设备录音"
        case .fileError(let mac, let uuid, let code):
            guard matches(mac, uuid) else { return }; error = "读取录音列表失败（\(code)），请刷新重试。"
        case .progress(let mac, let uuid, let id, let total, let current):
            guard matches(mac, uuid), pendingFileID == id, total > 0 else { return }
            progress = min(1, max(0, Double(current) / Double(total)))
        case .completed(let mac, let uuid, let id, let path):
            guard matches(mac, uuid), pendingFileID == id, let folder = transferFolder else { return }
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let allowed = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard url.path.hasPrefix(allowed), FileManager.default.fileExists(atPath: url.path) else {
                finishTransfer(.failure(PrototypeError.message("SDK 返回的文件路径不在本次同步目录中。"))); return
            }
            progress = 1; status = "设备文件已同步，正在准备回放音频…"
            finishTransfer(.success(url))
        case .transferError(let mac, let uuid, let id):
            guard matches(mac, uuid), pendingFileID == id else { return }
            error = "soundcore 文件同步失败，设备原文件仍保留。"
            finishTransfer(.failure(PrototypeError.message(error!)))
        }
    }
}

enum SoundcoreEvent {
    case auth(Bool, Int32), scan(SoundcoreDevice), scanError(Int32)
    case connected(String?), disconnected(String?), connectionError
    case synced(String, String, Bool), record(String, String, Int32, Int32, Int32), duration(String, String, Int64)
    case info(String, String, Int32, Int32)
    case files(String, String, [FileInfoModel]), fileError(String, String, Int32)
    case progress(String, String, Int32, Int32, Int32), completed(String, String, Int32, String)
    case transferError(String, String, Int32)
}
