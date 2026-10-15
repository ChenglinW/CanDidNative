import SwiftUI

struct ProductHome:View {
    @EnvironmentObject var store:Store
    let onSettings:()->Void
    @State private var scenario="all"
    @State private var scenarioInitialized=false
    @State private var create=false
    @State private var ask=false
    private var projects:[ProductProject] {store.products.filter{$0.status=="active" && (scenario=="all" || $0.scenario==scenario)}}
    private var next:BusinessMeeting? {store.productDetails.flatMap(\.meetings).filter{$0.status=="planned"}.filter{m in projects.contains{$0.id==m.project_id}}.sorted{($0.date ?? .distantFuture)<($1.date ?? .distantFuture)}.first}
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                HStack {
                    Button(action:onSettings) {Image(systemName:"person.crop.circle.fill").font(.system(size:38)).foregroundStyle(Warm.purple).frame(width:44,height:44)}.accessibilityLabel("个人与设置")
                    VStack(alignment:.leading,spacing:3) {Text(store.personalState.profile.display_name.isEmpty ? "一起准备下一次" : store.personalState.profile.display_name+"，一起准备下一次").font(.title2.bold());Text("销售与面试，把每场沟通连起来").font(.caption).foregroundStyle(RecordingFormat.secondary)}
                    Spacer()
                    Button {store.recordingNavigation.newMeeting=true;store.recordingNavigation.showRecorder=true} label:{Image(systemName:"record.circle").font(.title2).frame(width:44,height:44)}.accessibilityLabel("开始新录音")
                }
                Picker("场景",selection:$scenario) {Text("全部").tag("all");Text("销售 BD").tag("sales");Text("面试").tag("interview")}.pickerStyle(.segmented)
                if !store.remote {Label("当前为示例资料 · 连接后端后开始真实项目",systemImage:"info.circle").font(.caption).foregroundStyle(RecordingFormat.secondary)}
                VStack(alignment:.leading,spacing:12) {
                    Text("下一场").font(.headline)
                    if let m=next,let p=projects.first(where:{$0.id==m.project_id}) {
                        NavigationLink {ProductMeetingPage(project:p,meeting:m)} label:{WarmCard(color:Warm.lavender) {
                            Text(m.title).font(.title3.bold());Text(p.name).font(.subheadline);Text(ProductDate.display(m.scheduled_at)).font(.caption)
                            Text(m.goal.isEmpty ? "说说这次最想推进什么":m.goal).font(.body).lineSpacing(4)
                            Label(store.productDetails.first(where:{$0.project.id==p.id})?.preparations.contains(where:{$0.meeting_id==m.id})==true ? "准备包已保存":"准备包待整理",systemImage:"doc.text")
                        }}.buttonStyle(.plain)
                    } else {
                        WarmCard(color:Warm.lavender) {Text("下一次，要见谁？").font(.title3.bold());Text("一句话安排沟通，我会沿着项目帮你准备。").font(.subheadline);Button("安排下一场",systemImage:"plus") {create=true}.frame(minHeight:44)}
                    }
                }
                HStack {Text("进行中的项目").font(.headline);Spacer();Button("新建",systemImage:"plus") {create=true}.frame(minHeight:44)}
                if projects.isEmpty {ContentUnavailableView("从一个方向开始",systemImage:"square.stack",description:Text("客户机会和岗位机会分别保留自己的上下文。"))}
                ForEach(projects) {p in NavigationLink {ProductProjectPage(id:p.id)} label:{ProductProjectRow(project:p)}.buttonStyle(.plain)}
                ProductTasks(items:store.productDetails.flatMap(\.items).filter{i in projects.contains{$0.id==i.project_id} && i.kind=="action" && i.status=="open" && i.is_practice != true && i.is_example != true})
                if !store.remote {Button("连接本机后端",action:onSettings).buttonStyle(RecordingPrimary())}
            }.padding(22).frame(maxWidth:700).frame(maxWidth:.infinity)
        }.background(Warm.paper.ignoresSafeArea()).toolbar(.hidden,for:.navigationBar)
            .safeAreaInset(edge:.bottom) {ProductInput(scope:["mode":"all"],ask:$ask)}
            .sheet(isPresented:$create) {ProductCreator()}
            .sheet(isPresented:$ask) {NavigationStack {ChatView(onSettings:onSettings).toolbar(.visible,for:.navigationBar).toolbar {ToolbarItem(placement:.topBarLeading){Button("返回") {ask=false}}}}}
            .onAppear {if !scenarioInitialized {let preferred=store.personalState.profile.scenarios;if preferred.count==1 {scenario=preferred[0]};scenarioInitialized=true}}
            .task {if !store.remote {store.seedProducts()} else{await store.perform {try await store.reloadProducts()}}}
            .refreshable {await store.perform {try await store.reloadProducts()}}
    }
}
struct ProductProjectRow:View {
    let project:ProductProject
    var body:some View {VStack(alignment:.leading,spacing:9) {
        HStack {Text(project.name).font(.headline);Spacer();Image(systemName:"chevron.right").font(.caption).foregroundStyle(RecordingFormat.secondary)}
        Text(project.goal.isEmpty ? "目标可以在沟通中慢慢补齐":project.goal).font(.subheadline).lineLimit(2).foregroundStyle(RecordingFormat.secondary)
        HStack {Text(project.scenarioTitle);Text("·");Text(project.stageTitle);if project.is_example==true {Text("· 示例")};Spacer()}.font(.caption).foregroundStyle(Warm.purple)
    }.padding(.vertical,16).padding(.horizontal,18).background(Warm.white,in:RoundedRectangle(cornerRadius:16))}
}
struct ProductProjects:View {
    @EnvironmentObject var store:Store
    @State private var archived=false
    @State private var create=false
    @State private var ask=false
    var body:some View {
        ScrollView {VStack(alignment:.leading,spacing:18) {
            Picker("项目状态",selection:$archived) {Text("进行中").tag(false);Text("已归档").tag(true)}.pickerStyle(.segmented)
            ForEach(store.products.filter{($0.status=="archived")==archived}) {p in NavigationLink {ProductProjectPage(id:p.id)} label:{ProductProjectRow(project:p)}.buttonStyle(.plain)}
            if store.products.filter({($0.status=="archived")==archived}).isEmpty {ContentUnavailableView(archived ? "暂无归档项目":"暂无项目",systemImage:"square.stack",description:Text("每个方向有独立上下文，可包含多场沟通。"))}
        }.padding(22)}.background(Warm.paper).navigationTitle("项目")
            .toolbar {Button("新建项目",systemImage:"plus") {create=true}}
            .sheet(isPresented:$create) {ProductCreator()}
            .safeAreaInset(edge:.bottom) {ProductInput(scope:["mode":"all"],ask:$ask)}
            .sheet(isPresented:$ask) {ProductAskSheet()}
            .refreshable {await store.perform {try await store.reloadProducts()}}
    }
}
struct ProductProjectPage:View {
    @EnvironmentObject var store:Store
    let id:String
    @State private var ask=false
    @State private var newMeeting=false
    @State private var edit=false
    @State private var jobs:[BusinessJob]=[]
    private var detail:ProductDetail? {store.productDetails.first{$0.project.id==id}}
    var body:some View {
        ScrollView {if let d=detail {VStack(alignment:.leading,spacing:22) {
            HStack {Text(d.project.scenarioTitle).font(.subheadline);Spacer();Text(d.project.stageTitle).font(.subheadline.bold()).foregroundStyle(Warm.purple)}
            Text(d.project.goal.isEmpty ? "目标待补充":d.project.goal).font(.title3).lineSpacing(5)
            if d.project.is_example==true {Label("示例项目，未计入个人表现",systemImage:"info.circle").font(.caption)}
            if let people=d.project.participants,!people.isEmpty {Text("参与方").font(.headline);ForEach(people,id:\.self) {p in Text(p.name+" · "+p.role+" · "+(p.side=="self" ? "我方":"对方")).font(.subheadline)}}
            HStack {Text("场次时间线").font(.headline);Spacer();Button("安排一场",systemImage:"plus") {newMeeting=true}.frame(minHeight:44).disabled(d.project.status=="archived")}
            ScrollView(.horizontal) {HStack(spacing:12) {
                ForEach(d.meetings) {m in NavigationLink {ProductMeetingPage(project:d.project,meeting:m)} label:{VStack(alignment:.leading,spacing:9) {
                    Text(m.title).font(.headline).lineLimit(2);Text(ProductDate.display(m.scheduled_at ?? m.actual_at)).font(.caption)
                    Text(m.is_practice==true ? "练习":m.status=="completed" ? "已复盘":"会前准备").font(.caption).foregroundStyle(Warm.purple)
                }.frame(width:180,alignment:.leading).padding(16).background(Warm.white,in:RoundedRectangle(cornerRadius:16))}.buttonStyle(.plain)}
                Button {newMeeting=true} label:{Label("新建场次",systemImage:"plus").frame(width:150,height:100).background(Warm.lavender,in:RoundedRectangle(cornerRadius:16))}.disabled(d.project.status=="archived")
            }}
            if let tracking=d.tracking,!tracking.isEmpty {
                Text("跨场问题追踪").font(.headline)
                ForEach(tracking) {q in VStack(alignment:.leading,spacing:8) {
                    Text(q.key).font(.headline)
                    Text("出现 \(q.occurrences) 次 · \(q.status=="answered" ? "已有回答":"尚待回答")").font(.caption).foregroundStyle(Warm.purple)
                    if q.wording_variants>1 {Text("存在不同回答表述，准备时一起核对口径。").font(.caption)}
                    ProductEvidenceLinks(refs:(q.questions+q.answers).flatMap(\.evidence_refs))
                }}
            }
            ProductItems(items:d.items.filter{$0.kind != "action" && $0.kind != "question" && $0.kind != "answer"},showFAQ:true)
            ProductTasks(items:d.items.filter{$0.kind=="action"})
            if d.project.scenario=="interview" {
                WarmCard {Text("面试准备素材").font(.headline);Text("JD、简历与公司资料共用项目范围，准备包会结合上一轮原文和已确认故事。").font(.subheadline)
                    NavigationLink("上传 JD / 简历 / 资料") {ProductMaterialPage(project:d.project)}.frame(minHeight:44)
                    Button("模拟一轮面试",systemImage:"bubble.left.and.bubble.right") {Task {await store.perform {try await store.openScope(["mode":"project","project_id":id,"practice":true]);store.sendChat("请开始一轮面试练习，明确标记为模拟。只使用已有已确认资料，逐题询问并反馈，不把练习当真实经历。");ask=true}}}.frame(minHeight:44)
                }
            } else {NavigationLink("项目资料与公司调研") {ProductMaterialPage(project:d.project)}.frame(minHeight:44)}
            ProductJobList(jobs:jobs.filter{$0.object_id==id})
            Button(d.project.status=="archived" ? "恢复项目":"归档并整理资料",systemImage:"archivebox") {Task {await store.productOperation {
                _=try await store.api.raw("/v1/project-spaces/"+id+(d.project.status=="archived" ? "/restore":"/archive"),method:"POST",body:["expected_version":d.project.version])
            }}}.frame(minHeight:44).disabled(!store.remote)
            Text("归档自动整理；已有事实直接复用，新增跨场个人结论集中确认。").font(.caption).foregroundStyle(RecordingFormat.secondary)
        }.padding(22)}}.background(Warm.paper).navigationTitle(detail?.project.name ?? "项目").navigationBarTitleDisplayMode(.inline)
            .toolbar {Button("编辑",systemImage:"pencil") {edit=true}}
            .safeAreaInset(edge:.bottom) {ProductInput(scope:["mode":"project","project_id":id],ask:$ask)}
            .sheet(isPresented:$ask) {ProductAskSheet()}
            .sheet(isPresented:$newMeeting) {if let p=detail?.project {ProductCreator(project:p)}}
            .sheet(isPresented:$edit) {if let p=detail?.project {ProductProjectEditor(project:p)}}
            .task {guard store.remote else{return};while !Task.isCancelled {do {jobs=try await store.api.all("/v1/business-jobs");if jobs.contains(where:{$0.object_id==id && $0.status=="completed"}) {try await store.reloadProducts()}} catch {} ;try? await Task.sleep(for:.seconds(4))}}
    }
}
struct ProductMeetingPage:View {
    @EnvironmentObject var store:Store
    let project:ProductProject;let meeting:BusinessMeeting
    @State private var mode="before"
    @State private var ask=false
    @State private var link=false
    @State private var selectedDraft:FollowupDraft?
    @State private var jobs:[BusinessJob]=[]
    private var d:ProductDetail? {store.productDetails.first{$0.project.id==project.id}}
    private var items:[ProjectItem] {d?.items.filter{$0.meeting_id==meeting.id} ?? []}
    var body:some View {
        ScrollView {VStack(alignment:.leading,spacing:20) {
            Text(ProductDate.display(meeting.scheduled_at ?? meeting.actual_at)).font(.subheadline).foregroundStyle(RecordingFormat.secondary)
            Text(meeting.goal.isEmpty ? project.goal:meeting.goal).font(.title3).lineSpacing(5)
            Picker("场次阶段",selection:$mode) {Text("会前").tag("before");Text("现场").tag("live");Text("会后").tag("after")}.pickerStyle(.segmented)
            if mode=="before" {before}
            if mode=="live" {live}
            if mode=="after" {after}
            ProductJobList(jobs:jobs.filter{$0.object_id==meeting.id})
        }.padding(22)}.background(Warm.paper).navigationTitle(meeting.title).navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge:.bottom) {ProductInput(scope:["mode":"meeting","meeting_id":meeting.id],ask:$ask)}
            .sheet(isPresented:$ask) {ProductAskSheet()}
            .sheet(isPresented:$link) {ProductRecordingLink(meeting:meeting)}
            .sheet(item:$selectedDraft) {draft in ProductFollowup(draft:draft)}
            .task {guard store.remote else{return};while !Task.isCancelled {do {jobs=try await store.api.all("/v1/business-jobs");if jobs.contains(where:{$0.object_id==meeting.id && $0.status=="completed"}) {try await store.reloadProducts()}} catch {};try? await Task.sleep(for:.seconds(4))}}
    }
    private var before:some View {VStack(alignment:.leading,spacing:18) {
        Text(project.scenario=="interview" ? "这一轮，准备讲什么":"这一场，准备推进什么").font(.headline)
        if let pack=d?.preparations.first(where:{$0.meeting_id==meeting.id}) {ProductPreparationExports(pack:pack);ForEach(pack.sections) {s in VStack(alignment:.leading,spacing:8) {
            Text(s.title+(s.suggestion==true ? " · 建议":"")).font(.headline);Text(s.text).lineSpacing(5).textSelection(.enabled);ProductEvidenceLinks(refs:s.evidence_refs)
        }.padding(.vertical,8)}} else {Text("会聚合前场问题、承诺、真实进展和项目资料。没有证据的内容会标明为建议。").font(.subheadline).foregroundStyle(RecordingFormat.secondary)}
        if !store.remote {Text("连接后端后可整理准备包").font(.caption).foregroundStyle(RecordingFormat.secondary)}
        Button("整理会前准备包",systemImage:"doc.text") {queue("prepare")}.buttonStyle(RecordingPrimary()).disabled(!store.remote)
        Button("问 Candid",systemImage:"bubble.left") {Task {await store.perform {try await store.openScope(["mode":"meeting","meeting_id":meeting.id]);ask=true}}}.frame(minHeight:44)
    }}
    private var live:some View {VStack(alignment:.leading,spacing:18) {
        Text("录音仍在全局录音库").font(.headline)
        Text("开启后可收起录音页、查看资料和问 Candid。录后再关联到这一场；实时先显示文字，姓名在异步整理后补充。").font(.subheadline).lineSpacing(5)
        Button("开始沟通录音",systemImage:"record.circle") {store.recordingNavigation.newMeeting=true;store.recordingNavigation.showRecorder=true}.buttonStyle(RecordingPrimary())
        Button("关联已有录音",systemImage:"link") {link=true}.frame(minHeight:44).disabled(!store.remote)
        ForEach(d?.recordings.filter{$0.meeting_id==meeting.id} ?? []) {r in NavigationLink("查看关联录音") {RecordingDetail(recordID:r.session_id)}}
        if !store.remote,let o=store.occasions.first(where:{$0.id==project.id}) {NavigationLink("练习与口述复盘") {OccasionDetailView(occasion:o)}}
    }}
    private var after:some View {VStack(alignment:.leading,spacing:18) {
        HStack {Button("关联录音",systemImage:"link") {link=true};Spacer();Button("整理本场",systemImage:"sparkles") {queue("analyze")}}.frame(minHeight:44).disabled(!store.remote)
        ProductItems(items:items.filter{$0.kind != "action"},showFAQ:true)
        ProductTasks(items:items.filter{$0.kind=="action"})
        if items.isEmpty {ContentUnavailableView("等待本场资料",systemImage:"text.alignleft",description:Text("先关联精转写完成的录音，再整理共识、问题和行动。"))}
        Menu("生成客户跟进") {ForEach(["email","wechat","whatsapp"],id:\.self) {channel in Button(channel=="email" ? "邮件":channel=="wechat" ? "微信":"WhatsApp") {draft(channel:channel,internalOnly:false)}}}.frame(minHeight:44).disabled(items.isEmpty || !store.remote || meeting.is_practice==true)
        Button("生成内部纪要",systemImage:"doc.text") {draft(channel:"email",internalOnly:true)}.frame(minHeight:44).disabled(items.isEmpty || !store.remote)
        ForEach(d?.followups.filter{$0.meeting_id==meeting.id} ?? []) {f in Button {selectedDraft=f} label:{HStack {Text(f.title);Spacer();Text(f.send_status=="sent" ? "已发出":"草稿").font(.caption)}}.frame(minHeight:44)}
    }}
    private func queue(_ action:String) {Task {await store.perform {_=try await store.api.raw("/v1/meetings/"+meeting.id+"/"+action,method:"POST");jobs=try await store.api.all("/v1/business-jobs")}}}
    private func draft(channel:String,internalOnly:Bool) {Task {await store.productOperation {selectedDraft=try await store.api.call("/v1/meetings/"+meeting.id+"/followups",method:"POST",body:["channel":channel,"internal":internalOnly])}}}
}
struct ProductItems:View {
    @EnvironmentObject var store:Store
    let items:[ProjectItem];var showFAQ=false
    var body:some View {VStack(alignment:.leading,spacing:14) {
        ForEach(items) {i in VStack(alignment:.leading,spacing:8) {
            HStack {Text(ProductLabels.kind(i.kind)).font(.caption.bold()).foregroundStyle(Warm.purple);Spacer();if !i.current {Text("依据已修订").font(.caption).foregroundStyle(.red)}}
            Text(i.text).font(.body).lineSpacing(5).textSelection(.enabled)
            ProductEvidenceLinks(refs:i.evidence_refs)
            if showFAQ && ["question","answer"].contains(i.kind) {Button("存入 FAQ",systemImage:"bookmark") {Task {await store.perform {_=try await store.api.raw("/v1/project-items/"+i.id+"/faq",method:"POST");try await store.reload();store.message="已存入当前项目 FAQ"}}}.font(.caption).frame(minHeight:44).disabled(!store.remote || !i.current)}
        }.padding(.vertical,12);Divider()}
    }}
}
struct ProductTasks:View {
    @EnvironmentObject var store:Store
    let items:[ProjectItem]
    @State private var editing:ProjectItem?
    var body:some View {VStack(alignment:.leading,spacing:12) {
        if !items.isEmpty {HStack {Text("下一步与跟进").font(.headline);Spacer();Button("开启提醒",systemImage:"bell") {Task {await ProductNotifications.shared.authorize();await ProductNotifications.shared.sync(store.productDetails.flatMap(\.items))}}.font(.caption).frame(minHeight:44)}
            ForEach(items) {i in VStack(alignment:.leading,spacing:8) {
                HStack(alignment:.top) {Button {Task {await store.productOperation {_=try await store.api.raw("/v1/project-items/"+i.id,method:"PATCH",body:["status":i.status=="done" ? "open":"done","expected_version":i.version])}}} label:{Image(systemName:i.status=="done" ? "checkmark.circle.fill":"circle").font(.title2).frame(width:44,height:44)}.disabled(!store.remote || !i.current)
                    VStack(alignment:.leading,spacing:6) {Text(i.text).strikethrough(i.status=="done");Text((i.owner.isEmpty ? "负责人待定":i.owner)+" · "+ProductDate.display(i.due_at)).font(.caption).foregroundStyle(RecordingFormat.secondary)}
                    Spacer();Button {editing=i} label:{Image(systemName:"pencil").frame(width:44,height:44)}.accessibilityLabel("修改行动")}
                ProductEvidenceLinks(refs:i.evidence_refs)
                Text(i.current ? "仅按已有记录追踪；没有新记录时，请核对跟进。":"依据已修订，请核对这项行动。").font(.caption2).foregroundStyle(RecordingFormat.secondary)
            }.padding(.vertical,8)}
        }
    }.sheet(item:$editing) {i in ProductActionEditor(item:i)}}
}
struct ProductActionEditor:View {
    @EnvironmentObject var store:Store
    @Environment(\.dismiss) private var dismiss
    let item:ProjectItem
    @State private var text="";@State private var owner="";@State private var date=Date();@State private var dated=false
    var body:some View {NavigationStack {Form {TextEditor(text:$text).frame(minHeight:100);TextField("负责人",text:$owner);Toggle("有截止时间",isOn:$dated);if dated {DatePicker("截止时间",selection:$date)}}.navigationTitle("修改行动").toolbar {ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("保存"){Task {await store.productOperation {_=try await store.api.raw("/v1/project-items/"+item.id,method:"PATCH",body:["text":text,"owner":owner,"due_at":dated ? ISO8601DateFormatter().string(from:date):NSNull(),"expected_version":item.version]);dismiss()}}}.disabled(text.isEmpty || store.busy)}}.onAppear {text=item.text;owner=item.owner;if let d=ProductDate.parse(item.due_at ?? "") {date=d;dated=true}}}}
}
struct ProductEvidenceLinks:View {
    let refs:[ProductEvidence]
    var body:some View {HStack {ForEach(refs.prefix(4),id:\.source_id) {ref in
        if ref.source_id.hasPrefix("message:"),let quote=ref.quote {Text("用户原话："+quote).font(.caption).foregroundStyle(RecordingFormat.secondary).textSelection(.enabled)}
        if let sid=ref.session_id {NavigationLink {CompanionRecordingPage(id:sid,focusMS:ref.start_ms)} label:{Label("原文 "+RecordingFormat.clock((ref.start_ms ?? 0)/1000),systemImage:"quote.bubble").font(.caption).frame(minHeight:44)}}
    }} }
}
struct ProductInput:View {
    @EnvironmentObject var store:Store
    let scope:[String:Any]
    @Binding var ask:Bool
    @State private var ready=false
    @FocusState private var focused:Bool
    var body:some View {VStack(spacing:0) {
        HStack {Button("问 Candid · "+scopeLabel,systemImage:"bubble.left") {Task {await store.perform {try await store.openScope(scope);ask=true}}}.font(.caption).frame(minHeight:44);Spacer()}
        RecordingStatusBar(speech:store.speech,device:store.soundcore)
        VoiceInputStatus(voice:store.voice)
        VoiceComposer(voice:store.voice,focused:$focused,send:{store.sendChat(store.chatDraft);ask=true}).environmentObject(store)
    }.padding(.horizontal,18).padding(.vertical,8).frame(maxWidth:.infinity).fixedSize(horizontal:false,vertical:true).background(Warm.paper)
        .task(id:scopeKey+DeviceRecordingMap.identity(store.api)+String(store.remote)) {ready=false;guard store.remote else{return};do {try await store.openScope(scope);ready=true} catch {store.chatError=error.localizedDescription}}
        .disabled(store.remote && !ready)
    }
    private var scopeLabel:String {
        if scope["mode"] as? String=="personal" {return "个人"}
        if let pid=scope["project_id"] as? String {return store.products.first{$0.id==pid}?.name ?? "项目"}
        if let mid=scope["meeting_id"] as? String {return store.productDetails.flatMap(\.meetings).first{$0.id==mid}?.title ?? "本场"}
        return "全部"
    }
    private var scopeKey:String {scope.keys.sorted().map{$0+"="+String(describing:scope[$0]!)}.joined(separator:"&")}
}
struct ProductAskSheet:View {
    @Environment(\.dismiss) private var dismiss
    var body:some View {NavigationStack {ChatView(onSettings:{}).toolbar(.visible,for:.navigationBar).toolbar {ToolbarItem(placement:.topBarLeading){Button("返回"){dismiss()}}}}}
}
struct ProductCreator:View {
    @EnvironmentObject var store:Store
    @Environment(\.dismiss) private var dismiss
    var project:ProductProject?=nil
    @State private var text="";@State private var name="";@State private var scenario="sales";@State private var natural=true
    @State private var dated=false;@State private var date=Date();@State private var request=UUID().uuidString
    var body:some View {NavigationStack {Form {
        Text(project==nil ? "说一句要见谁、谈什么，剩下的在沟通中补齐。":"安排这个项目的下一场沟通。没有录音也能先准备。").font(.subheadline)
        if project==nil {Picker("场景",selection:$scenario) {Text("销售 BD").tag("sales");Text("面试").tag("interview")}}
        Toggle("用一句话安排",isOn:$natural)
        if natural {TextEditor(text:$text).frame(minHeight:140).accessibilityLabel("项目或场次描述")}
        else {TextField(project==nil ? "项目名称":"场次名称",text:$name);TextField("目标（选填）",text:$text);if project != nil {Toggle("有计划时间",isOn:$dated);if dated {DatePicker("计划时间",selection:$date)}}}
        if !store.remote {Text("示例模式不创建真实项目，请在设置连接后端。").font(.caption)}
    }.navigationTitle(project==nil ? "新项目":"安排一场").toolbar {
        ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}}
        ToolbarItem(placement:.confirmationAction){Button("创建"){Task {await create()}}.disabled(store.busy || !store.remote || (natural ? text.isEmpty:name.isEmpty))}
    }}}
    private func create() async {await store.productOperation {
        if natural {var body:[String:Any]=["text":text,"client_request_id":request,"scenario":project?.scenario ?? scenario,"timezone":"Asia/Hong_Kong"];if let p=project {body["project_id"]=p.id};let _:NaturalProductResult=try await store.api.call("/v1/projects/natural/create",method:"POST",body:body)}
        else if let p=project {let _:BusinessMeeting=try await store.api.call("/v1/projects/"+p.id+"/meetings",method:"POST",body:["title":name,"goal":text,"scheduled_at":dated ? ISO8601DateFormatter().string(from:date):NSNull(),"timezone":"Asia/Hong_Kong","client_request_id":request])}
        else {let _:ProductProject=try await store.api.call("/v1/projects",method:"POST",body:["name":name,"goal":text,"scenario":scenario,"client_request_id":request])}
        dismiss()
    }}
}
struct ProductProjectEditor:View {
    @EnvironmentObject var store:Store;@Environment(\.dismiss) private var dismiss
    let project:ProductProject
    @State private var name="";@State private var goal="";@State private var scenario="sales";@State private var stage="demand";@State private var people="";@State private var organization="";@State private var opportunity="";@State private var result=""
    var body:some View {NavigationStack {Form {TextField("项目名称",text:$name);TextField("公司",text:$organization);TextField("岗位 / 机会",text:$opportunity);TextField("目标",text:$goal);Picker("场景",selection:$scenario){Text("销售 BD").tag("sales");Text("面试").tag("interview")}.onChange(of:scenario){_,v in stage=v=="sales" ? "demand":"preparing"};Picker("阶段",selection:$stage){ForEach(scenario=="sales" ? ProductLabels.sales:ProductLabels.interview,id:\.self){Text(ProductLabels.stage($0)).tag($0)}};TextField("结果（用户更新）",text:$result);Text("参与方：每行 姓名,角色,我方/对方").font(.caption);TextEditor(text:$people).frame(minHeight:120)}.navigationTitle("项目资料").toolbar {ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("保存"){Task {await store.productOperation {
        let participants=people.split(separator:"\n").map{line->[String:String] in let parts=line.split(separator:",",omittingEmptySubsequences:false).map(String.init);return ["name":parts[0],"role":parts.count>1 ? parts[1]:"","side":parts.count>2 && parts[2]=="我方" ? "self":"other"]}
        _=try await store.api.raw("/v1/projects/"+project.id,method:"PATCH",body:["name":name,"goal":goal,"organization":organization,"opportunity":opportunity,"scenario":scenario,"stage":stage,"result":result,"participants":participants,"expected_version":project.version]);dismiss()
    }}}.disabled(name.isEmpty || !store.remote || store.busy)}}.onAppear {name=project.name;goal=project.goal;organization=project.organization ?? "";opportunity=project.opportunity ?? "";scenario=project.scenario ?? "sales";stage=project.stage ?? (scenario=="sales" ? "demand":"preparing");result=project.result ?? "";people=(project.participants ?? []).map{$0.name+","+$0.role+","+($0.side=="self" ? "我方":"对方")}.joined(separator:"\n")}}}
}
struct ProductRecordingLink:View {
    @EnvironmentObject var store:Store;@Environment(\.dismiss) private var dismiss
    let meeting:BusinessMeeting
    @State private var records:[RecordingRecord]=[]
    var body:some View {NavigationStack {List {Text("关联不会移动录音，也不影响它在其他项目中的引用。").font(.caption);ForEach(records){r in Button {Task {await store.productOperation {_=try await store.api.raw("/v1/meetings/"+meeting.id+"/recordings",method:"POST",body:["session_id":r.id]);dismiss()}}} label:{VStack(alignment:.leading){Text(RecordingFormat.title(r));Text(RecordingFormat.status(r)).font(.caption)}}}}.navigationTitle("关联全局录音").toolbar {Button("取消"){dismiss()}}.task {await store.perform {records=try await store.api.all("/v1/recordings")}}}}
}
struct ProductMaterialPage:View {
    @EnvironmentObject var store:Store
    let project:ProductProject
    @State private var title="";@State private var text="";@State private var upload=false;@State private var ask=false;@State private var materials:[WorkspaceMaterial]=[]
    var body:some View {ScrollView {VStack(alignment:.leading,spacing:18) {
        Text("这些资料只进入当前项目范围。").font(.subheadline)
        TextField("资料名称，如 JD / 简历",text:$title).textFieldStyle(.roundedBorder)
        TextEditor(text:$text).frame(minHeight:150).accessibilityLabel("资料正文")
        HStack {Button("保存文字"){Task {await store.perform {_=try await store.api.raw("/v1/materials",method:"POST",body:["workspace_id":project.id,"title":title.isEmpty ? "项目资料":title,"text":text]);text="";try await reload()}}}.disabled(text.isEmpty || !store.remote);Spacer();Button("导入 PDF",systemImage:"doc"){upload=true}.disabled(!store.remote)}.frame(minHeight:44)
        Button("调研这家公司",systemImage:"magnifyingglass"){Task {await store.perform {try await store.openScope(["mode":"project","project_id":project.id]);store.sendChat("请联网调研这个项目中的公司："+(project.organization?.isEmpty==false ? project.organization!:project.name)+"。使用公司调研 Skill 和 Monid，列明来源和资料缺口。");ask=true}}}.frame(minHeight:44).disabled(!store.remote)
        ForEach(materials.filter(\.linked)){m in VStack(alignment:.leading,spacing:7){Text(m.title).font(.headline);Text(m.text_preview).lineLimit(5).font(.subheadline)}}
    }.padding(22)}.background(Warm.paper).navigationTitle("项目资料").navigationBarTitleDisplayMode(.inline)
        .task {try? await reload()}.sheet(isPresented:$ask){ProductAskSheet()}
        .fileImporter(isPresented:$upload,allowedContentTypes:[.pdf]) {result in
            switch result {
            case .success(let url):Task {await store.perform {_=try await store.api.uploadPDF(url,workspaceID:project.id,title:url.deletingPathExtension().lastPathComponent);try await reload()}}
            case .failure(let error):if !ImportedDocumentFiles.isCancellation(error) {store.error=error.localizedDescription}
            }
        }
    }
    private func reload() async throws {guard store.remote else{return};materials=try await store.api.all("/v1/project-spaces/"+project.id+"/materials")}
}
struct ProductMemory:View {
    @EnvironmentObject var store:Store
    @State private var tab="me";@State private var ask=false;@State private var selected:Set<String>=[];@State private var progress:PersonalProgress?
    @State private var edit:PersonalDiscovery?
    var body:some View {ScrollView {VStack(alignment:.leading,spacing:20) {
        Picker("记忆内容",selection:$tab){Text("我").tag("me");Text("素材").tag("materials");Text("跨场发现").tag("discoveries")}.pickerStyle(.segmented)
        if tab=="me" {NavigationLink("我的介绍与资料") {PersonalProfilePage()}.frame(minHeight:44);Text("属于你的资料，逐渐积累").font(.title3.bold());if let p=progress {Text("\(p.sample_count) 场真实沟通样本").font(.headline);ProductCoverageRadar(metrics:p.metrics);ForEach(p.metrics,id:\.name){metric in Text(metric.name+"：\(metric.count) / \(metric.total)");ProductEvidenceLinks(refs:metric.evidence_refs)};Text(p.note).font(.caption).foregroundStyle(RecordingFormat.secondary)} else {Text("暂无可核对的真实场次统计。").font(.subheadline)}
            ForEach(store.personalDiscoveries.filter{$0.status=="confirmed"}){d in discoveryRow(d)}
            NavigationLink("查看已确认素材与自我介绍版本") {MemoryView()}
            NavigationLink("历史归档个人记忆") {PersonalMemories()}
        }
        if tab=="materials" {NavigationLink("带入的资料与个人介绍") {PersonalProfilePage()}.frame(minHeight:44);NavigationLink("自我介绍、故事与 FAQ") {MemoryView()}.frame(minHeight:44);ForEach(store.assets.filter{$0.status=="confirmed"}){a in NavigationLink {AssetDetailView(asset:a)} label:{VStack(alignment:.leading,spacing:7){Text(a.title).font(.headline);Text(a.body.text).lineLimit(3)}}.buttonStyle(.plain)}}
        if tab=="discoveries" {
            Text("跨场综合的新结论集中核对一次；已有事实复用不再问。").font(.subheadline)
            if store.personalDiscoveries.isEmpty {ContentUnavailableView("发现会在资料积累后出现",systemImage:"sparkles",description:Text("归档项目会自动整理，也可在下方整理当前项目。"))}
            ForEach(store.personalDiscoveries.filter{$0.status != "withdrawn"}){d in HStack(alignment:.top){if d.status=="pending" {Button {if selected.contains(d.id){selected.remove(d.id)}else{selected.insert(d.id)}} label:{Image(systemName:selected.contains(d.id) ? "checkmark.circle.fill":"circle").font(.title2).frame(width:44,height:44)}.disabled(d.reference_status=="superseded")};discoveryRow(d);Button{edit=d}label:{Image(systemName:"pencil").frame(width:44,height:44)}}}
            Button("确认选中的发现（\(selected.count)）") {decision("confirmed")}.buttonStyle(RecordingPrimary()).disabled(selected.isEmpty || store.busy)
            Button("选中的内容不准确") {decision("withdrawn")}.frame(minHeight:44).disabled(selected.isEmpty)
            Menu("整理项目中的个人发现") {
                ForEach(store.products.filter{$0.is_example != true}) {p in
                    Button(p.name) {
                        Task {await store.perform {_=try await store.api.raw("/v1/projects/"+p.id+"/discoveries",method:"POST")}}
                    }
                }
            }.frame(minHeight:44).disabled(!store.remote)
        }
    }.padding(22)}.background(Warm.paper).navigationTitle("记忆库")
        .safeAreaInset(edge:.bottom){ProductInput(scope:["mode":"personal"],ask:$ask)}.sheet(isPresented:$ask){ProductAskSheet()}
        .sheet(item:$edit){d in ProductDiscoveryEditor(discovery:d)}
        .task {guard store.remote else{return};while !Task.isCancelled {do {try await store.reloadProducts();progress=try await store.api.call("/v1/personal-progress")} catch {};try? await Task.sleep(for:.seconds(5))}}
    }
    private func discoveryRow(_ d:PersonalDiscovery)->some View {VStack(alignment:.leading,spacing:8){Text(d.title).font(.headline);Text(d.text).lineSpacing(5);Text(d.reference_status=="superseded" ? "依据已修订":d.status=="confirmed" ? "已确认":"AI 发现 · 待核对").font(.caption).foregroundStyle(Warm.purple);ProductEvidenceLinks(refs:d.evidence_refs)}}
    private func decision(_ status:String){Task {await store.productOperation {let rows=store.personalDiscoveries.filter{selected.contains($0.id)}.map{["id":$0.id,"expected_version":$0.version,"status":status] as [String:Any]};_=try await store.api.raw("/v1/discoveries/decisions",method:"POST",body:["items":rows]);selected=[]}}}
}
struct ProductDiscoveryEditor:View {
    @EnvironmentObject var store:Store;@Environment(\.dismiss) private var dismiss
    let discovery:PersonalDiscovery;@State private var text=""
    var body:some View {NavigationStack {Form {TextEditor(text:$text).frame(minHeight:180);Button("撤回 / 不准确",role:.destructive){save("withdrawn")}}.navigationTitle("修改个人发现").toolbar{Button("保存并确认"){save("confirmed")}.disabled(text.isEmpty || store.busy)}.onAppear{text=discovery.text}}}
    private func save(_ status:String){Task {await store.productOperation {_=try await store.api.raw("/v1/discoveries/decisions",method:"POST",body:["items":[["id":discovery.id,"text":text,"expected_version":discovery.version,"status":status]]]);dismiss()}}}
}
struct ProductJobList:View {
    @EnvironmentObject var store:Store
    let jobs:[BusinessJob]
    var body:some View {ForEach(jobs.filter{$0.status != "completed"}) {job in VStack(alignment:.leading,spacing:8) {Text(job.progress ?? "等待整理").font(.subheadline);if let error=job.error {Text(error).font(.caption)};if ["interrupted","failed","cancelled"].contains(job.status){Button("继续处理"){Task {await store.perform {_=try await store.api.raw("/v1/business-jobs/"+job.id+"/retry",method:"POST")}}}.frame(minHeight:44)};if ["running","queued"].contains(job.status){Button("停止等待"){Task {await store.perform {_=try await store.api.raw("/v1/business-jobs/"+job.id+"/cancel",method:"POST")}}}.frame(minHeight:44)}}}}
}

