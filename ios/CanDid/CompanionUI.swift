import SwiftUI
import UniformTypeIdentifiers

struct CompanionSection:Decodable {var title:String;var text:String}
struct CompanionPreparation:Decodable,Identifiable {
    var id:String;var client:String;var goal:String;var scenario:String;var scheduled_at:String?;var concerns:String?
    var sections:[CompanionSection];var status:String;var version:Int;var reference_status:String?
}
struct CompanionSnapshot:Decodable {var thread:ChatThread;var preparations:[CompanionPreparation];var next_preparation:CompanionPreparation?}
struct CompanionExpression:Decodable,Identifiable {
    var id:String;var title:String;var body:BodyText;var quote:String?;var tags:[String];var version:Int
    var source_session_id:String?;var evidence_refs:[ProductEvidence];var reference_status:String;var user_edited:Bool?
}
struct CompanionMemorySnapshot:Decodable {var expressions:[CompanionExpression];var discoveries:[PersonalDiscovery]}

extension Store {
    func reloadCompanion() async throws {
        guard remote else{return}
        let connection=api
        async let state:CompanionSnapshot=connection.call("/v1/companion")
        async let rows:[RecordingRecord]=connection.all("/v1/recordings")
        async let memory:CompanionMemorySnapshot=connection.call("/v1/companion/memory")
        let (snapshot,recordings,memories)=try await (state,rows,memory)
        try Task.checkCancellation()
        guard DeviceRecordingMap.identity(connection)==DeviceRecordingMap.identity(api) else{return}
        companion=snapshot;companionRecordings=recordings.filter{$0.fixture != true};companionMemory=memories
        if chatThread?.id != snapshot.thread.id {try await reloadProjectSpaces();try await loadChat(snapshot.thread.id)}
        else if !chatControlBusy && !chatLoading && !chatBusy && chatRequest == nil {try await refreshCompanionChat(snapshot.thread.id)}
    }
}

