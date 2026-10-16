import SwiftUI
import UniformTypeIdentifiers

struct CompanionSection: Decodable {
  var title: String
  var text: String
}
struct CompanionPreparation: Decodable, Identifiable {
  var id: String
  var client: String
  var goal: String
  var scenario: String
  var scheduled_at: String?
  var concerns: String?
  var participants: [String]?
  var evidence_refs: [ProductEvidence]?
  var sections: [CompanionSection]
  var status: String
  var version: Int
  var reference_status: String?
  var workspace_id: String?
  var created_at:String?
}
struct CompanionSnapshot: Decodable {
  var thread: ChatThread
  var preparations: [CompanionPreparation]
  var next_preparation: CompanionPreparation?
}
struct CompanionExpression: Decodable, Identifiable {
  var id: String
  var title: String
  var body: BodyText
  var quote: String?
  var tags: [String]
  var version: Int
  var source_session_id: String?
  var evidence_refs: [ProductEvidence]
  var reference_status: String
  var user_edited: Bool?
  var faq_topic: String?
  var faq_period: String?
  var faq_expires_on: String?
  var faq_history: [CompanionFAQRevision]?
  var edited_at: String?
  var created_at: String?
}
struct CompanionMemorySnapshot: Decodable {
  var expressions: [CompanionExpression]
  var discoveries: [PersonalDiscovery]
  var question_grouping: CompanionQuestionGrouping?
  var delivery: CompanionDelivery?
}
struct CompanionQuestionGroup: Decodable, Identifiable {
  var id: String
  var title: String
  var question: String
  var expression_ids: [String]
  var occurrences: Int
  var recording_count: Int
}
struct CompanionQuestionGrouping: Decodable {
  var groups: [CompanionQuestionGroup]
  var status: String
  var job_id: String?
  var error: String?
}
struct CompanionDelivery: Decodable {
  var recording_count: Int
  var reviewed_count: Int
  var next_step_count: Int
  var speaking_samples: [CompanionSpeakingSample]
}
struct CompanionSpeakingSample: Decodable, Identifiable {
  var id: String
  var title: String
  var date: String
  var speaking_share: Double
}

extension Store {
  func reloadCompanion() async throws {
    guard remote else { return }
    let connection = api
    async let state: CompanionSnapshot = connection.call("/v1/companion")
    async let rows: [RecordingRecord] = connection.all("/v1/recordings")
    async let memory: CompanionMemorySnapshot = connection.call("/v1/companion/memory")
    let (snapshot, recordings, memories) = try await (state, rows, memory)
    try Task.checkCancellation()
    guard DeviceRecordingMap.identity(connection) == DeviceRecordingMap.identity(api) else {
      return
    }
    voice.refreshRecoveries(store:self)
    companion = snapshot
    companionRecordings = recordings.filter { $0.fixture != true }
    companionMemory = memories
    // Refresh metadata without resetting the user's selected context.
    try await reloadProjectSpaces()
    if chatThread == nil && !newWorkspacePending {try await restoreWorkspaceSelection()}
    else if !chatControlBusy && !chatLoading && !chatBusy && chatRequest == nil, let id=chatThread?.id {
      try await refreshCompanionChat(id)
    }
  }
}

// Reference HTML supplies the visual proportions; native controls keep voice and accessibility behavior.
enum CompanionStyle {
  static func meetingTime(_ text: String?) -> String {
    guard let date = ProductDate.parse(text ?? "") else { return "时间待定" }
    let calendar = Calendar.current
    let day = calendar.isDateInToday(date) ? "今天" : calendar.isDateInTomorrow(date) ? "明天" : ""
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "HH:mm"
    return day.isEmpty ? ProductDate.display(text) : day + " " + formatter.string(from: date)
  }
  static let line = Color(red: 0.902, green: 0.882, blue: 0.835)
  static let lavenderLine = Color(red: 0.875, green: 0.824, blue: 0.941)
}
struct CompanionType: ViewModifier {
  @ScaledMetric var size: CGFloat
  var weight: Font.Weight
  init(_ size: CGFloat, weight: Font.Weight) {
    _size = ScaledMetric(wrappedValue: size)
    self.weight = weight
  }
  func body(content: Content) -> some View {
    content.font(.system(size: size, weight: weight, design: .rounded))
  }
}
extension View {
  func companionFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
    modifier(CompanionType(size, weight: weight))
  }
  func companionReport(_ title: String) -> some View {
    modifier(CompanionReportStyle(title: title))
  }
}
struct CompanionReportStyle: ViewModifier {
  @EnvironmentObject var store: Store
  @State private var identity = UUID()
  let title: String
  func body(content: Content) -> some View {
    content.background(Warm.paper).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
      .toolbar(.visible, for: .navigationBar)
      .toolbar(.hidden, for: .tabBar)
      .toolbar {
        ToolbarItem(placement: .principal) { Text(title).companionFont(22, weight: .bold) }
      }
      .onAppear { store.recordingNavigation.visibleDetails.insert(identity) }
      .onDisappear { store.recordingNavigation.visibleDetails.remove(identity) }
  }
}

