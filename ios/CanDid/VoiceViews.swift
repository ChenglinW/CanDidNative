import SwiftUI
import UIKit

struct VoicePresentation:ViewModifier {
    @EnvironmentObject var store:Store
    @ObservedObject var voice:VoiceSessionController
    @Environment(\.scenePhase) private var scene
    func body(content:Content)->some View {
        content.fullScreenCover(isPresented:$voice.showContinuous,onDismiss:{voice.exit()}) {VoiceConversationView(voice:voice).environmentObject(store)}
            .onChange(of:scene) {_,value in if value != .active {voice.pause(reason:"已暂停收音，回来后点击继续。")} else {voice.refreshRecoveries()}}
            .onChange(of:store.currentProjectSpace?.id) {_,_ in voice.contextChanged()}
            .onChange(of:store.base) {_,_ in voice.contextChanged()}
            .onChange(of:store.remote) {_,value in if !value {voice.contextChanged()}}

    }
}

struct VoiceConversationView:View {
    @EnvironmentObject var store:Store
    @ObservedObject var voice:VoiceSessionController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var history=false
    private var status:String {
        if voice.microphonePaused {return "已暂停"}
        switch voice.phase {
        case .idle:return "准备好，就开口吧"
        case .connecting:return "正在连接"
        case .listening:return "在听"
        case .finalizing:return "正在整理这句话"
        case .submitting,.thinking:return "正在思考"
        case .speaking:return "正在说"
        case .paused:return "已暂停"
        case .failed:return "需要重新连接"
        }
    }
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Button {voice.exit()} label:{Label("返回",systemImage:"chevron.down").font(.subheadline)}.frame(minHeight:44)
                Spacer()
                Text(store.currentProjectSpace?.name ?? "Candid").font(.subheadline.weight(.medium)).lineLimit(1)
            }.padding(.horizontal,22).padding(.top,12)
            Spacer(minLength:18)
            VStack(spacing:22) {
                ZStack {
                    Circle().fill(Warm.lavender).frame(width:152,height:152)
                        .scaleEffect(1+CGFloat(voice.level)*0.12)
                        .animation(reduceMotion ? nil:.easeOut(duration:0.12),value:voice.level)
                    Mascot(size:106)
                }.accessibilityHidden(true)
                Text(status).font(.title2.bold()).contentTransition(.opacity)
                Text(voice.microphonePaused ? "点击继续后再说。" : "自然地说，停一下我就接话。\n我说话时，你也可以开口打断。")
                    .font(.subheadline).foregroundStyle(RecordingFormat.secondary).multilineTextAlignment(.center).lineSpacing(5).fixedSize(horizontal:false,vertical:true)
            }.padding(.horizontal,24)
            Spacer(minLength:20)
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    if !voice.preview.isEmpty {
                        VStack(alignment:.leading,spacing:8) {Text("你").font(.caption).foregroundStyle(RecordingFormat.secondary);Text(voice.preview).font(.body).lineSpacing(5)}
                    }
                    if !voice.response.isEmpty {
                        VStack(alignment:.leading,spacing:8) {Text("Candid").font(.caption).foregroundStyle(Warm.purple);Text(voice.response).font(.body).lineSpacing(5)}
                    }
                    if let notice=voice.notice {Text(notice).font(.subheadline).foregroundStyle(RecordingFormat.secondary)}
                }.frame(maxWidth:.infinity,alignment:.leading).padding(22)
            }.frame(maxHeight:250)
                .background(Warm.white,in:RoundedRectangle(cornerRadius:22)).overlay(RoundedRectangle(cornerRadius:22).stroke(Warm.ink.opacity(0.07)))
                .padding(.horizontal,22)
            if !voice.active {
                Button("开始自由对话") {voice.enter(store:store)}.buttonStyle(RecordingPrimary()).padding(22)
            } else {
                HStack(spacing:28) {
                    Button {if voice.microphonePaused {voice.resume()} else{voice.pause()}} label:{VStack(spacing:8){Image(systemName:voice.microphonePaused ? "mic":"mic.slash").font(.title2).frame(width:54,height:54).background(Warm.lavender,in:Circle());Text(voice.microphonePaused ? "继续":"静音").font(.caption)}}
                    Button {voice.exit()} label:{VStack(spacing:8){Image(systemName:"keyboard").font(.title2).frame(width:54,height:54).background(Warm.white,in:Circle());Text("切文字").font(.caption)}}
                    Button {voice.exit()} label:{VStack(spacing:8){Image(systemName:"xmark").font(.title2).frame(width:54,height:54).background(Warm.orange,in:Circle());Text("结束").font(.caption)}}
                }.foregroundStyle(Warm.ink).padding(.top,25).padding(.bottom,25)
            }
            Button("查看聊天记录",systemImage:"text.bubble") {voice.pause(reason:"查看文字时已暂停收音，点击继续后再说。");history=true}.font(.caption).frame(minHeight:44)
            Text("当前空间的上下文会继续保留").font(.caption2).foregroundStyle(RecordingFormat.secondary).padding(.bottom,16)
        }.background(Warm.paper.ignoresSafeArea()).fontDesign(.rounded).foregroundStyle(Warm.ink)
            .onChange(of:voice.preview) {_,_ in voice.captionObserved()}
            .sheet(isPresented:$history) {
                NavigationStack {
                    ScrollView {VStack(alignment:.leading,spacing:20) {
                        ForEach(store.chatMessages) {message in VStack(alignment:.leading,spacing:7) {Text(message.role=="user" ? "你":"Candid").font(.caption).foregroundStyle(RecordingFormat.secondary);Text(message.content).textSelection(.enabled).lineSpacing(5)}}
                        if !store.chatPartial.isEmpty {Text(store.chatPartial).textSelection(.enabled)}
                    }.padding(22)}.background(Warm.paper).navigationTitle("当前对话").navigationBarTitleDisplayMode(.inline)
                        .toolbar {Button("返回") {history=false}}
                }
            }
    }
}

