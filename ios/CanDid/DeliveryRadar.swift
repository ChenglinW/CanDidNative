import SwiftUI

/// Score-based radar: radius = score/4. Larger means closer to reference rubric, not “more of a raw metric”.
enum DeliveryRadarScale {
  static let scoreMax=4.0
  static let axes=["语速","停顿","口头禅","起伏","时长控制"]
  static let keys=["pace","pause","filler","pitch","duration"]
  static func key(_ axis:String)->String {
    switch axis {
    case "语速":return "pace";case "停顿":return "pause";case "口头禅":return "filler"
    case "起伏":return "pitch";case "时长控制":return "duration";default:return axis
    }
  }
  static func axis(_ key:String)->String {
    switch key {
    case "pace":return "语速";case "pause":return "停顿";case "filler":return "口头禅"
    case "pitch":return "起伏";case "duration":return "时长控制";default:return key
    }
  }
  static func radius(score:Int?)->Double? {
    guard let score, (1...4).contains(score) else {return nil}
    return Double(score)/scoreMax
  }
  static func colorName(_ score:Int?)->Color {
    switch score {
    case 4,3:return Color(red:0.22,green:0.55,blue:0.35)
    case 2:return Color(red:0.82,green:0.55,blue:0.15)
    case 1:return Color(red:0.75,green:0.28,blue:0.22)
    default:return RecordingFormat.secondary
    }
  }
}

struct LibraryScoreAxis:Decodable,Equatable {
  var score:Int?
  var status:String?
  var label:String?
  var color:String?
  var target:String?
  var rule_id:String?
  var explanation:String?
  var suggestion:String?
  var evidence_grade:String?
  var measurement_quality:String?
  var coverage:Int?
  var raw:LibraryScoreRaw?
  var sources:[LibraryScoreSource]?
}

struct LibraryScoreSource:Decodable,Equatable {var session_id:String?;var from_ms:Double?;var to_ms:Double?}

struct LibraryScoreRaw:Decodable,Equatable {
  var value:Double?
  var unit:String?
  var metric:String?
  var rate_per_min:Double?
  var percent:Double?
  var pvq:Double?
  var pitch_range_st:Double?
  var boundary_median_s:Double?
  var non_boundary_ratio:Double?
  var long_pause_per_min:Double?
  var actual_ms:Double?
  var target_ms:Double?
  var deviation:Double?
}

struct LibraryExpressionScores:Decodable,Equatable {
  var rule_version:String?
  var profile:String?
  var language:String?
  var note:String?
  var overall:LibraryScoreAxis?
  var axes:LibraryScoreAxes?
}

struct LibraryScoreAxes:Decodable,Equatable {
  var pace:LibraryScoreAxis?
  var pause:LibraryScoreAxis?
  var filler:LibraryScoreAxis?
  var pitch:LibraryScoreAxis?
  var duration:LibraryScoreAxis?
  func cell(_ key:String)->LibraryScoreAxis? {
    switch key {
    case "pace":return pace;case "pause":return pause;case "filler":return filler
    case "pitch":return pitch;case "duration":return duration;default:return nil
    }
  }
}

enum DeliveryRadarAxisStatus:Equatable {
  case scored(Int)
  case analyzing
  case unscored(String)
  case empty
  var message:String {
    switch self {
    case .scored(let s):
      switch s {case 4:return "强";case 3:return "有效";case 2:return "待改进";case 1:return "需优先改进";default:return "已评分"}
    case .analyzing:return "分析中"
    case .unscored(let reason):return reason
    case .empty:return "暂无数据"
    }
  }
}

struct DeliveryRadarAxisPoint:Equatable,Identifiable {
  var id:String {axis}
  let axis:String
  let score:Int?
  let radius:Double?
  let status:DeliveryRadarAxisStatus
  let coverage:Int
  let detail:LibraryScoreAxis?
  var hasPlot:Bool {radius != nil}
}