struct CompanionButtonStyle: ButtonStyle {
  var primary = false
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.companionFont(12, weight: .semibold).foregroundStyle(Warm.ink)
      .padding(.horizontal, 12).frame(minHeight: 44)
      .background {
        RoundedRectangle(cornerRadius: 12).fill(primary ? Warm.orange : Warm.white)
          .shadow(
            color: primary ? Color.brown.opacity(0.45) : CompanionStyle.line,
            radius: 0, y: configuration.isPressed ? 0 : 3
          )
          .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(
              primary ? Color.brown.opacity(0.35) : CompanionStyle.line, lineWidth: 1.3))
      }
      .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
  }
}
struct CompanionPanel<Content: View>: View {
  var color: Color = Warm.white
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 10) { content }.frame(
      maxWidth: .infinity, alignment: .leading
    ).padding(16).background(color, in: RoundedRectangle(cornerRadius: 18)).overlay(
      RoundedRectangle(cornerRadius: 18).stroke(
        color == Warm.lavender ? CompanionStyle.lavenderLine : CompanionStyle.line, lineWidth: 1))
  }
}
// Page-local categories use solid surfaces; the root TabView keeps system glass.
struct CompanionTabs: View {
  let values: [String]
  @Binding var selection: String
  var body: some View {
    HStack(spacing: 0) {
      ForEach(values, id: \.self) { value in
        Button {selection = value} label: {
          Text(value).companionFont(13, weight: .semibold)
            .foregroundStyle(selection == value ? Warm.ink : RecordingFormat.secondary)
            .frame(maxWidth: .infinity).frame(minHeight: 44)
            .background {
              RoundedRectangle(cornerRadius:10).fill(selection == value ? Warm.white : .clear)
                .shadow(color:selection == value ? CompanionStyle.line : .clear,radius:0,y:2)
                .padding(.horizontal,2)
            }
            // Visual gutters stay inside each button: both hit regions meet at the divider.
            // The transparent half has exactly the same interaction region as the selected half.
            .contentShape(.interaction,Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selection == value ? .isSelected : [])
      }
    }.padding(.horizontal,2).padding(.vertical,4).background(
      CompanionStyle.line.opacity(0.55), in: RoundedRectangle(cornerRadius: 13))
      .accessibilityIdentifier("page-content-segments")
  }
}
struct CompanionPageHeader<Trailing: View>: View {
  let title: String
  @ViewBuilder var trailing: Trailing
  var body: some View {
    HStack {
      Text(title).companionFont(23, weight: .bold)
      Spacer()
      trailing
    }.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 12).frame(maxWidth: 700).frame(
      maxWidth: .infinity)
  }
}
struct CompanionQuickActions: View {
  let hasRecording: Bool
  var prepare: () -> Void
  var review: () -> Void
  var body: some View {
    HStack(spacing: 8) {
      Button(action: prepare) { Label("准备客户", systemImage: "scope").frame(maxWidth: .infinity) }
      Button(action: review) {
        Label(hasRecording ? "复盘上一场" : "用录音豆录音", systemImage: hasRecording ? "headphones" : "mic")
          .frame(maxWidth: .infinity)
      }
    }.buttonStyle(CompanionButtonStyle())
  }
}
/// The dashboard stays in place; each customer opens a separate, stateful conversation page.
struct CompanionHome: View {
  @EnvironmentObject var store: Store
  let onSettings: () -> Void
  @State private var chat = false
  @State private var focusChat = false
  @State private var device = false
  @State private var issue: String?
  @State private var sort = CustomerTrackerSort.activity
  @State private var preparationIndex = 0
  @FocusState private var focused: Bool
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var expandedLayout:Bool {typeSize >= .xLarge}
  private var packs: [CompanionPreparation] { CustomerWorkspacePresentation.preparations(store.companion?.preparations ?? []) }
  private var customers: [ProjectSpace] { CustomerWorkspacePresentation.customers(store.activeProjectSpaces, sort:sort) }
  var body: some View {
    VStack(spacing:0) {
      header
      GeometryReader { geometry in
        if expandedLayout || geometry.size.height < 340 {
          ScrollView { dashboard }
        } else { dashboard }
      }
      CustomerConversationDock(focused:$focused,device:$device,send:send,onWorkspaceSelected:{openChat(focus:store.newWorkspacePending)})
    }.frame(maxWidth:700).frame(maxWidth:.infinity).background(Warm.paper.ignoresSafeArea())
      .toolbar(.hidden,for:.navigationBar)
      .navigationDestination(isPresented:$chat) { CustomerConversationPage(onSettings:onSettings,focusComposer:focusChat) }
      .sheet(isPresented:$device) {NavigationStack {CompanionDeviceGuide().toolbar {Button("返回") {device=false}}}}
      .onChange(of:focused) {_,value in if value {openChat(focus:true)}}
      .onChange(of:store.voice.holding) {_,value in if value {openChat(focus:false)}}
      .onChange(of:store.voice.preview) {_,value in if !value.isEmpty && !store.voice.showContinuous {openChat(focus:false)}}
      .task(id:String(store.remote)+store.base) {
        guard store.remote else{return}
        while !Task.isCancelled {
          do {try await store.reloadCompanion();issue=nil} catch is CancellationError {break}
          catch {issue="暂时无法刷新，请检查网络后重试。"}
          do {try await Task.sleep(for:.seconds(5))} catch {break}
        }
      }
  }
  private var header:some View {
    HStack(spacing:10) {
      Button {} label:{Mascot(size:44)}
        .simultaneousGesture(TapGesture(count:2).onEnded {store.voice.enter(store:store)})
        .accessibilityLabel("Candid 头像").accessibilityIdentifier("candid-avatar")
        .accessibilityAction(named:Text("连续对话")) {store.voice.enter(store:store)}
        .contextMenu {Button("个人与设置",action:onSettings).accessibilityIdentifier("open-settings");NavigationLink("全部准备包") {CompanionPreparationList()}}
      VStack(alignment:.leading,spacing:3) {
        Text("Candid").companionFont(23,weight:.bold).lineLimit(1)
        Text("和你一起，准备下一次").companionFont(11).foregroundStyle(RecordingFormat.secondary).fixedSize(horizontal:false,vertical:true)
      }
      Spacer()
      Button {device=true} label:{Image(systemName:"mic").font(.system(size:17)).frame(width:44,height:44).background(Warm.white,in:Circle()).overlay(Circle().stroke(CompanionStyle.line))}
        .accessibilityLabel("使用安克录音豆录音")
    }.dynamicTypeSize(...DynamicTypeSize.xxxLarge).padding(.horizontal,22).padding(.top,8).padding(.bottom,16)
  }
  private var dashboard:some View {
    VStack(alignment:.leading,spacing:8) {
      RecordingStatusBar(speech:store.speech,device:store.soundcore)
      HStack {Text("会前准备").companionFont(12).foregroundStyle(RecordingFormat.secondary);Spacer();NavigationLink {RoleplaySetup(workspaceID:store.currentProjectSpace?.is_companion==false ? store.currentProjectSpace?.id:nil)} label:{Label("模拟练习",systemImage:"bubble.left.and.bubble.right")}.companionFont(13).foregroundStyle(Warm.purple).frame(minHeight:44).accessibilityIdentifier("roleplay-entry")}
      if let issue {HStack {Text(issue).companionFont(12);Button("重试"){Task {try? await store.reloadCompanion()}}}}
      if packs.isEmpty && customers.isEmpty {
        Spacer(minLength:20)
        VStack(spacing:16) {
          Mascot(size:80)
          Text("下一场沟通，一起准备。").companionFont(22,weight:.bold)
          Text("直接告诉我下一次要见谁，一起开始准备。").companionFont(13).foregroundStyle(RecordingFormat.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth:.infinity)
        Spacer(minLength:25)
      } else {
        if !packs.isEmpty {
          HStack {Spacer();Text("\(min(preparationIndex+1,packs.count)) / \(packs.count)").monospacedDigit()}
            .companionFont(12).foregroundStyle(RecordingFormat.secondary).padding(.bottom,3)
          if expandedLayout {
            CompanionPreparationCard(pack:packs[min(preparationIndex,packs.count-1)])
              .fixedSize(horizontal:false,vertical:true)
              .simultaneousGesture(DragGesture(minimumDistance:30).onEnded {value in
                if abs(value.translation.width)>abs(value.translation.height) {movePreparation(value.translation.width<0 ? 1:-1)}
              }).accessibilityIdentifier("preparation-carousel-expanded")
          } else {
            TabView(selection:$preparationIndex) {
              ForEach(Array(packs.enumerated()),id:\.element.id) {index,pack in
                CompanionPreparationCard(pack:pack).tag(index)
              }
            }.tabViewStyle(.page(indexDisplayMode:.never)).frame(height:165)
              .accessibilityIdentifier("preparation-carousel")
          }
          HStack(spacing:10) {
            Button {movePreparation(-1)} label:{Image(systemName:"chevron.left").frame(width:44,height:44)}.accessibilityLabel("上一份准备包")
            ForEach(0..<min(packs.count,7),id:\.self) {index in
              Capsule().fill(index==preparationIndex ? Warm.purple:Warm.purple.opacity(0.18)).frame(width:index==preparationIndex ? 16:5,height:5).accessibilityHidden(true)
            }
            Button {movePreparation(1)} label:{Image(systemName:"chevron.right").frame(width:44,height:44)}.accessibilityLabel("下一份准备包")
          }.frame(maxWidth:.infinity).frame(height:32)
        }
        if !customers.isEmpty {
          HStack(spacing:7) {
            Text("客户 Tracker").companionFont(13)
            Text(sort.rawValue).companionFont(10).foregroundStyle(RecordingFormat.secondary)
            Spacer()
            Menu {Picker("排序方式",selection:$sort) {ForEach(CustomerTrackerSort.allCases,id:\.self) {Text($0.rawValue).tag($0)}}}
              label:{Image(systemName:"line.3.horizontal.decrease").frame(width:44,height:44)}.accessibilityLabel("客户 Tracker 排序")
          }.foregroundStyle(RecordingFormat.secondary)
          if expandedLayout {trackerRows}
          else {ScrollView {trackerRows}.scrollBounceBehavior(.basedOnSize)}
        }
        Spacer(minLength:0)
      }
    }.padding(.horizontal,22).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
      .onChange(of:packs.map(\.id)) {_,_ in preparationIndex=min(preparationIndex,max(0,packs.count-1))}
  }
  private func movePreparation(_ step:Int) {
    guard !packs.isEmpty else{return}
    withAnimation(reduceMotion ? nil:.easeOut(duration:0.22)) {preparationIndex=(preparationIndex+step+packs.count)%packs.count}
  }
  private var trackerRows:some View {
    VStack(spacing:9) {
      ForEach(customers.prefix(3)) {space in
        Button {Task {await store.selectProjectSpace(space.id);if store.currentProjectSpace?.id==space.id {openChat(focus:false)}}}
          label:{CustomerTrackerRow(space:space)}.buttonStyle(.plain).accessibilityIdentifier("customer-tracker-"+space.id)
      }
    }.padding(.bottom,6)
  }
  private func openChat(focus:Bool) {
    guard !chat else{return}
    if store.currentProjectSpace==nil || store.currentProjectSpace?.is_companion==true {store.beginNewCustomerConversation()}
    focusChat=focus;focused=false;chat=true
  }
  private func send() {openChat(focus:false);store.sendChat(store.chatDraft)}
}

enum CustomerTrackerSort:String,CaseIterable {case activity="最近活跃",sessions="场次最多",name="客户名称"}
enum CustomerWorkspacePresentation {
  static func preparations(_ rows:[CompanionPreparation])->[CompanionPreparation] {
    rows.filter {$0.status=="ready" && $0.reference_status != "superseded"}.sorted {a,b in
      let ad=ProductDate.parse(a.scheduled_at ?? ""),bd=ProductDate.parse(b.scheduled_at ?? "")
      if ad != bd {return (ad ?? .distantPast)>(bd ?? .distantPast)}
      return (a.created_at ?? "",a.version,a.id)>(b.created_at ?? "",b.version,b.id)
    }
  }
  static func customers(_ rows:[ProjectSpace],sort:CustomerTrackerSort)->[ProjectSpace] {
    rows.filter {$0.is_scope_context != true && $0.is_companion != true && ($0.name != "新会话" || $0.message_count>0 || ($0.confirmed_recording_count ?? 0)>0)}.sorted {a,b in
      switch sort {
      case .name:if a.name != b.name {return a.name.localizedStandardCompare(b.name) == .orderedAscending}
      case .sessions:if a.confirmed_recording_count != b.confirmed_recording_count {return (a.confirmed_recording_count ?? 0)>(b.confirmed_recording_count ?? 0)}
      case .activity:break
      }
      return (a.last_active_at ?? a.created_at,a.id)>(b.last_active_at ?? b.created_at,b.id)
    }
  }
  static func stage(_ space:ProjectSpace)->String {
    let labels=["demand":"需求了解","proposal":"方案确认","negotiation":"商务谈判","won":"已达成合作","lost":"已结束","preparing":"开始准备","hr":"HR 沟通","business":"业务面试","final":"终面","offer":"Offer 沟通","closed":"已结束"]
    return labels[space.stage ?? ""] ?? "开始准备"
  }
}
struct CustomerTrackerRow:View {
  let space:ProjectSpace
  private var count:Int {space.confirmed_recording_count ?? 0}
  var body:some View {
    VStack(alignment:.leading,spacing:12) {
      HStack(alignment:.top,spacing:8) {
        Text(space.name+(space.opportunity?.isEmpty==false ? " · "+space.opportunity!:"")).companionFont(14,weight:.semibold).lineLimit(2).multilineTextAlignment(.leading)
        Spacer(minLength:0)
        Text(space.scenario=="interview" ? "面试":"销售").companionFont(10).foregroundStyle(Warm.purple).padding(.horizontal,8).padding(.vertical,4).background(Warm.lavender,in:Capsule())
      }
      HStack(spacing:8) {
        HStack(spacing:4) {ForEach(0..<min(max(count,1),5),id:\.self) {index in Capsule().fill(index==min(max(count,1),5)-1 ? Warm.purple:Color(red:0.36,green:0.5,blue:0.39)).frame(width:18,height:4)}}.accessibilityHidden(true)
        Text(count==0 ? "尚无录音 · 开始准备":"第 \(count) 场 · "+CustomerWorkspacePresentation.stage(space)).companionFont(11).foregroundStyle(RecordingFormat.secondary)
      }
    }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Warm.white,in:RoundedRectangle(cornerRadius:20))
  }
}