struct CompanionHome:View {
    @EnvironmentObject var store:Store
    let onSettings:()->Void
    @State private var open=false
    @State private var issue:String?
    @State private var device=false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func revealChat(_ value:Bool){withAnimation(reduceMotion ? nil:.easeOut(duration:0.3)){open=value}}
    private var records:[RecordingRecord] {Array(store.companionRecordings.prefix(3))}
    private var empty:Bool {store.companion?.next_preparation==nil && records.isEmpty}
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:10) {
                Button {} label:{Mascot(size:47)}.simultaneousGesture(TapGesture(count:2).onEnded{store.voice.enter(store:store)})
                    .accessibilityLabel("Candid 头像").accessibilityIdentifier("candid-avatar")
                    .accessibilityAction(named:Text("连续对话")){store.voice.enter(store:store)}
                VStack(alignment:.leading,spacing:3){Text("Candid").font(.title2.bold());Text("和你一起，准备下一次").font(.caption).foregroundStyle(RecordingFormat.secondary)}
                Spacer()
                Menu {Button("个人与设置",systemImage:"person.crop.circle",action:onSettings);NavigationLink("全部准备包"){CompanionPreparationList()}}
                    label:{Image(systemName:"ellipsis").frame(width:44,height:44)}.accessibilityLabel("个人与准备包")
                Button {device=true} label:{Image(systemName:"mic").frame(width:44,height:44).background(Warm.white,in:Circle())}.accessibilityLabel("使用安克录音豆录音")
            }.padding(.horizontal,22).padding(.top,12).padding(.bottom,18)
            GeometryReader {geometry in ZStack(alignment:.bottom) {
                Group {
                    if typeSize.isAccessibilitySize {ScrollView {backgroundContent}}
                    else {backgroundContent}
                }.opacity(open ? 0:1).accessibilityHidden(open)
                ChatView(onSettings:onSettings,embedded:true,focusComposer:open)
                    .padding(.top,48)
                    .overlay(alignment:.topTrailing){Button {revealChat(false)} label:{Image(systemName:"chevron.down").frame(width:44,height:44).background(Warm.white,in:Circle())}.padding(.trailing,22).accessibilityLabel("收起对话")}
                    .background(Warm.paper).opacity(open ? 1:0).allowsHitTesting(open).accessibilityHidden(!open)
                    .offset(y:open || reduceMotion ? 0:geometry.size.height)
                    .simultaneousGesture(DragGesture(minimumDistance:45).onEnded{value in
                        if value.startLocation.y<55 && value.translation.height>65 {revealChat(false)}
                    })
            }}.clipped()
            if !open {dock}
        }.frame(maxWidth:700).frame(maxWidth:.infinity).background(Warm.paper.ignoresSafeArea())
            .toolbar(.hidden,for:.navigationBar)
            .sheet(isPresented:$device){NavigationStack{CompanionDeviceGuide().toolbar{Button("返回"){device=false}}}}
            .task(id:String(store.remote)+store.base){
                guard store.remote else{return}
                while !Task.isCancelled {do{try await store.reloadCompanion();issue=nil}catch is CancellationError{break}catch{issue="暂时无法刷新，请检查网络后重试。"};do{try await Task.sleep(for:.seconds(5))}catch{break}}
            }
            .onChange(of:store.voice.preview){_,value in if !value.isEmpty && !store.voice.showContinuous {revealChat(true)}}
    }
    private var backgroundContent:some View {
        VStack(alignment:.leading,spacing:14) {
            RecordingStatusBar(speech:store.speech,device:store.soundcore)
            if let issue {HStack{Text(issue).font(.caption);Button("重试"){Task{do{try await store.reloadCompanion();self.issue=nil}catch{}}}}}
            if empty {
                Spacer(minLength:25)
                VStack(spacing:18){Mascot(size:80);Text("下一场沟通，一起准备。").font(.title2.bold());Text("说说你要见谁，或用录音豆记录一场沟通。").font(.subheadline).foregroundStyle(RecordingFormat.secondary).multilineTextAlignment(.center)}.frame(maxWidth:.infinity)
                Spacer(minLength:30)
            } else {
                if let pack=store.companion?.next_preparation {
                    Text("下一场").font(.caption).foregroundStyle(RecordingFormat.secondary)
                    CompanionPreparationCard(pack:pack)
                }
                if !records.isEmpty {
                    HStack{Text("最近沟通").font(.caption).foregroundStyle(RecordingFormat.secondary);Spacer();Button("全部录音 →"){store.recordingNavigation.section = .recordings}.font(.caption).frame(minHeight:44)}
                    ForEach(records){r in NavigationLink{CompanionRecordingPage(id:r.id)}label:{CompanionRecordingRow(record:r)}.buttonStyle(.plain)}
                }
                Spacer(minLength:0)
            }
        }.padding(.horizontal,22).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
    }
    private var prepareButton:some View {Button("准备下一场",systemImage:"scope"){revealChat(true);if store.remote{store.sendChat("帮我准备下一场沟通。")}else{store.saveChatDraft("帮我准备下一场沟通")}}.frame(minHeight:44)}
    private var continuousButton:some View {Button("连续对话",systemImage:"waveform"){store.voice.enter(store:store)}.frame(minHeight:44)}
    private var dock:some View {
        VStack(spacing:4){
            ViewThatFits(in:.horizontal){
                HStack{prepareButton;Spacer(minLength:12);continuousButton}
                VStack(alignment:.leading,spacing:4){prepareButton;continuousButton}.frame(maxWidth:.infinity,alignment:.leading)
            }.font(.caption)

            Button {revealChat(true)} label:{
                HStack{Image(systemName:"bubble.left").imageScale(.small).frame(minWidth:44,minHeight:44);Text(store.chatDraft.isEmpty ? "说说下一场，或者聊聊刚才…":store.chatDraft).font(.body).foregroundStyle(RecordingFormat.secondary).lineLimit(2).fixedSize(horizontal:false,vertical:true);Spacer();Mascot(size:30)}.padding(8).background(Warm.white,in:RoundedRectangle(cornerRadius:18)).overlay(RoundedRectangle(cornerRadius:18).stroke(Warm.ink.opacity(0.12)))
            }.buttonStyle(.plain).accessibilityLabel("给 Candid 的消息").accessibilityIdentifier("home-chat-input")
                .modifier(VoiceHoldGesture(voice:store.voice))
            VoiceInputStatus(voice:store.voice)
        }.padding(.horizontal,22).padding(.bottom,10).background(Warm.paper)
    }
}

