import SwiftUI
import UniformTypeIdentifiers
import Vision
import PDFKit
import CryptoKit
import QuickLook
import Charts

struct LibraryPage:Decodable,Identifiable {var page:Int;var text:String;var source:String?;var review_required:Bool?;var id:Int {page}}
struct LibraryVersion:Decodable,Identifiable {var id:String;var text:String;var answer_version:Int;var reason:String?}
struct LibraryUse:Decodable,Identifiable {var id:String;var session_id:String?;var answer_version:Int;var text:String?;var outcome:String?;var reason:String?}
struct LibraryTurn:Decodable {var question:String;var answer:String;var feedback:String;var suggested_text:String?}
struct LibraryPractice:Decodable,Identifiable {var id:String;var question:String;var status:String;var turns:[LibraryTurn];var job_id:String?}
struct LibraryReference:Decodable {var source_id:String;var source_version:String?;var session_id:String?;var start_ms:Int?;var title:String?;var original_id:String?}
struct LibraryItem:Decodable,Identifiable {
  var id:String;var title:String;var text:String;var topic:String;var scenario:String;var item_type:String
  var version:Int;var expression_state:String;var evidence_state:String;var effect_state:String
  var evidence_refs:[LibraryReference];var uses:[LibraryUse];var history:[LibraryVersion];var practices:[LibraryPractice]
  var topics:[String];var remind:Bool?;var valid_until:String?;var suggested_text:String?;var synced_at:String?;var user_edited:Bool?
  var label:String {if evidence_state == "expired" {return "已过期"};if evidence_state == "changed" {return "依据有变化"};if expression_state == "improve" {return "待改进"};if effect_state == "positive" {return "有正向记录"};return "尚未实战"}
}
struct LibraryDocument:Decodable,Identifiable {
  var id:String;var title:String;var status:String;var error:String?;var job_id:String?;var family_id:String
  var version:Int;var versions:[String];var sha256:String;var pages:[LibraryPage];var text:String;var parsed_id:String?;var changes:[String];var pending_id:String?
}
struct LibrarySessionMetric:Decodable,Identifiable {var id:String;var title:String;var date:String;var scenario:String;var self_ms:Double;var total_ms:Double;var pace:Double;var share:Double;var filler_rate:Double;var coverage:Double}
struct LibraryAggregate:Decodable {var count:Int;var self_ms:Double;var pace:Double?;var share:Double?;var filler_rate:Double?;var from:String?;var to:String?}
struct LibraryMetrics:Decodable {var sessions:[LibrarySessionMetric];var recent:LibraryAggregate;var baseline:LibraryAggregate?;var note:String}
struct LibraryUpdate:Decodable,Identifiable {var id:String;var status:String;var message:String}
struct LibrarySnapshot:Decodable {var items:[LibraryItem];var documents:[LibraryDocument];var metrics:LibraryMetrics;var updates:[LibraryUpdate]}

