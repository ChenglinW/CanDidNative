import SwiftUI

struct CompanionFAQRevision: Decodable {
  var text: String
  var period: String?
  var version: Int
  var edited_at: String?
}

enum CompanionFAQ {
  static let topics = ["车型与配置", "价格与保值", "金融与分期", "置换", "交付与售后", "用车场景", "其他"]
  static let icons = ["car", "tag", "creditcard", "arrow.left.arrow.right", "shippingbox", "person.2", "text.bubble"]
  static func rows(_ group: CompanionQuestionGroup, _ expressions: [CompanionExpression]) -> [CompanionExpression] {
    expressions.filter { group.expression_ids.contains($0.id) }
  }
  static func latest(_ rows: [CompanionExpression]) -> CompanionExpression? {
    rows.sorted {
      if ($0.edited_at ?? $0.created_at ?? "") != ($1.edited_at ?? $1.created_at ?? "") { return ($0.edited_at ?? $0.created_at ?? "") > ($1.edited_at ?? $1.created_at ?? "") }
      if $0.user_edited != $1.user_edited { return $0.user_edited == true }
      return $0.id < $1.id
    }.first
  }
  static func topic(_ group: CompanionQuestionGroup, _ row: CompanionExpression?) -> String {
    if let value = row?.faq_topic, topics.contains(value) { return value }
    let text = group.title + group.question
    let keywords = [["车型","配置","续航","燃油","纯电"], ["价格","贵","优惠","保值","报价"], ["金融","首付","贷款","利率","分期"], ["置换","旧车"], ["提车","交付","保养","售后","质保"], ["孩子","家用","场景","空间"]]
    return keywords.enumerated().first(where: { $0.element.contains(where: text.contains) }).map { topics[$0.offset] } ?? "其他"
  }
  static func expired(_ row: CompanionExpression) -> Bool {
    guard let value = row.faq_expires_on, !value.isEmpty else { return false }
    let format = DateFormatter(); format.locale = Locale(identifier:"en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"
    guard let date = format.date(from:value) else { return false }
    return Calendar.current.startOfDay(for:Date()) > date
  }
  static func needsWork(_ row: CompanionExpression?) -> Bool {
    guard let row else { return true }
    return row.reference_status != "current" || expired(row) || (row.user_edited != true && row.tags.contains("需要改善"))
  }
  static func status(_ row: CompanionExpression?) -> String {
    guard let row else { return "待改进" }
    if row.reference_status != "current" { return "依据待核对" }
    if expired(row) { return "已到期" }
    return needsWork(row) ? "待改进" : "还没用过"
  }
  static func reason(_ row: CompanionExpression?) -> String {
    guard let row else { return "尚未整理出可用的说法" }
    if row.reference_status != "current" { return "原文依据已修订，请重新核对" }
    if expired(row) { return "适用时间已结束，请更新说法" }
    return "复盘标记为需要改善，请结合原文打磨"
  }
}

struct CompanionFAQBadge: View {
  var row: CompanionExpression?
  var body: some View {
    Text(CompanionFAQ.status(row)).companionFont(11,weight:.medium)
      .foregroundStyle(CompanionFAQ.needsWork(row) ? Color.brown : Warm.purple)
      .padding(.horizontal,8).padding(.vertical,4)
      .background(CompanionFAQ.needsWork(row) ? Warm.orange.opacity(0.22) : Warm.lavender,in:RoundedRectangle(cornerRadius:8))
  }
}

struct CompanionFAQHome: View {
  @EnvironmentObject var store: Store
  @Environment(\.dynamicTypeSize) private var typeSize
  let groups: [CompanionQuestionGroup]
  var upload: () -> Void
  @State private var search = ""
  @State private var expanded = false
  @State private var mode = "按主题"
  @State private var sort = "被问最多"
  private var expressions: [CompanionExpression] { store.companionMemory?.expressions ?? [] }
  private func current(_ group: CompanionQuestionGroup) -> CompanionExpression? { CompanionFAQ.latest(CompanionFAQ.rows(group,expressions)) }
  private var ordered: [CompanionQuestionGroup] { groups.sorted { $0.occurrences == $1.occurrences ? $0.id < $1.id : $0.occurrences > $1.occurrences } }
  private var improve: [CompanionQuestionGroup] { ordered.filter { CompanionFAQ.needsWork(current($0)) } }
  private var reusable: [CompanionQuestionGroup] {
    let rows = ordered.filter { !CompanionFAQ.needsWork(current($0)) }
    return sort == "最近更新" ? rows.sorted { (current($0)?.edited_at ?? "") > (current($1)?.edited_at ?? "") } : rows
  }
  var body: some View {
    VStack(alignment:.leading,spacing:14) {
      Text("客户常问什么，你怎么答最好。先把答得不好的改好，答得好的留着下次用。")
        .companionFont(12).foregroundStyle(RecordingFormat.secondary)
      HStack {
        Image(systemName:"magnifyingglass").foregroundStyle(RecordingFormat.secondary)
        TextField("搜问题，比如「利率」",text:$search).accessibilityIdentifier("memory-question-search")
        if !search.isEmpty { Button { search = "" } label: { Image(systemName:"xmark.circle.fill") }.accessibilityLabel("清除搜索") }
      }.companionFont(14).padding(14).background(Warm.white,in:RoundedRectangle(cornerRadius:20))
        .overlay(RoundedRectangle(cornerRadius:20).stroke(CompanionStyle.line))
      if let grouping = store.companionMemory?.question_grouping, grouping.status != "ready" {
        Text(["running","queued"].contains(grouping.status) ? "正在整理相似问题，先展示已有条目" : "问题归类尚未完成，现有条目仍可查看")
          .companionFont(12).foregroundStyle(RecordingFormat.secondary)
        if ["failed","interrupted","cancelled"].contains(grouping.status), let id = grouping.job_id {
          Button("重试归类") { Task { await store.perform {
            _ = try await store.api.raw("/v1/business-jobs/"+id+"/retry",method:"POST")
            try await store.reloadCompanion()
          } } }.frame(minHeight:44)
        }
      }
      if !search.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
        let found = ordered.filter { group in
          let key = search.trimmingCharacters(in:.whitespacesAndNewlines)
          return (group.title + group.question).localizedCaseInsensitiveContains(key)
            || CompanionFAQ.rows(group,expressions).contains { $0.body.text.localizedCaseInsensitiveContains(key) }
        }
        Text("找到 \(found.count) 个问题").companionFont(12)
        ForEach(found) { row($0) }
        if found.isEmpty { Text("没有找到相关问题，换个关键词试试。").companionFont(14) }
      } else if groups.isEmpty {
        CompanionFAQCard {
          Text("还没有 FAQ").companionFont(17,weight:.semibold)
          Text("完成录音复盘后，客户提问与有依据的应对会汇集在这里。相似问法会自动归到一起。")
            .companionFont(14).foregroundStyle(RecordingFormat.secondary)
        }
      } else {
        VStack(alignment:.leading,spacing:12) {
          HStack {
            VStack(alignment:.leading,spacing:4) {
              Text("待改进").companionFont(12).foregroundStyle(.brown)
              Text("先把这些问题答好").companionFont(17,weight:.semibold)
            }
            Spacer()
            Text("\(improve.count)").companionFont(30,weight:.semibold).foregroundStyle(.brown)
          }
          if improve.isEmpty { Text("暂时没有待改进的问题").companionFont(13) }
          ForEach(Array((expanded ? improve : Array(improve.prefix(2))))) { group in row(group,reason:true) }
          if !improve.isEmpty {
            Button("补充背景资料",systemImage:"square.and.arrow.up") { upload() }
              .buttonStyle(CompanionButtonStyle(primary:true))
          }
          if improve.count > 2 {
            Button(expanded ? "收起" : "展开全部 \(improve.count) 个") { expanded.toggle() }.frame(minHeight:44).companionFont(13)
          }
        }.padding(16).background(Warm.orange.opacity(0.16),in:RoundedRectangle(cornerRadius:20))
          .overlay(RoundedRectangle(cornerRadius:20).stroke(Warm.orange.opacity(0.45)))
        if let discovery = store.companionMemory?.discoveries.first(where: { $0.reference_status != "superseded" }) {
          NavigationLink { CompanionDiscoveryPage(discovery:discovery) } label: {
            VStack(alignment:.leading,spacing:8) {
              Text("跨场发现 · 查看依据与修正").companionFont(12)
              Text(discovery.title).companionFont(15,weight:.semibold)
              Label("看看这条",systemImage:"chevron.right").companionFont(13)
            }.foregroundStyle(Warm.purple).padding(16).frame(maxWidth:.infinity,alignment:.leading)
              .background(Warm.lavender,in:RoundedRectangle(cornerRadius:20))
          }.buttonStyle(.plain)
        }
        ViewThatFits(in:.horizontal) {
          HStack { reusableTitle; Spacer(); menus }
          VStack(alignment:.leading) { reusableTitle; menus }
        }.padding(.top,8)
        Text("复盘整理的应对和你打磨好的说法。更新后还需要在真实沟通里验证。")
          .companionFont(12).foregroundStyle(RecordingFormat.secondary)
        if mode == "按主题" {
          LazyVGrid(columns:Array(repeating:GridItem(.flexible(),alignment:.top),count:typeSize.isAccessibilitySize ? 1 : 2),spacing:10) {
            ForEach(Array(CompanionFAQ.topics.enumerated()).filter { $0.element != "其他" || reusable.contains { CompanionFAQ.topic($0,current($0)) == "其他" } },id:\.offset) { index, topic in
              let list = reusable.filter { CompanionFAQ.topic($0,current($0)) == topic }
              NavigationLink { CompanionFAQTopicPage(topic:topic,groups:list) } label: {
                CompanionFAQCard {
                  Image(systemName:CompanionFAQ.icons[index]).foregroundStyle(Warm.purple).frame(width:34,height:34)
                    .background(Warm.lavender,in:RoundedRectangle(cornerRadius:10))
                  Text(topic).companionFont(14,weight:.semibold)
                  Text("\(list.count) 个回答").companionFont(12).foregroundStyle(RecordingFormat.secondary)
                  Text(list.first.map { "常被问："+$0.question } ?? "这个主题下的说法还在积累")
                    .companionFont(12).foregroundStyle(RecordingFormat.secondary).lineLimit(2)
                }.frame(maxHeight:.infinity,alignment:.top)
              }.buttonStyle(.plain)
            }
          }
        } else { ForEach(reusable) { row($0) } }
      }
    }
  }
  private var reusableTitle: some View { Text("值得复用的回答  \(reusable.count)").companionFont(17,weight:.semibold) }
  private var menus: some View {
    HStack {
      if mode == "按问题" { Menu(sort) { Picker("排序",selection:$sort) { Text("被问最多").tag("被问最多"); Text("最近更新").tag("最近更新") } } }
      Menu(mode) { Picker("查看方式",selection:$mode) { Text("按主题").tag("按主题"); Text("按问题").tag("按问题") } }
    }.companionFont(12).frame(minHeight:44)
  }
  private func row(_ group: CompanionQuestionGroup, reason: Bool = false) -> some View {
    NavigationLink { CompanionFAQDetail(group:group) } label: {
      CompanionFAQCard {
        Text(group.question).companionFont(14,weight:.semibold).foregroundStyle(Warm.ink)
        HStack {
          Text("被问 \(group.occurrences) 次 · \(group.recording_count) 场沟通").companionFont(11).foregroundStyle(RecordingFormat.secondary)
          Spacer(); CompanionFAQBadge(row:current(group))
        }
        if reason { Text(CompanionFAQ.reason(current(group))).companionFont(12).foregroundStyle(.brown) }
      }
    }.buttonStyle(.plain).accessibilityIdentifier("memory-question-"+group.id)
  }
}