struct CompanionPreparationCard:View {
    var pack:CompanionPreparation
    var body:some View {NavigationLink{CompanionPreparationPage(id:pack.id)}label:{VStack(alignment:.leading,spacing:10){Text(pack.client).font(.headline);Text(ProductDate.display(pack.scheduled_at)).font(.caption).foregroundStyle(Warm.purple);Text("准备包已生成 · "+pack.goal).font(.caption).lineLimit(2);Text("查看会前准备包").font(.subheadline.weight(.semibold)).padding(.horizontal,14).frame(minHeight:44).background(Warm.orange,in:RoundedRectangle(cornerRadius:12))}.frame(maxWidth:.infinity,alignment:.leading).padding(16).background(Warm.lavender,in:RoundedRectangle(cornerRadius:22))}.buttonStyle(.plain).accessibilityIdentifier("preparation-card-"+pack.id)}
}
struct CompanionPreparationPage:View {
    @EnvironmentObject var store:Store
    let id:String
    @State private var pack:CompanionPreparation?
    @State private var issue:String?
    var body:some View {ScrollView{VStack(alignment:.leading,spacing:22){if let pack{Text(ProductDate.display(pack.scheduled_at)).font(.caption).foregroundStyle(RecordingFormat.secondary);Text(pack.client).font(.largeTitle.bold());if pack.reference_status=="superseded"{Text("准备依据已更新，请回到对话重新整理。").foregroundStyle(Warm.purple)};ForEach(Array(pack.sections.enumerated()),id:\.offset){_,s in VStack(alignment:.leading,spacing:10){Text(s.title).font(.headline);Text(s.text).lineSpacing(6).textSelection(.enabled)}}}else if let issue{Text(issue);Button("重试"){Task{await load()}}}else{ProgressView()}}.padding(22).frame(maxWidth:700).frame(maxWidth:.infinity)}.background(Warm.paper).navigationTitle("会前准备包").navigationBarTitleDisplayMode(.inline).task{await load()}}
    private func load() async{if !store.remote {pack=store.companion?.preparations.first{$0.id==id};return};do{pack=try await store.api.call("/v1/companion/preparations/"+id);issue=nil}catch{issue=error.localizedDescription}}
}
struct CompanionPreparationList:View {
    @EnvironmentObject var store:Store
    var body:some View {ScrollView{VStack(spacing:16){if (store.companion?.preparations ?? []).isEmpty{ContentUnavailableView("还没有准备包",systemImage:"doc.text",description:Text("在 Candid 对话中说说下一次要见谁。"))};ForEach(store.companion?.preparations ?? []){p in VStack(alignment:.leading){CompanionPreparationCard(pack:p);Text(p.status=="completed" ? "本场已结束":p.reference_status=="superseded" ? "依据已更新，请重新整理":(ProductDate.parse(p.scheduled_at ?? "") ?? .distantFuture)<Date() ? "计划时间已过，请核对场次状态":"准备就绪").font(.caption).foregroundStyle(RecordingFormat.secondary);if p.status=="ready"{Button("本场已经结束"){Task{await store.perform{_=try await store.api.raw("/v1/companion/preparations/"+p.id+"/complete",method:"POST",body:["expected_version":p.version]);try await store.reloadCompanion()}}}.frame(minHeight:44)}}}.padding(22)}}.background(Warm.paper).navigationTitle("全部准备包")}
}