struct CustomerConversationPage:View {
  @EnvironmentObject var store:Store
  @Environment(\.dismiss) private var dismiss
  let onSettings:()->Void
  var focusComposer=false
  @FocusState private var focused:Bool
  @State private var device=false
  @State private var editor=false
  @State private var spaces=false
  @State private var navigationIdentity=UUID()
  private var space:ProjectSpace? {store.currentProjectSpace}
  var body:some View {
    VStack(spacing:0) {
      HStack(spacing:8) {
        Button {focused=false;dismiss()} label:{Image(systemName:"chevron.left").font(.title3).frame(width:44,height:44)}.accessibilityLabel("返回首页").accessibilityIdentifier("workspace-back")
        VStack(alignment:.leading,spacing:4) {
          Text(space?.is_companion==true ? "Candid":space?.name ?? "新会话").companionFont(24,weight:.bold).lineLimit(2)
          Text(space == nil ? "准备下一次沟通":(space?.opportunity?.isEmpty==false ? space!.opportunity!:"客户沟通")+" · \(space?.confirmed_recording_count ?? 0) 场沟通").companionFont(12).foregroundStyle(RecordingFormat.secondary)
        }
        Spacer(minLength:0)
        Button {} label:{Mascot(size:34).frame(width:44,height:44)}.simultaneousGesture(TapGesture(count:2).onEnded {startVoice()})
          .accessibilityLabel("Candid 头像").accessibilityIdentifier("workspace-candid-avatar").accessibilityAction(named:Text("连续对话")){startVoice()}
        Menu {
          NavigationLink {RoleplaySetup(workspaceID:space?.id)} label:{Label("模拟这次沟通",systemImage:"bubble.left.and.bubble.right")}
          Button("连续对话",systemImage:"waveform",action:startVoice)
          if space != nil {Button("修改客户信息",systemImage:"pencil"){editor=true}}
          Button("工作区与归档",systemImage:"archivebox"){spaces=true}
          Button("个人与设置",systemImage:"gearshape",action:onSettings)
        } label:{Image(systemName:"ellipsis").frame(width:44,height:44)}.accessibilityLabel("工作区更多操作")
      }.padding(.horizontal,10).padding(.top,8).padding(.bottom,12)
      ScrollView(.horizontal) {
        HStack(spacing:8) {
          if let space,space.is_companion != true {
            NavigationLink {CustomerWorkspaceSessions(space:space)} label:{Label("沟通场次  \(space.confirmed_recording_count ?? 0)",systemImage:"clock")}.accessibilityIdentifier("workspace-sessions")
            NavigationLink {CustomerWorkspaceInfo(space:space)} label:{Label("客户信息",systemImage:"folder")}.accessibilityIdentifier("workspace-info")
          }
          Button(action:startVoice) {Label("连续对话",systemImage:"waveform")}.accessibilityIdentifier("workspace-continuous-voice")
        }.companionFont(12).buttonStyle(CustomerContextButton()).padding(.horizontal,22)
      }.scrollIndicators(.hidden).padding(.bottom,10)
      ChatView(onSettings:onSettings,embedded:true,showsComposer:false)
      CustomerConversationDock(focused:$focused,device:$device,send:{store.sendChat(store.chatDraft)})
    }.frame(maxWidth:700).frame(maxWidth:.infinity).background(Warm.paper.ignoresSafeArea())
      .toolbar(.hidden,for:.navigationBar).toolbar(.hidden,for:.tabBar)
      .onAppear {store.recordingNavigation.visibleDetails.insert(navigationIdentity)}
      .onDisappear {store.recordingNavigation.visibleDetails.remove(navigationIdentity)}
      .task {if focusComposer {focused=true}}
      .onChange(of:store.newWorkspacePending) {_,value in if value {focused=true}}
      .sheet(isPresented:$device) {NavigationStack {CompanionDeviceGuide().toolbar {Button("返回"){device=false}}}}
      .sheet(isPresented:$editor) {if let space {WorkspaceEditor(space:space)}}
      .sheet(isPresented:$spaces) {WorkspaceList()}
  }
  private func startVoice() {focused=false;store.voice.enter(store:store)}
}
struct CustomerContextButton:ButtonStyle {
  func makeBody(configuration:Configuration)->some View {
    configuration.label.padding(.horizontal,12).frame(minHeight:44).background(Warm.ink.opacity(configuration.isPressed ? 0.12:0.055),in:RoundedRectangle(cornerRadius:12))
  }
}
struct CustomerConversationDock:View {
  @EnvironmentObject var store:Store
  var focused:FocusState<Bool>.Binding
  @Binding var device:Bool
  var send:()->Void
  var onWorkspaceSelected:()->Void={}
  @State private var chooser=false
  @Environment(\.dynamicTypeSize) private var typeSize
  private var latest:RecordingRecord? {
    let all=store.companionRecordings.sorted {($0.started_at ?? "",$0.id)>($1.started_at ?? "",$1.id)}
    if let space=store.currentProjectSpace,space.is_companion != true {return all.first {$0.customer_workspace_id==space.id && $0.customer_confirmed_at != nil}}
    return all.first
  }
  var body:some View {
    VStack(spacing:4) {
      SpeechPlaybackBar(speech:store.speech)
      VoiceInputStatus(voice:store.voice)
      VoiceComposer(voice:store.voice,focused:focused,compact:true,inputIdentifier:"home-chat-input",send:send)
      if typeSize.isAccessibilitySize {VStack(alignment:.leading,spacing:0){workspaceButton;recapButton}}
      else {controls}
    }.padding(.horizontal,18).padding(.top,10).padding(.bottom,8).background(Warm.paper)
  }
  private var controls:some View {HStack(spacing:12){workspaceButton;Spacer(minLength:0);recapButton}}
  private var workspaceButton:some View {
    Button {focused.wrappedValue=false;chooser=true} label:{
      HStack(spacing:6){Image(systemName:"folder");Text(store.currentProjectSpace?.is_companion==true ? "新工作区":store.currentProjectSpace?.name ?? "新工作区").lineLimit(1);Image(systemName:"chevron.down").font(.system(size:9,weight:.semibold))}
        .companionFont(12).foregroundStyle(RecordingFormat.secondary).frame(minHeight:44).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityLabel("切换工作区").accessibilityIdentifier("workspace-selector")
      .disabled(store.voice.active || store.chatControlBusy || store.chatLoading)
      .popover(isPresented:$chooser,attachmentAnchor:.rect(.bounds),arrowEdge:.bottom) {CustomerWorkspaceChooser(selected:{chooser=false;onWorkspaceSelected()}).frame(minWidth:280,idealWidth:310,maxWidth:340).presentationCompactAdaptation(.popover)}
  }
  private var recapLabel:some View {Label("复盘上一场",systemImage:"arrow.counterclockwise").companionFont(12,weight:.semibold).padding(.horizontal,12).frame(minHeight:44).foregroundStyle(Warm.purple).background(Warm.lavender.opacity(0.65),in:RoundedRectangle(cornerRadius:12))}
  @ViewBuilder private var recapButton:some View {
    Group {
      if let latest {NavigationLink {CompanionRecordingPage(id:latest.id)} label:{recapLabel}}
      else {Button {focused.wrappedValue=false;device=true} label:{recapLabel}}
    }.buttonStyle(.plain).accessibilityIdentifier("review-last-recording").disabled(store.voice.active || store.chatControlBusy || store.chatLoading)
  }
}
struct CustomerWorkspaceChooser:View {
  @EnvironmentObject var store:Store
  var selected:()->Void
  var choose:((ProjectSpace)->Void)?=nil
  @State private var query=""
  @State private var matches:[ProjectSpace]=[]
  @State private var cursor:String?
  @State private var loading=false
  @State private var error:String?
  @FocusState private var searchFocused:Bool
  var body:some View {
    VStack(alignment:.leading,spacing:10) {
      Text("切换工作区").companionFont(12,weight:.semibold).foregroundStyle(RecordingFormat.secondary)
      TextField("搜索客户",text:$query).textFieldStyle(.roundedBorder).focused($searchFocused).frame(minHeight:44)
        .onTapGesture {searchFocused=true}.accessibilityIdentifier("workspace-search")
      ScrollView {
        LazyVStack(spacing:0) {
          ForEach(matches) {space in Button {if let choose {choose(space);selected()} else {Task {await store.selectProjectSpace(space.id);if store.currentProjectSpace?.id==space.id {selected()}}}} label:{
            HStack {VStack(alignment:.leading,spacing:4){Text(space.name).companionFont(14,weight:.semibold);Text("\(space.confirmed_recording_count ?? 0) 场沟通").companionFont(11).foregroundStyle(RecordingFormat.secondary)};Spacer();if store.currentProjectSpace?.id==space.id {Image(systemName:"checkmark").foregroundStyle(Warm.purple)}}.frame(minHeight:52).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityIdentifier("choose-workspace-"+space.id)}
          if matches.isEmpty && !loading {Text(error ?? "没有找到客户，可新建工作区。").companionFont(12).padding(.vertical,12)}
          if loading {ProgressView().padding()}
          if cursor != nil {Button("加载更多") {Task {await search(more:true)}}.frame(minHeight:44)}
          if error != nil {Button("重试") {Task {await search()}}.frame(minHeight:44)}
        }
      }.frame(height:min(224,max(104,CGFloat(matches.count)*56+(cursor == nil ? 0:44))))
      Divider()
      if choose == nil {Button {store.beginNewCustomerConversation();selected()} label:{Label("新建客户工作区",systemImage:"plus").frame(minHeight:44)}.companionFont(13,weight:.semibold).accessibilityIdentifier("new-customer-workspace")}
    }.padding(16).background(Warm.white).ignoresSafeArea(.keyboard,edges:.bottom)
      .onAppear {searchFocused=true}
      .task(id:query) {do {try await Task.sleep(for:.milliseconds(220));await search()} catch {}}
  }
  private func search(more:Bool=false) async {
    let requested=query;loading=true;error=nil
    defer {if requested==query {loading=false}}
    guard store.remote else {matches=store.activeProjectSpaces.filter {$0.is_scope_context != true && (requested.isEmpty || $0.name.localizedCaseInsensitiveContains(requested))};return}
    do {
      let q=requested.addingPercentEncoding(withAllowedCharacters:.urlQueryAllowed.subtracting(CharacterSet(charactersIn:"&+?=#"))) ?? ""
      let page:Page<ProjectSpace>=try await store.api.call("/v1/project-spaces?customers_only=true&limit=20&q="+q+(more ? "&cursor="+(cursor ?? ""):""))
      try Task.checkCancellation();guard requested==query else{return}
      matches=more ? matches+page.data:page.data;cursor=page.next_cursor
      for space in page.data {if let i=store.projectSpaces.firstIndex(where:{$0.id==space.id}) {store.projectSpaces[i]=space} else {store.projectSpaces.append(space)}}
    } catch is CancellationError {} catch {if requested==query {self.error="工作区暂时无法加载"}}
  }
}
struct CustomerWorkspaceSessions:View {
  @EnvironmentObject var store:Store
  let space:ProjectSpace
  private var records:[RecordingRecord] {store.companionRecordings.filter {$0.customer_workspace_id==space.id && $0.customer_confirmed_at != nil}.sorted {($0.started_at ?? "")>($1.started_at ?? "")}}
  var body:some View {
    ScrollView {VStack(alignment:.leading,spacing:16) {
      Text(space.name+" · 已归档 \(records.count) 场").companionFont(13).foregroundStyle(RecordingFormat.secondary)
      if records.isEmpty {ContentUnavailableView("还没有沟通记录",systemImage:"waveform",description:Text("录音同步后确认客户归属，会出现在这里。"))}
      ForEach(records) {record in NavigationLink {CompanionRecordingPage(id:record.id)} label:{CompanionRecordingRow(record:record)}.buttonStyle(.plain)}
    }.padding(22).frame(maxWidth:700).frame(maxWidth:.infinity)}.companionReport("沟通场次")
  }
}
struct CustomerWorkspaceInfo:View {
  @EnvironmentObject var store:Store
  let space:ProjectSpace
  var body:some View {
    ScrollView {VStack(alignment:.leading,spacing:24) {
      info("当前客户",space.name)
      info("跟进状态",CustomerWorkspacePresentation.stage(space)+" · 已归档 \(space.confirmed_recording_count ?? 0) 场沟通")
      info("沟通目标",space.goal.isEmpty ? "尚未确认，可以在对话中补充。":space.goal)
      if let pack=CustomerWorkspacePresentation.preparations(store.companion?.preparations ?? []).first(where:{$0.workspace_id==space.id}) {info("已记录的顾虑",pack.concerns ?? "尚未确认，可以在对话中补充。")}
      NavigationLink {WorkspaceMaterials(space:space)} label:{Label("可读取的资料",systemImage:"books.vertical").frame(minHeight:44)}
      NavigationLink {CompanionPreparationList(workspaceID:space.id)} label:{Label("客户准备包",systemImage:"doc.text").frame(minHeight:44)}
    }.padding(22).frame(maxWidth:700).frame(maxWidth:.infinity)}.companionReport("客户信息")
  }
  private func info(_ title:String,_ text:String)->some View {VStack(alignment:.leading,spacing:8){Text(title).companionFont(12).foregroundStyle(RecordingFormat.secondary);Text(text).companionFont(16).textSelection(.enabled)}}
}

struct CompanionPreparationCard: View {
  var pack: CompanionPreparation
  var conversation=false
  var body: some View {
    NavigationLink {
      CompanionPreparationPage(id: pack.id)
    } label: {
      CompanionPanel(color: Warm.lavender) {
        if conversation {Text((pack.scenario=="interview" ? "面试准备":"销售沟通")+" · 待开始").companionFont(11).foregroundStyle(Warm.purple)}
        Text(pack.client).companionFont(16, weight: .bold)
        Text(pack.meetingLabel).companionFont(11).foregroundStyle(RecordingFormat.secondary)
        HStack(alignment: .top, spacing: 6) {
          Circle().fill(Warm.purple).frame(width: 6, height: 6).padding(.top, 4)
          Text("准备包已生成 · " + pack.goal).companionFont(11).lineLimit(2)
        }
        HStack {
          Text("查看会前准备包")
          if conversation {Spacer();Image(systemName:"arrow.up.right")}
        }.padding(.horizontal,12).frame(minHeight:44).companionFont(12,weight:.semibold)
        .background {
          RoundedRectangle(cornerRadius: 11).fill(conversation ? Warm.white:Warm.orange)
        }

      }
    }.buttonStyle(.plain).accessibilityIdentifier("preparation-card-" + pack.id)
  }
}
extension CompanionPreparation {
  var meetingLabel: String {
    ([CompanionStyle.meetingTime(scheduled_at)] + (participants ?? [])).joined(separator: " · ")
  }
  var reportSections: [CompanionSection] {
    sections.filter { !["目标", "本次目标", "这次的目标", "准备依据", "资料依据", "来源"].contains($0.title) }
  }
}
struct CompanionPreparationPage: View {
  @EnvironmentObject var store: Store
  let id: String
  @State private var pack: CompanionPreparation?
  @State private var issue: String?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        if let pack {
          Text(pack.meetingLabel).companionFont(12).foregroundStyle(RecordingFormat.secondary)
          Text(pack.client).companionFont(25, weight: .bold)
          if pack.reference_status == "superseded" {
            Text("准备依据已更新，请回到对话重新整理。").foregroundStyle(Warm.purple)
          }
          CompanionPanel(color: Warm.lavender) {
            Text("本次目标").companionFont(12).foregroundStyle(RecordingFormat.secondary)
            Text(pack.goal).companionFont(15, weight: .semibold)
          }
          if let concerns = pack.concerns, !concerns.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Text("重点关注").companionFont(12).foregroundStyle(RecordingFormat.secondary)
              Text(concerns).companionFont(14)
            }
          }
          NavigationLink {RoleplaySetup(workspaceID:pack.workspace_id,preparationID:pack.id)} label:{Label("模拟这一场",systemImage:"mic")}.buttonStyle(CompanionButtonStyle(primary:true))
          Text("沟通建议").companionFont(12).foregroundStyle(RecordingFormat.secondary)
          ForEach(Array(pack.reportSections.enumerated()), id: \.offset) { index, section in
            HStack(alignment: .top, spacing: 12) {
              Text("\(index+1)").companionFont(12, weight: .semibold).frame(width: 25, height: 25)
                .background(CompanionStyle.line.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
              VStack(alignment: .leading, spacing: 10) {
                Text(section.title).companionFont(14, weight: .semibold)
                Text(section.text).companionFont(14).lineSpacing(7).textSelection(.enabled)
              }
            }
          }
          CompanionPanel {
            Text("准备依据").companionFont(12).foregroundStyle(RecordingFormat.secondary)
            ForEach(
              Array(
                pack.sections.filter { ["准备依据", "资料依据", "来源"].contains($0.title) }.enumerated()),
              id: \.offset
            ) { _, section in Text(section.text).companionFont(13) }
            if let refs = pack.evidence_refs, !refs.isEmpty {
              CompanionEvidenceList(refs: refs)
            } else {
              Text("基于本次对话整理；尚未附上可核对的外部资料依据。").companionFont(12).foregroundStyle(
                RecordingFormat.secondary)
            }
          }
        } else if let issue {
          Text(issue)
          Button("重试") { Task { await load() } }
        } else {
          ProgressView()
        }
      }.padding(18).frame(maxWidth: 700).frame(maxWidth: .infinity)
    }.companionReport("会前准备包").task { await load() }
  }
  private func load() async {
    if !store.remote {
      pack = store.companion?.preparations.first { $0.id == id }
      return
    }
    do {
      pack = try await store.api.call("/v1/companion/preparations/" + id)
      issue = nil
    } catch { issue = error.localizedDescription }
  }
}
struct CompanionPreparationList: View {
  @EnvironmentObject var store: Store
  var workspaceID:String?=nil
  private var rows:[CompanionPreparation] {(store.companion?.preparations ?? []).filter {workspaceID==nil || $0.workspace_id==workspaceID}}
  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        if rows.isEmpty {
          ContentUnavailableView(
            "还没有准备包", systemImage: "doc.text", description: Text("在 Candid 对话中说说下一次要见谁。"))
        }
        ForEach(rows) { p in
          VStack(alignment: .leading) {
            CompanionPreparationCard(pack: p)
            Text(
              p.status == "completed"
                ? "本场已结束"
                : p.reference_status == "superseded"
                  ? "依据已更新，请重新整理"
                  : (ProductDate.parse(p.scheduled_at ?? "") ?? .distantFuture) < Date()
                    ? "计划时间已过，请核对场次状态" : "准备就绪"
            ).font(.caption).foregroundStyle(RecordingFormat.secondary)
            if p.status == "ready" {
              Button("本场已经结束") {
                Task {
                  await store.perform {
                    _ = try await store.api.raw(
                      "/v1/companion/preparations/" + p.id + "/complete", method: "POST",
                      body: ["expected_version": p.version])
                    try await store.reloadCompanion()
                  }
                }
              }.frame(minHeight: 44)
            }
          }
        }.padding(22)
      }
    }.background(Warm.paper).navigationTitle("全部准备包")
  }
}