struct VoiceHoldGesture:ViewModifier {
    @EnvironmentObject var store:Store
    @ObservedObject var voice:VoiceSessionController
    var enabled:Bool=true
    @State private var began=false
    func body(content:Content)->some View {
        content.simultaneousGesture(LongPressGesture(minimumDuration:0.35,maximumDistance:45).sequenced(before:DragGesture(minimumDistance:0))
            .onChanged {value in
                guard enabled else{return}
                switch value {
                case .first(true):if !began {began=true;voice.beginHold(store:store)}
                case .second(true,let drag):
                    if !began {began=true;voice.beginHold(store:store)}
                    voice.cancelling=(drag?.translation.height ?? 0)<(-60)
                default:break
                }
            }.onEnded {value in
                guard began else{return};began=false
                let cancel=voice.cancelling;voice.gestureEnded()
                voice.releaseHold(cancelled:cancel)
            },including:enabled ? .all:.subviews)
    }
}

struct VoiceComposer:View {
    @EnvironmentObject var store:Store
    @ObservedObject var voice:VoiceSessionController
    var focused:FocusState<Bool>.Binding
    var send:()->Void
    var body:some View {
        HStack(spacing:8) {
            Button {
                guard !voice.justEndedGesture else{return}
                if voice.holding {voice.releaseHold(cancelled:false)} else {focused.wrappedValue=false;voice.beginHold(store:store)}
            } label:{Image(systemName:voice.holding ? "stop.circle.fill":"mic").font(.body).frame(width:44,height:44)}
                .accessibilityLabel(voice.holding ? "结束并发送语音":"开始语音输入，再次点击发送")
                .modifier(VoiceHoldGesture(voice:voice))
            TextField(store.chatBusy ? "补充内容，会排队处理":"长按说话，或点这里输入",text:Binding(get:{store.chatDraft},set:{store.saveChatDraft($0)}),axis:.vertical)
                .lineLimit(1...5).focused(focused).font(.body).padding(.vertical,9).allowsHitTesting(focused.wrappedValue)
                .accessibilityLabel("给 Candid 的消息")
            Button(action:send) {Image(systemName:"arrow.up").font(.headline).foregroundStyle(.white).frame(width:44,height:44).background(Warm.purple,in:RoundedRectangle(cornerRadius:12))}
                .disabled(store.chatDraft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || store.chatControlBusy || store.chatLoading || voice.active)
                .opacity(store.chatDraft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? 0.45:1)
                .accessibilityLabel("发送消息")
        }.padding(8).background(Warm.white,in:RoundedRectangle(cornerRadius:18))
            .overlay(RoundedRectangle(cornerRadius:18).stroke(voice.holding ? Warm.purple:Warm.ink.opacity(0.15)))
            .contentShape(RoundedRectangle(cornerRadius:18))
            .onTapGesture {if !voice.holding && !voice.justEndedGesture {focused.wrappedValue=true}}
            .modifier(VoiceHoldGesture(voice:voice,enabled:!focused.wrappedValue))
            .disabled(store.currentProjectSpace?.status != "active" || store.chatLoading)
    }
}

struct VoiceInputStatus:View {
    @EnvironmentObject var store:Store
    @ObservedObject var voice:VoiceSessionController
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            if voice.holding || voice.canDiscard {
                HStack {Label(voice.holding ? (voice.phase == .connecting ? "正在准备收音…":voice.cancelling ? "松开取消":"松开发送 · 上滑取消"):"正在整理这句话",systemImage:"waveform").font(.caption).foregroundStyle(Warm.purple);Spacer();Button("取消") {voice.discard()}.font(.caption).frame(minHeight:44)}
                if !voice.preview.isEmpty {Text(voice.preview).font(.subheadline).lineLimit(4)}
            }
            if let notice=voice.notice,!voice.showContinuous {Text(notice).font(.caption).foregroundStyle(RecordingFormat.secondary)}
            ForEach(voice.visibleRecoveries.filter{$0.backend==voice.identity(store.api) && $0.workspace==store.currentProjectSpace?.id}) {row in
                HStack {Text(row.unknown ? "有一条语音待核对发送结果":"保留了一段未完成的语音").font(.caption);Spacer();Button("查看") {Task {await voice.recoverText(row,store:store)}}.font(.caption).frame(minHeight:44);if row.requestID==nil {Button("恢复转写") {voice.retranscribe(row,store:store)}.font(.caption).frame(minHeight:44)};Button("丢弃") {voice.removeRecovery(row.id)}.font(.caption).frame(minHeight:44)}
            }
        }.padding(.horizontal,22)
    }
}