struct CompanionRecordingRow:View {
    let record:RecordingRecord
    var body:some View {HStack(spacing:12){Image(systemName:"mic").foregroundStyle(Warm.purple).frame(width:34,height:38).background(Warm.lavender,in:RoundedRectangle(cornerRadius:12));VStack(alignment:.leading,spacing:5){Text(RecordingFormat.title(record)).font(.subheadline.weight(.semibold)).lineLimit(1);Text(RecordingFormat.timestamp(record)+" · "+RecordingFormat.clock((record.duration_ms ?? 0)/1000)+" · "+RecordingFormat.status(record)).font(.caption2).foregroundStyle(RecordingFormat.secondary)};Spacer(minLength:0);Image(systemName:"chevron.right").font(.caption).foregroundStyle(RecordingFormat.secondary)}.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Warm.white,in:RoundedRectangle(cornerRadius:16))}
}
struct CompanionDeviceGuide:View {
    @EnvironmentObject var store:Store
    @State private var connect=false
    @Environment(\.dismiss) private var dismiss
    var body:some View {ScrollView{VStack(spacing:24){Mascot(size:110);Text("用安克录音豆，\n记录下一场沟通。").font(.title.bold()).multilineTextAlignment(.center);Text("录音同步后，会自动整理复盘，\n再把结果带回 Candid 对话。").multilineTextAlignment(.center).foregroundStyle(RecordingFormat.secondary);WarmCard{Label("安克录音豆",systemImage:"mic").font(.headline);Text(store.soundcore.connected==nil ? "尚未连接":"已连接");Button("连接与同步"){connect=true}.buttonStyle(RecordingPrimary())};Button("手机会议录音（备用）"){dismiss();store.recordingNavigation.newMeeting=true;store.recordingNavigation.showRecorder=true}.font(.subheadline).frame(minHeight:44).accessibilityIdentifier("phone-recording-fallback")}.padding(24).frame(maxWidth:600).frame(maxWidth:.infinity)}.background(Warm.paper).navigationTitle("录音设备").navigationBarTitleDisplayMode(.inline).sheet(isPresented:$connect){NavigationStack{RecordingDeviceLibrary(speech:store.speech,device:store.soundcore)}}}
}
struct CompanionRecordings:View {
    @EnvironmentObject var store:Store
    @State private var device=false
    var body:some View {ScrollView{VStack(alignment:.leading,spacing:14){if store.companionRecordings.isEmpty{VStack(spacing:20){Mascot(size:110);Text("第一场经验，从这里留下。").font(.title2.bold());Text("请使用安克录音豆录音。\n同步后，你的录音会出现在这里。").font(.subheadline).foregroundStyle(RecordingFormat.secondary).multilineTextAlignment(.center);Button("使用录音豆"){device=true}.buttonStyle(RecordingPrimary())}.padding(.top,80)}else{ForEach(store.companionRecordings){r in NavigationLink{CompanionRecordingPage(id:r.id)}label:{CompanionRecordingRow(record:r)}.buttonStyle(.plain)}};Button("手机会议录音（备用）"){store.recordingNavigation.newMeeting=true;store.recordingNavigation.showRecorder=true}.frame(minHeight:44).font(.subheadline).accessibilityIdentifier("phone-recording-fallback")}.padding(22).frame(maxWidth:700).frame(maxWidth:.infinity)}.background(Warm.paper).navigationTitle("录音").toolbar{Button("录音设备",systemImage:"mic"){device=true}}.sheet(isPresented:$device){NavigationStack{CompanionDeviceGuide().toolbar{Button("返回"){device=false}}}}.refreshable{try? await store.reloadCompanion()}}
}