/// Tags describe a recording; this explicit primary association controls customer history.
struct RecordingCustomerAssignment:View {
  @EnvironmentObject var store:Store
  let record:RecordingRecord
  var onSaved:(RecordingRecord)->Void
  @State private var selected:ProjectSpace?
  @State private var choosing=false
  @State private var saving=false
  @State private var error:String?
  private var confirmed:ProjectSpace? {store.projectSpaces.first {$0.id==record.customer_workspace_id}}
  private var suggestion:ProjectSpace? {
    let tags=record.tags ?? []
    return store.activeProjectSpaces.first {space in space.is_scope_context != true && tags.contains {$0.active && ($0.workspace_id==space.id || $0.label==space.name)}}
  }
  var body:some View {
    VStack(alignment:.leading,spacing:8) {
      if record.customer_confirmed_at != nil {
        Label("主要客户 · "+(confirmed?.name ?? "已确认客户"),systemImage:"folder.badge.checkmark").companionFont(12).foregroundStyle(Warm.purple)
      } else {
        Text("确认这场录音的客户").companionFont(14,weight:.semibold)
        Text("确认后计入该客户的沟通场次，复盘会回到对应对话。标签仍可有多个，也可以稍后再确认。").companionFont(12).foregroundStyle(RecordingFormat.secondary).fixedSize(horizontal:false,vertical:true)
        HStack(spacing:8) {
          Button {choosing=true} label:{Label((selected ?? suggestion)?.name ?? "选择客户",systemImage:"folder").lineLimit(2).frame(minHeight:44)}
            .accessibilityIdentifier("recording-customer-choose")
            .popover(isPresented:$choosing,attachmentAnchor:.rect(.bounds),arrowEdge:.bottom) {
              CustomerWorkspaceChooser(selected:{choosing=false},choose:{selected=$0}).frame(width:310).presentationCompactAdaptation(.popover)
            }
          Spacer(minLength:0)
          Button(saving ? "正在保存…":"确认归属") {Task {await confirm()}}
            .companionFont(12,weight:.semibold).frame(minHeight:44).padding(.horizontal,12).background(Warm.lavender,in:RoundedRectangle(cornerRadius:12))
            .disabled((selected ?? suggestion)==nil || saving || !store.remote).accessibilityIdentifier("recording-customer-confirm")
        }
        if selected==nil && suggestion != nil {Text("根据录音标签建议，尚未确认").companionFont(11).foregroundStyle(RecordingFormat.secondary)}
        if let error {Text(error).companionFont(12).foregroundStyle(.red)}
      }
    }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Warm.white,in:RoundedRectangle(cornerRadius:16))
  }
  private func confirm() async {
    guard let space=selected ?? suggestion,!saving else{return}
    saving=true;error=nil;defer {saving=false}
    do {
      let updated:RecordingRecord=try await store.api.call("/v1/recordings/"+record.id+"/customer",method:"PUT",body:["workspace_id":space.id,"expected_revision":record.customer_assignment_revision ?? 0])
      onSaved(updated);try await store.reloadCompanion()
    } catch {self.error="归属暂未保存，请重试。"+error.localizedDescription}
  }
}

struct CompanionRecordingRow: View {
  let record: RecordingRecord
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "mic").font(.system(size: 16, weight: .regular)).foregroundStyle(
        Warm.purple
      ).frame(width: 32, height: 34).background(
        Warm.lavender, in: RoundedRectangle(cornerRadius: 11))
      VStack(alignment: .leading, spacing: 4) {
        Text(RecordingFormat.title(record)).companionFont(13, weight: .semibold).lineLimit(1)
        Text(
          RecordingFormat.timestamp(record) + " · "
            + RecordingFormat.clock((record.duration_ms ?? 0) / 1000) + " · "
            + (record.pipeline_status == "done" ? "已复盘" : RecordingFormat.status(record))
        ).companionFont(10).foregroundStyle(RecordingFormat.secondary)
        if record.customer_confirmed_at==nil {Text("待确认主要客户").companionFont(11).foregroundStyle(Warm.purple)}
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(
        RecordingFormat.secondary)
    }.padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
      .background(Warm.white, in: RoundedRectangle(cornerRadius: 16))
  }
}
struct CompanionDeviceGuide: View {
  @EnvironmentObject var store: Store
  @State private var connect = false
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        Mascot(size: 110)
        Text("用安克录音豆，\n记录下一场沟通。").font(.title.bold()).multilineTextAlignment(.center)
        Text("录音同步后会自动整理复盘，\n确认客户后，结果会回到对应工作区。").multilineTextAlignment(.center).foregroundStyle(
          RecordingFormat.secondary)
        WarmCard {
          Label("安克录音豆", systemImage: "mic").font(.headline)
          Text(store.soundcore.connected == nil ? "尚未连接" : "已连接")
          Button("连接与同步") { connect = true }.buttonStyle(RecordingPrimary())
        }
        Button("手机会议录音（备用）") {
          dismiss()
          store.recordingNavigation.newMeeting = true
          store.recordingNavigation.showRecorder = true
        }.font(.subheadline).frame(minHeight: 44).accessibilityIdentifier(
          "phone-recording-fallback")
      }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
    }.background(Warm.paper).navigationTitle("录音设备").navigationBarTitleDisplayMode(.inline).sheet(
      isPresented: $connect
    ) { NavigationStack { if store.soundcore.connected == nil { SoundcoreDeviceView(device: store.soundcore) } else { RecordingDeviceLibrary(speech: store.speech, device: store.soundcore) } } }
  }
}
struct CompanionRecordings: View {
  @EnvironmentObject var store: Store
  @State private var device = false
  var body: some View {
    VStack(spacing: 0) {
      CompanionPageHeader(title: "录音") {
        Button {
          device = true
        } label: {
          Image(systemName: "mic").font(.system(size: 17)).frame(width: 40, height: 40).background(
            Warm.white, in: Circle()
          )
          .overlay(Circle().stroke(CompanionStyle.line))
        }.frame(minWidth: 44, minHeight: 44).accessibilityLabel("录音设备")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if store.companionRecordings.isEmpty {
            VStack(spacing: 20) {
              Mascot(size: 105)
              Text("第一场经验，从这里留下。").companionFont(20, weight: .bold)
              Text("请使用安克录音豆录音。\n同步后，你的录音会出现在这里。").companionFont(13).foregroundStyle(
                RecordingFormat.secondary
              ).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(.top, 130).padding(.bottom, 36)
          } else {
            Text("过往沟通").companionFont(12).foregroundStyle(RecordingFormat.secondary)
            ForEach(store.companionRecordings) { r in
              NavigationLink {
                CompanionRecordingPage(id: r.id)
              } label: {
                CompanionRecordingRow(record: r)
              }.buttonStyle(.plain)
            }
          }
          Button("手机会议录音（备用）") {
            store.recordingNavigation.newMeeting = true
            store.recordingNavigation.showRecorder = true
          }.frame(minHeight: 44).companionFont(12).accessibilityIdentifier(
            "phone-recording-fallback")
        }.padding(18).frame(maxWidth: 700).frame(maxWidth: .infinity)
      }
    }.background(Warm.paper).toolbar(.hidden, for: .navigationBar).sheet(isPresented: $device) {
      NavigationStack { CompanionDeviceGuide().toolbar { Button("返回") { device = false } } }
    }.refreshable { try? await store.reloadCompanion() }
  }
}

