import Foundation
import Combine
import UIKit
import CoreBluetooth
import CryptoKit
import module_spplinkKit

struct SoundcoreAuth: Codable {
    var userID = ""
    var deviceID = ""
    var token = ""
    var license = ""
    var signature = ""
    var production = false
    var expiresAt: Double = 0
    var valid: Bool {
        !userID.isEmpty && UUID(uuidString: deviceID) != nil && !token.isEmpty && expiresAt > Date().timeIntervalSince1970 + 30
    }
    static func phoneID() throws -> String {
        let account = "soundcore-phone-id-v1"
        let saved = TokenVault.read(account: account)
        if UUID(uuidString: saved) != nil { return saved }
        let value = UUID().uuidString.lowercased()
        try TokenVault.save(value, account: account)
        return value
    }
}
struct SoundcoreGrant: Decodable {
    let user_id, device_id, token, license_json, license_signature, environment, product_code, sdk_version: String
    let token_expires_at, license_expires_at: Double
    var auth: SoundcoreAuth {
        SoundcoreAuth(userID: user_id, deviceID: device_id, token: token, license: license_json,
            signature: license_signature, production: environment == "production",
            expiresAt: min(token_expires_at, license_expires_at))
    }
}
struct SoundcoreDevice: Identifiable, Codable, Equatable {
    static let serviceUUID = "020cf5da-0000-1000-8000-00805f9b34fb"
    var name: String
    var mac: String
    var uuid: String
    var advertisedUUID: String?
    var serial: String?
    var productCode = "D3200"
    var bound = false
    var signal = -100
    var id: String { mac.lowercased() + "|" + uuid.lowercased() }
    var recordingID: String { serial?.isEmpty == false ? "soundcore-sn:" + serial!.uppercased() : "soundcore-mac:" + mac.lowercased() }
    var likelyRecorder: Bool {
        let name = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return productCode.uppercased() == "D3200" || advertisedUUID?.lowercased() == Self.serviceUUID || name.contains("soundcorework") || name.contains("d3200")
    }
}
struct SoundcoreSavedAuth: Codable {
    let scope: String
    let auth: SoundcoreAuth
}
struct SoundcoreRemembered: Codable {
    let scope: String
    let device: SoundcoreDevice
    let serial: String
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
    @Published private(set) var status = "连接录音豆后，同步设备录音"
    @Published private(set) var error: String?
    @Published private(set) var recordStatus: Int32 = 0
    @Published private(set) var durationMS = 0
    @Published private(set) var currentFileID: Int32?
    @Published private(set) var progress: Double = 0
    @Published private(set) var transferring = false
    @Published private(set) var realtimeReady = false
    @Published private(set) var liveAudioRequested = false
    @Published private(set) var receivingLiveAudio = false
    private var liveFrameCount = 0
    @Published private(set) var fileMarkers:[Int32:[Int]]=[:]
    @Published private(set) var markedFragments:[Int32:Set<Int32>]=[:]
    @Published private(set) var liveMarkTimes:[Int32:[Int]]=[:]
    @Published private(set) var markReceiptCount=0
    private var markerDeviceID:String?
    var onLiveAudio: ((Data,Int32)->Void)?
    var onRecordingEnded: (()->Void)?
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
    @Published private(set) var authorizing = false
    @Published private(set) var awaitingBinding = false
    @Published private(set) var serialNumber = ""
    @Published private(set) var firmwareVersion = ""
    @Published private(set) var battery: Int?
    @Published private(set) var bluetoothIssue: String?
    private var bluetooth: SoundcoreBluetooth?
    private var activeAuth: SoundcoreAuth?
    private var api: API?
    private var authScope = ""
    private var discoveryRequested = false
    private var reconnectAllowed = false
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    private var remembered: SoundcoreRemembered?
    private var bindingConfirmed = false
    private var diagnosticEvents: [[String: String]] = []
    private func diagnose(_ event: String, _ details: [String: String] = [:]) {
        diagnosticEvents.append(details.merging(["event": event, "time": ISO8601DateFormatter().string(from: Date())]) { _, new in new })
        diagnosticEvents = Array(diagnosticEvents.suffix(120))
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SoundcoreConnectionDiagnostics.json")
        if let data = try? JSONSerialization.data(withJSONObject: diagnosticEvents, options: [.sortedKeys]) {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        }
    }