struct CompanionRecordingPage:View {
    @EnvironmentObject var store:Store
    let id:String
    var focusMS:Int?=nil
    @State private var record:RecordingRecord?
    @State private var tab="复盘"
    @State private var speaker=false
    @State private var edit=false
    @State private var issue:String?
    var body:some View {ScrollViewReader{proxy in ScrollView{VStack(alignment:.leading,spacing:20){
        if let r=record {
            Text(RecordingFormat.timestamp(r)+" · "+RecordingFormat.clock((r.duration_ms ?? 0)/1000)).font(.caption).foregroundStyle(RecordingFormat.secondary)
            Text(RecordingFormat.title(r)).font(.title2.bold())
            Button("回听录音",systemImage:"play.fill"){Task{await store.perform{try await store.playRecording(r.id,startMS:0,endMS:r.duration_ms ?? 0)}}}.frame(minHeight:44)
            if store.recordingPlaybackID==id {RecordingPlayerBar()}
            Picker("录音内容",selection:$tab){Text("复盘").tag("复盘");Text("原文").tag("原文")}.pickerStyle(.segmented)
            if tab=="复盘" {
                if (r.knowledge ?? []).isEmpty {ContentUnavailableView("正在整理这场沟通",systemImage:"sparkles",description:Text(RecordingFormat.status(r)+"；完成后会给你一条复盘消息。"));ForEach((r.jobs ?? []).filter{["failed","interrupted","cancelled"].contains($0.status)}){job in Text(job.error ?? "整理尚未完成");Button("重试整理"){Task{await store.perform{_=try await store.api.raw("/v1/business-jobs/"+job.id+"/retry",method:"POST",body:[:])}}}.frame(minHeight:44)}}
                ForEach(r.knowledge ?? []){k in Text(k.text).lineSpacing(6).textSelection(.enabled);reviewList("这次有效的表达",k.review?.strengths ?? []);reviewList("下次可以更清楚的",k.review?.improvements ?? []);reviewList("建议跟进",k.review?.next_steps ?? [])}
                let expressions=(store.companionMemory?.expressions ?? []).filter{$0.source_session_id==id}
                if !expressions.isEmpty{Text("这场的关键问答与表达").font(.headline);ForEach(expressions){e in NavigationLink{CompanionExpressionPage(expression:e)}label:{VStack(alignment:.leading,spacing:7){Text(e.title).font(.subheadline.weight(.semibold));Text(e.quote ?? "").font(.caption).foregroundStyle(RecordingFormat.secondary)}.frame(maxWidth:.infinity,alignment:.leading).padding(16).background(Warm.white,in:RoundedRectangle(cornerRadius:16))}.buttonStyle(.plain)}}
                Button("查看完整原文"){tab="原文"}.frame(minHeight:44)
            } else {
                HStack{Button("说话人认领"){speaker=true};Spacer();Button("修订原文"){edit=true}}.font(.subheadline).frame(minHeight:44)
                ForEach(r.segments ?? []){s in VStack(alignment:.leading,spacing:8){Button{speaker=true}label:{Text(RecordingFormat.speakerName(s)+" · "+RecordingFormat.clock(s.start_ms/1000)).font(.caption).foregroundStyle(Warm.purple)}.frame(minHeight:44);Text(s.text).lineSpacing(6).textSelection(.enabled)}.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(Warm.white,in:RoundedRectangle(cornerRadius:16)).id(s.id)}
            }
        }else if let issue{Text(issue);Button("重试"){Task{await load()}}}else{ProgressView()}
    }.padding(22).frame(maxWidth:700).frame(maxWidth:.infinity)}.background(Warm.paper).navigationTitle("沟通复盘").navigationBarTitleDisplayMode(.inline)
        .task{if focusMS != nil{tab="原文"};while !Task.isCancelled{await load();if let focusMS,let s=record?.segments?.first(where:{$0.end_ms>=focusMS}){proxy.scrollTo(s.id,anchor:.center)};do{try await Task.sleep(for:.seconds(5))}catch{break}}}
        .sheet(isPresented:$speaker,onDismiss:{Task{await load()}}){if let record{RecordingSpeakerPicker(record:record)}}
        .sheet(isPresented:$edit,onDismiss:{Task{await load()}}){if let record{TranscriptEditor(record:record)}}
        .onDisappear{if store.recordingPlaybackID==id{store.stopPlayback()}}
    }}
    private func load() async{guard store.remote else{record=store.companionRecordings.first{$0.id==id};return};do{record=try await store.api.call("/v1/recordings/"+id);issue=nil}catch{issue=error.localizedDescription}}
    @ViewBuilder private func reviewList(_ title:String,_ rows:[String])->some View{if !rows.isEmpty{Text(title).font(.headline);ForEach(Array(rows.enumerated()),id:\.offset){_,s in Text(s).font(.subheadline).lineSpacing(6)}}}
}