/// Questions come from actual transcript punctuation, never invented model attributions.
/// Answers remain labelled by their recorded speakers, including unknown speakers.
struct CompanionExchange: Identifiable {
  var question: RecordingSentence
  var following: [RecordingSentence]
  var id: String { question.id }
  static func extract(_ lines: [RecordingSentence]) -> [CompanionExchange] {
    let sorted = lines.sorted { ($0.start_ms, $0.id) < ($1.start_ms, $1.id) }
    let questions = sorted.indices.filter {
      sorted[$0].text.contains("？") || sorted[$0].text.contains("?")
    }
    return questions.enumerated().map { offset, index in
      let end = offset + 1 < questions.count ? questions[offset + 1] : sorted.count
      return CompanionExchange(question: sorted[index], following: Array(sorted[(index + 1)..<end]))
    }
  }
}
struct CompanionSentencePlay: View {
  @EnvironmentObject var store: Store
  let recordID: String
  let line: RecordingSentence
  var selected: Bool {
    store.recordingPlaybackID == recordID && store.recordingPlaybackStartMS == line.start_ms
      && store.recordingPlaybackEndMS == line.end_ms
  }
  var body: some View {
    Button {
      Task {
        await store.perform {
          if selected {
            store.toggleRecordingPlayback()
          } else {
            try await store.playRecording(recordID, startMS: line.start_ms, endMS: line.end_ms)
          }
        }
      }
    } label: {
      Image(systemName: selected && store.recordingPlaybackPlaying ? "pause.fill" : "play.fill")
        .font(.system(size: 12)).foregroundStyle(Warm.purple).frame(width: 30, height: 30)
        .background(Warm.lavender, in: Circle()).frame(width: 44, height: 44)
    }.buttonStyle(.plain).disabled(line.end_ms <= line.start_ms).accessibilityLabel(
      selected && store.recordingPlaybackPlaying ? "暂停这一句" : "播放这一句"
    ).accessibilityIdentifier("play-sentence-" + line.id)
  }
}
struct CompanionAudioPlayer: View {
  @EnvironmentObject var store: Store
  let record: RecordingRecord
  private var active: Bool { store.recordingPlaybackID == record.id }
  private var duration: Int {
    max(record.duration_ms ?? 0, record.segments?.map(\.end_ms).max() ?? 0)
  }
  var body: some View {
    CompanionPanel {
      HStack(spacing: 10) {
        Button {
          Task {
            await store.perform {
              if active && store.recordingPlaybackStartMS == 0
                && store.recordingPlaybackEndMS == duration
              {
                store.toggleRecordingPlayback()
              } else {
                try await store.playRecording(
                  record.id, startMS: 0, endMS: duration > 0 ? duration : nil)
              }
            }
          }
        } label: {
          Image(systemName: active && store.recordingPlaybackPlaying ? "pause.fill" : "play.fill")
            .foregroundStyle(Warm.purple).frame(width: 44, height: 44).background(
              Warm.lavender, in: Circle())
        }.accessibilityLabel(active && store.recordingPlaybackPlaying ? "暂停回听" : "播放录音")
        VStack(alignment: .leading, spacing: 4) {
          Text("录音回放").companionFont(10).foregroundStyle(RecordingFormat.secondary)
          Slider(
            value: Binding(
              get: { active ? Double(store.recordingPlaybackPositionMS) : 0 },
              set: { store.seekRecordingPlayback($0) }),
            in: 0...Double(max(1, active ? store.recordingPlaybackEndMS : duration))
          ).disabled(!active).accessibilityLabel("回听进度")
          HStack {
            Text(RecordingFormat.clock(active ? store.recordingPlaybackPositionMS / 1000 : 0))
            Spacer()
            Text(RecordingFormat.clock(duration / 1000))
          }.companionFont(10).foregroundStyle(RecordingFormat.secondary)
        }
      }
      if active { Button("停止回听") { store.stopPlayback() }.companionFont(11).frame(minHeight: 44) }
    }
  }
}
struct CompanionRecordingPage: View {
  @EnvironmentObject var store: Store
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.verticalSizeClass) private var heightClass
  private var compactHeader:Bool {typeSize.isAccessibilitySize || heightClass == .compact}
  let id: String
  var focusMS: Int? = nil
  @State private var record: RecordingRecord?
  @State private var tab = "复盘"
  @State private var speaker = false
  @State private var edit = false
  @State private var issue: String?
  @State private var initialFocusApplied=false
  @State private var contentLaidOut=false
  private var initialFocusTarget:String? {
    guard let focusMS else {return nil}
    return record?.segments?.first(where:{$0.end_ms>=focusMS})?.id
  }
  var body: some View {
    ScrollViewReader {proxy in
      VStack(spacing:0) {
        if let r=record {
          // Switching a tall transcript to a short review cannot clamp the selector's offset.
          // Header/player/selector are shared; only the selected content scrolls.
          recordingHeader(r)
          ScrollView {
            VStack(alignment:.leading,spacing:18) {
              if compactHeader {recordingMetadata(r)}
              if tab == "复盘" {review(r)} else {transcript(r)}
            }.padding(.horizontal,18).padding(.top,9).padding(.bottom,18)
              .frame(maxWidth:700,alignment:.leading).frame(maxWidth:.infinity,alignment:.top)
              .onGeometryChange(for:CGSize.self) {$0.size} action: {size in
                if size.width>0 && size.height>0 {contentLaidOut=true;focusInitial(proxy)}
              }
          }.onChange(of:initialFocusTarget) {_,_ in
            if contentLaidOut {focusInitial(proxy)}
          }
        } else if let issue {
          VStack(spacing:18) {Text(issue);Button("重试") {Task {await load()}}}
            .frame(maxWidth:.infinity,maxHeight:.infinity)
        } else {ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity)}
      }.ignoresSafeArea(.keyboard,edges:.bottom).companionReport("沟通复盘")
        .task {
          if focusMS != nil {tab = "原文"}
          while !Task.isCancelled {
            await load()
            do {try await Task.sleep(for:.seconds(5))} catch {break}
          }
        }
        .sheet(isPresented:$speaker,onDismiss:{Task {await load()}}) {
          if let record {RecordingSpeakerPicker(record:record)}
        }
        .sheet(isPresented:$edit,onDismiss:{Task {await load()}}) {
          if let record {TranscriptEditor(record:record)}
        }
        .onDisappear {if store.recordingPlaybackID==id {store.stopPlayback()}}
    }
  }
  private func focusInitial(_ proxy:ScrollViewProxy) {
    guard !initialFocusApplied,tab == "原文",let target=initialFocusTarget else {return}
    initialFocusApplied=true
    // A post-layout turn lets the reader register IDs in the nested transcript builder.
    DispatchQueue.main.async {proxy.scrollTo(target,anchor:.center)}
  }
  private func recordingHeader(_ r:RecordingRecord)->some View {
    VStack(alignment:.leading,spacing:18) {
      if !compactHeader {recordingMetadata(r)}
      CompanionTabs(values:["复盘","原文"],selection:$tab)
    }.padding(.horizontal,18).padding(.top,18).padding(.bottom,9)
      .frame(maxWidth:700).frame(maxWidth:.infinity)
  }
  private func recordingMetadata(_ r:RecordingRecord)->some View {
    VStack(alignment:.leading,spacing:18) {
      Text(RecordingFormat.timestamp(r)+" · "+RecordingFormat.clock((r.duration_ms ?? 0)/1000))
        .companionFont(12).foregroundStyle(RecordingFormat.secondary).fixedSize(horizontal:false,vertical:true)
      Text(RecordingFormat.title(r)).companionFont(19,weight:.bold).fixedSize(horizontal:false,vertical:true)
      CompanionAudioPlayer(record:r)
      RecordingCustomerAssignment(record:r,onSaved:{updated in record=updated})
    }
  }
  @ViewBuilder private func transcript(_ r: RecordingRecord) -> some View {
    HStack {
      Button("说话人认领") { speaker = true }
      Spacer()
      Button("修订原文") { edit = true }
    }.companionFont(12).frame(minHeight: 44)
    if let marks=r.marks,!marks.isEmpty {
      ScrollView(.horizontal) {HStack {ForEach(marks) {mark in Button {Task {await store.perform {try await store.playRecording(id,startMS:mark.t_ms)}}} label:{Label(RecordingFormat.clock(mark.t_ms/1000),systemImage:"bookmark.fill").frame(minHeight:44)}}}}.companionFont(12)
    }
    ForEach(r.segments ?? []) { line in sentence(line) }
  }
  private func sentence(_ line: RecordingSentence) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Button {
          speaker = true
        } label: {
          Text(
            RecordingFormat.speakerName(line) + " · " + RecordingFormat.clock(line.start_ms / 1000)
          ).companionFont(11).foregroundStyle(Warm.purple)
        }.frame(minHeight: 44)
        Spacer()
        CompanionSentencePlay(recordID: id, line: line)
      }
      Text(line.text).companionFont(14).lineSpacing(6).textSelection(.enabled)
    }.padding(.horizontal, 14).padding(.bottom, 14).frame(maxWidth: .infinity, alignment: .leading)
      .background(Warm.white, in: RoundedRectangle(cornerRadius: 14)).id(line.id)
  }
  @ViewBuilder private func review(_ r: RecordingRecord) -> some View {
    let stalled = (r.jobs ?? []).filter { ["failed", "interrupted", "cancelled"].contains($0.status) }
    if let value=r.highlights {RecordingHighlightsSection(recordID:id,value:value,onChange:{Task {await load()}})}
    if (r.knowledge ?? []).isEmpty {
      ContentUnavailableView(
        stalled.contains { $0.kind == "recording_knowledge" } ? "复盘整理没有完成" : "正在整理这场沟通",
        systemImage: "sparkles",
        description: Text(stalled.contains { $0.kind == "recording_knowledge" }
          ? "已完成的原文仍可查看。下面只重试失败的步骤。"
          : RecordingFormat.status(r) + "；完成后会给你一条复盘消息。"))
    }
    ForEach(stalled) { job in
      VStack(alignment: .leading, spacing: 8) {
        Text(reviewJobTitle(job.kind)).companionFont(15, weight: .semibold)
        Text(job.error ?? "这一步尚未完成，已有结果会保留。").companionFont(13).foregroundStyle(RecordingFormat.secondary)
        Button("重试这一步") {
          Task {
            await store.perform {
              _ = try await store.api.raw(
                "/v1/business-jobs/" + job.id + "/retry", method: "POST", body: [:])
            }
          }
        }.frame(minHeight: 44)
      }
    }
    ForEach(r.knowledge ?? []) { k in
      CompanionPanel(color: Warm.sage.opacity(0.35)) {
        HStack(spacing: 10) {
          Mascot(size: 42)
          Text(k.title).companionFont(17, weight: .semibold)
        }
        Text(k.text).companionFont(14).lineSpacing(7).textSelection(.enabled)
        reviewList("这次有效的表达", k.review?.strengths ?? [])
        reviewList("建议跟进", k.review?.next_steps ?? [])
        reviewList("仍需核实", k.review?.open_questions ?? [])
        Button("查看原文") { tab = "原文" }.companionFont(12).frame(minHeight: 44)
      }
    }
    let expressions = (store.companionMemory?.expressions ?? []).filter {
      $0.source_session_id == id
    }
    let improve = expressions.filter { $0.tags.contains("需要改善") }
    if !improve.isEmpty {
      Text("下次可以更清楚的 \(improve.count) 个回答").companionFont(16, weight: .semibold)
      ForEach(Array(improve.enumerated()), id: \.element.id) { index, e in
        NavigationLink {
          CompanionExpressionPage(expression: e)
        } label: {
          HStack(alignment: .top, spacing: 12) {
            Text("\(index+1)").companionFont(12, weight: .semibold).frame(width: 26, height: 26)
              .background(Warm.lavender, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
              Text(e.title).companionFont(14, weight: .semibold)
              Text("需要改善 · " + RecordingFormat.clock((e.evidence_refs.first?.start_ms ?? 0) / 1000))
                .companionFont(11).foregroundStyle(RecordingFormat.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption)
          }.frame(minHeight: 56)
        }.buttonStyle(.plain)
      }
    } else {
      ForEach(r.knowledge ?? []) { k in reviewList("下次可以更清楚的", k.review?.improvements ?? []) }
    }
    let reusable = expressions.filter { !$0.tags.contains("需要改善") }
    if !reusable.isEmpty {
      Text("这次值得积累的表达").companionFont(16, weight: .semibold)
      ForEach(reusable) { e in
        NavigationLink {
          CompanionExpressionPage(expression: e)
        } label: {
          CompanionExpressionRow(expression: e)
        }.buttonStyle(.plain)
      }
    }
    let exchanges = CompanionExchange.extract(r.segments ?? [])
    if !exchanges.isEmpty {
      Text("本场全部问答 · \(exchanges.count) 条").companionFont(16, weight: .semibold)
      Text("保留问题与后续原文，姓名以说话人认领为准。").companionFont(12).foregroundStyle(RecordingFormat.secondary)
      ForEach(exchanges) { exchange in
        DisclosureGroup {
          sentence(exchange.question)
          ForEach(exchange.following) { sentence($0) }
        } label: {
          VStack(alignment: .leading, spacing: 5) {
            Text(exchange.question.text).companionFont(14, weight: .semibold)
            Text(
              RecordingFormat.speakerName(exchange.question) + " · "
                + RecordingFormat.clock(exchange.question.start_ms / 1000)
            ).companionFont(11).foregroundStyle(RecordingFormat.secondary)
          }
        }.padding(.vertical, 10)
        Divider()
      }
    }
    Button("查看完整原文") { tab = "原文" }.companionFont(13).frame(minHeight: 44)
  }
  private func reviewJobTitle(_ kind: String) -> String {
    switch kind {
    case "recording_knowledge": return "复盘整理"
    case "recording_marks": return "重点整理"
    case "library_extract": return "问答提取"
    case "transcribe": return "转写"
    case "companion_discovery": return "跨场发现"
    default: return "整理"
    }
  }
  private func load() async {
    guard store.remote else {
      record = store.companionRecordings.first { $0.id == id }
      return
    }
    do {
      record = try await store.api.call("/v1/recordings/" + id)
      issue = nil
    } catch { issue = error.localizedDescription }
  }
  @ViewBuilder private func reviewList(_ title: String, _ rows: [String]) -> some View {
    if !rows.isEmpty {
      Text(title).companionFont(12).foregroundStyle(RecordingFormat.secondary).padding(.top, 8)
      ForEach(Array(rows.enumerated()), id: \.offset) { _, s in
        Text(s).companionFont(14).lineSpacing(6)
      }
    }
  }
}
struct CompanionExpressionRow: View {
  let expression: CompanionExpression
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "bubble.left").foregroundStyle(Warm.purple).frame(width: 40, height: 42)
        .background(Warm.lavender, in: RoundedRectangle(cornerRadius: 12))
      VStack(alignment: .leading, spacing: 5) {
        Text(expression.title).companionFont(14, weight: .semibold)
        Text(
          expression.tags.joined(separator: " · ") + " · "
            + (expression.reference_status == "current" ? "有原文依据" : "依据已更新，待重核")
        ).companionFont(11).foregroundStyle(RecordingFormat.secondary)
        Text(expression.user_edited == true ? "已保留你的讲法" : "建议表达 · 待实战验证").companionFont(11)
          .foregroundStyle(RecordingFormat.secondary)
      }
      Spacer()
      Image(systemName: "chevron.right").font(.caption).foregroundStyle(RecordingFormat.secondary)
    }.padding(.vertical, 14).overlay(alignment: .bottom) { CompanionStyle.line.frame(height: 1) }
  }
}