struct ProductRecordingInput:View {
    @State private var ask=false
    var body:some View {ProductInput(scope:["mode":"all"],ask:$ask).sheet(isPresented:$ask){ProductAskSheet()}}
}

struct ProductScopeChooser:View {
    @EnvironmentObject var store:Store
    @Environment(\.dismiss) private var dismiss
    var body:some View {NavigationStack {List {
        Button("个人资料") {select(["mode":"personal"])}
        Button("全部项目") {select(["mode":"all"])}
        Button("销售 BD") {select(["mode":"scenario","scenario":"sales"])}
        Button("面试") {select(["mode":"scenario","scenario":"interview"])}
        ForEach(store.products) {p in Section(p.name) {
            Button("整个项目") {select(["mode":"project","project_id":p.id])}
            ForEach(store.productDetails.first(where:{$0.project.id==p.id})?.meetings ?? []) {m in Button(m.title) {select(["mode":"meeting","meeting_id":m.id])}}
        }}
    }.navigationTitle("问答范围").toolbar {Button("关闭"){dismiss()}}}}
    private func select(_ scope:[String:Any]) {Task {await store.perform {try await store.openScope(scope);dismiss()}}}
}

struct ProductCoverageRadar:View {
    let metrics:[ProgressMetric]
    private func point(_ index:Int,_ ratio:Double,_ size:CGSize)->CGPoint {
        let angle=Double(index)*2*Double.pi/Double(max(metrics.count,1))-Double.pi/2
        let radius=min(size.width,size.height)*0.3*ratio
        return CGPoint(x:size.width/2+CGFloat(cos(angle)*radius),y:size.height/2+CGFloat(sin(angle)*radius))
    }
    var body:some View {
        if metrics.count>=3 && metrics.allSatisfy({$0.total>0}) {
            Canvas {context,size in
                for ring in [0.5,1.0] {var path=Path();for i in metrics.indices {let p=point(i,ring,size);if i==0 {path.move(to:p)} else {path.addLine(to:p)}};path.closeSubpath();context.stroke(path,with:.color(Warm.purple.opacity(0.25)),lineWidth:1)}
                var area=Path();for i in metrics.indices {let p=point(i,Double(metrics[i].count)/Double(metrics[i].total),size);if i==0 {area.move(to:p)}else{area.addLine(to:p)}};area.closeSubpath();context.fill(area,with:.color(Warm.purple.opacity(0.2)));context.stroke(area,with:.color(Warm.purple),lineWidth:2)
                for i in metrics.indices {context.draw(Text(metrics[i].name).font(.caption).foregroundColor(Warm.ink),at:point(i,1.4,size))}
            }.frame(height:220).accessibilityLabel("文本资料覆盖比例").accessibilityValue(metrics.map{$0.name+" \($0.count) / \($0.total)"}.joined(separator:"，"))
        } else {Text("覆盖图暂无足够依据，先查看已有记录。").font(.caption).foregroundStyle(RecordingFormat.secondary)}
    }
}
