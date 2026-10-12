import SwiftUI

struct SoundcoreDeviceView: View {
    @ObservedObject var device: Soundcore
    @State private var auth = SoundcoreAuth.load()
    @State private var error: String?
    var body: some View {
        Form {
            Section("soundcore") {
                Text(device.status)
                if Soundcore.simulator { Text("模拟器用于页面与音频处理测试，请在 iPhone 真机上连接 soundcore。").accessibilityIdentifier("soundcore-simulator-note") }
                if let message = error ?? device.error { Text(message).foregroundStyle(.orange) }
            }
            if !device.ready {
                Section("SDK 授权") {
                    TextField("云端授权用户 ID", text: $auth.userID)
                    TextField("云端授权设备 ID", text: $auth.deviceID)
                    SecureField("云端签发的 token", text: $auth.token)
                    SecureField("离线 license JSON（可选）", text: $auth.license)
                    SecureField("license 签名（可选）", text: $auth.signature)
                    Toggle("使用正式鉴权环境", isOn: $auth.production)
                    Text("用户 ID 与设备 ID 必须匹配签发的授权。token 或离线 license 均可；授权数据保存到本机 Keychain。").font(.footnote)
                    Button("验证 soundcore 授权") { do { try device.initialize(auth); error = nil } catch { self.error = error.localizedDescription } }
                        .disabled(!auth.valid || Soundcore.simulator)
                }.textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section("连接设备") {
                if let connected = device.connected {
                    Label(connected.name, systemImage: "checkmark.circle")
                    Button("刷新设备录音") { device.refreshFiles() }.disabled(device.transferring)
                    Button("断开连接") { device.disconnect() }.disabled(device.transferring)
                } else {
                    Button(device.scanning ? "停止查找" : "查找 soundcore 设备") {
                        if device.scanning { device.stopScan() }
                        else { do { try device.scan(); error = nil } catch { self.error = error.localizedDescription } }
                    }.disabled(!device.ready || device.connecting)
                    ForEach(device.devices) { found in Button(found.name) { device.connect(found) }.disabled(device.connecting) }
                }
            }
        }.navigationTitle("soundcore 设备")
            .onDisappear { device.stopScan() }
    }
}

struct RecordView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let occasion: Occasion
    var body: some View { SoundcoreRecordView(device: store.soundcore, occasion: occasion) }
}