struct CompanionFAQTopicPage: View {
  let topic: String
  let groups: [CompanionQuestionGroup]
  var body: some View {
    ScrollView { VStack(alignment:.leading,spacing:12) {
      Text("\(groups.count) 个值得复用的回答 · 按被问次数排序").companionFont(12)
      if groups.isEmpty { Text("这个主题下还没有可复用的回答。更新好待改进的说法后，会出现在这里。").companionFont(14) }
      ForEach(groups) { group in
        NavigationLink { CompanionFAQDetail(group:group) } label: {
          CompanionFAQCard { Text(group.question).companionFont(15,weight:.semibold); Text("被问 \(group.occurrences) 次").companionFont(12) }
        }.buttonStyle(.plain)
      }
    }.padding(18).frame(maxWidth:700).frame(maxWidth:.infinity) }.companionReport(topic)
  }
}

struct CompanionFAQDetail: View {
  @EnvironmentObject var store: Store
  let group: CompanionQuestionGroup
  @State private var editing = false
  @State private var text = ""
  @State private var period = ""
  @State private var hasExpiry = false
  @State private var expiry = Date()
  @State private var saving = false
  @State private var issue: String?
  @State private var chat = false
  @State private var editVersion = 0
  @State private var editID = ""
  private var rows: [CompanionExpression] { CompanionFAQ.rows(group,store.companionMemory?.expressions ?? []) }
  private var current: CompanionExpression? { CompanionFAQ.latest(rows) }
  var body: some View {
    ScrollView {
      VStack(alignment:.leading,spacing:16) {
        Text(group.question).companionFont(22,weight:.semibold)
        HStack { Text("被问 \(group.occurrences) 次 · \(group.recording_count) 场沟通").companionFont(12); Spacer(); CompanionFAQBadge(row:current) }
        if let row = current {
          HStack {
            Text("主题").foregroundStyle(RecordingFormat.secondary)
            Text(CompanionFAQ.topic(group,row)).foregroundStyle(Warm.purple)
            Menu("改主题") {
              ForEach(CompanionFAQ.topics,id:\.self) { topic in Button(topic) { Task { await update(row,["topic":topic]) } } }
            }.disabled(saving || editing)
          }.companionFont(12).frame(minHeight:44)
          if CompanionFAQ.needsWork(row) {
            CompanionFAQCard {
              Text(CompanionFAQ.reason(row)).companionFont(14).foregroundStyle(.brown)
              Text("更新说法后会移到可复用回答。练习反馈不代表真实沟通效果。").companionFont(12)
              Button("用 Mock 练一练") { Task { await practice(row) } }.buttonStyle(CompanionButtonStyle(primary:true)).disabled(!store.remote || saving || store.chatBusy || store.chatControlBusy)
            }
          }
          HStack { Text("现在的说法").companionFont(13); Spacer(); if !editing { Button("更新") { begin(row) }.frame(minHeight:44) } }
          CompanionFAQCard {
            if editing {
              TextEditor(text:$text).frame(minHeight:150).accessibilityLabel("FAQ 说法")
              TextField("适用时间（可选，如双十一活动）",text:$period).textFieldStyle(.roundedBorder)
              Toggle("设置截止日期",isOn:$hasExpiry)
              if hasExpiry { DatePicker("有效至",selection:$expiry,displayedComponents:.date) }
              HStack {
                Button("保存") { Task { await save(row) } }.buttonStyle(CompanionButtonStyle(primary:true)).disabled(saving || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                Button("取消") { editing = false }.disabled(saving).frame(minHeight:44)
              }
              Text("旧版本会保留在版本记录里。").companionFont(12)
            } else {
              Text(row.user_edited == true ? "你的说法" : "Candid 整理的说法").companionFont(12).foregroundStyle(Warm.purple)
              Text(row.body.text).companionFont(15).lineSpacing(5).textSelection(.enabled)
              if let period = row.faq_period, !period.isEmpty { Text("适用："+period).companionFont(12) }
              if let end = row.faq_expires_on, !end.isEmpty { Text("有效至 "+end).companionFont(12).foregroundStyle(CompanionFAQ.expired(row) ? .red : RecordingFormat.secondary) }
              Text("尚无可验证的使用效果，下一次沟通后再核对。").companionFont(12).foregroundStyle(RecordingFormat.secondary)
            }
          }
          Text("每次原始问法与应对").companionFont(13).foregroundStyle(RecordingFormat.secondary)
          ForEach(rows) { expression in
            CompanionFAQCard {
              Text(expression.quote ?? expression.title).companionFont(14,weight:.semibold)
              if expression.id != row.id { Text(expression.body.text).companionFont(13) }
              NavigationLink("查看与修改这次应对") { CompanionExpressionPage(expression:expression) }.companionFont(13).frame(minHeight:44)
              ForEach(Array(expression.evidence_refs.enumerated()),id:\.offset) { _, ref in
                if let sid = ref.session_id {
                  let recording = store.companionRecordings.first { $0.id == sid }
                  NavigationLink {
                    CompanionRecordingPage(id:sid,focusMS:ref.start_ms)
                  } label: {
                    Label((recording?.title ?? "来源录音")+" · "+RecordingFormat.clock((ref.start_ms ?? 0)/1000),systemImage:"play.circle")
                  }.companionFont(12).frame(minHeight:44)
                }
              }
            }
          }
          if let history = row.faq_history, !history.isEmpty {
            Text("版本记录").companionFont(13)
            ForEach(Array(history.enumerated()),id:\.offset) { _, revision in
              CompanionFAQCard {
                Text("v\(revision.version) · "+ProductDate.display(revision.edited_at)).companionFont(12).foregroundStyle(RecordingFormat.secondary)
                if let period = revision.period, !period.isEmpty { Text(period).companionFont(12) }
                Text(revision.text).companionFont(14)
              }
            }
          }
        } else { Text("问题来源已更新，请返回查看最新列表。").companionFont(14) }
        if let issue { Text(issue).companionFont(13).foregroundStyle(.red) }
      }.padding(18).frame(maxWidth:700).frame(maxWidth:.infinity)
    }.companionReport("FAQ").sheet(isPresented:$chat) { ProductAskSheet() }
  }
  private func begin(_ row: CompanionExpression) {
    text = row.body.text; period = row.faq_period ?? ""; editVersion = row.version; editID = row.id
    let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"
    hasExpiry = !(row.faq_expires_on ?? "").isEmpty
    expiry = format.date(from:row.faq_expires_on ?? "") ?? Date()
    editing = true; issue = nil
  }
  private func save(_ row: CompanionExpression) async {
    guard row.id == editID else { issue = "问题来源已更新，请取消后重新编辑；你的草稿仍保留在这里。"; return }
    let format = DateFormatter(); format.locale = Locale(identifier:"en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"
    await update(row,["text":text.trimmingCharacters(in:.whitespacesAndNewlines),"period":period,"expires_on":hasExpiry ? format.string(from:expiry) : ""],expected:editVersion)
  }
  private func update(_ row: CompanionExpression, _ fields: [String:Any], expected: Int? = nil) async {
    saving = true; defer { saving = false }
    do {
      var body = fields; body["expected_version"] = expected ?? row.version
      let updated: CompanionExpression = try await store.api.call("/v1/companion/faq/"+row.id,method:"PATCH",body:body)
      if let index = store.companionMemory?.expressions.firstIndex(where: { $0.id == updated.id }) { store.companionMemory?.expressions[index] = updated }
      editing = false; issue = nil
    } catch { issue = error.localizedDescription }
  }
  private func practice(_ row: CompanionExpression) async {
    saving = true; defer { saving = false }
    do {
      try await store.openScope(["mode":"personal"])
      store.sendChat("开始一轮明确标记为模拟的 FAQ 练习。请扮演客户，先只问这题，等我回答后给反馈：\(group.question)。参考说法：\(row.body.text)。价格、配置、交期和政策只能使用已上传资料，没有依据就指出缺口。不要把模拟当真实经历或真实客户反馈。")
      chat = true; issue = nil
    } catch { issue = error.localizedDescription }
  }
}


struct CompanionFAQCard<Content:View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment:.leading,spacing:10) { content }
      .frame(maxWidth:.infinity,alignment:.leading).padding(16)
      .background(Warm.white,in:RoundedRectangle(cornerRadius:20))
      .overlay(RoundedRectangle(cornerRadius:20).stroke(CompanionStyle.line))
  }
}