struct DeliveryRadarSeries:Equatable {
  let sessionCount:Int
  let from:String?
  let to:String?
  let points:[DeliveryRadarAxisPoint]
  let profile:String?
  let language:String?
  let ruleVersion:String?
  var label:String {sessionCount >= 3 ? "近期 3 场":"近期 \(sessionCount) 场"}
  var dateRange:String {
    guard from != nil || to != nil else {return ""}
    let a=ProductDate.display(from),b=ProductDate.display(to)
    return a == b ? a:"\(a) — \(b)"
  }
  func point(_ axis:String)->DeliveryRadarAxisPoint? {points.first {$0.axis==axis}}
}

struct DeliveryRadarSnapshot {
  let ordered:[LibrarySessionMetric]
  let recentRows:[LibrarySessionMetric]
  let baselineRows:[LibrarySessionMetric]?
  let recent:DeliveryRadarSeries?
  let baseline:DeliveryRadarSeries?
  var canCompare:Bool {baseline != nil}
  var sessionsNeededForBaseline:Int {max(0,6-ordered.count)}
  var fingerprint:String {
    ordered.map { row in
      let scores=DeliveryRadarScale.keys.map { key in
        if let score=row.expression_scores?.axes?.cell(key)?.score {return String(score)}
        return row.expression_scores?.axes?.cell(key)?.status ?? ""
      }.joined(separator:",")
      return "\(row.id)|\(row.date)|\(scores)|\(row.acoustic_status ?? "")"
    }.joined(separator:";")
  }
}

enum DeliveryRadarAggregation {
  static func ordered(_ sessions:[LibrarySessionMetric],scenario:String)->[LibrarySessionMetric] {
    sessions.filter {$0.scenario==scenario && $0.self_ms.isFinite && $0.self_ms > 0 && $0.total_ms.isFinite && $0.total_ms >= $0.self_ms}
      .sorted {a,b in a.date == b.date ? a.id < b.id:a.date < b.date}
  }

  static func snapshot(sessions:[LibrarySessionMetric],scenario:String)->DeliveryRadarSnapshot {
    let rows=ordered(sessions,scenario:scenario)
    let recentRows=Array(rows.suffix(3))
    let baselineRows=rows.count >= 6 ? Array(rows.prefix(3)):nil
    return DeliveryRadarSnapshot(ordered:rows,recentRows:recentRows,baselineRows:baselineRows,
                                 recent:recentRows.isEmpty ? nil:series(recentRows),
                                 baseline:baselineRows.map(series))
  }

  /// Median of per-session scores (never average raw metrics first).
  static func series(_ rows:[LibrarySessionMetric])->DeliveryRadarSeries {
    let versions=Set(rows.compactMap {$0.expression_scores?.rule_version})
    let points=DeliveryRadarScale.axes.map {axis -> DeliveryRadarAxisPoint in
      let key=DeliveryRadarScale.key(axis)
      var scores:[Int]=[]
      var details:[LibraryScoreAxis]=[]
      var analyzing=false
      var reasons:[String]=[]
      var unscoredDetail:LibraryScoreAxis?
      for row in rows {
        if versions.count > 1 {continue}
        if let cell=row.expression_scores?.axes?.cell(key),cell.status == "scored",let score=cell.score, (1...4).contains(score) {
          scores.append(score);details.append(cell)
        } else if ["queued","running"].contains(row.acoustic_status ?? ""), ["停顿","起伏"].contains(axis) {
          analyzing=true
        } else if let cell=row.expression_scores?.axes?.cell(key) {
          reasons.append(cell.label ?? cell.explanation ?? "未评分")
          unscoredDetail=cell
        }
      }
      let coverage=scores.count
      if let median=medianScore(scores) {
        let detail=details.last {$0.score == median}
        return DeliveryRadarAxisPoint(axis:axis,score:median,radius:DeliveryRadarScale.radius(score:median),
                                      status:.scored(median),coverage:coverage,detail:detail)
      }
      if analyzing {
        return DeliveryRadarAxisPoint(axis:axis,score:nil,radius:nil,status:.analyzing,coverage:0,detail:nil)
      }
      let reason=versions.count > 1 ? "评分版本不同，暂不汇总":(reasons.first ?? (rows.isEmpty ? "暂无数据":"未评分"))
      return DeliveryRadarAxisPoint(axis:axis,score:nil,radius:nil,status:.unscored(reason),coverage:0,detail:unscoredDetail)
    }
    let first=rows.first?.expression_scores
    let languages=Set(rows.compactMap {$0.expression_scores?.language})
    return DeliveryRadarSeries(sessionCount:rows.count,from:rows.first?.date,to:rows.last?.date,points:points,
                               profile:first?.profile,language:languages.count > 1 ? "mixed":first?.language,ruleVersion:first?.rule_version)
  }