struct LegacyCompanionMemory: View {
  @EnvironmentObject var store: Store
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var tab = "我"
  @State private var upload = false
  private var expressions: [CompanionExpression] { store.companionMemory?.expressions ?? [] }
  private var discoveries: [PersonalDiscovery] { store.companionMemory?.discoveries ?? [] }
  private var groups: [CompanionQuestionGroup] {
    if let grouped = store.companionMemory?.question_grouping { return grouped.groups }
    return expressions.filter { $0.tags.contains("客户常问") && $0.reference_status == "current" }.map {
      CompanionQuestionGroup(id: $0.id, title: $0.title, question: $0.quote ?? $0.title,
        expression_ids: [$0.id], occurrences: 1, recording_count: 1)
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      CompanionPageHeader(title: "记忆库") {
        Button { upload = true } label: {
          Image(systemName: "plus").frame(width: 40, height: 40)
            .background(Warm.white, in: Circle()).overlay(Circle().stroke(CompanionStyle.line))
        }.frame(minWidth: 44, minHeight: 44).accessibilityLabel("上传资料")
      }
      CompanionTabs(values:["我","FAQ","背景资料"],selection:$tab)
        .padding(.horizontal,18).padding(.vertical,12).frame(maxWidth:700)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if tab == "我" {
            personalOverview
            NavigationLink("表达积累") { ScrollView { VStack(spacing:12) {
              ForEach(expressions) { expression in
                NavigationLink { CompanionExpressionPage(expression:expression) } label: { CompanionExpressionRow(expression:expression) }.buttonStyle(.plain)
              }
            }.padding(18) }.companionReport("表达积累") }
            NavigationLink("全部跨场发现") { CompanionDiscoveryList() }
          }
          else if tab == "FAQ" { CompanionFAQHome(groups:groups, upload: { upload = true }) }
          else {
            Text("你上传的事实依据。回答价格、配置、交期和政策时，请核对资料。").companionFont(12).foregroundStyle(RecordingFormat.secondary)
            documents
            Button("上传文件") { upload = true }.buttonStyle(CompanionButtonStyle(primary:true))
          }
          if let error = store.personalImportError { Text(error).companionFont(13).foregroundStyle(.red) }
          NavigationLink("我的介绍与资料") { PersonalProfilePage() }
            .companionFont(12).frame(minHeight:44)
        }.padding(.horizontal,18).padding(.bottom,24).frame(maxWidth:700).frame(maxWidth:.infinity)
      }
    }.background(Warm.paper).toolbar(.hidden, for: .navigationBar)
      .fileImporter(isPresented:$upload, allowedContentTypes:[.pdf,
        UTType(filenameExtension:"docx") ?? .data, UTType(filenameExtension:"pptx") ?? .data,
        .plainText, UTType(filenameExtension:"md") ?? .plainText], allowsMultipleSelection:true) { result in
          if case .success(let urls) = result { Task { await store.addOnboardingFiles(urls) } }
          else if case .failure(let error) = result, !ImportedDocumentFiles.isCancellation(error) {
            store.personalImportError = error.localizedDescription
          }
        }
      .task {
        while !Task.isCancelled {
          await store.restorePersonalProfile()
          try? await store.reloadCompanion()
          do { try await Task.sleep(for:.seconds(5)) } catch { break }
        }
      }
  }
  private var personalOverview: some View {
    VStack(alignment:.leading,spacing:12) {
      NavigationLink { CompanionDeliveryPage() } label: {
        CompanionMemoryCard {
          HStack {
            Text("表达").companionFont(16,weight:.semibold)
            Spacer()
            Text("查看详情").companionFont(12)
            Image(systemName:"chevron.right").font(.caption)
          }
          HStack(spacing:18) {
            if !typeSize.isAccessibilitySize {
              Image(systemName:"waveform.path").font(.system(size:38,weight:.light))
                .foregroundStyle(Warm.purple).frame(width:86,height:86)
                .background(Warm.lavender,in:RoundedRectangle(cornerRadius:20))
            }
            VStack(alignment:.leading,spacing:7) {
              Text("来自 \(store.companionMemory?.delivery?.recording_count ?? 0) 次有录音的沟通")
                .companionFont(12).foregroundStyle(RecordingFormat.secondary)
              Text((store.companionMemory?.delivery?.recording_count ?? 0) < 3 ? "表达雷达待积累" : "表达评分待校准").companionFont(14,weight:.semibold)
              Text("五个维度，一起了解你的表达习惯").companionFont(12)
                .foregroundStyle(RecordingFormat.secondary).fixedSize(horizontal:false,vertical:true)
            }
          }.padding(.top,6)
        }
      }.buttonStyle(.plain).accessibilityIdentifier("memory-expression-overview")
      LazyVGrid(columns:typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()),GridItem(.flexible())],alignment:.leading,spacing:10) {
        Button { tab = "FAQ" } label: {
          CompanionMemoryCard {
            Text(String(groups.filter { group in
              expressions.contains { group.expression_ids.contains($0.id) && $0.user_edited == true }
            }.count)).companionFont(27,weight:.semibold)
            Text("问题已有我的说法").companionFont(12).foregroundStyle(RecordingFormat.secondary)
          }
        }.buttonStyle(.plain).accessibilityIdentifier("memory-my-answers")
        CompanionMemoryCard {
          Text("\(store.companionMemory?.delivery?.next_step_count ?? 0) / \(store.companionMemory?.delivery?.reviewed_count ?? 0)")
            .companionFont(27,weight:.semibold)
          Text("录音复盘提到了下一步").companionFont(12).foregroundStyle(RecordingFormat.secondary)
        }
      }
      if let first = discoveries.first(where: { $0.reference_status != "superseded" }) {
        discoveryCard(first)
      } else {
        CompanionMemoryCard {
          Label("跨场发现",systemImage:"sparkles").companionFont(15,weight:.semibold)
          Text("多聊几场，再一起看看反复出现的习惯。").companionFont(13)
          Text("至少两场已认领的本人原话，才会形成待核对的发现。")
            .companionFont(12).foregroundStyle(RecordingFormat.secondary)
        }
      }
    }
  }
  private func discoveryCard(_ first: PersonalDiscovery) -> some View {
    NavigationLink { CompanionDiscoveryPage(discovery:first) } label: {
      VStack(alignment:.leading,spacing:10) {
        let count = Set(first.evidence_refs.compactMap(\.session_id)).count
        Text("跨场发现 · 来自 \(count) 场沟通").companionFont(12).opacity(0.85)
        Text(first.title).companionFont(16,weight:.semibold).fixedSize(horizontal:false,vertical:true)
        HStack {
          Text(first.reference_status == "superseded" ? "依据已修订，待重新核对" : first.status == "confirmed" ? "你已确认" : "你确认后才算数")
          Spacer()
          Text("查看依据").fontWeight(.semibold)
          Image(systemName:"chevron.right")
        }.companionFont(12)
      }.padding(16).frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(.white)
        .background(Color(red:0.345,green:0.255,blue:0.753),in:RoundedRectangle(cornerRadius:14))
    }.buttonStyle(.plain)
  }
  @ViewBuilder private var discoveryList: some View {
    if discoveries.isEmpty {
      CompanionMemoryCard {
        Text("还没有跨场发现").companionFont(17,weight:.semibold)
        Text("完成录音复盘、认领自己的原话后，跨场习惯会逐渐出现在这里。").companionFont(13)
      }
    } else {
      ForEach(discoveries) { discoveryCard($0) }
      NavigationLink("查看全部发现与集中确认") { CompanionDiscoveryList() }
        .companionFont(13).frame(minHeight:44)
    }
  }
  @ViewBuilder private var documents: some View {
    if store.personalState.documents.isEmpty {
      Text("还没有长期资料").companionFont(14)
      Button("添加第一份资料") { upload = true }.buttonStyle(CompanionButtonStyle(primary: true))
    }
    ForEach(store.personalState.documents) { item in
      VStack(alignment: .leading, spacing: 6) {
        NavigationLink {
          CompanionDocumentPage(id: item.serverID ?? item.id)
        } label: {
          HStack(spacing: 12) {
            Image(systemName: "doc.text").foregroundStyle(Warm.purple).frame(width: 40, height: 42)
              .background(Warm.lavender, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
              Text(item.title).companionFont(14, weight: .semibold)
              Text(item.statusTitle).companionFont(11).foregroundStyle(RecordingFormat.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption)
          }
        }.buttonStyle(.plain).frame(minHeight: 52)
        if let error = item.error { Text(error).companionFont(12).foregroundStyle(.red) }
        Menu("管理资料") {
          if ["failed", "interrupted", "cancelled", "upload_failed", "local"].contains(item.status)
          {
            Button("重试整理") { Task { await store.retryPersonalDocument(item) } }
          }
          Button("移除资料") { Task { await store.removePersonalDocument(item) } }
        }.companionFont(11).frame(minHeight: 44)
        Divider()
      }
    }
  }
}

struct CompanionMemoryCard<Content:View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment:.leading,spacing:10) { content }
      .frame(maxWidth:.infinity,alignment:.leading).padding(15)
      .background(Warm.white,in:RoundedRectangle(cornerRadius:14))
      .overlay(RoundedRectangle(cornerRadius:14).stroke(CompanionStyle.line))
  }
}

