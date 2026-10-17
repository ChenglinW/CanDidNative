import SwiftUI
import UniformTypeIdentifiers
import Vision
import PDFKit
import CryptoKit
import QuickLook
import Charts

struct LibraryPage:Decodable,Identifiable {var page:Int;var text:String;var source:String?;var review_required:Bool?;var id:Int {page}}
struct LibraryVersion:Decodable,Identifiable {
  var id:String;var text:String;var answer_version:Int;var reason:String?;var period:String?;var valid_until:String?
  // An omitted field means “keep current” in PATCH, so clear absent historical metadata explicitly.
  var restorationPatch:[String:Any] {["text":text,"period":period ?? "","valid_until":valid_until ?? ""]}
}
struct LibraryUse:Decodable,Identifiable {var id:String;var session_id:String?;var answer_version:Int;var text:String?;var outcome:String?;var reason:String?}
struct LibraryTurn:Decodable {var question:String;var answer:String;var feedback:String;var suggested_text:String?}
struct LibraryPractice:Decodable,Identifiable {var id:String;var question:String;var status:String;var turns:[LibraryTurn];var job_id:String?}
struct LibraryReference:Decodable {var source_id:String;var source_version:String?;var session_id:String?;var start_ms:Int?;var title:String?;var original_id:String?}
struct LibraryMigrationConflict:Decodable {var legacy_text:String;var legacy_version:Int;var legacy_status:String?;var legacy_revision:String;var source_table:String;var message:String}
struct LibraryQuestionGroup:Decodable,Identifiable {var id:String;var title:String;var question:String;var item_ids:[String];var occurrences:Int;var recording_count:Int;var scenario:String;var legacy_group_ids:[String]?;var legacy_counts:[Int]?;var prior_canonical_group_ids:[String]?}
struct LibraryQuestionGrouping:Decodable {var groups:[LibraryQuestionGroup];var status:String;var job_id:String?;var error:String?}
struct LibraryItem:Decodable,Identifiable {
  var id:String;var title:String;var text:String;var topic:String;var scenario:String;var item_type:String
  var version:Int;var expression_state:String;var evidence_state:String;var effect_state:String
  var evidence_refs:[LibraryReference];var uses:[LibraryUse];var history:[LibraryVersion];var practices:[LibraryPractice]
  var original_question:String?;var topics:[String];var remind:Bool?;var valid_until:String?;var suggested_text:String?;var synced_at:String?;var user_edited:Bool?
  var updated_at:String?;var created_at:String?;var status:String?;var material_kind:String?;var period:String?;var migration_conflict:LibraryMigrationConflict?
  var label:String {if evidence_state == "expired" {return "已过期"};if evidence_state == "changed" {return "依据有变化"};if expression_state == "improve" {return "待改进"};return "说法可复用 · 待实战验证"}
}
struct LibraryDocument:Decodable,Identifiable {
  var id:String;var title:String;var status:String;var error:String?;var job_id:String?;var family_id:String
  var version:Int;var versions:[String];var sha256:String;var pages:[LibraryPage];var text:String;var parsed_id:String?;var changes:[String];var pending_id:String?
}
struct LibrarySessionMetric:Decodable,Identifiable {
  var id:String;var title:String;var date:String;var scenario:String;var self_ms:Double;var total_ms:Double;var pace:Double;var share:Double;var filler_rate:Double;var coverage:Double
  var articulation_rate:Double?;var language:String?
  var pause_count:Double?;var pause_rate:Double?;var pause_mean_seconds:Double?
  var pitch_range_st:Double?;var volume_range_db:Double?;var acoustic_ms:Double?;var voiced_ms:Double?
  var pvq:Double?;var boundary_pause_median_s:Double?;var boundary_pause_samples:Int?
  var non_boundary_pause_ratio:Double?;var long_pause_rate:Double?
  var acoustic_status:String?;var acoustic_job_id:String?
  var expression_scores:LibraryExpressionScores?
  var acousticMessage:String {
    switch acoustic_status {
    case "queued","running":return "正在分析原音频"
    case "failed","interrupted","cancelled":return "音频分析未完成，可重试"
    case "unavailable":return "原音频不可用，无法分析"
    case "insufficient":return "本人有效声音不足，暂无法测量"
    case "ready":return "已完成音频分析"
    default:return "音频分析尚未提供"
    }
  }
}
struct LibraryAcousticSummary {
  let rows:[LibrarySessionMetric]
  var ready:[LibrarySessionMetric] {rows.filter {$0.acoustic_status=="ready"}}
  var pauseRate:Double? {
    let valid=ready.filter {
      guard let count=$0.pause_count,count.isFinite,count >= 0 else {return false}
      guard let ms=$0.acoustic_ms,ms.isFinite,ms > 0 else {return false}
      return true
    }
    let ms=valid.reduce(0) {$0+($1.acoustic_ms ?? 0)}
    return ms>0 ? valid.reduce(0) {$0+($1.pause_count ?? 0)}*60000/ms:nil
  }
  var meanPause:Double? {
    let valid=ready.filter {
      guard let mean=$0.pause_mean_seconds,mean.isFinite,mean >= 0 else {return false}
      guard let count=$0.pause_count,count.isFinite,count >= 0 else {return false}
      return true
    }
    let count=valid.reduce(0) {$0+($1.pause_count ?? 0)}
    return count>0 ? valid.reduce(0) {$0+($1.pause_mean_seconds ?? 0)*($1.pause_count ?? 0)}/count:(valid.isEmpty ? nil:0)
  }
  func weighted(_ key:KeyPath<LibrarySessionMetric,Double?>)->Double? {
    let valid=ready.filter {
      guard let value=$0[keyPath:key],value.isFinite,value >= 0 else {return false}
      guard let voiced=$0.voiced_ms,voiced.isFinite,voiced > 0 else {return false}
      return true
    }
    let ms=valid.reduce(0) {$0+($1.voiced_ms ?? 0)}
    return ms>0 ? valid.reduce(0) {$0+($1[keyPath:key] ?? 0)*($1.voiced_ms ?? 0)}/ms:nil
  }
}
struct LibraryAggregate:Decodable {var count:Int;var self_ms:Double;var pace:Double?;var share:Double?;var filler_rate:Double?;var from:String?;var to:String?}
struct LibraryMetrics:Decodable {
  var sessions:[LibrarySessionMetric];var recent:LibraryAggregate;var baseline:LibraryAggregate?;var note:String
  var score_rule_version:String?
}
struct LibraryUpdate:Decodable,Identifiable {var id:String;var status:String;var message:String}
struct LibrarySnapshot:Decodable {var items:[LibraryItem];var documents:[LibraryDocument];var metrics:LibraryMetrics;var updates:[LibraryUpdate];var question_grouping:LibraryQuestionGrouping?}