  static func medianScore(_ values:[Int])->Int? {
    guard !values.isEmpty else {return nil}
    let sorted=values.sorted()
    if sorted.count % 2 == 1 {return sorted[sorted.count/2]}
    // Even count: conservative lower mid (avoid inflating).
    return min(sorted[sorted.count/2 - 1],sorted[sorted.count/2])
  }

  static func weightedPace(_ rows:[LibrarySessionMetric])->Double? {weighted(rows,\.pace)}
  static func weighted(_ rows:[LibrarySessionMetric],_ key:KeyPath<LibrarySessionMetric,Double>)->Double? {
    let valid=rows.filter {$0.self_ms.isFinite && $0.self_ms > 0 && $0[keyPath:key].isFinite && $0[keyPath:key] >= 0}
    let ms=valid.reduce(0) {$0+$1.self_ms}
    guard ms > 0 else {return nil}
    return valid.reduce(0) {$0+$1[keyPath:key]*$1.self_ms}/ms
  }
  static func speakingShare(_ rows:[LibrarySessionMetric])->Double? {
    let valid=rows.filter {$0.self_ms.isFinite && $0.self_ms > 0 && $0.total_ms.isFinite && $0.total_ms > 0}
    let selfMS=valid.reduce(0) {$0+$1.self_ms},total=valid.reduce(0) {$0+$1.total_ms}
    guard selfMS > 0,total > 0 else {return nil}
    return selfMS*100/total
  }
}

struct DeliveryRadarChart:View {
  let recent:DeliveryRadarSeries
  let baseline:DeliveryRadarSeries?
  let showBaseline:Bool
  @Binding var selected:String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var appeared=false

  var body:some View {
    let size:CGFloat=typeSize.isAccessibilitySize ? 220:260
    VStack(alignment:.leading,spacing:10) {
      Text("满分 4 分 · 半径越大越接近参考标准").companionFont(11).foregroundStyle(RecordingFormat.secondary)
      ZStack {
        canvas(size:size)
        labelOverlay(size:size).dynamicTypeSize(.large)
      }
      .frame(width:size,height:size)
      .frame(maxWidth:.infinity)
      .accessibilityElement(children:.contain)
      .accessibilityIdentifier("delivery-radar")
      ViewThatFits(in:.horizontal) {
        HStack(spacing:10) {scoreLegend}
        VStack(alignment:.leading,spacing:8) {scoreLegend}
      }.companionFont(10)
      if showBaseline,let baseline {
        HStack(spacing:14) {
          Text("近期 · "+recent.dateRange)
          Text("起点 · "+baseline.dateRange).foregroundStyle(Warm.ink.opacity(0.55))
        }.companionFont(11).foregroundStyle(RecordingFormat.secondary)
          .accessibilityIdentifier("delivery-radar-baseline-legend")
      }
    }
    .onAppear {
      guard !reduceMotion else {appeared=true;return}
      withAnimation(.easeOut(duration:0.45)) {appeared=true}
    }
  }

  private func legendChip(_ title:String,_ color:Color)->some View {
    HStack(spacing:4) {Circle().fill(color).frame(width:8,height:8);Text(title)}
  }

  @ViewBuilder private var scoreLegend:some View {
    legendChip("强/有效",DeliveryRadarScale.colorName(4))
    legendChip("待改进",DeliveryRadarScale.colorName(2))
    legendChip("需优先改进",DeliveryRadarScale.colorName(1))
  }