struct CompanionQuestionPage: View {
  @EnvironmentObject var store: Store
  let group: CompanionQuestionGroup
  var body: some View {
    ScrollView {
      VStack(alignment:.leading,spacing:16) {
        Text(group.title).companionFont(25,weight:.bold)
        Text("相似问法与每一次的应对").companionFont(13).foregroundStyle(RecordingFormat.secondary)
        let rows = (store.companionMemory?.expressions ?? []).filter { group.expression_ids.contains($0.id) }
        if rows.isEmpty { Text("来源已更新，请返回记忆库查看最新问题。").companionFont(14) }
        ForEach(rows) { expression in
          CompanionMemoryCard {
            Text(expression.quote ?? expression.title).companionFont(16,weight:.semibold)
            Text(expression.user_edited == true ? "我的说法" : "建议的应对 · 待实战验证")
              .companionFont(12).foregroundStyle(Warm.purple)
            Text(expression.body.text).companionFont(14)
            if expression.reference_status != "current" { Text("来源已修订，待核对").companionFont(12) }
            NavigationLink("查看与修改这次应对") { CompanionExpressionPage(expression:expression) }
              .companionFont(13).frame(minHeight:44)
            ForEach(Array(expression.evidence_refs.enumerated()),id:\.offset) { _, ref in
              if let sid = ref.session_id {
                NavigationLink("回到原文 · "+RecordingFormat.clock((ref.start_ms ?? 0)/1000)) {
                  CompanionRecordingPage(id:sid,focusMS:ref.start_ms)
                }.companionFont(13).frame(minHeight:44)
              }
            }
          }
        }
      }.padding(18).frame(maxWidth:700).frame(maxWidth:.infinity)
    }.companionReport("客户问题")
  }
}

struct CompanionDeliveryPage: View {
  @EnvironmentObject var store: Store
  @State private var selected = "语速"
  private let axes = ["语速","停顿","口头禅","起伏","说话占比"]
  private var delivery: CompanionDelivery? { store.companionMemory?.delivery }
  private var detail: String {
    switch selected {
    case "语速": return "需要剔除静音后计算发音速率。当前转写只有句级时间，中文参考区间也仍待校准。"
    case "停顿": return "需要区分句中停顿与答前思考。当前转写不能可靠区分，暂不评分。"
    case "口头禅": return "转写可能省略「嗯」「啊」等词，需要核对原音后再统计每分钟次数。"
    case "起伏": return "观察片段之间的语速变化。此维度为实验性，暂不生成分数。"
    default: return "以下为已认领说话人的句段时长占比估算。句内静音与重叠说话会影响结果；拜访阶段的参考区间待校准，暂不评分。"
    }
  }
  var body: some View {
    ScrollView {
      VStack(alignment:.leading,spacing:16) {
        Text("表达").companionFont(27,weight:.bold)
        Text("来自 \(delivery?.recording_count ?? 0) 次有录音的沟通")
          .companionFont(13).foregroundStyle(RecordingFormat.secondary)
        CompanionMemoryCard {
          Image(systemName:"waveform.path").font(.system(size:40)).foregroundStyle(Warm.purple)
            .frame(maxWidth:.infinity).padding(.vertical,12)
          Text((delivery?.recording_count ?? 0) < 3 ? "再积累 \(max(0,3-(delivery?.recording_count ?? 0))) 场录音" : "五个维度的评分仍在校准")
            .companionFont(17,weight:.semibold)
          Text("至少 3 场有效测量才能展示最近表现，满 6 场后对照最早 3 场。当前暂无完整的五轴测量数据。")
            .companionFont(13).foregroundStyle(RecordingFormat.secondary)
        }
        LazyVGrid(columns:[GridItem(.adaptive(minimum:95))],spacing:8) {
          ForEach(axes,id:\.self) { axis in
            Button { selected = axis } label: {
              Text(axis).companionFont(13).frame(maxWidth:.infinity,minHeight:44)
                .background(selected == axis ? Warm.lavender : Warm.white,in:RoundedRectangle(cornerRadius:10))
                .overlay(RoundedRectangle(cornerRadius:10).stroke(selected == axis ? Warm.purple : CompanionStyle.line))
            }.buttonStyle(.plain).accessibilityAddTraits(selected == axis ? .isSelected : [])
          }
        }
        CompanionMemoryCard {
          HStack {
            Text(selected).companionFont(17,weight:.semibold)
            Spacer()
            Text(selected == "起伏" ? "实验性" : "待校准").companionFont(12).foregroundStyle(RecordingFormat.secondary)
          }
          Text(detail).companionFont(14).lineSpacing(5)
          if selected == "说话占比" {
            let samples = delivery?.speaking_samples ?? []
            if samples.isEmpty {
              Text("在录音原文中认领自己的声音后，这里会显示时长占比。").companionFont(13)
            }
            ForEach(samples.prefix(3)) { sample in
              NavigationLink { CompanionRecordingPage(id:sample.id) } label: {
                HStack {
                  VStack(alignment:.leading,spacing:4) {
                    Text(sample.title).lineLimit(2)
                    Text(ProductDate.display(sample.date)).foregroundStyle(RecordingFormat.secondary)
                  }
                  Spacer()
                  Text("你 \(sample.speaking_share, specifier:"%.0f")%")
                  Image(systemName:"chevron.right")
                }.companionFont(13).frame(minHeight:52)
              }.buttonStyle(.plain)
            }
          }
        }
        Label("只统计取得录音同意的真实沟通，示例和练习不计入。",systemImage:"info.circle")
          .companionFont(12).foregroundStyle(RecordingFormat.secondary)
      }.padding(18).frame(maxWidth:700).frame(maxWidth:.infinity)
    }.companionReport("表达")
  }
}

struct CompanionDiscoveryList: View {
  @EnvironmentObject var store: Store
  @State private var selected: Set<String> = []
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("跨场综合的新个人结论，集中核对一次。").companionFont(14).foregroundStyle(RecordingFormat.secondary)
        let discoveries = store.companionMemory?.discoveries ?? []
        ForEach(discoveries) { d in
          HStack(alignment: .top) {
            if d.status == "pending" {
              Button {
                if selected.contains(d.id) { selected.remove(d.id) } else { selected.insert(d.id) }
              } label: {
                Image(systemName: selected.contains(d.id) ? "checkmark.circle.fill" : "circle")
                  .frame(width: 44, height: 44)
              }.accessibilityLabel("选择发现：" + d.title).disabled(d.reference_status == "superseded")
            }
            NavigationLink {
              CompanionDiscoveryPage(discovery: d)
            } label: {
              VStack(alignment: .leading, spacing: 7) {
                Text(d.title).companionFont(16, weight: .semibold)
                Text(d.text).companionFont(13).lineLimit(3)
              }
            }.buttonStyle(.plain)
          }
        }
        if !selected.isEmpty {
          Button("确认选中的发现（\(selected.count)）") {
            Task {
              await store.perform {
                _ = try await store.api.raw(
                  "/v1/discoveries/decisions", method: "POST",
                  body: [
                    "items": discoveries.filter { selected.contains($0.id) }.map {
                      ["id": $0.id, "expected_version": $0.version, "status": "confirmed"]
                        as [String: Any]
                    }
                  ])
                selected = []
                try await store.reloadCompanion()
              }
            }
          }.buttonStyle(CompanionButtonStyle(primary: true))
        }
      }.padding(18).frame(maxWidth: 700).frame(maxWidth: .infinity)
    }.companionReport("跨场发现")
  }
}
struct CompanionExpressionPage: View {
  @EnvironmentObject var store: Store
  let expression: CompanionExpression
  @State private var text = ""
  @State private var editing = false
  @State private var version = 0
  @State private var issue: String?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text(expression.tags.joined(separator: " · ")).companionFont(11).foregroundStyle(
          Warm.purple)
        Text(expression.title).companionFont(25, weight: .bold)
        if let quote = expression.quote {
          CompanionPanel {
            Text("当时的原话").companionFont(12).foregroundStyle(RecordingFormat.secondary)
            Text("“" + quote + "”").companionFont(15).lineSpacing(6)
          }
        }
        CompanionPanel(color: Warm.lavender) {
          HStack {
            Text(expression.user_edited == true ? "你保存的表达" : "可以试试这样说").companionFont(
              14, weight: .semibold)
            Spacer()
            Text("待实战验证").companionFont(10)
          }
          if editing {
            TextEditor(text: $text).frame(minHeight: 180).accessibilityLabel("我的表达")
            Button("保存我的说法") { Task { await save() } }.buttonStyle(
              CompanionButtonStyle(primary: true))
          } else {
            Text(text).companionFont(15).lineSpacing(7).textSelection(.enabled)
            Divider()
            Text(
              expression.reference_status == "current" ? "有原文依据；适用条件变化后仍需核对。" : "来源已修订，这版表达需要重新核对。"
            ).companionFont(12).foregroundStyle(RecordingFormat.secondary)
            Button("改成我的说法") { editing = true }.companionFont(13).frame(minHeight: 44)
          }
        }
        if let issue { Text(issue).foregroundStyle(.red) }
        Text("依据与适用范围").companionFont(12).foregroundStyle(RecordingFormat.secondary)
        ForEach(Array(expression.evidence_refs.enumerated()), id: \.offset) { _, ref in
          if let sid = ref.session_id {
            NavigationLink("回到原文 · " + RecordingFormat.clock((ref.start_ms ?? 0) / 1000)) {
              CompanionRecordingPage(id: sid, focusMS: ref.start_ms)
            }.companionFont(13).frame(minHeight: 44)
          }
        }
      }.padding(18).frame(maxWidth: 700).frame(maxWidth: .infinity)
    }.companionReport("表达积累").onAppear {
      if version == 0 {
        text = expression.body.text
        version = expression.version
      }
    }
  }
  private func save() async {
    do {
      let updated: CompanionExpression = try await store.api.call(
        "/v1/companion/expressions/" + expression.id, method: "PATCH",
        body: ["text": text, "expected_version": version])
      version = updated.version
      editing = false
      issue = nil
      try await store.reloadCompanion()
    } catch { issue = error.localizedDescription }
  }
}
struct CompanionDiscoveryPage: View {
  @EnvironmentObject var store: Store
  let discovery: PersonalDiscovery
  @State private var edit = false
  @State private var confirmed = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text(discovery.title).companionFont(27, weight: .bold)
        Text(discovery.status == "confirmed" || confirmed ? "已确认的跨场发现" : "AI 跨场发现 · 待核对").font(.caption)
          .foregroundStyle(Warm.purple)
        CompanionPanel { Text(discovery.text).companionFont(15).lineSpacing(7) }
        if discovery.reference_status == "superseded" {
          Text("依据已修订，请重新核对。").foregroundStyle(Warm.purple)
        }
        Text("一起看看原话").font(.headline)
        CompanionEvidenceList(refs: discovery.evidence_refs)
        if discovery.status == "pending" && !confirmed {
          Text("这条判断准吗？").companionFont(16, weight: .semibold)
          Button("是这样，确认这条发现") {
            Task { await store.perform {
              _ = try await store.api.raw("/v1/discoveries/decisions", method:"POST", body:[
                "items": [["id":discovery.id,"expected_version":discovery.version,"status":"confirmed"] as [String:Any]]
              ])
              confirmed = true
              try await store.reloadCompanion()
            } }
          }.buttonStyle(CompanionButtonStyle(primary:true))
            .disabled(discovery.reference_status == "superseded" || store.busy)
        }
        Button("这条发现不准确，补充说明") { edit = true }.frame(minHeight: 44)
      }.padding(22)
    }.companionReport("跨场发现").sheet(isPresented: $edit) {
      ProductDiscoveryEditor(discovery: discovery)
    }
  }
}

struct CompanionDocumentPage: View {
  struct Document: Decodable {
    var id: String
    var title: String
    var text: String
    var pages: [Page]
  }
  struct Page: Decodable {
    var page: Int
    var text: String
  }
  @EnvironmentObject var store: Store
  let id: String
  @State private var document: Document?
  @State private var issue: String?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        if let d = document {
          Text(d.title).companionFont(25, weight: .bold)
          if d.pages.isEmpty {
            Text(d.text).textSelection(.enabled).lineSpacing(6)
          } else {
            ForEach(d.pages, id: \.page) { p in
              Text("第 \(p.page) 页").font(.headline)
              Text(p.text).textSelection(.enabled).lineSpacing(6)
            }
          }
        } else if let issue {
          Text(issue)
          Button("重试读取") { Task { await load() } }.frame(minHeight: 44)
        } else {
          ProgressView()
        }
      }.padding(22).frame(maxWidth: 700).frame(maxWidth: .infinity)
    }.companionReport("长期资料").task { await load() }
  }
  private func load() async {
    do {
      document = try await store.api.call("/v1/companion/documents/" + id)
      issue = nil
    } catch { issue = error.localizedDescription }
  }
}