struct CompanionMemory:View {
  @EnvironmentObject var store:Store
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var scenario="sales"
  @State private var selections=["sales":"我","interview":"我"]
  @State private var snapshot:LibrarySnapshot?
  @State private var error:String?
  @State private var importing=false
  private var tab:Binding<String> {Binding(get:{selections[scenario] ?? "我"},set:{selections[scenario]=$0})}
  private var rows:[LibraryItem] {(snapshot?.items ?? []).filter {$0.scenario==scenario && ($0.status ?? "active")=="active"}}
  var body:some View {
    VStack(spacing:0) {
      CompanionPageHeader(title:"记忆库") {Button {importing=true} label:{Image(systemName:"plus").frame(width:44,height:44)}.accessibilityLabel("上传资料")}
      HStack(spacing:10) {
        scenarioButton("销售积累","sales");scenarioButton("面试积累","interview")
      }.padding(.horizontal,18).padding(.top,8).frame(maxWidth:700).frame(maxWidth:.infinity)
      CompanionTabs(values:["我","FAQ","背景资料"],selection:tab).padding(.horizontal,18).padding(.vertical,12).frame(maxWidth:700).frame(maxWidth:.infinity).accessibilityIdentifier("memoryLibraryTabs")
      ScrollView {
        VStack(alignment:.leading,spacing:14) {
          if let error {Text(error).companionFont(13).foregroundStyle(.red);Button("重新读取") {Task {await load()}}}
          if let s=snapshot {
            if tab.wrappedValue == "我" {overview(s)}
            else if tab.wrappedValue == "FAQ" {MergedLibraryFAQ(items:rows,grouping:s.question_grouping,scenario:scenario,upload:{importing=true}).id(scenario)}
            else {LibraryDocuments(documents:s.documents,items:rows,onChange:{Task {await load()}})}
          } else if error == nil {ProgressView("正在读取你的积累")}
          if let issue=store.personalImportError {Text(issue).companionFont(13).foregroundStyle(.red)}
        }.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,18).padding(.bottom,24).frame(maxWidth:700).frame(maxWidth:.infinity)
      }.refreshable {await load()}
    }.background(Warm.paper).toolbar(.hidden,for:.navigationBar)
      .fileImporter(isPresented:$importing,allowedContentTypes:[.pdf,.image,.plainText,UTType(filenameExtension:"docx") ?? .data,UTType(filenameExtension:"pptx") ?? .data,UTType(filenameExtension:"md") ?? .plainText],allowsMultipleSelection:true) {result in
        switch result {case .success(let urls):Task {await store.addOnboardingFiles(urls);await load()};case .failure(let e):if !ImportedDocumentFiles.isCancellation(e) {error=e.localizedDescription}}
      }
      .task {while !Task.isCancelled {await load();do {try await Task.sleep(for:.seconds(5))} catch {break}}}
  }
  private func scenarioButton(_ title:String,_ value:String)->some View {
    Button {scenario=value} label:{Text(title).companionFont(13,weight:.semibold).frame(maxWidth:.infinity,minHeight:44).background(scenario==value ? Warm.lavender:Warm.white,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(scenario==value ? Warm.purple:CompanionStyle.line))}.buttonStyle(.plain).accessibilityIdentifier("memory-"+value).accessibilityAddTraits(scenario==value ? .isSelected:[])
  }
  private func load() async {
    #if DEBUG
    if Store.isolatedTestRun {loadPreview();return}
    #endif
    guard store.remote else {error="连接 Candid 后查看记忆库，已有本机资料仍保留。";return}
    do {let connection=store.api;let value:LibrarySnapshot=try await connection.call("/v1/library");guard DeviceRecordingMap.identity(connection)==DeviceRecordingMap.identity(store.api) else{return};snapshot=value;error=nil;await store.restorePersonalProfile()}
    catch {if !Task.isCancelled {self.error=error.localizedDescription}}
  }
  @ViewBuilder private func overview(_ s:LibrarySnapshot)->some View {
    let materials=rows.filter {$0.item_type=="material"}
    let materialsTitle=scenario=="interview" ? "面试故事与表达素材":"故事与表达素材"
    NavigationLink {MergedDeliveryPage(metrics:s.metrics,scenario:scenario)} label: {
      CompanionMemoryCard {
        HStack {Text("表达").companionFont(16,weight:.semibold);Spacer();Text("查看详情").companionFont(12);Image(systemName:"chevron.right")}
        HStack(spacing:18) {
          if !typeSize.isAccessibilitySize {Image(systemName:"waveform.path").font(.system(size:38,weight:.light)).foregroundStyle(Warm.purple).frame(width:86,height:86).background(Warm.lavender,in:RoundedRectangle(cornerRadius:20))}
          VStack(alignment:.leading,spacing:7) {Text("来自 \(s.metrics.sessions.filter {$0.scenario==scenario}.count) 次有本人录音的沟通").companionFont(12).foregroundStyle(RecordingFormat.secondary);Text("五个维度，了解你的表达习惯").companionFont(14,weight:.semibold);Text("五个维度基于本人片段；停顿与起伏在音频分析后展示。").companionFont(12).foregroundStyle(RecordingFormat.secondary)}
        }.padding(.top,6)
      }
    }.buttonStyle(.plain).accessibilityIdentifier("memory-expression-overview")
    LazyVGrid(columns:typeSize.isAccessibilitySize ? [GridItem(.flexible())]:[GridItem(.flexible()),GridItem(.flexible())],spacing:10) {
      Button {selections[scenario]="FAQ"} label:{CompanionMemoryCard {Text("\(rows.filter {$0.item_type=="faq" && $0.user_edited==true}.count)").companionFont(27,weight:.semibold);Text("问题已有我的说法").companionFont(12)}}.buttonStyle(.plain)
      NavigationLink {MergedMaterialList(items:materials,title:materialsTitle)} label:{CompanionMemoryCard {Text("\(materials.count)").companionFont(27,weight:.semibold);HStack {Text(materialsTitle).companionFont(12);Spacer();Image(systemName:"chevron.right").font(.system(size:12))}}}.buttonStyle(.plain).accessibilityIdentifier("memory-materials-overview")
    }
    if let d=store.companionMemory?.discoveries.first {
      NavigationLink {CompanionDiscoveryPage(discovery:d)} label:{VStack(alignment:.leading,spacing:10) {Text("跨场发现 · 个人积累").companionFont(12);Text(d.title).companionFont(16,weight:.semibold);Text("查看依据与集中确认 →").companionFont(12)}.padding(16).frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(.white).background(Color(red:0.345,green:0.255,blue:0.753),in:RoundedRectangle(cornerRadius:14))}.buttonStyle(.plain)
    }
    NavigationLink("全部跨场发现") {CompanionDiscoveryList()}.frame(minHeight:44)
    NavigationLink("我的介绍与资料") {PersonalProfilePage()}.frame(minHeight:44)
    let archived=s.items.filter {$0.scenario==scenario && $0.status=="archived"}
    NavigationLink("已归档素材（\(archived.count)）") {MergedMaterialList(items:archived,title:"已归档素材")}.frame(minHeight:44)
    let other=s.items.filter {!["sales","interview"].contains($0.scenario)}
    if !other.isEmpty {NavigationLink("其他历史积累（\(other.count)）") {MergedMaterialList(items:other,title:"其他历史积累")}.frame(minHeight:44)}
    ForEach(s.updates.filter {["failed","interrupted"].contains($0.status)}) {u in
      VStack(alignment:.leading,spacing:6) {Text(u.message).companionFont(12).foregroundStyle(RecordingFormat.secondary);Button("继续整理") {Task {do {_ = try await store.api.raw("/v1/business-jobs/"+u.id+"/retry",method:"POST");await load()} catch {self.error=error.localizedDescription}}}.frame(minHeight:44)}
    }
  }
  #if DEBUG
  private func loadPreview() {
    let items=(store.companionMemory?.expressions ?? []).map {r -> [String:Any] in
      ["id":r.id,"title":r.title,"text":r.body.text,"topic":"价格与政策","scenario":"sales","item_type":"faq","version":r.version,"status":"active","expression_state":r.user_edited==true ? "reusable":"improve","evidence_state":r.reference_status=="current" ? "ready":"changed","effect_state":"untried","evidence_refs":[],"uses":[],"history":[],"practices":[],"topics":["价格与政策"],"user_edited":r.user_edited==true]
    }
    let empty:[String:Any]=["count":0,"self_ms":0]
    let payload:[String:Any]=["items":items,"documents":[],"metrics":["sessions":[],"recent":empty,"note":"隔离测试数据"],"updates":[]]
    var result=payload
    let args=ProcessInfo.processInfo.arguments
    if args.contains("-candid-radar-full") {
      result["metrics"]=LibraryPreviewMetrics.radarFull()
    } else if args.contains("-candid-radar-partial") {
      result["metrics"]=LibraryPreviewMetrics.radarPartial()
    } else if args.contains("-candid-acoustics-preview") {
      result["metrics"]=LibraryPreviewMetrics.acousticsSingle()
    }
    if let grouping=store.companionMemory?.question_grouping {result["question_grouping"]=["groups":grouping.groups.map {g in ["id":g.id,"title":g.title,"question":g.question,"item_ids":g.expression_ids,"occurrences":g.occurrences,"recording_count":g.recording_count,"scenario":"sales"] as [String:Any]},"status":"ready"]}
    if let data=try? JSONSerialization.data(withJSONObject:result) {snapshot=try? JSONDecoder().decode(LibrarySnapshot.self,from:data)}
  }
  #endif
}