  private func canvas(size:CGFloat)->some View {
    Canvas {context,canvasSize in
      let center=CGPoint(x:canvasSize.width/2,y:canvasSize.height/2)
      let radius=min(canvasSize.width,canvasSize.height)*0.32
      for ring in 1...4 {
        var grid=Path()
        let r=radius*CGFloat(ring)/4
        for i in 0..<5 {
          let p=point(center:center,radius:r,index:i)
          if i==0 {grid.move(to:p)} else {grid.addLine(to:p)}
        }
        grid.closeSubpath()
        context.stroke(grid,with:.color(Warm.ink.opacity(0.12)),lineWidth:1)
      }
      for i in 0..<5 {
        var spoke=Path();spoke.move(to:center);spoke.addLine(to:point(center:center,radius:radius,index:i))
        context.stroke(spoke,with:.color(Warm.ink.opacity(0.1)),lineWidth:1)
      }
      if showBaseline,let baseline {
        drawSeries(baseline,center:center,radius:radius,context:context,fill:false,stroke:Warm.ink.opacity(0.4),dashed:true)
      }
      drawSeries(recent,center:center,radius:radius,context:context,fill:true,stroke:Warm.purple,dashed:false)
    }.frame(width:size,height:size)
  }

  private func drawSeries(_ series:DeliveryRadarSeries,center:CGPoint,radius:CGFloat,context:GraphicsContext,fill:Bool,stroke:Color,dashed:Bool) {
    let progress:CGFloat=appeared ? 1:0.01
    let complete=series.points.allSatisfy(\.hasPlot)
    if fill,complete {
      var area=Path()
      for (index,item) in series.points.enumerated() {
        guard let r=item.radius else {continue}
        let p=point(center:center,radius:radius*CGFloat(r)*progress,index:index)
        if index==0 {area.move(to:p)} else {area.addLine(to:p)}
      }
      area.closeSubpath()
      context.fill(area,with:.color(Warm.purple.opacity(0.16)))
    }
    var line=Path();var started=false
    for i in 0..<5 {
      let j=(i+1)%5
      guard let a=series.points[i].radius,let b=series.points[j].radius else {started=false;continue}
      let p1=point(center:center,radius:radius*CGFloat(a)*progress,index:i)
      let p2=point(center:center,radius:radius*CGFloat(b)*progress,index:j)
      if !started {line.move(to:p1);started=true}
      line.addLine(to:p2)
    }
    context.stroke(line,with:.color(stroke),style:StrokeStyle(lineWidth:2.2,lineJoin:.round,dash:dashed ? [5,4]:[]))
    for (index,item) in series.points.enumerated() {
      guard let r=item.radius else {continue}
      let p=point(center:center,radius:radius*CGFloat(r)*progress,index:index)
      let selected=item.axis==selected
      let dot=Path(ellipseIn:CGRect(x:p.x-(selected ? 6:4.5),y:p.y-(selected ? 6:4.5),width:selected ? 12:9,height:selected ? 12:9))
      context.fill(dot,with:.color(selected ? Warm.purple:stroke))
    }
  }