struct SoundcoreRecordView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var device: Soundcore
    let occasion: Occasion
    @State private var kind = "practice"
    @State private var agreed = false
    @State private var text = ""
    @State private var selected: Int32?
    @State private var session: Session?
    @State private var pending: URL?
    @State private var milliseconds = 0
    @State private var working = false
    @State private var analyze = false
    private var allowed: Bool { kind != "live" || agreed }
    var body: some View {
        NavigationStack {
            ScrollView { VStack(spacing: 18) {
                Mascot(size: 90)
                Text("用 soundcore 记录，\n为下一次留下经验。").font(.title.bold()).multilineTextAlignment(.center)
                if session == nil {
                    Picker("记录方式", selection: $kind) {
                        Text("本人练习").tag("practice"); Text("真实沟通").tag("live"); Text("口述复盘").tag("oral_debrief")
                    }.pickerStyle(.segmented)
                    if kind == "live" { Toggle("这份录音已告知对方并获得同意", isOn: $agreed) }
                    Picker("原音频保留", selection: $store.retention) {
                        ForEach([0,7,30,90,180], id: \.self) { Text($0 == 0 ? "处理后即删" : "\($0) 天").tag($0) }
                    }
                }
                if kind == "oral_debrief" {
                    TextEditor(text: $text).frame(minHeight: 180).accessibilityLabel("本人复述")
                    if store.remote && store.capabilities?.llm_configured == true {
                        Toggle("同意将本次本人复述发送给 DeepSeek 分析", isOn: $analyze)
                        Text("模型：\(store.capabilities?.llm_model ?? "")。生成的诊断与素材需由你核对确认。").font(.caption)
                    } else { Text("连接已配置 DeepSeek 的后端后，可分析本人复述。").font(.caption) }
                    Button(analyze ? "保存并分析本人复述" : "保存本人复述") { Task { await store.perform {
                        let value: Session
                        if let session { value = session }
                        else { value = try await store.beginSession(occasion: occasion, kind: kind, agreed: agreed); session = value }
                        try await store.submitOral(value, text: text, analyze: analyze); dismiss()
                    } } }.buttonStyle(PrimaryButton()).disabled(store.busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    WarmCard(color: Warm.sage) {
                        Label(device.connected?.name ?? "soundcore 设备", systemImage: "waveform")
                        Text("请按设备按键开始和结束录音，再选择完整文件同步到这一场。").font(.subheadline)
                        Text("设备中的原文件由设备管理；App 的保留设置作用于同步到本机或后端的副本。").font(.caption)
                        NavigationLink("连接与授权") { SoundcoreDeviceView(device: device) }.disabled(working)
                        if Soundcore.simulator { Text("模拟器不能进行真实设备录音，请用 iPhone 连接 soundcore。").font(.caption).accessibilityIdentifier("soundcore-simulator-note") }
                        if device.recordStatus != 0 {
                            Text(device.recordStatus == 1 ? "设备正在录音" : "设备录音已暂停")
                            Text(String(format: "%02d:%02d", device.durationMS / 60_000, device.durationMS / 1000 % 60)).monospacedDigit()
                            Button(device.recordStatus == 1 ? "暂停设备录音" : "继续设备录音") { device.pauseOrResume() }.disabled(!allowed || working)
                        }
                    }
                    if let message = device.error { Text(message).foregroundStyle(.orange).font(.caption) }
                    if let pending, let session {
                        Text("设备录音已保存在本机，上传失败时可以重试。")
                        Button("重试保存与上传") { Task { await store.perform {
                            try await store.finish(session, url: pending, seconds: milliseconds / 1000, durationMS: milliseconds); dismiss()
                        } } }.buttonStyle(PrimaryButton()).disabled(store.busy)
                        Button("稍后处理，保留本机文件") { dismiss() }.disabled(store.busy)
                    } else {
                        HStack { Text("设备录音").font(.headline); Spacer(); Button("刷新") { device.refreshFiles() }.disabled(device.connected == nil || working) }
                        if device.files.isEmpty { Text("连接设备并结束录音后，刷新获取文件。").foregroundStyle(.secondary) }
                        ForEach(device.files) { file in
                            Button { selected = file.id } label: {
                                WarmCard {
                                    HStack { Text(file.title); Spacer(); Image(systemName: selected == file.id ? "checkmark.circle.fill" : "circle") }
                                    Text("\(file.durationMS / 1000) 秒 · \(file.info.size / 1024) KB").font(.caption)
                                }
                            }.buttonStyle(.plain).disabled(working || session != nil || (file.id == device.currentFileID && device.recordStatus != 0))
                        }
                        if working { ProgressView(value: device.progress); Text(device.status).font(.caption) }
                        Button(session == nil ? "同步并保存到这一场" : "重新同步这一份录音") { importRecording() }
                            .buttonStyle(PrimaryButton()).disabled(!allowed || selected == nil || device.connected == nil || device.recordStatus != 0 || working || store.busy)
                    }
                }
                Text("录音自动转写尚未配置。本人文字复述可通过后端交给 DeepSeek 分析。").font(.caption).foregroundStyle(.secondary)
            }.padding(24) }.background(Warm.paper.ignoresSafeArea()).navigationTitle("记录这一场")
                .toolbar { Button("关闭") { dismiss() }.disabled(working || store.busy) }
                .interactiveDismissDisabled(working || store.busy)
                .onDisappear { device.stopScan() }
        }
    }
    private func importRecording() {
        guard let file = device.files.first(where: { $0.id == selected }) else { return }
        working = true
        Task {
            defer { working = false }
            await store.perform {
                let value: Session
                if let session { value = session }
                else {
                    value = try await store.beginSession(occasion: occasion, kind: kind, agreed: agreed, recordingSource: "soundcore", deviceFileID: file.id)
                    session = value
                }
                let raw = try await device.download(file)
                defer { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
                let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var url = folder.appendingPathComponent(value.id + ".m4a")
                guard !FileManager.default.fileExists(atPath: url.path) else { throw PrototypeError.message("场次已有本机录音，请先保存已有文件。") }
                milliseconds = try await SoundcoreAudio.convert(raw: raw, destination: url)
                var resource = URLResourceValues(); resource.isExcludedFromBackup = true
                try? url.setResourceValues(resource)
                pending = url
                try await store.finish(value, url: url, seconds: milliseconds / 1000, durationMS: milliseconds)
                dismiss()
            }
        }
    }
}