struct CompanionMemory:View {
  @EnvironmentObject var store:Store
  @State private var tab="我"
  @State private var snapshot:LibrarySnapshot?
  @State private var error:String?
  @State private var importing=false
  var body:some View {
    VStack(spacing:0) {
      CompanionPageHeader(title:"记忆库") {Button {importing=true} label:{Image(systemName:"plus").frame(width:44,height:44)}.accessibilityLabel("上传背景资料")}
      CompanionTabs(values:["我","FAQ","背景资料"],selection:$tab).padding(.horizontal,18).padding(.vertical,12).accessibilityIdentifier("memoryLibraryTabs")
      ScrollView {
        VStack(alignment:.leading,spacing:18) {
          if let error {Text(error).companionFont(13).foregroundStyle(.red);Button("重新读取") {Task {await load()}}}
          if let s=snapshot {
            if tab == "我" {me(s)}
            else if tab == "FAQ" {LibraryFAQList(items:s.items)}
            else {LibraryDocuments(documents:s.documents,items:s.items,onChange:{Task {await load()}})}
          } else if error == nil {ProgressView("正在读取你的积累")}
          if let issue=store.personalImportError {Text(issue).companionFont(13).foregroundStyle(.red)}
        }.frame(maxWidth:.infinity,alignment:.leading).padding(18).frame(maxWidth:700).frame(maxWidth:.infinity)
      }.refreshable {await load()}
    }.background(Warm.paper).toolbar(.hidden,for:.navigationBar)
      .fileImporter(isPresented:$importing,allowedContentTypes:[.pdf,.image,.plainText,UTType(filenameExtension:"docx") ?? .data,UTType(filenameExtension:"pptx") ?? .data,UTType(filenameExtension:"md") ?? .plainText],allowsMultipleSelection:true) {result in
        switch result {case .success(let urls):Task {await store.addOnboardingFiles(urls);await load()};case .failure(let e):if !ImportedDocumentFiles.isCancellation(e) {error=e.localizedDescription}}
      }
      .task {while !Task.isCancelled {await load();do {try await Task.sleep(for:.seconds(5))} catch {break}}}
  }
  private func load() async {
    guard store.remote else {error="连接 Candid 后查看记忆库，已有本机资料仍保留。";return}
    do {let connection=store.api;let value:LibrarySnapshot=try await connection.call("/v1/library");guard DeviceRecordingMap.identity(connection)==DeviceRecordingMap.identity(store.api) else{return};snapshot=value;error=nil;await store.restorePersonalProfile()}
    catch {if !Task.isCancelled {self.error=error.localizedDescription}}
  }
  @ViewBuilder private func me(_ s:LibrarySnapshot)->some View {
    Text("你的沟通，慢慢看得见变化。").companionFont(17,weight:.semibold)
    NavigationLink {LibraryMetricsPage(metrics:s.metrics)} label: {
      CompanionPanel {
        HStack {Text("表达与趋势").companionFont(17,weight:.semibold);Spacer();Image(systemName:"chevron.right")}
        if s.metrics.sessions.isEmpty {Text("有录音并认领本人后，这里会出现真实的表达数据。").companionFont(13)}
        else {Text("来自 \(s.metrics.sessions.count) 场有录音的沟通").companionFont(12).foregroundStyle(RecordingFormat.secondary);LibraryMetricValues(value:s.metrics.recent)}
      }
    }.buttonStyle(.plain)
    if let d=store.companionMemory?.discoveries.first {
      NavigationLink {CompanionDiscoveryPage(discovery:d)} label: {
        CompanionPanel(color:Warm.lavender) {Text("跨场发现").companionFont(12).foregroundStyle(Warm.purple);Text(d.title).companionFont(17,weight:.semibold);Text(d.text).companionFont(13).lineLimit(3);Text(d.status == "confirmed" ? "查看依据 →":"看看依据，集中确认 →").companionFont(12)}
      }.buttonStyle(.plain)
    }
    NavigationLink {CompanionDiscoveryList()} label:{Text("全部跨场发现与集中确认").frame(maxWidth:.infinity,minHeight:44,alignment:.leading).contentShape(Rectangle())}.buttonStyle(.plain)
    NavigationLink {PersonalProfilePage()} label:{Text("个人介绍与资料").frame(maxWidth:.infinity,minHeight:44,alignment:.leading).contentShape(Rectangle())}.buttonStyle(.plain)
    let materials=s.items.filter {$0.item_type == "material"}
    if !materials.isEmpty {Text("故事与表达素材").companionFont(17,weight:.semibold);ForEach(materials) {item in NavigationLink {LibraryFAQDetail(item:item)} label:{LibraryItemRow(item:item)}.buttonStyle(.plain)}}
    ForEach(s.updates.filter {["failed","interrupted"].contains($0.status)}) {u in
      VStack(alignment:.leading,spacing:6) {Text(u.message).companionFont(12).foregroundStyle(RecordingFormat.secondary);Button("继续整理") {Task {do {_ = try await store.api.raw("/v1/business-jobs/"+u.id+"/retry",method:"POST");await load()} catch {self.error=error.localizedDescription}}}.frame(minHeight:44)}
    }
  }
}
struct LibraryMetricValues:View {
  let value:LibraryAggregate
  var body:some View {VStack(alignment:.leading,spacing:8) {
    metric("转写语速估计",value.pace,"字词/分钟")
    metric("说话占比",value.share,"%")
    metric("转写中口头禅",value.filler_rate,"次/分钟")
  }}
  private func metric(_ title:String,_ value:Double?,_ unit:String)->some View {HStack {Text(title);Spacer();Text(value.map {String(format:"%.1f",$0)+" "+unit} ?? "暂无数据").monospacedDigit()}.companionFont(14)}
}
struct LibraryMetricsPage:View {
  let metrics:LibraryMetrics
  @State private var axis="语速"
  @State private var scenario="sales"
  private var visible:LibraryMetrics {
    let rows=metrics.sessions.filter {$0.scenario==scenario}
    func aggregate(_ group:[LibrarySessionMetric])->LibraryAggregate {
      let ms=group.reduce(0) {$0+$1.self_ms},total=group.reduce(0) {$0+$1.total_ms}
      return LibraryAggregate(count:group.count,self_ms:ms,pace:ms>0 ? group.reduce(0) {$0+$1.pace*$1.self_ms}/ms:nil,share:total>0 ? ms*100/total:nil,filler_rate:ms>0 ? group.reduce(0) {$0+$1.filler_rate*$1.self_ms}/ms:nil,from:group.first?.date,to:group.last?.date)
    }
    return LibraryMetrics(sessions:rows,recent:aggregate(Array(rows.suffix(3))),baseline:rows.count>=6 ? aggregate(Array(rows.prefix(3))):nil,note:metrics.note)
  }
  var body:some View {ScrollView {VStack(alignment:.leading,spacing:20) {
    Text("表达与趋势").companionFont(25,weight:.bold)
    Picker("沟通场景",selection:$scenario) {Text("销售 BD").tag("sales");Text("面试").tag("interview")}.pickerStyle(.segmented)
    if visible.sessions.isEmpty {Text("先完成一场录音并认领本人。无需凑满多场，就能查看单场数据。")}
    else {
      Text(visible.sessions.count>=3 ? "最近三场":"近期 \(visible.sessions.count) 场").companionFont(17,weight:.semibold)
      CompanionPanel {LibraryMetricValues(value:visible.recent);Text("本人有效句段 \(Int(visible.recent.self_ms/60000)) 分钟").companionFont(12)}
      if let baseline=visible.baseline {Text("最早三场 · 起点").companionFont(17,weight:.semibold);CompanionPanel {LibraryMetricValues(value:baseline);Text("\(ProductDate.display(baseline.from)) — \(ProductDate.display(baseline.to))").companionFont(12)}}
      else {Text(visible.sessions.count<3 ? "满三场后查看近期趋势，满六场后与起点对比。":"再积累 \(max(0,6-visible.sessions.count)) 场，即可与最早三场对比。").companionFont(13).foregroundStyle(RecordingFormat.secondary)}
      if visible.sessions.count>=3 {
        Picker("趋势指标",selection:$axis) {Text("语速").tag("语速");Text("说话占比").tag("占比");Text("口头禅").tag("口头禅")}.pickerStyle(.segmented)
        Chart(Array(visible.sessions.enumerated()),id:\.element.id) {index,r in
          LineMark(x:.value("场次",index+1),y:.value(axis,axis == "语速" ? r.pace:axis == "占比" ? r.share:r.filler_rate)).foregroundStyle(Warm.purple)
          PointMark(x:.value("场次",index+1),y:.value(axis,axis == "语速" ? r.pace:axis == "占比" ? r.share:r.filler_rate)).foregroundStyle(Warm.purple)
        }.frame(height:170).accessibilityLabel("真实沟通的"+axis+"趋势，逐场数值见下方记录")
      }
      Text("逐场记录").companionFont(17,weight:.semibold)
      ForEach(visible.sessions.reversed()) {r in
        NavigationLink {CompanionRecordingPage(id:r.id)} label: {VStack(alignment:.leading,spacing:8) {Text(ProductDate.display(r.date)).companionFont(14,weight:.semibold);Text("语速 \(r.pace,specifier:"%.1f") · 占比 \(r.share,specifier:"%.1f")% · 口头禅 \(r.filler_rate,specifier:"%.1f")/分钟").companionFont(12);Text("说话人认领覆盖 \(r.coverage,specifier:"%.0f")% · 查看原文 →").companionFont(12).foregroundStyle(Warm.purple);Divider()}.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())}.buttonStyle(.plain)
      }
    }
    Text(visible.note).companionFont(12).foregroundStyle(RecordingFormat.secondary)
    Text("变化用于了解自己，不代表成交、录用或表达能力评分。").companionFont(12).foregroundStyle(RecordingFormat.secondary)
  }.frame(maxWidth:.infinity,alignment:.leading).padding(18).frame(maxWidth:700).frame(maxWidth:.infinity)}.companionReport("表达与趋势")}
}
struct LibraryItemRow:View {
  let item:LibraryItem
  var body:some View {VStack(alignment:.leading,spacing:7) {HStack(alignment:.top) {Text(item.title).companionFont(15,weight:.semibold);Spacer();Image(systemName:"chevron.right").font(.caption)};Text(item.topic+" · "+item.label).companionFont(12).foregroundStyle(RecordingFormat.secondary);Divider()}.padding(.vertical,6).frame(maxWidth:.infinity,minHeight:60).contentShape(Rectangle())}
}
struct LibraryFAQList:View {
  let items:[LibraryItem]
  @State private var query=""
  @State private var expanded=false
  @State private var byTopic=true
  @State private var selectedTopic="全部"
  var rows:[LibraryItem] {items.filter {$0.item_type == "faq" && (query.isEmpty || ($0.title+$0.text+$0.topic).localizedCaseInsensitiveContains(query))}}
  var body:some View {
    VStack(alignment:.leading,spacing:18) {
      Text("常被问到的，留下更好的回答。").companionFont(17,weight:.semibold)
      TextField("搜问题、主题或说法",text:$query).textFieldStyle(.roundedBorder).accessibilityIdentifier("libraryFAQSearch")
      let bad=rows.filter {$0.expression_state == "improve"}
      if !bad.isEmpty {CompanionPanel(color:Warm.orange.opacity(0.25)) {
        HStack {Text("这些问题，下次可以答得更好").companionFont(17,weight:.semibold);Spacer();Text("\(bad.count)")}
        ForEach(expanded ? bad:Array(bad.prefix(2))) {row in link(row)}
        if bad.count>2 {Button(expanded ? "收起":"展开全部 \(bad.count) 个") {expanded.toggle()}.frame(minHeight:44)}
      }}
      HStack {Text("值得复用的回答").companionFont(17,weight:.semibold);Spacer();Menu(byTopic ? "按主题":"按问题") {Button("按主题") {byTopic=true};Button("按问题") {byTopic=false}}}
      let good=rows.filter {$0.expression_state != "improve"}
      if byTopic && query.isEmpty {
        ForEach(Array(Set(good.map(\.topic))).sorted(),id:\.self) {topic in
          NavigationLink {ScrollView {VStack(alignment:.leading,spacing:16) {ForEach(good.filter {$0.topic==topic}) {link($0)}}.padding(18)}.companionReport(topic)} label: {HStack {Image(systemName:"text.bubble").foregroundStyle(Warm.purple);Text(topic);Spacer();Text("\(good.filter {$0.topic==topic}.count)");Image(systemName:"chevron.right")}.frame(maxWidth:.infinity,minHeight:52).contentShape(Rectangle())}.buttonStyle(.plain)
        }
      } else {ForEach(good) {link($0)}}
      if rows.isEmpty {Text(query.isEmpty ? "录音与复盘中的问题会自动整理到这里。故事和个人表达保留在“我”页。":"没有找到，换个关键词试试。").companionFont(14).foregroundStyle(RecordingFormat.secondary)}
    }
  }
  private func link(_ row:LibraryItem)->some View {NavigationLink {LibraryFAQDetail(item:row)} label:{LibraryItemRow(item:row)}.buttonStyle(.plain)}
}
struct LibraryFAQDetail:View {
  @EnvironmentObject var store:Store
  @State var item:LibraryItem
  @State private var editing=false
  @State private var draft=""
  @State private var expiry=Date()
  @State private var hasExpiry=false
  @State private var error:String?
  @State private var busy=false
  @State private var documents:[LibraryDocument]=[]
  @State private var linking=false
  var body:some View {ScrollView {VStack(alignment:.leading,spacing:20) {
    Text(item.title).companionFont(25,weight:.bold)
    HStack {Text(item.label).foregroundStyle(Warm.purple);Spacer();Menu(item.topic) {ForEach(item.topics,id:\.self) {topic in Button(topic) {Task {await update(["topic":topic])}}}}}.companionFont(12)
    CompanionPanel(color:Warm.lavender) {
      HStack {Text("现在的说法").companionFont(17,weight:.semibold);Spacer();Button("更新") {draft=item.text;hasExpiry = !(item.valid_until ?? "").isEmpty;expiry=ProductDate.parse(item.valid_until ?? "") ?? Date();editing=true}}
      Text(item.text).companionFont(15).textSelection(.enabled)
      Text(item.user_edited == true ? "你的说法 · v\(item.version)":"Candid 整理 · v\(item.version)").companionFont(12)
      if let date=item.valid_until,!date.isEmpty {Text("适用至 "+ProductDate.display(date)).companionFont(12)}
    }
    if let suggestion=item.suggested_text {CompanionPanel {Text("新资料带来的修改建议").companionFont(15,weight:.semibold);Text(suggestion).companionFont(14);Button("采用并编辑") {draft=suggestion;editing=true}}}
    if item.evidence_state != "ready" {Text(item.evidence_state == "missing" ? "事实依据尚未补齐，修改说法不会自动消除这个缺口。":"部分依据已变化或过期；说法和历史仍保留。").companionFont(13).foregroundStyle(RecordingFormat.secondary)}
    NavigationLink {LibraryMockPage(item:item)} label:{Label("用 Mock 练一练",systemImage:"bubble.left.and.bubble.right").frame(maxWidth:.infinity)}.buttonStyle(CompanionButtonStyle(primary:true))
    Toggle("会前准备时提醒我",isOn:Binding(get:{item.remind ?? true},set:{v in Task {await update(["remind":v])}})).tint(Warm.purple)
    Text("依据与原文").companionFont(17,weight:.semibold)
    ForEach(Array(item.evidence_refs.enumerated()),id:\.offset) {_,ref in
      if let sid=ref.session_id {NavigationLink("回听原文 · "+RecordingFormat.clock((ref.start_ms ?? 0)/1000)) {CompanionRecordingPage(id:sid,focusMS:ref.start_ms)}.frame(minHeight:44)}
      else if let original=ref.original_id {NavigationLink(ref.title ?? "背景资料") {LibraryLinkedDocument(id:original)}.frame(minHeight:44)}
      else {Text(ref.title ?? "资料来源").companionFont(12)}
    }
    Button("关联背景资料") {Task {do {let value:LibrarySnapshot=try await store.api.call("/v1/library");documents=value.documents;linking=true} catch {self.error=error.localizedDescription}}}.frame(minHeight:44)
    if !item.uses.isEmpty {Text("真实沟通中的记录").companionFont(17,weight:.semibold);ForEach(item.uses) {u in VStack(alignment:.leading,spacing:8) {Text(u.text ?? "");Text(u.reason ?? "").companionFont(12).foregroundStyle(RecordingFormat.secondary);Text(u.answer_version == 0 ? "来自当时原话，不代表新说法已验证":"回答版本 v\(u.answer_version)").companionFont(12);Divider()}}}
    if !item.practices.isEmpty {Text("练习记录 · 不计入实战").companionFont(17,weight:.semibold);ForEach(item.practices) {p in NavigationLink {LibraryMockPage(item:item,existing:p)} label:{Text("\(p.turns.count) 轮 · "+p.question).lineLimit(2).frame(minHeight:44)}}}
    if !item.history.isEmpty {Text("版本记录").companionFont(17,weight:.semibold);ForEach(item.history) {v in VStack(alignment:.leading,spacing:6) {Text("v\(v.answer_version) · "+(v.reason ?? "历史说法")).companionFont(12);Text(v.text).companionFont(14);Button("恢复为新版本") {Task {await update(["text":v.text])}}.frame(minHeight:44);Divider()}}}
    if let error {Text(error).foregroundStyle(.red).companionFont(13)}
  }.frame(maxWidth:.infinity,alignment:.leading).padding(18).frame(maxWidth:700).frame(maxWidth:.infinity)}.companionReport(item.item_type == "faq" ? "FAQ":"表达素材")
    .task {await refresh()}
    .sheet(isPresented:$editing) {NavigationStack {Form {TextEditor(text:$draft).frame(minHeight:180);Toggle("设置适用期限",isOn:$hasExpiry);if hasExpiry {DatePicker("适用至",selection:$expiry,displayedComponents:.date)};Button("保存说法") {Task {await update(["text":draft,"valid_until":hasExpiry ? ISO8601DateFormatter().string(from:expiry):""]);if error==nil {editing=false}}}.disabled(busy || draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty);if let error {Text(error).foregroundStyle(.red)}}.navigationTitle("更新说法").toolbar {Button("取消") {editing=false}}}}
    .sheet(isPresented:$linking) {NavigationStack {List(documents.filter {$0.parsed_id != nil}) {d in Button(d.title) {Task {do {item=try await store.api.call("/v1/library/items/"+item.id+"/document",method:"POST",body:["document_id":d.parsed_id!,"expected_version":item.version]);linking=false} catch {self.error=error.localizedDescription}}}}.navigationTitle("关联背景资料").toolbar {Button("关闭") {linking=false}}}}
  }
  private func refresh() async {do {item=try await store.api.call("/v1/library/items/"+item.id)} catch {self.error=error.localizedDescription}}
  private func update(_ patch:[String:Any]) async {busy=true;defer {busy=false};do {var body=patch;body["expected_version"]=item.version;item=try await store.api.call("/v1/library/items/"+item.id,method:"PATCH",body:body);error=nil} catch {self.error=error.localizedDescription}}
}
struct LibraryMockPage:View {
  @EnvironmentObject var store:Store
  @Environment(\.scenePhase) private var scenePhase
  let item:LibraryItem
  var existing:LibraryPractice?=nil
  @State private var practice:LibraryPractice?
  @State private var answer=""
  @State private var error:String?
  @State private var notice:String?
  @State private var busy=false
  @State private var requestID=UUID().uuidString
  @StateObject private var dictation=OnboardingDictation()
  var body:some View {ScrollView {VStack(alignment:.leading,spacing:20) {
    Text(item.scenario == "interview" ? "面试练习":"客户问答练习").companionFont(25,weight:.bold)
    Text("练习记录独立保存，不计入真实沟通表现。").companionFont(12).foregroundStyle(RecordingFormat.secondary)
    CompanionPanel(color:Warm.lavender) {Text(practice?.question ?? item.title).companionFont(17,weight:.semibold)}
    if let p=practice {ForEach(Array(p.turns.enumerated()),id:\.offset) {_,t in VStack(alignment:.leading,spacing:12) {Text(t.question).companionFont(13).foregroundStyle(RecordingFormat.secondary);Text("我的回答").companionFont(12);Text(t.answer).companionFont(15);Text(t.feedback).companionFont(14);if let text=t.suggested_text,!text.isEmpty {Text(text).companionFont(14).foregroundStyle(Warm.purple);Button("保存为我的新说法") {Task {await save(text)}}};Divider()}}}
    TextEditor(text:$answer).frame(minHeight:140).padding(8).background(Warm.white,in:RoundedRectangle(cornerRadius:14)).accessibilityLabel("练习回答")
    HStack {Button(dictation.active ? "说完了":"用语音回答") {Task {if dictation.active {await dictation.finish()} else {await dictation.start(store:store)}}}.frame(minHeight:44);Spacer();Button(busy ? "正在反馈…":"提交回答") {Task {await submit()}}.disabled(busy || dictation.active || answer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
    if let notice {Text(notice).foregroundStyle(Warm.purple).companionFont(13)}
    if let e=dictation.error {Text(e).foregroundStyle(.red).companionFont(12)}
    if let error {Text(error).foregroundStyle(.red).companionFont(13);Button("继续这次练习") {Task {await submit()}}.disabled(busy)}
  }.frame(maxWidth:.infinity,alignment:.leading).padding(18).frame(maxWidth:700).frame(maxWidth:.infinity)}.companionReport("Mock 练习")
    .task {practice=existing}
    .onChange(of:dictation.text) {_,value in if !value.isEmpty {answer=value}}
    .onChange(of:scenePhase) {_,v in if v != .active {dictation.cancel()}}
    .onDisappear {dictation.cancel()}
  }
  private func submit() async {
    busy=true;defer {busy=false}
    do {
      var body:[String:Any]=["client_request_id":requestID,"answer":answer]
      if let p=practice {body["practice_id"]=p.id}
      let p:LibraryPractice=try await store.api.call("/v1/library/items/"+item.id+"/practice",method:"POST",body:body);practice=p
      if let job=p.job_id {
        while !Task.isCancelled {
          let data=try await store.api.raw("/v1/business-jobs/"+job)
          let j=try JSONSerialization.jsonObject(with:data) as? [String:Any]
          if j?["status"] as? String == "completed" {practice=try await store.api.call("/v1/library/practices/"+p.id);answer="";requestID=UUID().uuidString;error=nil;return}
          if ["failed","interrupted","cancelled"].contains(j?["status"] as? String ?? "") {throw PrototypeError.message(j?["error"] as? String ?? "练习未完成，回答已保留")}
          try await Task.sleep(for:.seconds(1))
        }
      }
    } catch {self.error=error.localizedDescription}
  }
  private func save(_ text:String) async {do {let current:LibraryItem=try await store.api.call("/v1/library/items/"+item.id);_ = try await store.api.raw("/v1/library/items/"+item.id,method:"PATCH",body:["expected_version":current.version,"text":text]);notice="已保存新说法，仍待实战使用。";error=nil} catch {self.error=error.localizedDescription}}
}

struct LibraryDocuments:View {
  @EnvironmentObject var store:Store
  let documents:[LibraryDocument]
  let items:[LibraryItem]
  var onChange:()->Void
  var body:some View {VStack(alignment:.leading,spacing:18) {
    Text("回答背后的事实依据").companionFont(17,weight:.semibold)
    Text("上传资料后自动整理。价格、政策和交期使用适用的资料，缺少的部分会明确标出。").companionFont(13).foregroundStyle(RecordingFormat.secondary)
    let missing=items.filter {$0.item_type == "faq" && $0.evidence_state != "ready"}
    if !missing.isEmpty {CompanionPanel(color:Warm.orange.opacity(0.25)) {Text("仍需补齐或更新的依据").companionFont(15,weight:.semibold);ForEach(Array(missing.prefix(3))) {r in NavigationLink {LibraryFAQDetail(item:r)} label:{Text(r.title).companionFont(14).frame(minHeight:44)}.buttonStyle(.plain)}}}
    if documents.isEmpty {Text("点右上角＋上传第一份资料。支持文件、照片和扫描 PDF。").companionFont(14)}
    ForEach(documents) {d in
      NavigationLink {LibraryDocumentDetail(document:d,onChange:onChange)} label: {HStack(spacing:12) {Image(systemName:"doc.text").foregroundStyle(Warm.purple);VStack(alignment:.leading,spacing:6) {Text(d.title).companionFont(15,weight:.semibold);Text("v\(d.version) · "+(d.parsed_id != nil ? "可读取":d.error ?? "正在解析 / 等待本机识别")).companionFont(12).foregroundStyle(RecordingFormat.secondary)};Spacer();Image(systemName:"chevron.right")}.frame(maxWidth:.infinity,minHeight:64).contentShape(Rectangle())}.buttonStyle(.plain)
      Divider()
    }
  }}
}
struct LibraryDocumentDetail:View {
  @EnvironmentObject var store:Store
  @Environment(\.dismiss) private var dismiss
  @State var document:LibraryDocument
  var onChange:()->Void
  @State private var replacing=false
  @State private var busy=false
  @State private var error:String?
  @State private var preview:URL?
  var body:some View {ScrollView {VStack(alignment:.leading,spacing:18) {
    Text(document.title).companionFont(23,weight:.bold)
    Text("当前 v\(document.version)").companionFont(12).foregroundStyle(RecordingFormat.secondary)
    if !document.changes.isEmpty {CompanionPanel(color:Warm.lavender) {Text("这次更新改了什么").companionFont(15,weight:.semibold);ForEach(document.changes,id:\.self) {Text($0).companionFont(14)}}}
    if let error {Text(error).foregroundStyle(.red).companionFont(13)}
    if document.pending_id != nil {Button("继续新版资料同步") {Task {do {_ = try await store.api.raw("/v1/library/documents/"+document.id+"/retry-sync",method:"POST");await refresh()} catch {self.error=error.localizedDescription}}}.frame(minHeight:44)}
    if let message=document.error {Text(message).foregroundStyle(.red).companionFont(13)}
    Button("查看原文件") {Task {await original(document.id)}}.frame(minHeight:44)
    Button(busy ? "正在整理新版…":"上传新版本") {replacing=true}.buttonStyle(CompanionButtonStyle(primary:true)).disabled(busy)
    if document.parsed_id==nil {Button("重试整理") {Task {do {_ = try await store.api.raw("/v1/onboarding/documents/"+document.id+"/retry",method:"POST");onChange()} catch {self.error=error.localizedDescription}}}.frame(minHeight:44)}
    if document.pages.isEmpty {Text(document.text.isEmpty ? "原文件已保留，解析完成后会显示内容。":document.text).companionFont(14).textSelection(.enabled)}
    ForEach(document.pages) {p in VStack(alignment:.leading,spacing:8) {Text("第 \(p.page) 页 · "+(p.source == "vision" ? "本机文字识别":"文件文字")).companionFont(12).foregroundStyle(Warm.purple);if p.review_required==true {Text("这一页部分内容不清楚，使用数字前请核对原文件。").companionFont(12).foregroundStyle(.orange)};Text(p.text.isEmpty ? "这一页未识别出文字，其他页仍可使用。":p.text).companionFont(14).textSelection(.enabled);Divider()}}
    if document.versions.count>1 {
      Text("版本记录").companionFont(17,weight:.semibold)
      ForEach(Array(document.versions.enumerated()),id:\.element) {index,id in
        HStack {
          Button("查看 v\(index+1) 原文件") {Task {await original(id)}}
          Spacer()
          if id != document.id {Button("恢复") {Task {await restore(id)}}}
        }.frame(minHeight:44)
      }
    }
    Text("新版自动同步相关说法，保留你的改写和旧版本。").companionFont(12).foregroundStyle(RecordingFormat.secondary)
    Button("移除这份资料",role:.destructive) {Task {do {_ = try await store.api.raw("/v1/onboarding/documents/"+document.id,method:"DELETE");store.personalState.documents.removeAll {$0.serverID==document.id || $0.id==document.id};store.personalState.removedDocumentIDs.append(document.id);store.persistOnboarding();onChange();dismiss()} catch {self.error=error.localizedDescription}}}.frame(minHeight:44)
  }.frame(maxWidth:.infinity,alignment:.leading).padding(18).frame(maxWidth:700).frame(maxWidth:.infinity)}.companionReport("背景资料").quickLookPreview($preview).task {while !Task.isCancelled {await refresh();do {try await Task.sleep(for:.seconds(4))} catch {break}}}
    .fileImporter(isPresented:$replacing,allowedContentTypes:[.pdf,.image,.plainText,UTType(filenameExtension:"docx") ?? .data,UTType(filenameExtension:"pptx") ?? .data,UTType(filenameExtension:"md") ?? .plainText]) {result in
      if case .success(let url)=result {Task {await replace(url)}} else if case .failure(let e)=result,!ImportedDocumentFiles.isCancellation(e) {error=e.localizedDescription}
    }
  }
  private func refresh() async {do {let value:LibrarySnapshot=try await store.api.call("/v1/library");if let d=value.documents.first(where:{$0.family_id==document.family_id}) {document=d}} catch {self.error=error.localizedDescription}}
  private func restore(_ id:String) async {do {_ = try await store.api.raw("/v1/library/documents/"+document.id+"/restore",method:"POST",body:["new_document_id":id]);onChange();await refresh()} catch {self.error=error.localizedDescription}}
  private func original(_ id:String) async {do {let raw=try await store.api.raw("/v1/library/documents/"+id+"/file");let ext=(document.title as NSString).pathExtension;let url=FileManager.default.temporaryDirectory.appendingPathComponent(id+"."+ext);try raw.write(to:url,options:.completeFileProtection);preview=url} catch {self.error=error.localizedDescription}}
  private func replace(_ url:URL) async {busy=true;defer {busy=false};do {
    let local=try await ImportedDocumentFiles.copy(url,into:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("OnboardingFiles"),maxBytes:25_000_000)
    let receipt=try await store.api.uploadOnboarding(local,title:url.lastPathComponent)
    _ = try await store.api.raw("/v1/library/documents/"+document.id+"/replace",method:"POST",body:["new_document_id":receipt.id]);error=nil;onChange()
  } catch {self.error=error.localizedDescription}}
}

// Original bytes and page-level provenance survive upload and recognition retries.
enum NativeDocumentOCR {
  static func recognize(_ file:URL) throws -> [[String:Any]] {
    let ext=file.pathExtension.lowercased()
    if ext=="pdf" {
      guard let pdf=PDFDocument(url:file),!pdf.isLocked,pdf.pageCount<=300 else {throw PrototypeError.message("PDF 无法打开或超过 300 页，请检查文件。")}
      return try (0..<pdf.pageCount).map {index in try autoreleasepool {
        guard let page=pdf.page(at:index) else {throw PrototypeError.message("PDF 页面无法读取")}
        let native=page.string?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        let bounds=page.bounds(for:.mediaBox);let scale=min(2,1800/max(bounds.width,bounds.height))
        let image=page.thumbnail(of:CGSize(width:bounds.width*scale,height:bounds.height*scale),for:.mediaBox)
        let recognized=try recognizeImage(image)
        let useNative=native.count>=recognized.0.count && native.count>20
        return ["page":index+1,"text":useNative ? native:recognized.0,"source":useNative ? "pdf_text":"vision","review_required":useNative ? false:recognized.1] as [String:Any]
      }}
    }
    guard let image=UIImage(contentsOfFile:file.path) else {throw PrototypeError.message("图片无法打开，请换成 JPG 或 PNG。")}
    let result=try recognizeImage(image)
    return [["page":1,"text":result.0,"source":"vision","review_required":result.1]]
  }
  static func recognizeImage(_ image:UIImage) throws -> (String,Bool) {
    guard let cg=image.cgImage else {throw PrototypeError.message("图片无法识别")}
    let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.usesLanguageCorrection=true
    request.recognitionLanguages=["zh-Hans","zh-Hant","en-US"]
    let orientation:CGImagePropertyOrientation
    switch image.imageOrientation {case .left:orientation = .left;case .right:orientation = .right;case .down:orientation = .down;default:orientation = .up}
    try VNImageRequestHandler(cgImage:cg,orientation:orientation).perform([request])
    let lines=(request.results ?? []).compactMap {$0.topCandidates(1).first}
    return (lines.map(\.string).joined(separator:"\n"),lines.isEmpty || lines.contains {$0.confidence<0.65})
  }
}

struct LibraryLinkedDocument:View {
  @EnvironmentObject var store:Store
  let id:String
  @State private var doc:LibraryDocument?
  @State private var error:String?
  var body:some View {Group {if let doc {LibraryDocumentDetail(document:doc,onChange:{})} else if let error {Text(error).padding()} else {ProgressView("正在读取资料")}}.task {do {let value:LibrarySnapshot=try await store.api.call("/v1/library");doc=value.documents.first {$0.id==id};if doc==nil {error="这份依据已更新或移除，可在背景资料查看当前版本。"}} catch {self.error=error.localizedDescription}}}
}