struct CompanionMemory:View {
    @EnvironmentObject var store:Store
    @State private var tab="长期资料"
    @State private var filter="全部"
    @State private var upload=false
    @State private var selected:Set<String>=[]
    var body:some View {ScrollView{VStack(alignment:.leading,spacing:20){
        let discoveries=store.companionMemory?.discoveries ?? []
        if let first=discoveries.first {NavigationLink{CompanionDiscoveryPage(discovery:first)}label:{WarmCard(color:Warm.lavender){Text(first.status=="pending" ? "跨场发现 · 待核对":"最近一个发现").font(.caption);Text(first.title).font(.title3.bold());Text(first.text).font(.subheadline).lineLimit(3);Text("看看依据与下一步 →").font(.caption).foregroundStyle(Warm.purple)}}.buttonStyle(.plain)}
        Picker("记忆内容",selection:$tab){Text("长期资料").tag("长期资料");Text("表达积累").tag("表达积累");Text("跨场发现").tag("跨场发现")}.pickerStyle(.segmented)
        if tab=="长期资料" {
            if store.personalState.documents.isEmpty {VStack(spacing:18){Mascot(size:100);Text("把你的经验，慢慢种在这里。").font(.title2.bold());Text("先添加资料。聊过的内容，会逐渐变成你的表达积累。").font(.subheadline).foregroundStyle(RecordingFormat.secondary);Button("添加第一份资料"){upload=true}.buttonStyle(RecordingPrimary())}.padding(.top,45)}
            ForEach(store.personalState.documents){item in
                VStack(alignment:.leading,spacing:6){
                    NavigationLink{CompanionDocumentPage(id:item.serverID ?? item.id)}label:{Label(item.title,systemImage:"doc.text").font(.headline).frame(minHeight:44)}
                    Text(item.statusTitle).font(.caption).foregroundStyle(RecordingFormat.secondary)
                    if let error=item.error{Text(error).font(.caption).foregroundStyle(.red)}
                    HStack{if ["failed","interrupted","cancelled","upload_failed","local"].contains(item.status){Button("重试整理"){Task{await store.retryPersonalDocument(item)}}};Spacer();Button("移除资料"){Task{await store.removePersonalDocument(item)}}}.font(.caption).frame(minHeight:44)
                }.padding(16).background(Warm.white,in:RoundedRectangle(cornerRadius:16))
            }
            if let error=store.personalImportError{Text(error).font(.subheadline).foregroundStyle(.red)}
            NavigationLink("我的介绍与资料"){PersonalProfilePage()}.font(.subheadline).frame(minHeight:44)
        }else if tab=="表达积累" {
            let rows=(store.companionMemory?.expressions ?? []).filter{filter=="全部" || $0.tags.contains(filter)}
            ScrollView(.horizontal,showsIndicators:false){HStack{ForEach(["全部","客户常问","值得复用","需要改善"],id:\.self){value in Button(value){filter=value}.font(.caption).padding(.horizontal,12).frame(minHeight:44).background(filter==value ? Warm.sage:Warm.white,in:Capsule())}}}
            if rows.isEmpty{ContentUnavailableView("还没有表达积累",systemImage:"leaf",description:Text("录音同步并完成复盘后，有原文依据的表达会自动沉淀在这里。"))}
            ForEach(rows){e in NavigationLink{CompanionExpressionPage(expression:e)}label:{VStack(alignment:.leading,spacing:8){Text(e.title).font(.headline);Text(e.tags.joined(separator:" · ")+" · "+(e.reference_status=="current" ? "有原文依据":"依据已更新，待重核")).font(.caption).foregroundStyle(Warm.purple);Text(e.body.text).font(.subheadline).lineLimit(3)}.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(Warm.white,in:RoundedRectangle(cornerRadius:16))}.buttonStyle(.plain)}
        }else{
            Text("跨场综合的新个人结论，集中核对一次。").font(.subheadline).foregroundStyle(RecordingFormat.secondary)
            ForEach(discoveries){d in HStack(alignment:.top){if d.status=="pending"{Button{if selected.contains(d.id){selected.remove(d.id)}else{selected.insert(d.id)}}label:{Image(systemName:selected.contains(d.id) ? "checkmark.circle.fill":"circle").frame(width:44,height:44)}.disabled(d.reference_status=="superseded")};NavigationLink{CompanionDiscoveryPage(discovery:d)}label:{VStack(alignment:.leading){Text(d.title).font(.headline);Text(d.text).font(.subheadline).lineLimit(3)}}.buttonStyle(.plain)}}
            if !selected.isEmpty{Button("确认选中的发现（\(selected.count)）"){Task{await store.perform{_=try await store.api.raw("/v1/discoveries/decisions",method:"POST",body:["items":discoveries.filter{selected.contains($0.id)}.map{["id":$0.id,"expected_version":$0.version,"status":"confirmed"] as [String:Any]}]);selected=[];try await store.reloadCompanion()}}}.buttonStyle(RecordingPrimary())}
        }
    }.padding(22).frame(maxWidth:700).frame(maxWidth:.infinity)}.background(Warm.paper).navigationTitle("记忆库")
        .toolbar{Button("上传资料",systemImage:"plus"){upload=true}}
        .fileImporter(isPresented:$upload,allowedContentTypes:[.pdf,UTType(filenameExtension:"docx") ?? .data,UTType(filenameExtension:"pptx") ?? .data,.plainText,UTType(filenameExtension:"md") ?? .plainText],allowsMultipleSelection:true){result in if case .success(let urls)=result{Task{await store.addOnboardingFiles(urls)}}else if case .failure(let error)=result,!ImportedDocumentFiles.isCancellation(error){store.personalImportError=error.localizedDescription}}
        .task{while !Task.isCancelled{await store.restorePersonalProfile();try? await store.reloadCompanion();do{try await Task.sleep(for:.seconds(5))}catch{break}}}
    }
}
struct CompanionExpressionPage:View {
    @EnvironmentObject var store:Store
    let expression:CompanionExpression
    @State private var text=""
    @State private var editing=false
    @State private var version=0
    @State private var issue:String?
    var body:some View {ScrollView{VStack(alignment:.leading,spacing:22){Text(expression.title).font(.title.bold());Text(expression.reference_status=="current" ? "有原文依据 · 建议表达待实战验证":"来源已修订 · 这版表达待重新核对").font(.caption).foregroundStyle(Warm.purple);if let quote=expression.quote{Text("当时怎么说").font(.headline);Text("“"+quote+"”").lineSpacing(6)};Text(expression.user_edited==true ? "你保存的表达":"可以试试这样说").font(.headline);if editing{TextEditor(text:$text).frame(minHeight:180);Button("保存我的说法"){Task{await save()}}.buttonStyle(RecordingPrimary())}else{Text(text).lineSpacing(6).textSelection(.enabled);Button("改成我的说法"){editing=true}.frame(minHeight:44)};if let issue{Text(issue).foregroundStyle(.red)};Text("依据与适用范围").font(.headline);ForEach(Array(expression.evidence_refs.enumerated()),id:\.offset){_,ref in if let sid=ref.session_id{NavigationLink("回到原文 · "+RecordingFormat.clock((ref.start_ms ?? 0)/1000)){CompanionRecordingPage(id:sid,focusMS:ref.start_ms)}.frame(minHeight:44)}}}.padding(22).frame(maxWidth:700).frame(maxWidth:.infinity)}.background(Warm.paper).navigationTitle("表达积累").navigationBarTitleDisplayMode(.inline).onAppear{if version==0{text=expression.body.text;version=expression.version}}}
    private func save() async{do{let updated:CompanionExpression=try await store.api.call("/v1/companion/expressions/"+expression.id,method:"PATCH",body:["text":text,"expected_version":version]);version=updated.version;editing=false;issue=nil;try await store.reloadCompanion()}catch{issue=error.localizedDescription}}
}
struct CompanionDiscoveryPage:View {
    @EnvironmentObject var store:Store
    let discovery:PersonalDiscovery
    @State private var edit=false
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:22){Text(discovery.title).font(.largeTitle.bold());Text(discovery.status=="confirmed" ? "已确认的跨场发现":"AI 跨场发现 · 待集中核对").font(.caption).foregroundStyle(Warm.purple);Text(discovery.text).lineSpacing(6);if discovery.reference_status=="superseded"{Text("依据已修订，请重新核对。").foregroundStyle(Warm.purple)};Text("一起看看原话").font(.headline);ProductEvidenceLinks(refs:discovery.evidence_refs);Button("这条发现不准确，补充说明"){edit=true}.frame(minHeight:44)}.padding(22)}.background(Warm.paper).navigationTitle("跨场发现").navigationBarTitleDisplayMode(.inline).sheet(isPresented:$edit){ProductDiscoveryEditor(discovery:discovery)}}
}