#if DEBUG
enum LibraryPreviewMetrics {
  private static let note="隔离合成数据，用于验证表达参考评分展示，不代表真实录音精度。"
  private static let empty:[String:Any]=["count":0,"self_ms":0]
  static func acousticsSingle()->[String:Any] {
    metrics([ready(id:"acoustic-preview",day:17,pace:210,pause:3,pitch:4.5,pvq:170,scores:demoScores(pace:4,pause:3,filler:4,pitch:4,duration:nil))])
  }
  static func radarPartial()->[String:Any] {
    metrics([
      ready(id:"radar-partial-1",day:15,pace:160,pause:2,pitch:nil,pvq:nil,scores:demoScores(pace:2,pause:3,filler:3,pitch:nil,duration:nil)),
      running(id:"radar-partial-2",day:16,pace:170,scores:demoScores(pace:2,pause:nil,filler:3,pitch:nil,duration:nil))
    ])
  }
  static func radarFull()->[String:Any] {
    var sessions:[[String:Any]]=[]
    for index in 1...6 {
      let paceScore=index <= 3 ? 2:4
      sessions.append(ready(id:"radar-full-\(index)",day:10+index,pace:140+Double(index)*12,pause:Double(index),pitch:3+Double(index)*0.7,pvq:120+Double(index)*10,share:40+Double(index)*3,filler:0.5+Double(index)*0.2,
                            scores:demoScores(pace:paceScore,pause:min(4,index),filler:3,pitch:index <= 2 ? 2:4,duration:nil)))
    }
    return metrics(sessions)
  }
  private static func metrics(_ sessions:[[String:Any]])->[String:Any] {
    ["sessions":sessions,"recent":empty,"note":note,"score_rule_version":"expression-scoring@1.0.0"]
  }
  private static func demoScores(pace:Int?,pause:Int?,filler:Int?,pitch:Int?,duration:Int?)->[String:Any] {
    func axis(_ score:Int?,_ label:String,_ suggestion:String)->[String:Any] {
      if let score {
        return ["score":score,"status":"scored","label":label,"color":score >= 3 ? "green":(score == 2 ? "yellow":"red"),
                "target":"见研究稿","explanation":"隔离合成参考分","suggestion":suggestion,
                "evidence_grade":"C","measurement_quality":"ready","rule_id":"preview"]
      }
      return ["status":"unscored","label":label,"color":"neutral","explanation":"数据不足、不适用或分析中",
              "suggestion":suggestion,"evidence_grade":"C","measurement_quality":"insufficient","rule_id":"preview.unscored"]
    }
    let paceLabel=pace.map { $0 >= 3 ? "有效":"待改进"} ?? "未评分"
    return ["rule_version":"expression-scoring@1.0.0","profile":"sales_reference","language":"zh","note":"隔离合成参考评分",
            "axes":["pace":axis(pace,paceLabel,"合成建议：按内容类型调整语速。"),
                    "pause":axis(pause,pause == nil ? "分析中":"参考","合成建议：把停顿放到意群边界。"),
                    "filler":axis(filler,"参考","合成建议：用短停顿代替口头禅。"),
                    "pitch":axis(pitch,pitch == nil ? "分析中":"参考","合成建议：在关键词上做自然强调。"),
                    "duration":axis(duration,"不适用","销售场景默认不套用面试单题时长。")]]
  }
  private static func ready(id:String,day:Int,pace:Double,pause:Double,pitch:Double?,pvq:Double?,share:Double=50,filler:Double=1,scores:[String:Any])->[String:Any] {
    var payload:[String:Any]=base(id:id,day:day,pace:pace,share:share,filler:filler)
    payload["acoustic_status"]="ready"
    payload["articulation_rate"]=pace
    payload["language"]="zh"
    payload["pause_count"]=pause
    payload["pause_rate"]=pause
    payload["pause_mean_seconds"]=0.5
    payload["boundary_pause_median_s"]=0.55
    payload["boundary_pause_samples"]=4
    payload["non_boundary_pause_ratio"]=0.04
    payload["long_pause_rate"]=0.5
    payload["acoustic_ms"]=60000
    payload["voiced_ms"]=40000
    payload["volume_range_db"]=8.2
    if let pitch {payload["pitch_range_st"]=pitch}
    if let pvq {payload["pvq"]=pvq}
    payload["expression_scores"]=scores
    return payload
  }
  private static func running(id:String,day:Int,pace:Double,scores:[String:Any])->[String:Any] {
    var payload=base(id:id,day:day,pace:pace,share:50,filler:1)
    payload["acoustic_status"]="running"
    payload["acoustic_job_id"]="job-"+id
    payload["language"]="zh"
    payload["expression_scores"]=scores
    return payload
  }
  private static func base(id:String,day:Int,pace:Double,share:Double,filler:Double)->[String:Any] {
    ["id":id,"title":"合成场次 \(id)","date":String(format:"2026-10-%02dT10:00:00Z",day),"scenario":"sales","self_ms":60000,"total_ms":120000,"pace":pace,"share":share,"filler_rate":filler,"coverage":100]
  }
}
#endif
struct MergedMaterialList:View {
  let items:[LibraryItem];let title:String
  var body:some View {ScrollView {VStack(alignment:.leading,spacing:12) {if items.isEmpty {Text("还没有素材。历史内容同步后会显示在这里。").companionFont(14)};ForEach(items) {item in NavigationLink {LibraryFAQDetail(item:item)} label:{CompanionMemoryCard {Text(item.title).companionFont(16,weight:.semibold);Text(item.item_type=="faq" ? "问答":item.material_kind=="story" ? "故事":item.material_kind=="experience" ? "经历":"表达").companionFont(11).foregroundStyle(Warm.purple);Text(item.text).companionFont(13).lineLimit(3);Text(item.status=="archived" ? "已归档":item.label).companionFont(12).foregroundStyle(RecordingFormat.secondary)}}.buttonStyle(.plain)}}.padding(18).frame(maxWidth:700).frame(maxWidth:.infinity)}.companionReport(title)}
}
struct MergedDeliveryPage:View {
  let metrics:LibraryMetrics;let scenario:String
  @EnvironmentObject private var store:Store
  @State private var selected="语速"
  @State private var showBaseline=false
  @State private var refreshed:LibraryMetrics?
  @State private var issue:String?
  @State private var lastFingerprint=""
  private let axes=DeliveryRadarScale.axes
  private var current:LibraryMetrics {refreshed ?? metrics}
  private var radar:DeliveryRadarSnapshot {DeliveryRadarAggregation.snapshot(sessions:current.sessions,scenario:scenario)}
  private var recent:[LibrarySessionMetric] {radar.recentRows}
  private var acoustics:LibraryAcousticSummary {LibraryAcousticSummary(rows:recent)}
  private var selectedPoint:DeliveryRadarAxisPoint? {radar.recent?.point(selected)}
  var body:some View {ScrollView {VStack(alignment:.leading,spacing:16) {
    Text("表达").companionFont(27,weight:.bold)
    DeliveryRadarCard(snapshot:radar,selected:$selected,showBaseline:$showBaseline)
    LazyVGrid(columns:[GridItem(.adaptive(minimum:95))],spacing:8) {
      ForEach(axes,id:\.self) {axis in
        Button {selected=axis} label:{
          Text(axis).companionFont(13).frame(maxWidth:.infinity,minHeight:44)
            .background(selected==axis ? Warm.lavender:Warm.white,in:RoundedRectangle(cornerRadius:10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("delivery-axis-button-"+axis)
        .accessibilityAddTraits(selected==axis ? .isSelected:[])
      }
    }
    CompanionMemoryCard {
      Text(selected).companionFont(17,weight:.semibold)
      if case .scored(let score)=selectedPoint?.status {
        Text("参考 \(score) 分 · \(selectedPoint?.status.message ?? "")")
          .companionFont(25,weight:.semibold)
          .foregroundStyle(DeliveryRadarScale.colorName(score))
          .accessibilityIdentifier("delivery-axis-value")
      } else {
        Text(detailPlaceholder).companionFont(14).accessibilityIdentifier("delivery-axis-placeholder")
      }
      if let detail=selectedPoint?.detail {
        if let target=detail.target {Text("目标："+target).companionFont(13)}
        if let explanation=detail.explanation {Text(explanation).companionFont(13)}
        if let suggestion=detail.suggestion {Text("改进建议："+suggestion).companionFont(13).foregroundStyle(Warm.purple)}
        Text("证据等级 \(detail.evidence_grade ?? "—") · 本次测量：\(qualityText(detail.measurement_quality))")
          .companionFont(11).foregroundStyle(RecordingFormat.secondary)
        if let count=selectedPoint?.coverage,count>0 {Text("有效 \(count)/\(recent.count) 场；原始值与说明来自该分数的代表场次。").companionFont(12)}
        if let source=detail.sources?.first,let id=source.session_id {
          NavigationLink("查看依据录音与原文") {CompanionRecordingPage(id:id)}.frame(minHeight:44)
        }
      }
      rawMetricLines
      if ["停顿","起伏"].contains(selected) {
        Text("最近 \(recent.count) 场，\(acoustics.ready.count) 场有有效音频分析").companionFont(12)
        ForEach(recent.filter {$0.acoustic_status != "ready"}) {row in
          Text(row.title+" · "+row.acousticMessage).companionFont(12)
          if let job=row.acoustic_job_id,["failed","interrupted","cancelled"].contains(row.acoustic_status ?? "") {
            Button("重试这场音频分析") {Task {await retry(job)}}.frame(minHeight:44)
          }
        }
      }
      if selected != "时长控制" {
        Text("说话占比（原始指标，不参与评分）："+shareText).companionFont(12).foregroundStyle(RecordingFormat.secondary)
      }
      Text(current.note).companionFont(12).foregroundStyle(RecordingFormat.secondary)
    }
    if let issue {Text("刷新未成功，仍显示上次结果。"+issue).companionFont(12).foregroundStyle(.red).accessibilityIdentifier("delivery-refresh-issue")}
    NavigationLink("查看逐场记录与趋势") {LibraryMetricsPage(metrics:current,scenario:scenario)}.frame(minHeight:44).accessibilityIdentifier("delivery-session-trend")
  }.padding(18).frame(maxWidth:700).frame(maxWidth:.infinity)}.companionReport("表达")
    .refreshable {await refresh()}
    .task {
      lastFingerprint=radar.fingerprint
      guard store.remote else {return}
      while !Task.isCancelled {
        await refresh()
        do {try await Task.sleep(for:.seconds(5))} catch {break}
      }
    }
  }
  private var shareText:String {
    let selfMS=recent.reduce(0){$0+$1.self_ms},total=recent.reduce(0){$0+$1.total_ms}
    guard selfMS > 0,total > 0 else {return "暂无"}
    return String(format:"%.1f%%",selfMS*100/total)
  }
  private func qualityText(_ value:String?)->String {
    switch value {case "ready":return "已完成";case "limited":return "仅供参考";case "insufficient":return "数据不足";case "uncalibrated":return "待校准";case "inapplicable":return "不适用";default:return "待分析"}
  }
  @ViewBuilder private var rawMetricLines:some View {
    let raw=selectedPoint?.detail?.raw
    switch selected {
    case "语速":
      if let v=raw?.value {Text(String(format:"原始 %@ %.1f %@",raw?.metric == "articulation_rate" ? "发音速率":"语速",v,raw?.unit ?? "字词/分钟")).companionFont(13)}
      else if let pace=DeliveryRadarAggregation.weightedPace(recent) {Text(String(format:"原始整体语速 %.1f 字词/分钟",pace)).companionFont(13)}
      Text("语速来自转写估计；评分优先使用剔除静音的发音速率。").companionFont(12).foregroundStyle(RecordingFormat.secondary)
    case "口头禅":
      if let rate=raw?.rate_per_min {Text(String(format:"原始 %.1f 次/分钟",rate)).companionFont(13)}
      if let pct=raw?.percent {Text(String(format:"占比 %.1f%%",pct)).companionFont(13)}
      Text("口头禅可能受转写省略影响；有实义的“然后/就是”不简单扣分。").companionFont(12).foregroundStyle(RecordingFormat.secondary)
    case "停顿":
      if let rate=acoustics.pauseRate {Text(String(format:"%.1f 次/分钟",rate)).companionFont(13)}
      if let mean=acoustics.meanPause {Text(String(format:"平均每次 %.2f 秒",mean)).companionFont(13)}
      if let median=raw?.boundary_median_s ?? recent.compactMap(\.boundary_pause_median_s).first {
        Text(String(format:"边界停顿中位 %.2f 秒",median)).companionFont(13)
      }
    case "起伏":
      if let pvq=raw?.pvq ?? recent.compactMap(\.pvq).first {Text(String(format:"参考 PVQ %.1f",pvq)).companionFont(13)}
      if let st=raw?.pitch_range_st ?? acoustics.weighted(\.pitch_range_st) {Text(String(format:"%.1f 半音",st)).companionFont(13)}
      if let volume=acoustics.weighted(\.volume_range_db) {Text(String(format:"音量变化 %.1f dB",volume)).companionFont(13)}
      Text("半音跨度用于观察音调变化；起伏评分待量纲校准后提供。").companionFont(12).foregroundStyle(RecordingFormat.secondary)
    case "时长控制":
      if let actual=raw?.actual_ms,let target=raw?.target_ms {
        Text(String(format:"实际 %.0f 秒 / 目标 %.0f 秒",actual/1000,target/1000)).companionFont(13)
      }
    default:EmptyView()
    }
  }
  private var detailPlaceholder:String {
    if recent.isEmpty {return "认领本人录音后显示"}
    if let point=selectedPoint {
      switch point.status {
      case .analyzing:return "正在分析原音频"
      case .unscored(let reason):return reason
      case .empty:return "暂无可靠测量"
      case .scored:break
      }
    }
    return recent.first(where:{$0.acoustic_status != "ready"})?.acousticMessage ?? "暂无可靠测量"
  }
  private func refresh() async {
    guard store.remote else {return}
    let connection=store.api
    do {
      let data:LibraryMetrics=try await connection.call("/v1/library/metrics")
      guard DeviceRecordingMap.identity(connection)==DeviceRecordingMap.identity(store.api) else {return}
      let next=DeliveryRadarAggregation.snapshot(sessions:data.sessions,scenario:scenario)
      if next.fingerprint != lastFingerprint {
        lastFingerprint=next.fingerprint
        if !next.canCompare {showBaseline=false}
      }
      refreshed=data;issue=nil
    } catch {if !Task.isCancelled {issue=error.localizedDescription}}
  }
  private func retry(_ job:String) async {
    do {_ = try await store.api.raw("/v1/business-jobs/"+job+"/retry",method:"POST");await refresh()}
    catch {issue=error.localizedDescription}
  }
}
struct MergedLibraryFAQ:View {
  let items:[LibraryItem];let grouping:LibraryQuestionGrouping?;let scenario:String;var upload:()->Void
  @EnvironmentObject private var store:Store
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var search="";@State private var expanded=false;@State private var mode="按主题";@State private var sort="被问最多";@State private var retryError:String?
  private var groups:[LibraryQuestionGroup] {
    if let grouping {return grouping.groups.filter {$0.scenario==scenario}}
    return items.filter {$0.item_type=="faq"}.map {LibraryQuestionGroup(id:$0.id,title:$0.title,question:$0.title,item_ids:[$0.id],occurrences:1,recording_count:0,scenario:scenario)}
  }
  private func rows(_ group:LibraryQuestionGroup)->[LibraryItem] {items.filter {group.item_ids.contains($0.id)}}
  private func latest(_ group:LibraryQuestionGroup)->LibraryItem? {rows(group).sorted {if ($0.updated_at ?? $0.created_at ?? "") != ($1.updated_at ?? $1.created_at ?? "") {return ($0.updated_at ?? $0.created_at ?? "") > ($1.updated_at ?? $1.created_at ?? "")};return ($0.user_edited==true ? 0:1,$0.id)<($1.user_edited==true ? 0:1,$1.id)}.first}
  private func needsWork(_ group:LibraryQuestionGroup)->Bool {guard let r=latest(group) else{return true};return r.expression_state=="improve" || r.evidence_state != "ready"}
  private var filtered:[LibraryQuestionGroup] {groups.filter {search.isEmpty || ($0.question+$0.title+rows($0).map { $0.text+$0.topic+($0.original_question ?? "") }.joined()).localizedCaseInsensitiveContains(search)}.sorted {a,b in if sort=="最近更新" {return (latest(a)?.updated_at ?? "") > (latest(b)?.updated_at ?? "")};return a.occurrences==b.occurrences ? a.id<b.id:a.occurrences>b.occurrences}}
  var body:some View {VStack(alignment:.leading,spacing:14) {
    Text(scenario=="interview" ? "面试问过什么，留下自己的回答。":"客户常问什么，你怎么答最好。").companionFont(12).foregroundStyle(RecordingFormat.secondary)
    HStack {Image(systemName:"magnifyingglass");TextField("搜问题，或搜你的说法",text:$search).accessibilityIdentifier("memory-question-search");if !search.isEmpty {Button {search=""} label:{Image(systemName:"xmark.circle.fill").frame(width:44,height:44)}.accessibilityLabel("清除搜索")}}.padding(12).background(Warm.white,in:RoundedRectangle(cornerRadius:14))
    if let grouping,grouping.status != "ready" {Text(grouping.error ?? "相似问题正在整理，先显示已有问法。").companionFont(12).foregroundStyle(RecordingFormat.secondary);if let job=grouping.job_id,["failed","interrupted","cancelled"].contains(grouping.status) {Button("重试归类") {Task {do {_ = try await store.api.raw("/v1/business-jobs/"+job+"/retry",method:"POST");retryError=nil} catch {retryError=error.localizedDescription}}}.frame(minHeight:44)}}
    if let retryError {Text(retryError).companionFont(12).foregroundStyle(.red)}
    if filtered.isEmpty {Text(search.isEmpty ? "还没有 FAQ，沟通与复盘后会逐渐积累。":"没有找到相关问题，换个关键词试试。").companionFont(14)}
    let improve=filtered.filter {needsWork($0)}
    VStack(alignment:.leading,spacing:12) {HStack {Text("先把这些问题答好").companionFont(17,weight:.semibold);Spacer();Text("\(improve.count)").companionFont(27,weight:.semibold)};ForEach(expanded ? improve:Array(improve.prefix(2))) {link($0)};if !improve.isEmpty {Button("补充背景资料",systemImage:"square.and.arrow.up",action:upload).buttonStyle(CompanionButtonStyle(primary:true))};if improve.count>2 {Button(expanded ? "收起":"展开全部 \(improve.count) 个") {expanded.toggle()}.frame(minHeight:44)}}.padding(16).background(Warm.orange.opacity(0.16),in:RoundedRectangle(cornerRadius:20))
    HStack {Text("值得复用的回答").companionFont(17,weight:.semibold);Spacer();Menu(sort) {Button("被问最多") {sort="被问最多"};Button("最近更新") {sort="最近更新"}};Menu(mode) {Button("按主题") {mode="按主题"};Button("按问题") {mode="按问题"}}}
    let reusable=filtered.filter {!needsWork($0)}
    if mode=="按主题" && search.isEmpty {LazyVGrid(columns:Array(repeating:GridItem(.flexible(),alignment:.top),count:typeSize.isAccessibilitySize ? 1:2),spacing:10) {ForEach(Array(Set(reusable.compactMap {latest($0)?.topic})).sorted(),id:\.self) {topic in NavigationLink {ScrollView {VStack(spacing:12) {ForEach(reusable.filter {latest($0)?.topic==topic}) {link($0)}}.padding(18)}.companionReport(topic)} label:{CompanionFAQCard {Image(systemName:"text.bubble").foregroundStyle(Warm.purple);Text(topic).companionFont(14,weight:.semibold);Text("\(reusable.filter {latest($0)?.topic==topic}.count) 个问题").companionFont(12)}}.buttonStyle(.plain)}}}
    else {ForEach(reusable) {link($0)}}
  }}
  private func link(_ group:LibraryQuestionGroup)->some View {NavigationLink {MergedFAQGroupPage(group:group,items:rows(group))} label:{CompanionFAQCard {Text(group.question).companionFont(14,weight:.semibold);Text(group.occurrences>0 ? "被问 \(group.occurrences) 次 · \(group.recording_count) 场沟通":"历史问法 · 次数待核对").companionFont(11);Text(latest(group)?.label ?? "待整理").companionFont(11).foregroundStyle(Warm.purple)}}.buttonStyle(.plain).accessibilityIdentifier("memory-question-"+group.id)}
}
struct MergedFAQGroupPage:View {
  let group:LibraryQuestionGroup;@State var items:[LibraryItem]
  @EnvironmentObject private var store:Store
  @State private var error:String?
  var body:some View {ScrollView {VStack(alignment:.leading,spacing:14) {Text(group.question).companionFont(25,weight:.bold);Text("相似问法放在一起，每次回答与资料依据分别保留。").companionFont(13);if let error {Text(error).companionFont(12).foregroundStyle(.red);Button("重新读取") {Task {await refresh()}}};ForEach(Array((group.legacy_counts ?? []).enumerated()),id:\.offset) {_,count in Text("旧题库计数：\(count) 次，尚未核对来源录音").companionFont(12)};ForEach(items) {item in NavigationLink {LibraryFAQDetail(item:item)} label:{CompanionFAQCard {Text(item.original_question ?? item.title).companionFont(16,weight:.semibold);Text(item.text).companionFont(14);Text("查看与修改这次应对 →").companionFont(12).foregroundStyle(Warm.purple)}}.buttonStyle(.plain).accessibilityIdentifier("library-group-item-"+item.id)};if !(group.legacy_group_ids ?? []).isEmpty {Text("已保留旧问题组的对应关系").companionFont(12).foregroundStyle(RecordingFormat.secondary)};if !(group.prior_canonical_group_ids ?? []).isEmpty {Text("已保留合并前 FAQ 组的对应关系").companionFont(12).foregroundStyle(RecordingFormat.secondary)}}.padding(18).frame(maxWidth:700).frame(maxWidth:.infinity)}.companionReport("FAQ").task {await refresh()}}
  private func refresh() async {
    #if DEBUG
    if Store.isolatedTestRun {return}
    #endif
    do {
      let value:LibrarySnapshot=try await store.api.call("/v1/library")
      items=value.items.filter {group.item_ids.contains($0.id) && ($0.status ?? "active")=="active"}
      error=nil
    } catch {if !Task.isCancelled {self.error=error.localizedDescription}}
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
struct LibraryAcousticValues:View {
  let rows:[LibrarySessionMetric]
  private var summary:LibraryAcousticSummary {LibraryAcousticSummary(rows:rows)}
  var body:some View {VStack(alignment:.leading,spacing:8) {
    Text("停顿 · "+(summary.pauseRate.map {String(format:"%.1f 次/分钟",$0)} ?? "待分析")).companionFont(14)
    Text("音高起伏 · "+(summary.weighted(\.pitch_range_st).map {String(format:"%.1f 半音",$0)} ?? "待分析")).companionFont(14)
    Text("音频分析覆盖 \(summary.ready.count)/\(rows.count) 场").companionFont(12).foregroundStyle(RecordingFormat.secondary)
  }}
}
struct LibraryMetricsPage:View {
  let metrics:LibraryMetrics
  @State private var axis="语速"
  @State private var scenario:String
  init(metrics:LibraryMetrics,scenario:String="sales") {self.metrics=metrics;_scenario=State(initialValue:scenario)}
  private var visible:LibraryMetrics {
    let radar=DeliveryRadarAggregation.snapshot(sessions:metrics.sessions,scenario:scenario)
    let rows=radar.ordered
    func aggregate(_ group:[LibrarySessionMetric])->LibraryAggregate {
      LibraryAggregate(count:group.count,self_ms:group.reduce(0) {$0+$1.self_ms},
                       pace:DeliveryRadarAggregation.weighted(group,\.pace),
                       share:DeliveryRadarAggregation.speakingShare(group),
                       filler_rate:DeliveryRadarAggregation.weighted(group,\.filler_rate),
                       from:group.first?.date,to:group.last?.date)
    }
    return LibraryMetrics(sessions:rows,recent:aggregate(radar.recentRows),baseline:radar.baselineRows.map(aggregate),note:metrics.note)
  }
  private func chartValue(_ row:LibrarySessionMetric)->Double? {
    switch axis {case "语速":return row.pace;case "占比":return row.share;case "停顿":return row.pause_rate;case "起伏":return row.pitch_range_st;default:return row.filler_rate}
  }
  var body:some View {ScrollView {VStack(alignment:.leading,spacing:20) {
    Text("表达与趋势").companionFont(25,weight:.bold)
    Picker("沟通场景",selection:$scenario) {Text("销售 BD").tag("sales");Text("面试").tag("interview")}.pickerStyle(.segmented)
    if visible.sessions.isEmpty {Text("先完成一场录音并认领本人。无需凑满多场，就能查看单场数据。")}
    else {
      Text(visible.sessions.count>=3 ? "最近三场":"近期 \(visible.sessions.count) 场").companionFont(17,weight:.semibold)
      CompanionPanel {LibraryMetricValues(value:visible.recent);LibraryAcousticValues(rows:Array(visible.sessions.suffix(3)));Text("本人有效句段 \(Int(visible.recent.self_ms/60000)) 分钟").companionFont(12)}
      if let baseline=visible.baseline {Text("最早三场 · 起点").companionFont(17,weight:.semibold);CompanionPanel {LibraryMetricValues(value:baseline);LibraryAcousticValues(rows:Array(visible.sessions.prefix(3)));Text("\(ProductDate.display(baseline.from)) — \(ProductDate.display(baseline.to))").companionFont(12)}}
      else {Text(visible.sessions.count<3 ? "满三场后查看近期趋势，满六场后与起点对比。":"再积累 \(max(0,6-visible.sessions.count)) 场，即可与最早三场对比。").companionFont(13).foregroundStyle(RecordingFormat.secondary)}
      if visible.sessions.count>=3 {
        Picker("趋势指标",selection:$axis) {Text("语速").tag("语速");Text("说话占比").tag("占比");Text("口头禅").tag("口头禅");Text("停顿（次/分钟）").tag("停顿");Text("起伏（半音）").tag("起伏")}.pickerStyle(.menu)
        Chart(Array(visible.sessions.enumerated()),id:\.element.id) {index,r in
          if let y=chartValue(r) {
            if !["停顿","起伏"].contains(axis) {LineMark(x:.value("场次",index+1),y:.value(axis,y)).foregroundStyle(Warm.purple)}
            PointMark(x:.value("场次",index+1),y:.value(axis,y)).foregroundStyle(Warm.purple)
          }
        }.frame(height:170).accessibilityLabel("真实沟通的"+axis+"趋势，逐场数值见下方记录")
      }
      Text("逐场记录").companionFont(17,weight:.semibold)
      ForEach(visible.sessions.reversed()) {r in
        NavigationLink {CompanionRecordingPage(id:r.id)} label: {VStack(alignment:.leading,spacing:8) {Text(ProductDate.display(r.date)).companionFont(14,weight:.semibold);Text("语速 \(r.pace,specifier:"%.1f") · 占比 \(r.share,specifier:"%.1f")% · 口头禅 \(r.filler_rate,specifier:"%.1f")/分钟").companionFont(12);LibraryAcousticValues(rows:[r]);Text(r.acousticMessage).companionFont(12);Text("说话人认领覆盖 \(r.coverage,specifier:"%.0f")% · 查看原文 →").companionFont(12).foregroundStyle(Warm.purple);Divider()}.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())}.buttonStyle(.plain)
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
  @State private var period=""
  @State private var selectedTopic=""
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
      HStack {Text("现在的说法").companionFont(17,weight:.semibold);Spacer();Button("更新") {beginEditing(item.text)}}
      Text(item.text).companionFont(15).textSelection(.enabled)
      Text(item.user_edited == true ? "你的说法 · v\(item.version)":"Candid 整理 · v\(item.version)").companionFont(12)
      if let period=item.period,!period.isEmpty {Text("适用："+period).companionFont(12)}
      if let date=item.valid_until,!date.isEmpty {Text("适用至 "+ProductDate.display(ProductDate.parse(date).map {dateOnly($0.addingTimeInterval(-1))} ?? date)).companionFont(12)}
    }
    if let suggestion=item.suggested_text {CompanionPanel {Text("新资料带来的修改建议").companionFont(15,weight:.semibold);Text(suggestion).companionFont(14);Button("采用并编辑") {beginEditing(suggestion)}}}
    if item.evidence_state != "ready" {Text(item.evidence_state == "missing" ? "事实依据尚未补齐，修改说法不会自动消除这个缺口。":"部分依据已变化或过期；说法和历史仍保留。").companionFont(13).foregroundStyle(RecordingFormat.secondary)}
    NavigationLink {RoleplaySetup(itemID:item.id)} label:{Label("练这道题",systemImage:"mic").frame(maxWidth:.infinity)}.buttonStyle(CompanionButtonStyle(primary:true))
    NavigationLink {LibraryMockPage(item:item)} label:{Label("用 Mock 练一练",systemImage:"bubble.left.and.bubble.right").frame(maxWidth:.infinity)}.buttonStyle(CompanionButtonStyle(primary:true))
    Text("依据与原文").companionFont(17,weight:.semibold)
    ForEach(Array(item.evidence_refs.enumerated()),id:\.offset) {_,ref in
      if let sid=ref.session_id {NavigationLink("回听原文 · "+RecordingFormat.clock((ref.start_ms ?? 0)/1000)) {CompanionRecordingPage(id:sid,focusMS:ref.start_ms)}.frame(minHeight:44)}
      else if let original=ref.original_id {NavigationLink(ref.title ?? "背景资料") {LibraryLinkedDocument(id:original)}.frame(minHeight:44)}
      else {Text(ref.title ?? "资料来源").companionFont(12)}
    }
    Button("关联背景资料") {Task {do {let value:LibrarySnapshot=try await store.api.call("/v1/library");documents=value.documents;linking=true} catch {self.error=error.localizedDescription}}}.frame(minHeight:44)
    if !item.practices.isEmpty {Text("练习记录 · 不计入实战").companionFont(17,weight:.semibold);ForEach(item.practices) {p in NavigationLink {LibraryMockPage(item:item,existing:p)} label:{Text("\(p.turns.count) 轮 · "+p.question).lineLimit(2).frame(minHeight:44)}}}
    if let conflict=item.migration_conflict {CompanionPanel(color:Warm.orange.opacity(0.2)) {Text("旧版与当前说法有差异").companionFont(16,weight:.semibold);Text(conflict.message).companionFont(12);Text("旧版："+conflict.legacy_text).companionFont(14);Button("保留当前说法") {Task {await update(["resolve_legacy":true,"expected_legacy_revision":conflict.legacy_revision])}};Button("采用旧版说法") {Task {await update(["text":conflict.legacy_text,"resolve_legacy":true,"expected_legacy_revision":conflict.legacy_revision])}}}}
    Button(item.status=="archived" ? "恢复归档素材":"归档这条素材") {Task {await update(["status":item.status=="archived" ? "active":"archived"])}}.frame(minHeight:44)
    if !item.history.isEmpty {Text("版本记录").companionFont(17,weight:.semibold);ForEach(item.history) {v in VStack(alignment:.leading,spacing:6) {Text("v\(v.answer_version) · "+(v.reason ?? "历史说法")).companionFont(12);Text(v.text).companionFont(14);Button("恢复为新版本") {Task {await restoreVersion(v)}}.frame(minHeight:44);Divider()}}}
    if let error {Text(error).foregroundStyle(.red).companionFont(13)}
  }.frame(maxWidth:.infinity,alignment:.leading).padding(18).frame(maxWidth:700).frame(maxWidth:.infinity)}.companionReport(item.item_type == "faq" ? "FAQ":"表达素材")
    .task {await refresh()}
    .sheet(isPresented:$editing) {NavigationStack {Form {TextEditor(text:$draft).frame(minHeight:180).accessibilityLabel("FAQ 说法");TextField("适用时间（可选，如双十一活动）",text:$period);Picker("主题",selection:$selectedTopic) {ForEach(item.topics,id:\.self) {Text($0).tag($0)}};Toggle("设置适用期限",isOn:$hasExpiry);if hasExpiry {DatePicker("适用至",selection:$expiry,displayedComponents:.date).accessibilityIdentifier("faq-expiry-picker")};Button("保存说法") {Task {await update(["text":draft,"period":period,"topic":selectedTopic,"valid_until":hasExpiry ? dateOnly(expiry):""]);if error==nil {editing=false}}}.disabled(busy || draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty);if let error {Text(error).foregroundStyle(.red);Button("重新读取当前版本（保留输入）") {Task {await refresh()}}.disabled(busy)}}.navigationTitle("更新说法").toolbar {Button("取消") {editing=false}}}}
    .sheet(isPresented:$linking) {NavigationStack {List(documents.filter {$0.parsed_id != nil}) {d in Button(d.title) {Task {do {item=try await store.api.call("/v1/library/items/"+item.id+"/document",method:"POST",body:["document_id":d.parsed_id!,"expected_version":item.version]);linking=false} catch {self.error=error.localizedDescription}}}}.navigationTitle("关联背景资料").toolbar {Button("关闭") {linking=false}}}}
  }
  private func dateOnly(_ value:Date)->String {let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.dateFormat="yyyy-MM-dd";return f.string(from:value)}
  private func beginEditing(_ text:String) {draft=text;period=item.period ?? "";selectedTopic=item.topic;hasExpiry = !(item.valid_until ?? "").isEmpty;expiry=ProductDate.parse(item.valid_until ?? "") ?? Date();if hasExpiry {expiry=Calendar.current.date(byAdding:.second,value:-1,to:expiry) ?? expiry};editing=true}
  private func restoreVersion(_ v:LibraryVersion) async {await update(v.restorationPatch)}
  private func refresh() async {
    #if DEBUG
    if Store.isolatedTestRun {return}
    #endif
    do {item=try await store.api.call("/v1/library/items/"+item.id);error=nil} catch {self.error=error.localizedDescription}
  }
  private func update(_ patch:[String:Any]) async {guard !busy else {return};busy=true;defer {busy=false};do {var body=patch;body["expected_version"]=item.version;item=try await store.api.call("/v1/library/items/"+item.id,method:"PATCH",body:body);error=nil} catch {self.error=error.localizedDescription}}
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
  var body:some View {Group {if let doc {VStack(spacing:0) {if doc.id != id {Text("这份依据已更新，以下为当前版本；历史原文件可在版本记录中查看。").companionFont(13).padding()};LibraryDocumentDetail(document:doc,onChange:{})}} else if let error {Text(error).padding()} else {ProgressView("正在读取资料")}}.task {do {let value:LibrarySnapshot=try await store.api.call("/v1/library");doc=value.documents.first {$0.id==id || $0.versions.contains(id)};if doc==nil {error="这份依据已更新或移除，可在背景资料查看当前版本。"}} catch {self.error=error.localizedDescription}}}
}