struct CompanionEvidenceItem: Decodable, Identifiable {
  var source_id: String
  var title: String
  var text: String
  var trust: String
  var text_truncated: Bool?
  var session_id: String?
  var start_ms: Int?
  var url: String?
  var id: String { source_id }
}
struct CompanionEvidenceList: View {
  struct Response: Decodable { var items: [CompanionEvidenceItem] }
  @EnvironmentObject var store: Store
  let refs: [ProductEvidence]
  @State private var items: [CompanionEvidenceItem] = []
  @State private var issue: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(refs) { ref in
        if let item = items.first(where: { $0.source_id == ref.source_id }) {
          NavigationLink {
            CompanionEvidencePage(item: item)
          } label: {
            Label(
              item.title,
              systemImage: ref.source_id.hasPrefix("document:") ? "doc.text" : "text.quote"
            ).companionFont(13).frame(minHeight: 44)
          }
        } else if let sid = ref.session_id {
          NavigationLink("原文 · " + RecordingFormat.clock((ref.start_ms ?? 0) / 1000)) {
            CompanionRecordingPage(id: sid, focusMS: ref.start_ms)
          }.companionFont(13).frame(minHeight: 44)
        } else {
          Text(issue ?? "正在核对资料依据…").companionFont(12).foregroundStyle(RecordingFormat.secondary)
        }
      }
      if issue != nil {
        Button("重新读取依据") { Task { await load() } }.companionFont(12).frame(minHeight: 44)
      }
    }.task(id: refs.map { $0.source_id + ($0.source_version ?? "") }.joined(separator: "|")) {
      await load()
    }
  }
  private func load() async {
    guard store.remote else {
      issue = "连接后可核对这份资料依据。"
      return
    }
    do {
      var result: [CompanionEvidenceItem] = []
      for offset in stride(from: 0, to: refs.count, by: 24) {
        let batch = refs[offset..<min(offset + 24, refs.count)].map { ref -> [String: Any] in
          var value: [String: Any] = ["source_id": ref.source_id]
          if let version = ref.source_version { value["source_version"] = version }
          return value
        }
        let response: Response = try await store.api.call(
          "/v1/agent/sources/read", method: "POST", body: ["references": batch])
        result += response.items
      }
      items = result
      issue = result.count < refs.count ? "部分依据已更新或不可读取，请回到对话重新整理。" : nil
    } catch { issue = error.localizedDescription }
  }
}
struct CompanionEvidencePage: View {
  let item: CompanionEvidenceItem
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text(item.title).companionFont(25, weight: .bold)
        Text(
          item.trust == "CONFIRMED"
            ? "用户已确认" : item.trust == "INFERRED" ? "AI 整理 · 请结合原文核对" : "原始资料依据"
        ).companionFont(12).foregroundStyle(Warm.purple)
        CompanionPanel { Text(item.text).companionFont(15).lineSpacing(7).textSelection(.enabled) }
        if item.text_truncated == true {
          Text("这里显示相关资料片段，未包含整份文件。").companionFont(12).foregroundStyle(RecordingFormat.secondary)
        }
        if let sid = item.session_id {
          NavigationLink("打开录音原文") { CompanionRecordingPage(id: sid, focusMS: item.start_ms) }
            .frame(minHeight: 44)
        }
        if let value = item.url, let url = URL(string: value),
          ["https", "http"].contains(url.scheme ?? "")
        {
          SwiftUI.Link("打开原始网页", destination: url).frame(minHeight: 44)
        }
      }.padding(18).frame(maxWidth: 700).frame(maxWidth: .infinity)
    }.companionReport("资料依据")
  }
}

#if DEBUG
  extension Store {
    func seedCompanionPreview() {
      func decode<T: Decodable>(_ type: T.Type, _ value: Any) -> T {
        try! JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
      }
      let thread: [String: Any] = [
        "id": "preview-chat", "title": "Candid", "status": "idle", "activity": [],
        "message_count": 0, "updated_at": "2026-10-16T01:00:00Z", "workspace_id": "preview-context",
      ]
      let pack: [String: Any] = [
        "id": "preview-preparation", "client": "华味餐饮 · 商务谈判", "goal": "确认三家门店试点与实施范围",
        "scenario": "sales", "scheduled_at": "2026-10-17T14:00:00+08:00",
        "participants": ["王总（采购）", "李工（IT）"], "concerns": "交付周期与服务范围",
        "sections": [
          ["title": "本次目标", "text": "确认三家门店试点与实施范围。"],
          ["title": "先确认现状与判断标准", "text": "了解当前做法、比较中的方案及最希望解决的问题。"],
          ["title": "围绕目标讲清相关价值", "text": "结合已确认的产品资料说明适用范围；价格和排期保留为待确认项。"],
          ["title": "约定一个明确的下一步", "text": "确认需要补充的资料、负责人和下一次沟通安排。"],
        ], "status": "ready", "version": 1, "reference_status": "current",
      ]
      companion = decode(
        CompanionSnapshot.self,
        ["thread": thread, "preparations": [pack], "next_preparation": pack])
      chatThread = companion?.thread
      projectSpaces = decode([ProjectSpace].self,[["id":"preview-context","name":"Candid","goal":"通用助手","default_thread_id":"preview-chat","version":1,"context_version":1,"status":"active","created_at":"2026-10-16","task_status":"idle","message_count":0,"last_message":"","queued_count":0,"is_scope_context":true,"is_companion":true]])
      // Synthetic, isolated UI acceptance corpus; never loaded for a real account.
      let customerNames=["华味餐饮","晴川零售","南岸门店"]
      let customerSpaces:[[String:Any]]=customerNames.enumerated().map {index,name in
        ["id":"preview-customer-\(index)","name":name,"goal":"确认试点范围与实施安排","default_thread_id":"preview-customer-thread-\(index)","version":1,"context_version":1,"status":"active","created_at":"2026-10-16T0\(3-index):00:00Z","last_active_at":"2026-10-16T0\(3-index):00:00Z","task_status":"idle","message_count":1,"last_message":"继续推进沟通","queued_count":0,"scenario":"sales","stage":["negotiation","proposal","demand"][index],"opportunity":["门店试点","系统替换","合作评估"][index],"confirmed_recording_count":1]
      }
      projectSpaces += decode([ProjectSpace].self,customerSpaces)
      var previewPacks=[pack.merging(["workspace_id":"preview-customer-0","created_at":"2026-10-16T01:00:00Z"]) {_,new in new}]
      for index in 1...2 {
        var item=pack;item["id"]="preview-preparation-\(index)";item["client"]=customerNames[index];item["workspace_id"]="preview-customer-\(index)";item["scheduled_at"]=index==1 ? "2026-10-16T10:00:00+08:00":NSNull();item["created_at"]="2026-10-16T00:00:00Z";previewPacks.append(item)
      }
      companion=decode(CompanionSnapshot.self,["thread":thread,"preparations":previewPacks,"next_preparation":previewPacks[0]])
      if ProcessInfo.processInfo.arguments.contains("-candid-clear-task-hints") {clearChatRecovery()}
      if ProcessInfo.processInfo.arguments.contains("-candid-stopped-chat") {
        chatMessages=decode([ChatMessage].self,[["id":"preview-answer","role":"assistant","content":"先确认客户当前的目标，再讨论方案。","sources":[],"tool_steps":[],"created_at":"","incomplete":true,"task_id":"preview-stopped"]])
        chatTasks=decode([AgentTask].self,[["id":"preview-stopped","thread_id":"preview-chat","turn_id":"preview-turn","status":"cancelled","attempt":1,"tool_steps":[],"input":["content":"帮我准备沟通"]]])
      }

      if ProcessInfo.processInfo.arguments.contains("-candid-stopped-chat") {
        chatThread?.workspace_id="preview-customer-0"
        projectSpaces[1].default_thread_id="preview-chat"
      }
      var longSegments:[[String:Any]]=[]
      for index in 0..<60 {
        var segment:[String:Any]=[:]
        segment["id"]="preview-long-"+String(index)
        segment["text"]="第\(index+1)段沟通记录，先确认服务范围与实施安排。"
        segment["start_ms"]=index*5000;segment["end_ms"]=index*5000+4000
        segment["speaker"]="unknown";segment["speaker_id"]="part0:0"
        longSegments.append(segment)
      }
      companionRecordings = decode(
        [RecordingRecord].self,
        [
          ("preview-a", "华味餐饮 · 产品方案沟通"), ("preview-b", "晴川零售 · 需求了解"),
          ("preview-c", "南岸门店 · 方案讨论"),
        ].map {
          [
            "id": $0.0, "title": $0.1, "pipeline_status": "done",
            "customer_workspace_id":"preview-customer-"+String(["preview-a","preview-b","preview-c"].firstIndex(of:$0.0)!),
            "customer_confirmed_at":"2026-10-16T06:00:00Z","customer_assignment_revision":1,
            "started_at": "2026-10-16T0"+String(6-["preview-a","preview-b","preview-c"].firstIndex(of:$0.0)!)+":00:00Z", "duration_ms": 1_920_000,
            "transcript_revision": 1,
            "segments": ProcessInfo.processInfo.arguments.contains("-candid-long-transcript") ? longSegments : [
              [
                "id": "preview-line", "session_id": $0.0, "text": "请先确认服务范围，再安排三家门店试点。",
                "start_ms": 1000, "end_ms": 4000, "speaker": "unknown", "speaker_id": "part0:0",
              ]
            ],
            "knowledge": [
              [
                "id": "preview-knowledge-" + $0.0, "title": "从价格比较，聊到了落地细节",
                "text": "明确试点范围，接口和实施排期仍待核实。", "review": ["next_steps": ["核实接口与排期，再确认下一次沟通安排。"]],
              ]
            ],
          ] as [String: Any]
        })
      if ProcessInfo.processInfo.arguments.contains("-candid-unassigned-recording") {companionRecordings[0].customer_workspace_id=nil;companionRecordings[0].customer_confirmed_at=nil;companionRecordings[0].customer_assignment_revision=0}
      let ref: [String: Any] = [
        "source_id": "transcript:preview-line", "session_id": "preview-a", "start_ms": 1000,
        "end_ms": 4000,
      ]
      companionMemory = decode(
        CompanionMemorySnapshot.self,
        [
          "expressions": [
            [
              "id": "preview-expression", "title": "为什么比另一家贵？",
              "body": ["text": "先对齐服务与实施范围，再比较价格。"], "quote": "为什么比另一家贵？",
              "tags": ["需要改善", "客户常问"], "version": 1, "source_session_id": "preview-a",
              "evidence_refs": [ref], "reference_status": "current",
            ],
            [
              "id":"preview-expression-b", "title":"为什么报价更高？",
              "body":["text":"可以先对照两份方案包含的服务。"], "quote":"你们的价格怎么比别家高？",
              "tags":["客户常问"], "version":1, "source_session_id":"preview-b",
              "evidence_refs":[["source_id":"transcript:preview-line-b","session_id":"preview-b","start_ms":2000,"end_ms":5000]],
              "reference_status":"current", "user_edited":true
            ]
          ],
          "question_grouping":["status":"ready","groups":[[
            "id":"preview-expression","title":"为什么比另一家贵？","question":"为什么比另一家贵？",
            "expression_ids":["preview-expression","preview-expression-b"],"occurrences":2,"recording_count":2
          ]]],
          "delivery":["recording_count":3,"reviewed_count":3,"next_step_count":2,"speaking_samples":[]],
          "discoveries": [
            [
              "id": "preview-discovery", "title": "客户问价格时，先对齐包含什么。", "text": "先比较服务范围，再继续讨论报价。",
              "status": "pending", "version": 1, "evidence_refs": [ref,
                ["source_id":"transcript:preview-line-b","session_id":"preview-b","start_ms":2000,"end_ms":5000]],
              "reference_status": "current",
            ]
          ],
        ])
    }
  }
#endif