struct CompanionDocumentPage:View {
    struct Document:Decodable{var id:String;var title:String;var text:String;var pages:[Page]}
    struct Page:Decodable{var page:Int;var text:String}
    @EnvironmentObject var store:Store
    let id:String
    @State private var document:Document?
    @State private var issue:String?
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:22){if let d=document{Text(d.title).font(.title.bold());if d.pages.isEmpty{Text(d.text).textSelection(.enabled).lineSpacing(6)}else{ForEach(d.pages,id:\.page){p in Text("第 \(p.page) 页").font(.headline);Text(p.text).textSelection(.enabled).lineSpacing(6)}}}else if let issue{Text(issue);Button("重试读取"){Task{await load()}}.frame(minHeight:44)}else{ProgressView()}}.padding(22).frame(maxWidth:700).frame(maxWidth:.infinity)}.background(Warm.paper).navigationTitle("长期资料").navigationBarTitleDisplayMode(.inline).task{await load()}}
    private func load() async{do{document=try await store.api.call("/v1/companion/documents/"+id);issue=nil}catch{issue=error.localizedDescription}}
}

#if DEBUG
extension Store {
    func seedCompanionPreview(){
        func decode<T:Decodable>(_ type:T.Type,_ value:Any)->T {try! JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:value))}
        let thread:[String:Any]=["id":"preview-chat","title":"Candid","status":"idle","activity":[],"message_count":0,"updated_at":"2026-10-16T01:00:00Z","workspace_id":"preview-context"]
        let pack:[String:Any]=["id":"preview-preparation","client":"华味餐饮 · 商务谈判","goal":"确认三家门店试点与实施范围","scenario":"sales","scheduled_at":"2026-10-17T14:00:00+08:00","sections":[["title":"本次目标","text":"确认三家门店试点与实施范围。"],["title":"沟通建议","text":"先确认现状，再约定一个明确的下一步。"]],"status":"ready","version":1,"reference_status":"current"]
        companion=decode(CompanionSnapshot.self,["thread":thread,"preparations":[pack],"next_preparation":pack])
        chatThread=companion?.thread
        companionRecordings=decode([RecordingRecord].self,[("preview-a","华味餐饮 · 产品方案沟通"),("preview-b","晴川零售 · 需求了解"),("preview-c","南岸门店 · 方案讨论")].map{["id":$0.0,"title":$0.1,"pipeline_status":"done","started_at":"2026-10-16T06:00:00Z","duration_ms":1920000,"transcript_revision":1,"segments":[["id":"preview-line","session_id":$0.0,"text":"请先确认服务范围，再安排三家门店试点。","start_ms":1000,"end_ms":4000,"speaker":"unknown","speaker_id":"part0:0"]],"knowledge":[["id":"preview-knowledge-"+$0.0,"title":"沟通复盘","text":"明确试点范围，接口和实施排期仍待核实。"]]] as [String:Any]})
        companionMemory=decode(CompanionMemorySnapshot.self,["expressions":[],"discoveries":[]])
    }
}
#endif