    var hasRememberedDevice: Bool { remembered != nil }
    var working: Bool { authorizing || initializing || scanning || connecting }
    static func scope(_ api: API) -> String {
        SHA256.hash(data: Data((api.base + "|" + api.token).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func beginConnection(_ api: API) async {
        diagnose("begin", ["ready": String(ready), "working": String(working)])
        guard !Self.simulator else { error = "请在 iPhone 上连接录音豆，模拟器不支持蓝牙设备。"; return }
        guard !working, connected == nil else { return }
        let scope = Self.scope(api)
        if scope != authScope {
            sdk.close(); OfflineLicenseManager.shared.clearLicense(); ready = false; activeAuth = nil; remembered = nil
            authScope = scope
            let saved = TokenVault.read(account: "soundcore-last-device-v1")
            if let value = try? JSONDecoder().decode(SoundcoreRemembered.self, from: Data(saved.utf8)), value.scope == scope { remembered = value }
        }
        self.api = api; error = nil; authorizing = true; discoveryRequested = true
        reconnectAllowed = true
        try? TokenVault.save("", account: "soundcore-manually-disconnected-v1")
        defer { authorizing = false }
        do {
            if ready, activeAuth?.valid == true { requestBluetooth(); return }
            ready = false; sdk.close()
            let cached = TokenVault.read(account: "soundcore-cached-auth-v1")
            if let saved = try? JSONDecoder().decode(SoundcoreSavedAuth.self, from: Data(cached.utf8)),
                saved.scope == scope, saved.auth.valid {
                activeAuth = saved.auth
                try initialize(saved.auth)
                return
            }
            status = "正在准备录音豆连接…"
            let companion = SoundcoreSDK.companion
            let grant: SoundcoreGrant = try await api.call("/v1/soundcore/authorization", method: "POST", body: [
                "device_id": try SoundcoreAuth.phoneID(), "product_code": companion.getProductCode(), "sdk_version": companion.getVersion()])
            guard authScope == scope, discoveryRequested else { return }
            guard grant.product_code == companion.getProductCode(), grant.sdk_version == companion.getVersion() else {
                throw PrototypeError.message("录音豆组件版本不匹配，请更新 App。")
            }
            diagnose("grant_received", ["sdk_version": grant.sdk_version, "environment": grant.environment])
            activeAuth = grant.auth
            let saved = SoundcoreSavedAuth(scope: scope, auth: grant.auth)
            try TokenVault.save(String(decoding: JSONEncoder().encode(saved), as: UTF8.self), account: "soundcore-cached-auth-v1")
            try initialize(grant.auth)
        } catch { diagnose("grant_failed"); discoveryRequested = false; self.error = error.localizedDescription; status = "连接尚未完成" }
    }
    func foreground(_ api: API) async {
        if !authScope.isEmpty, authScope != Self.scope(api) {
            disconnect(); sdk.close(); ready = false; activeAuth = nil; remembered = nil; authScope = ""
            return
        }
        let saved = TokenVault.read(account: "soundcore-last-device-v1")
        let previous = try? JSONDecoder().decode(SoundcoreRemembered.self, from: Data(saved.utf8))
        guard TokenVault.read(account: "soundcore-manually-disconnected-v1") != Self.scope(api) else { return }
        guard (reconnectAllowed || (authScope.isEmpty && previous?.scope == Self.scope(api))), connected == nil, reconnectAttempts < 2 else { return }
        reconnectAttempts += 1
        await beginConnection(api)
    }
    func resetAuthorization() {
        disconnect(); sdk.close(); OfflineLicenseManager.shared.clearLicense()
        ready = false; activeAuth = nil; remembered = nil; authScope = ""; api = nil
        for account in ["soundcore-last-device-v1", "soundcore-cached-auth-v1", "soundcore-manually-disconnected-v1", "soundcore-auth"] {
            try? TokenVault.save("", account: account)
        }
    }
    func forgetDevice() {
        disconnect(); remembered = nil
        try? TokenVault.save("", account: "soundcore-last-device-v1")
    }
    func suspendDiscovery() {
        discoveryRequested = false; stopScan(); reconnectTask?.cancel(); reconnectTask = nil
        // Do not interrupt an established recording or transfer when the app backgrounds.
    }
    private func requestBluetooth() {
        if bluetooth == nil {
            bluetooth = SoundcoreBluetooth { [weak self] state in self?.bluetoothChanged(state) }
        } else if let state = bluetooth?.state { bluetoothChanged(state) }
    }
    private func bluetoothChanged(_ state: CBManagerState) {
        diagnose("bluetooth", ["state": String(state.rawValue), "discovery_requested": String(discoveryRequested)])
        bluetoothIssue = nil
        switch state {
        case .poweredOn:
            if discoveryRequested, ready, !scanning, !connecting, connected == nil { do { try scan() } catch { self.error = error.localizedDescription } }
        case .poweredOff: bluetoothIssue = "请打开 iPhone 蓝牙，打开后会继续查找。"; stopScan()
        case .unauthorized: bluetoothIssue = "请在系统设置中允许 Candid 使用蓝牙。"; stopScan()
        case .unsupported: bluetoothIssue = "当前设备不支持蓝牙连接。"; stopScan()
        default: status = "正在准备蓝牙…"
        }
    }
    private func remember(_ device: SoundcoreDevice) {
        let value = SoundcoreRemembered(scope: authScope, device: device, serial: serialNumber)
        if let data = try? JSONEncoder().encode(value) {
            try? TokenVault.save(String(decoding: data, as: UTF8.self), account: "soundcore-last-device-v1")
        }
        remembered = value
    }
    private func finishConnection() {
        guard let candidate, !serialNumber.isEmpty, candidate.bound || bindingConfirmed else { return }
        var confirmed = candidate; confirmed.serial = serialNumber
        connected = confirmed; self.candidate = nil; connecting = false; awaitingBinding = false
        diagnose("connection_ready", ["serial_sha256": SHA256.hash(data: Data(serialNumber.uppercased().utf8)).map { String(format: "%02x", $0) }.joined()])
        connectionTimeout?.cancel(); connectionTimeout = nil; reconnectAttempts = 0
        remember(confirmed); status = "已连接 \(candidate.name)"
        sdk.syncTime(macAddress: candidate.mac, uuid: candidate.uuid, timeStamp: UInt32(Date().timeIntervalSince1970))
        refreshFiles()
    }
    private func scheduleReconnect() {
        guard reconnectAllowed, remembered != nil, reconnectAttempts < 2, let api else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.foreground(api)
        }
    }


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
        guard auth.valid else { throw PrototypeError.message("录音豆授权已过期，请重新连接。") }
        activeAuth = auth
        error = nil; initializing = true; status = "正在验证 soundcore 授权…"
        let config = SDKInitConfig(context: UIApplication.shared, userId: auth.userID, deviceId: auth.deviceID,
            token: auth.token, licenseJson: auth.license, license_signature: auth.signature,
            environment: auth.production ? .production : .development, isDebug: KotlinBoolean(bool: false),
            firmwareLogFilePath: nil, commandTimeOut: 5, fileTransferInterval: 200,
            isSPPSingleThread: false, androidUDPPingTimeIntval: 100, androidWIFIReceiveThreadSwitch: true)
        // The supplied development binary predates the QA host documented by Anker.
        AuthService.shared.updateServerUrl(baseUrl: auth.production ? "https://speaker-api.anker-in.com" : "https://speaker-api-qa.anker-in.com")
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
        guard !scanning, !connecting, !transferring, connected == nil else { return }
        diagnose("scan_start")
        error = nil; scanning = true; devices = []; status = "正在查找录音豆…"
        sdk.startScan(bleScan: true, sppScan: false, filters: NSMutableArray(), onReceiveScanResult: callbacks)
        scanTimeout?.cancel()
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self else { return }
            self.stopScan()
            self.status = self.devices.isEmpty ? "未发现录音豆，请让设备靠近手机并保持可连接状态。" : "请选择你的录音豆"
        }
    }
    func stopScan() {
        scanTimeout?.cancel(); scanTimeout = nil
        if scanning { diagnose("scan_stop", ["device_count": String(devices.count)]); sdk.stopScan() }
        scanning = false
    }
    func connect(_ device: SoundcoreDevice) {
        diagnose("connect", ["bound": String(device.bound)])
        guard ready, !connecting, !transferring, connected == nil else { return }
        guard activeAuth?.valid == true else { ready = false; error = "连接授权已过期，请重新查找录音豆。"; return }
        stopScan(); error = nil; connecting = true; candidate = device
        serialNumber = ""; firmwareVersion = ""; battery = nil; bindingConfirmed = false; awaitingBinding = false
        discoveryRequested = false
        status = "正在连接 \(device.name)…"
        if markerDeviceID != device.recordingID {fileMarkers=[:];markedFragments=[:];liveMarkTimes=[:];markReceiptCount=0;markerDeviceID=device.recordingID}
        sdk.connect(macAddress: device.mac, uuid: device.uuid, listener: callbacks)
        connectionTimeout?.cancel()
        connectionTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.connecting else { return }
            self.disconnect(); self.error = "soundcore 连接超时，请检查设备和蓝牙后重试。"
        }
    }
    func disconnect() {
        reconnectAllowed = false; discoveryRequested = false; reconnectTask?.cancel(); reconnectTask = nil
        if !authScope.isEmpty { try? TokenVault.save(authScope, account: "soundcore-manually-disconnected-v1") }
        awaitingBinding = false; bindingConfirmed = false
        if initializing { authenticationTimeout?.cancel(); authenticationTimeout = nil; initializing = false; sdk.close(); ready = false }
        stopScan()
        connectionTimeout?.cancel(); connectionTimeout = nil
        if let device = connected ?? candidate { sdk.disconnect(macAddress: device.mac, uuid: device.uuid) }
        realtimeReady=false;liveAudioRequested=false;receivingLiveAudio=false;onLiveAudio=nil;onRecordingEnded?()
        candidate = nil; connected = nil; connecting = false; devices = []; files = []; recordStatus = 0; currentFileID = nil
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
    func acquireLiveAudio() throws {
        guard recordStatus == 1,let device=connected else { throw PrototypeError.message("请先按录音豆按钮开始录音。") }
        guard !liveAudioRequested else { return }
        liveAudioRequested = true; receivingLiveAudio = false; liveFrameCount = 0
        diagnose("live_audio_requested")
        let folder=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("DeviceLiveAudio")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        sdk.acquireRealtimeAudioData(macAddress:device.mac,uuid:device.uuid,savaPath:SoundcoreTransferPaths.sdkDirectory(folder))
    }
    func download(_ file: SoundcoreFile) async throws -> URL {
        guard let device = connected, !transferring else { throw PrototypeError.message("请先连接 soundcore，等待上一份录音同步完成。") }
        guard recordStatus == 0, !sdk.isDataTransferring(macAddress: device.mac, uuid: device.uuid) else {
            throw PrototypeError.message("请先按设备停止键结束录音，并等待设备传输任务完成。")
        }
        guard file.id != currentFileID || recordStatus == 0 else { throw PrototypeError.message("请先按设备停止键结束这份录音，再同步完整文件。") }
        guard file.info.size > 0, file.info.size <= 2_000_000_000 else { throw PrototypeError.message("设备文件为空或超过 2GB，请选择其他录音。") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SoundcoreTransfers", isDirectory: true)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        diagnose("transfer_started", ["expected_bytes": String(file.info.size), "duration_ms": String(file.durationMS)])
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
                        fileList: NSMutableArray(object: file.info), savaPath: SoundcoreTransferPaths.sdkDirectory(folder), openBTTime: Int32.max)
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
        case .markers(let mac,let uuid,let fileID,let times):
            guard matches(mac,uuid) else{return}
            fileMarkers[fileID]=Array(Set((fileMarkers[fileID] ?? [])+times.filter{$0>=0})).sorted()
            diagnose("file_markers",["file_id":String(fileID),"times_ms":times.map(String.init).joined(separator:",")])
        case .markedFragment(let mac,let uuid,let fileID,let sequence,let continuation):
            guard matches(mac,uuid),sequence>=0 else{return}
            let inserted=markedFragments[fileID,default:[]].insert(sequence).inserted
            if recordStatus != 0 && fileID==currentFileID {
                if inserted {markReceiptCount+=1;diagnose("mark_received",["file_id":String(fileID),"sequence":String(sequence),"continuation":String(continuation)])}
                // SDK defines 20 ms per Opus sequence; >3h continuation is finalized from file markers.
                if !continuation && !(liveMarkTimes[fileID] ?? []).contains(Int(sequence)*20) {liveMarkTimes[fileID,default:[]].append(Int(sequence)*20)}
            }
        case .realtimeReady(let mac,let uuid,let fileID):
            guard matches(mac,uuid) else { return };realtimeReady=true;currentFileID=fileID
        case .liveAudio(let mac,let uuid,let fileID,let data,let sequence):
            guard matches(mac,uuid),fileID==currentFileID else { return }
            liveFrameCount += 1
            if !receivingLiveAudio { receivingLiveAudio = true }
            if liveFrameCount == 1 || liveFrameCount == 50 || liveFrameCount == 500 { diagnose("live_audio_received", ["frames": String(liveFrameCount), "bytes": String(data.count)]) }
            onLiveAudio?(data,sequence)
        case .auth(let success, let code):
            diagnose("sdk_auth", ["success": String(success), "code": String(code), "initializing": String(initializing)])
            guard initializing else { return }
            authenticationTimeout?.cancel(); authenticationTimeout = nil; initializing = false
            ready = success
            if success { sdk.registerBusinessCallback(callback: callbacks); status = "正在准备蓝牙…"; if discoveryRequested { requestBluetooth() } }
            else {
                activeAuth = nil
                try? TokenVault.save("", account: "soundcore-cached-auth-v1")
                error = "录音豆授权未通过（\(code)），请重新连接。"; status = "授权失败"
            }
        case .scanPayloadMissing(let product, let hasMAC, let hasUUID):
            diagnose("scan_payload_missing", ["product": String(product.prefix(30)), "has_mac": String(hasMAC), "has_uuid": String(hasUUID)])
        case .scan(let device):
            diagnose("scan_result", ["product": String(device.productCode.prefix(30)), "scanning": String(scanning)])
            // The D3200 SDK already filters supported advertisements; productCode is nullable.
            guard scanning, !device.mac.isEmpty else { return }
            if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device }
            else { devices.append(device) }
            devices.sort { $0.signal > $1.signal }
            if let remembered, remembered.device.id == device.id { connect(device) }
        case .scanError(let code):
            diagnose("scan_error", ["code": String(code)])
            guard scanning else { return }; stopScan()
            if code != 1 && code != 2 { error = "设备扫描失败（\(code)），请检查蓝牙权限。" }
            status = devices.isEmpty ? "未发现设备，请检查蓝牙和设备状态" : "请选择设备连接"
        case .connected(let mac):
            diagnose("ble_connected")
            guard let candidate, mac == nil || mac == candidate.mac else { return }
            status = "正在核对录音豆…"
            sdk.getDeviceInfo(macAddress: candidate.mac, uuid: candidate.uuid)
        case .disconnected(let mac):
            guard mac == nil || mac == connected?.mac || mac == candidate?.mac else { return }
            realtimeReady=false;liveAudioRequested=false;receivingLiveAudio=false;onLiveAudio=nil;onRecordingEnded?()
            connected = nil; candidate = nil; connecting = false; files = []; recordStatus = 0; currentFileID = nil
            connectionTimeout?.cancel(); connectionTimeout = nil
            awaitingBinding = false
            status = "设备已断开，请重新连接"
            scheduleReconnect()
            finishTransfer(.failure(PrototypeError.message("同步期间设备断开，设备原文件保留。")))
        case .connectionError:
            diagnose("connection_error")
            connectionTimeout?.cancel(); connectionTimeout = nil
            realtimeReady=false;liveAudioRequested=false;receivingLiveAudio=false;onLiveAudio=nil;onRecordingEnded?()
            connected = nil; candidate = nil; connecting = false; recordStatus=0;currentFileID=nil;status = "设备连接失败"
            awaitingBinding = false
            error = "无法连接 soundcore，请检查设备和蓝牙权限后重试。"
            scheduleReconnect()
            finishTransfer(.failure(PrototypeError.message("设备连接失败，请重新同步。")))
        case .synced(let mac, let uuid, let success):
            guard matches(mac, uuid) else { return }
            if !success { error = "设备时间同步失败，新录音时间可能不准确，请重新连接后重试。" }
            refreshFiles()
        case .record(let mac, let uuid, let status, let duration, let fileID):
            guard matches(mac, uuid) else { return }
            if status==0 { realtimeReady=false;liveAudioRequested=false;receivingLiveAudio=false;onLiveAudio=nil;onRecordingEnded?() }
            diagnose("recording_status", ["status": String(status)])
            recordStatus = status
            // onRealtimeTransferSwitch is Wi-Fi-only. BLE can request live audio as soon as recording starts.
            realtimeReady = status == 1
            if status != 1 { liveAudioRequested = false; receivingLiveAudio = false }
            if status == 1 { currentFileID = fileID }
            if status == 0 { durationMS = max(0, Int(duration)); currentFileID = nil; refreshFiles() }
        case .info(let mac, let uuid, let recording, let fileID, let serial, let firmware, let batteryValue):
            guard matches(mac, uuid) || (candidate?.mac == mac && candidate?.uuid == uuid) else { return }
            guard let serial, !serial.isEmpty else { disconnect(); error = "未能读取录音豆身份，请重新连接。"; return }
            if let remembered, remembered.device.id == candidate?.id, remembered.serial != serial {
                disconnect(); error = "设备身份与上次连接不同，请重新查找并选择录音豆。"; return
            }
            serialNumber = serial; firmwareVersion = firmware ?? ""; battery = min(100, max(0, Int(batteryValue) * 10))
            recordStatus = recording; realtimeReady = recording == 1
            if recording != 1 { liveAudioRequested = false; receivingLiveAudio = false }
            if recording != 0 { currentFileID = fileID }
            if let candidate {
                if candidate.bound { finishConnection() }
                else {
                    awaitingBinding = true; status = "请在充电盒上确认连接"
                    connectionTimeout?.cancel()
                    connectionTimeout = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(60))
                        guard !Task.isCancelled, let self, self.awaitingBinding else { return }
                        self.disconnect(); self.error = "设备确认超时，请重新连接并按充电盒按钮。"
                    }
                    sdk.bindingDevice(macAddress: candidate.mac, uuid: candidate.uuid, binding: true)
                }
            }
        case .bindingSent(let mac, let uuid):
            guard candidate?.mac == mac, candidate?.uuid == uuid, awaitingBinding else { return }
            status = "请将录音豆放入充电盒，灯闪烁时按下盒上的按钮。"
        case .bindingConfirmed(let mac, let uuid):
            diagnose("binding_confirmed")
            guard candidate?.mac == mac, candidate?.uuid == uuid, awaitingBinding else { return }
            bindingConfirmed = true; candidate?.bound = true; finishConnection()
        case .bindingError(let mac, let uuid, let code):
            guard candidate?.mac == mac, candidate?.uuid == uuid else { return }
            disconnect(); error = code == 3 ? "设备确认超时，请重新连接并按充电盒按钮。" : "录音豆未能确认连接，请检查充电盒后重试。"
        case .infoError(let mac, let uuid):
            guard candidate?.mac == mac, candidate?.uuid == uuid else { return }
            disconnect(); error = "未能读取录音豆信息，请重新连接。"
        case .battery(let mac, let uuid, let value):
            guard matches(mac, uuid) else { return }; battery = min(100, max(0, Int(value)))
        case .duration(let mac, let uuid, let value):
            guard matches(mac, uuid) else { return }; durationMS = max(0, Int(value))
        case .files(let mac, let uuid, let values):
            guard matches(mac, uuid) else { return }
            diagnose("files_loaded", ["count": String(values.count)])
            files = values.filter { $0.code == 0 && $0.size > 0 }.map { SoundcoreFile(info: $0) }.sorted { $0.id > $1.id }
            status = "已读取 \(files.count) 份设备录音"
        case .fileError(let mac, let uuid, let code):
            guard matches(mac, uuid) else { return }; error = "读取录音列表失败（\(code)），请刷新重试。"
        case .progress(let mac, let uuid, let id, let total, let current):
            guard matches(mac, uuid), pendingFileID == id, total > 0 else { return }
            progress = min(1, max(0, Double(current) / Double(total)))
        case .completed(let mac, let uuid, let id, let path):
            guard matches(mac, uuid), pendingFileID == id, let folder = transferFolder else { return }
            do {
                let url = try SoundcoreTransferPaths.completedFile(path, in: folder)
                diagnose("transfer_completed", ["bytes": String((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)])
                progress = 1; status = "设备文件已同步，正在准备回放音频…"
                finishTransfer(.success(url))
            } catch {
                diagnose("transfer_path_rejected")
                self.error = error.localizedDescription
                finishTransfer(.failure(error))
            }
        case .transferError(let mac, let uuid, let id):
            guard matches(mac, uuid), pendingFileID == id else { return }
            error = "soundcore 文件同步失败，设备原文件仍保留。"
            finishTransfer(.failure(PrototypeError.message(error!)))
        }
    }
}

enum SoundcoreEvent {
    case auth(Bool, Int32), scan(SoundcoreDevice), scanError(Int32), scanPayloadMissing(String, Bool, Bool)
    case connected(String?), disconnected(String?), connectionError
    case synced(String, String, Bool), record(String, String, Int32, Int32, Int32), duration(String, String, Int64)
    case info(String, String, Int32, Int32, String?, String?, Int32)
    case infoError(String, String), bindingSent(String, String), bindingConfirmed(String, String), bindingError(String, String, Int32), battery(String, String, Int32)
    case files(String, String, [FileInfoModel]), fileError(String, String, Int32)
    case progress(String, String, Int32, Int32, Int32), completed(String, String, Int32, String)
    case realtimeReady(String,String,Int32),liveAudio(String,String,Int32,Data,Int32)
    case markers(String,String,Int32,[Int]),markedFragment(String,String,Int32,Int32,Bool)
    case transferError(String, String, Int32)
}

@MainActor private final class SoundcoreBluetooth: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager!
    let changed: (CBManagerState) -> Void
    var state: CBManagerState { manager.state }
    init(changed: @escaping (CBManagerState) -> Void) {
        self.changed = changed
        super.init()
        manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor [weak self] in self?.changed(state) }
    }
}
