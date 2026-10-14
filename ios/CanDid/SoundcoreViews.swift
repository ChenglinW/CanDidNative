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

// Text practice and oral debrief remain separate from global meeting recordings.
struct RecordView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let occasion: Occasion
    @State private var kind="oral_debrief"
    @State private var text=""
    @State private var analyze=false
    @State private var session:Session?
    var body: some View {
        NavigationStack {
            Form {
                Picker("记录方式",selection:$kind) {Text("本人练习").tag("practice");Text("口述复盘").tag("oral_debrief")}.pickerStyle(.segmented).disabled(session != nil)
                TextEditor(text:$text).frame(minHeight:180).accessibilityLabel("本人复述")
                if store.remote && store.capabilities?.llm_configured==true {
                    Toggle("发送本次本人文字给已有模型分析",isOn:$analyze)
                    Text("模型：\(store.capabilities?.llm_model ?? "")").font(.caption).foregroundStyle(.secondary)
                }
                Button(analyze ? "保存并分析本人文字":"保存本人文字") {
                    Task {await store.perform {
                        let value:Session
                        if let session {value=session}
                        else {value=try await store.beginSession(occasion:occasion,kind:kind,agreed:true);session=value}
                        try await store.submitOral(value,text:text,analyze:analyze);dismiss()
                    }}
                }.disabled(store.busy || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                Text("沟通录音统一在录音页保存，通过标签关联空间；这里保留主动填写的本人文字。").font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("练习与口述复盘").navigationBarTitleDisplayMode(.inline)
                .toolbar {ToolbarItem(placement:.cancellationAction) {Button("取消") {dismiss()}}}
                .interactiveDismissDisabled(store.busy)
        }
    }
}
