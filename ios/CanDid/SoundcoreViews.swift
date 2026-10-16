import SwiftUI

struct SoundcoreDeviceView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var device: Soundcore
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: device.connected == nil ? "waveform" : "checkmark.circle.fill")
                    .font(.system(size: 40)).foregroundStyle(Warm.purple).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    Text(device.connected == nil ? "连接你的录音豆" : "录音豆已连接").font(.title2.bold())
                    Text(device.connected == nil ? "将录音豆取出后放回充电盒，确认指示灯亮起，再让它靠近 iPhone。Candid 会自动查找。" : "用设备按钮开始和结束录音，录完回到 App 同步与复盘。")
                        .font(.subheadline).foregroundStyle(RecordingFormat.secondary)
                }
                if device.working { HStack(spacing: 10) { ProgressView(); Text(device.status).font(.subheadline) } }
                else { Text(device.status).font(.subheadline).foregroundStyle(RecordingFormat.secondary) }
                if device.awaitingBinding {
                    WarmCard {
                        Label("在充电盒上确认", systemImage: "hand.tap").font(.headline)
                        Text("将录音豆放入充电盒，灯闪烁时按下盒上的按钮。确认完成后会自动连接，无需再点下一步。")
                            .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    }.accessibilityIdentifier("soundcore-binding-guide")
                }
                if let issue = device.bluetoothIssue {
                    Text(issue).font(.subheadline)
                    Button("打开系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }.frame(minHeight: 44)
                }
                if let issue = device.error { Text(issue).font(.subheadline).foregroundStyle(Warm.ink).accessibilityIdentifier("soundcore-error") }
                if Soundcore.simulator {
                    Text("模拟器不支持蓝牙设备。请在 iPhone 上连接录音豆。").font(.footnote).foregroundStyle(RecordingFormat.secondary).accessibilityIdentifier("soundcore-simulator-note")
                }
                if device.hasRememberedDevice && !device.working {
                    Button("更换录音豆") { device.forgetDevice(); Task { await device.beginConnection(store.api) } }
                        .frame(minHeight: 44).disabled(device.transferring)
                }
                if let connected = device.connected {
                    WarmCard {
                        Label(connected.name, systemImage: "mic.fill").font(.headline)
                        if let battery = device.battery { Text("电量 \(battery)%").font(.subheadline) }
                        Text("序列号 \(device.serialNumber)").font(.caption).foregroundStyle(RecordingFormat.secondary)
                        if !device.firmwareVersion.isEmpty { Text("固件 \(device.firmwareVersion)").font(.caption).foregroundStyle(RecordingFormat.secondary) }
                        NavigationLink("查看与同步录音") { RecordingDeviceLibrary(speech: store.speech, device: device) }.frame(minHeight: 44)
                    }
                    Button("断开连接") { device.disconnect() }.frame(minHeight: 44).disabled(device.transferring)
                } else {
                    ForEach(device.devices.filter { $0.likelyRecorder }) { found in foundDevice(found) }
                    if device.devices.contains(where: { !$0.likelyRecorder }) {
                        DisclosureGroup("其他附近设备") {
                            Text("设备广播信息不完整时，可在这里按名称查找你的录音豆。").font(.footnote).foregroundStyle(RecordingFormat.secondary)
                            ForEach(device.devices.filter { !$0.likelyRecorder }) { found in foundDevice(found) }
                        }
                    }
                    if device.working {
                        Button("取消连接") { device.disconnect() }.frame(minHeight: 44).disabled(device.transferring)
                    } else {
                        Button(device.error == nil && device.devices.isEmpty ? "查找录音豆" : "重新查找") {
                            Task { await device.beginConnection(store.api) }
                        }.buttonStyle(RecordingPrimary()).disabled(Soundcore.simulator || !store.connectionReady)
                            .accessibilityIdentifier("soundcore-discover")
                    }
                    Text("没有找到？确认触点保护膜已去掉，放回充电盒时指示灯会亮，且 iPhone 蓝牙已打开。先断开其他 App 的设备连接，再重新查找；无需先到系统蓝牙设置中配对。")
                        .font(.footnote).foregroundStyle(RecordingFormat.secondary)
                }
            }.padding(24).frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Warm.paper.ignoresSafeArea()).navigationTitle("安克录音豆").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { if !Soundcore.simulator && device.connected == nil { await device.beginConnection(store.api) } }
            .onDisappear { device.suspendDiscovery() }
    }
    private func foundDevice(_ found: SoundcoreDevice) -> some View {
                        Button { device.connect(found) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "mic.fill").foregroundStyle(Warm.purple)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(found.name).font(.headline)
                                    Text((found.likelyRecorder ? "录音豆" : "附近设备") + " · 尾号 " + String(found.mac.suffix(5))).font(.caption).foregroundStyle(RecordingFormat.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right").foregroundStyle(RecordingFormat.secondary)
                            }.padding(16).frame(maxWidth: .infinity, minHeight: 60).background(Warm.white, in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain).disabled(device.connecting).accessibilityIdentifier("soundcore-device-" + found.mac)
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