  private func labelOverlay(size:CGFloat)->some View {
    let center=CGPoint(x:size/2,y:size/2)
    let labelR=size*0.42
    return ZStack {
      ForEach(Array(DeliveryRadarScale.axes.enumerated()),id:\.offset) {index,axis in
        let p=point(center:center,radius:labelR,index:index)
        let item=recent.point(axis)
        Button {selected=axis} label: {
          VStack(spacing:1) {
            Text(axis).companionFont(12,weight:selected==axis ? .semibold:.regular)
              .foregroundStyle(selected==axis ? Warm.purple:Warm.ink)
            if case .scored(let score)=item?.status {
              Text("\(score) 分").companionFont(10).foregroundStyle(DeliveryRadarScale.colorName(score))
            } else if let item {
              Text(shortStatus(item.status)).companionFont(9).foregroundStyle(RecordingFormat.secondary)
            }
          }.frame(minWidth:44,minHeight:44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(p)
        .accessibilityIdentifier("delivery-radar-axis-"+axis)
        .accessibilityLabel(accessibilityLabel(axis:axis,point:item))
        .accessibilityAddTraits(selected==axis ? .isSelected:[])
      }
    }.frame(width:size,height:size)
  }

  private func shortStatus(_ status:DeliveryRadarAxisStatus)->String {
    switch status {
    case .analyzing:return "分析中"
    case .unscored(let reason):return reason.count > 6 ? "未评分":reason
    case .empty:return "暂无"
    case .scored:return ""
    }
  }

  private func accessibilityLabel(axis:String,point:DeliveryRadarAxisPoint?)->String {
    guard let point else {return axis+"，暂无数据"}
    if let score=point.score {return "\(axis)，参考 \(score) 分，有效 \(point.coverage) 场，\(point.detail?.suggestion ?? "")"}
    return "\(axis)，\(point.status.message)"
  }

  private func point(center:CGPoint,radius:CGFloat,index:Int)->CGPoint {
    let angle = (-.pi / 2) + (CGFloat(index) * 2 * .pi / 5)
    return CGPoint(x:center.x+cos(angle)*radius,y:center.y+sin(angle)*radius)
  }
}

struct DeliveryRadarCard:View {
  let snapshot:DeliveryRadarSnapshot
  @Binding var selected:String
  @Binding var showBaseline:Bool
  @State private var explain=false

  var body:some View {
    CompanionMemoryCard {
      Text("表达习惯 · 参考评分").companionFont(17,weight:.semibold)
      if let recent=snapshot.recent {
        Text(recent.label).companionFont(12).foregroundStyle(RecordingFormat.secondary)
          .accessibilityIdentifier("delivery-radar-window-label")
        Text(profileText(recent)).companionFont(12).foregroundStyle(RecordingFormat.secondary)
        DeliveryRadarChart(recent:recent,baseline:snapshot.baseline,showBaseline:showBaseline && snapshot.canCompare,selected:$selected)
        if snapshot.canCompare {
          Toggle(isOn:$showBaseline) {Text("与起点对比（评分）").companionFont(13)}
            .tint(Warm.purple).frame(minHeight:44)
            .accessibilityIdentifier("delivery-radar-compare-toggle")
        } else if snapshot.ordered.count > 0 {
          Text("再积累 \(snapshot.sessionsNeededForBaseline) 场，即可与最早三场对比。")
            .companionFont(12).foregroundStyle(RecordingFormat.secondary)
            .accessibilityIdentifier("delivery-radar-baseline-hint")
        }
        Text(recent.points.map {"\($0.axis)有效 \($0.coverage) 场"}.joined(separator:" · "))
          .companionFont(11).foregroundStyle(RecordingFormat.secondary)
          .accessibilityIdentifier("delivery-radar-coverage")
        DisclosureGroup(isExpanded:$explain) {
          Text("各轴为 1–4 参考分（研究稿 v1.0）。半径 = 分数/4，越大表示越符合参考标准，不是原始指标越高越好，也不预测录用或成交。未评分不等于零分。")
            .companionFont(12).foregroundStyle(RecordingFormat.secondary).padding(.top,4)
        } label: {
          Text("关于参考评分").companionFont(12).foregroundStyle(Warm.purple)
        }.accessibilityIdentifier("delivery-radar-explain")
      } else {
        Image(systemName:"waveform.path").font(.system(size:36)).foregroundStyle(Warm.purple.opacity(0.5))
          .frame(maxWidth:.infinity).padding(.vertical,8)
        Text("还没有已认领本人的真实录音指标。完成沟通录音并认领本人声音后，这里会显示参考评分。")
          .companionFont(13).accessibilityIdentifier("delivery-radar-empty")
      }
    }
  }

  private func profileText(_ recent:DeliveryRadarSeries)->String {
    let profile=recent.profile == "interview_general" ? "面试参考规则":"销售参考规则（非融资 pitch）"
    let lang:String={
      switch recent.language {
      case "zh":return "中文";case "en":return "英文";case "mixed":return "中英混说";default:return "语言待识别"
      }
    }()
    return "\(profile) · \(lang)"
  }
}
