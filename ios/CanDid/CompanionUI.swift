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
}
struct CompanionMemorySnapshot: Decodable {
  var expressions: [CompanionExpression]
  var discoveries: [PersonalDiscovery]
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
    companion = snapshot
    companionRecordings = recordings.filter { $0.fixture != true }
    companionMemory = memories
    if chatThread?.id != snapshot.thread.id {
      try await reloadProjectSpaces()
      try await loadChat(snapshot.thread.id)
    } else if !chatControlBusy && !chatLoading && !chatBusy && chatRequest == nil {
      try await refreshCompanionChat(snapshot.thread.id)
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
      .toolbar {
        ToolbarItem(placement: .principal) { Text(title).companionFont(22, weight: .bold) }
      }
      .onAppear { store.recordingNavigation.visibleDetails.insert(identity) }
      .onDisappear { store.recordingNavigation.visibleDetails.remove(identity) }
  }
}

// Only appearance preferences live here; switching them never replaces a navigation stack.
enum CompanionAppearance {
  enum Navigation: String { case fullWidth, capsule }
  enum Selection: String { case liquidGlass, classic }
  enum Buttons: String { case original, glass }
  static let defaults: UserDefaults = {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-candid-ui-testing") {
        let identity =
          ProcessInfo.processInfo.environment["CANDID_ONBOARDING_TEST_ID"] ?? UUID().uuidString
        return UserDefaults(suiteName: "candid.appearance.tests." + identity)!
      }
    #endif
    return .standard
  }()
}

/// Apply glass to the complete control, so its label stays above the system lens.
struct CompanionGlassControl: ViewModifier {
  var tint: Color = Warm.white
  var radius: CGFloat = 14
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *), !reduceTransparency, contrast != .increased {
      content.glassEffect(
        .regular.tint(tint).interactive(),
        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    } else {
      content.background(tint, in: RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(CompanionStyle.lavenderLine))
    }
  }
}
struct CompanionGlassGroup<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    if #available(iOS 26.0, *) { GlassEffectContainer(spacing: 8) { content } } else { content }
  }
}
struct CompanionSelection: ViewModifier {
  let selected: Bool
  var classicColor: Color = Warm.lavender
  var radius: CGFloat = 14
  @AppStorage("ui.selection", store: CompanionAppearance.defaults) private var style:
    CompanionAppearance.Selection = .liquidGlass
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *), style == .liquidGlass, !reduceTransparency, contrast != .increased {
      // A stable modifier keeps the foreground label mounted and above the lens.
      // Glass.identity removes only the material, without rebuilding the control.
      // Do not match IDs across whole controls: native morphing also fades their labels.
      content.glassEffect(selected ? .regular.tint(Warm.lavender).interactive() : .identity,
        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    } else {
      content.background {
        if selected { RoundedRectangle(cornerRadius: radius).fill(classicColor) }
      }
    }
  }
}
struct CompanionFloatingSurface: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  var body: some View {
    if reduceTransparency || contrast == .increased {
      Capsule().fill(Warm.white).overlay(Capsule().stroke(CompanionStyle.line))
    } else {
      Capsule().fill(.regularMaterial).overlay(Capsule().strokeBorder(Warm.white.opacity(0.7)))
        .shadow(color: Warm.ink.opacity(0.08), radius: 10, y: 4)
    }
  }
}
struct CompanionButtonStyle: ButtonStyle {
  var primary = false
  @Environment(\.isEnabled) private var enabled
  @AppStorage("ui.buttons", store: CompanionAppearance.defaults) private var style:
    CompanionAppearance.Buttons = .original
  private func label(_ configuration: Configuration) -> some View {
    configuration.label.companionFont(12, weight: .semibold).foregroundStyle(Warm.ink)
      .padding(.horizontal, 12).frame(minHeight: 44)
  }
  func makeBody(configuration: Configuration) -> some View {
    Group {
      if style == .glass {
        label(configuration).modifier(
          CompanionGlassControl(tint: primary ? Warm.orange : Warm.white, radius: 12))
      } else {
        label(configuration).background {
          RoundedRectangle(cornerRadius: 12).fill(primary ? Warm.orange : Warm.white)
            .shadow(
              color: primary ? Color.brown.opacity(0.45) : CompanionStyle.line,
              radius: 0, y: configuration.isPressed ? 0 : 3
            )
            .overlay(
              RoundedRectangle(cornerRadius: 12).stroke(
                primary ? Color.brown.opacity(0.35) : CompanionStyle.line, lineWidth: 1.3))
        }
      }
    }.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
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
struct CompanionTabs: View {
  let values: [String]
  @Binding var selection: String
  var body: some View {
    CompanionGlassGroup {
      HStack(spacing: 4) {
        ForEach(values, id: \.self) { value in
          Button {
            selection = value
          } label: {
            Text(value).companionFont(13, weight: selection == value ? .semibold : .regular)
              .frame(maxWidth: .infinity).frame(minHeight: 44)
              .modifier(
                CompanionSelection(
                  selected: selection == value, classicColor: Warm.white, radius: 10))
          }.buttonStyle(.plain).accessibilityAddTraits(selection == value ? .isSelected : [])
        }
      }
    }.padding(4).background(
      CompanionStyle.line.opacity(0.55), in: RoundedRectangle(cornerRadius: 13))
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
struct CompanionTabBar: View {
  @ObservedObject var navigation: RecordingNavigation
  @AppStorage("ui.navigation", store: CompanionAppearance.defaults) private var style:
    CompanionAppearance.Navigation = .fullWidth
  var body: some View {
    Group {
      if style == .capsule {
        items.padding(6).background { CompanionFloatingSurface() }
          .frame(maxWidth: 420).padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 8)
      } else {
        items.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
          .background(Warm.white.ignoresSafeArea(edges: .bottom))
          .overlay(alignment: .top) { CompanionStyle.line.frame(height: 1) }
      }
    }.frame(maxWidth: .infinity).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
  }
  private var items: some View {
    CompanionGlassGroup {
      HStack(spacing: 0) {
        item(.chat, "Candid", "bubble.left")
        item(.memory, "记忆库", "book")
        item(.recordings, "录音", "mic")
      }
    }
  }
  private func item(_ section: CandidSection, _ title: String, _ symbol: String) -> some View {
    Button {
      // Do not inject this animation into RecordingShell's page opacity transactions.
      navigation.section = section
    } label: {
      VStack(spacing: 4) {
        Image(systemName: symbol).font(.system(size: 20, weight: .regular))
        Text(title).companionFont(10, weight: navigation.section == section ? .semibold : .regular)
          .lineLimit(1).minimumScaleFactor(0.7)
      }.frame(maxWidth: .infinity).frame(minHeight: 52)
        .modifier(
          CompanionSelection(
            selected: navigation.section == section,
            radius: style == .capsule ? 100 : 14)
        )
        .contentShape(Rectangle())
    }.foregroundStyle(navigation.section == section ? Warm.purple : RecordingFormat.secondary)
      .buttonStyle(.plain).accessibilityAddTraits(navigation.section == section ? .isSelected : [])
  }
}

struct CompanionAppearanceSettings: View {
  @AppStorage("ui.navigation", store: CompanionAppearance.defaults) private var navigation:
    CompanionAppearance.Navigation = .fullWidth
  @AppStorage("ui.selection", store: CompanionAppearance.defaults) private var selection:
    CompanionAppearance.Selection = .liquidGlass
  @AppStorage("ui.buttons", store: CompanionAppearance.defaults) private var buttons:
    CompanionAppearance.Buttons = .original
  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 10) {
        Text("底部导航")
        Picker("底部导航", selection: $navigation) {
          Text("全宽底栏").tag(CompanionAppearance.Navigation.fullWidth)
          Text("悬浮胶囊").tag(CompanionAppearance.Navigation.capsule)
        }.pickerStyle(.segmented).accessibilityIdentifier("appearance-navigation")
      }.padding(.vertical, 4)
      VStack(alignment: .leading, spacing: 10) {
        Text("选中效果")
        Picker("选中效果", selection: $selection) {
          Text("液态玻璃").tag(CompanionAppearance.Selection.liquidGlass)
          Text("经典色块").tag(CompanionAppearance.Selection.classic)
        }.pickerStyle(.segmented).accessibilityIdentifier("appearance-selection")
      }.padding(.vertical, 4)
      VStack(alignment: .leading, spacing: 10) {
        Text("按钮质感")
        Picker("按钮质感", selection: $buttons) {
          Text("原版立体").tag(CompanionAppearance.Buttons.original)
          Text("轻盈玻璃").tag(CompanionAppearance.Buttons.glass)
        }.pickerStyle(.segmented).accessibilityIdentifier("appearance-buttons")
        Text("按钮预览").font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 8) {
          Button("准备客户") {}.buttonStyle(CompanionButtonStyle(primary: true))
          Button("复盘上一场") {}.buttonStyle(CompanionButtonStyle())
        }.allowsHitTesting(false).accessibilityHidden(true)
      }.padding(.vertical, 4)
    } header: {
      Text("界面外观")
    } footer: {
      Text("即选即保存。底栏与分类选中效果同步变化；按钮质感用于准备、复盘等快捷操作。iOS 26 以下或开启降低透明度、增强对比度时，玻璃采用清晰的实色外观。")
    }
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
struct CompanionHome: View {
  @EnvironmentObject var store: Store
  let onSettings: () -> Void
  @State private var open = false
  @State private var issue: String?
  @State private var device = false
  @FocusState private var focused: Bool
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private func revealChat(_ value: Bool) {
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { open = value }
    if !value { focused = false }
  }
  private var records: [RecordingRecord] { Array(store.companionRecordings.prefix(3)) }
  private var empty: Bool { store.companion?.next_preparation == nil && records.isEmpty }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Button {
        } label: {
          Mascot(size: 47)
        }.simultaneousGesture(
          TapGesture(count: 2).onEnded {
            focused = false
            store.voice.enter(store: store)
          }
        )
        .accessibilityLabel("Candid 头像").accessibilityIdentifier("candid-avatar")
        .accessibilityAction(named: Text("连续对话")) { store.voice.enter(store: store) }
        .contextMenu {
          Button("个人与设置", action: onSettings).accessibilityIdentifier("open-settings")
          NavigationLink("全部准备包") { CompanionPreparationList() }
        }
        VStack(alignment: .leading, spacing: 2) {
          Text("Candid").companionFont(20, weight: .bold).lineLimit(1).minimumScaleFactor(0.7)
          Text("和你一起，准备下一次").companionFont(11).foregroundStyle(RecordingFormat.secondary)
        }
        Spacer()
        Button {
          focused = false
          store.voice.enter(store: store)
        } label: {
          Image(systemName: "waveform").font(.system(size: 17)).frame(width: 44, height: 44)
        }.accessibilityLabel("连续对话")
        Button {
          focused = false
          device = true
        } label: {
          Image(systemName: "mic").font(.system(size: 17)).frame(width: 40, height: 40).background(
            Warm.white, in: Circle()
          )
          .overlay(Circle().stroke(CompanionStyle.line))
        }.frame(minWidth: 44, minHeight: 44).accessibilityLabel("使用安克录音豆录音")
      }.dynamicTypeSize(...DynamicTypeSize.xxxLarge).padding(.horizontal, 18).padding(.top, 8)
        .padding(.bottom, 10)
      GeometryReader { geometry in
        ZStack(alignment: .bottom) {
          Group {
            if typeSize.isAccessibilitySize || geometry.size.height < 350 {
              ScrollView { backgroundContent }
            } else {
              backgroundContent
            }
          }.opacity(open ? 0 : 1).accessibilityHidden(open)
          ChatView(onSettings: onSettings, embedded: true, showsComposer: false)
            .padding(.top, 44)
            .overlay(alignment: .topTrailing) {
              Button {
                revealChat(false)
              } label: {
                Image(systemName: "chevron.down").font(.system(size: 13)).frame(
                  width: 32, height: 32
                ).background(Warm.white, in: Circle()).overlay(
                  Circle().stroke(CompanionStyle.line.opacity(0.6)))
              }.frame(width: 44, height: 44).padding(.trailing, 12).accessibilityLabel("收起对话")
            }
            .background(Warm.paper).opacity(open ? 1 : 0).allowsHitTesting(open)
            .accessibilityHidden(!open)
            .offset(y: open || reduceMotion ? 0 : geometry.size.height)
            .simultaneousGesture(
              DragGesture(minimumDistance: 45).onEnded { value in
                if value.startLocation.y < 55 && value.translation.height > 65 { revealChat(false) }
              })
        }
      }.clipped()
      dock
    }.frame(maxWidth: 700).frame(maxWidth: .infinity).background(Warm.paper.ignoresSafeArea())
      .toolbar(.hidden, for: .navigationBar)
      .sheet(isPresented: $device) {
        NavigationStack { CompanionDeviceGuide().toolbar { Button("返回") { device = false } } }
      }
      .task(id: String(store.remote) + store.base) {
        guard store.remote else { return }
        while !Task.isCancelled {
          do {
            try await store.reloadCompanion()
            issue = nil
          } catch is CancellationError { break } catch { issue = "暂时无法刷新，请检查网络后重试。" }
          do { try await Task.sleep(for: .seconds(5)) } catch { break }
        }
      }
      .onChange(of: focused) { _, value in if value { revealChat(true) } }
      .onChange(of: store.voice.preview) { _, value in
        if !value.isEmpty && !store.voice.showContinuous { revealChat(true) }
      }
  }
  private var backgroundContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      RecordingStatusBar(speech: store.speech, device: store.soundcore)
      if let issue {
        HStack {
          Text(issue).companionFont(12)
          Button("重试") {
            Task {
              do {
                try await store.reloadCompanion()
                self.issue = nil
              } catch {}
            }
          }
        }
      }
      if empty {
        Spacer(minLength: 25)
        VStack(spacing: 18) {
          Mascot(size: 80)
          Text("下一场沟通，一起准备。").companionFont(22, weight: .bold)
          Text("说说你要见谁，或用录音豆记录一场沟通。").companionFont(13).foregroundStyle(RecordingFormat.secondary)
            .multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
        Spacer(minLength: 30)
      } else {
        if let pack = store.companion?.next_preparation {
          HStack {
            Text("下一场")
            Spacer()
            NavigationLink("全部准备包") { CompanionPreparationList() }
          }.companionFont(11).foregroundStyle(RecordingFormat.secondary).padding(.top, 10)
          CompanionPreparationCard(pack: pack)
        }
        if !records.isEmpty {
          HStack {
            Text("最近项目")
            Spacer()
            Button("全部录音 →") { store.recordingNavigation.section = .recordings }.foregroundStyle(
              Warm.purple)
          }.companionFont(12).foregroundStyle(RecordingFormat.secondary).frame(minHeight: 26)
            .padding(.top, 2)
          ForEach(records) { r in
            NavigationLink {
              CompanionRecordingPage(id: r.id)
            } label: {
              CompanionRecordingRow(record: r)
            }.buttonStyle(.plain)
          }
        }
        Spacer(minLength: 0)
      }
    }.padding(.horizontal, 18).frame(
      maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
  private func send(_ text: String? = nil) {
    let value = (text ?? store.chatDraft).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    revealChat(true)
    if store.remote { store.sendChat(value) } else { store.saveChatDraft(value) }
    focused = false
  }
  private var dock: some View {
    VStack(spacing: 10) {
      CompanionQuickActions(
        hasRecording: !records.isEmpty, prepare: { send("帮我准备下一场沟通。") },
        review: {
          if let last = records.first {
            send("帮我复盘录音「" + RecordingFormat.title(last) + "」，结合这场原文看看下次可以怎么说。")
          } else {
            focused = false
            device = true
          }
        })
      VoiceComposer(
        voice: store.voice, focused: $focused, compact: true, inputIdentifier: "home-chat-input",
        send: { send() })
      VoiceInputStatus(voice: store.voice)
    }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 12).background(Warm.paper)
      .overlay(alignment: .top) { CompanionStyle.line.opacity(0.6).frame(height: 1) }
  }
}

struct CompanionPreparationCard: View {
  var pack: CompanionPreparation
  var body: some View {
    NavigationLink {
      CompanionPreparationPage(id: pack.id)
    } label: {
      CompanionPanel(color: Warm.lavender) {
        Text(pack.client).companionFont(16, weight: .bold)
        Text(pack.meetingLabel).companionFont(11).foregroundStyle(RecordingFormat.secondary)
        HStack(alignment: .top, spacing: 6) {
          Circle().fill(Warm.purple).frame(width: 6, height: 6).padding(.top, 4)
          Text("准备包已生成 · " + pack.goal).companionFont(11).lineLimit(2)
        }
        Text("查看会前准备包").padding(.horizontal, 12).frame(minHeight: 36).companionFont(
          12, weight: .semibold
        )
        .background {
          RoundedRectangle(cornerRadius: 11).fill(Warm.orange).shadow(
            color: Color.brown.opacity(0.4), radius: 0, y: 3
          ).overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.brown.opacity(0.35)))
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
  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        if (store.companion?.preparations ?? []).isEmpty {
          ContentUnavailableView(
            "还没有准备包", systemImage: "doc.text", description: Text("在 Candid 对话中说说下一次要见谁。"))
        }
        ForEach(store.companion?.preparations ?? []) { p in
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
        Text("录音同步后，会自动整理复盘，\n再把结果带回 Candid 对话。").multilineTextAlignment(.center).foregroundStyle(
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
    ) { NavigationStack { RecordingDeviceLibrary(speech: store.speech, device: store.soundcore) } }
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
  let id: String
  var focusMS: Int? = nil
  @State private var record: RecordingRecord?
  @State private var tab = "复盘"
  @State private var speaker = false
  @State private var edit = false
  @State private var issue: String?
  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if let r = record {
            Text(
              RecordingFormat.timestamp(r) + " · "
                + RecordingFormat.clock((r.duration_ms ?? 0) / 1000)
            ).companionFont(12).foregroundStyle(RecordingFormat.secondary)
            Text(RecordingFormat.title(r)).companionFont(19, weight: .bold)
            CompanionAudioPlayer(record: r)
            CompanionTabs(values: ["复盘", "原文"], selection: $tab)
            if tab == "复盘" { review(r) } else { transcript(r) }
          } else if let issue {
            Text(issue)
            Button("重试") { Task { await load() } }
          } else {
            ProgressView()
          }
        }.padding(18).frame(maxWidth: 700).frame(maxWidth: .infinity)
      }.companionReport("沟通复盘")
        .task {
          if focusMS != nil { tab = "原文" }
          while !Task.isCancelled {
            await load()
            if let focusMS, let s = record?.segments?.first(where: { $0.end_ms >= focusMS }) {
              proxy.scrollTo(s.id, anchor: .center)
            }
            do { try await Task.sleep(for: .seconds(5)) } catch { break }
          }
        }
        .sheet(isPresented: $speaker, onDismiss: { Task { await load() } }) {
          if let record { RecordingSpeakerPicker(record: record) }
        }
        .sheet(isPresented: $edit, onDismiss: { Task { await load() } }) {
          if let record { TranscriptEditor(record: record) }
        }
        .onDisappear { if store.recordingPlaybackID == id { store.stopPlayback() } }
    }
  }
  @ViewBuilder private func transcript(_ r: RecordingRecord) -> some View {
    HStack {
      Button("说话人认领") { speaker = true }
      Spacer()
      Button("修订原文") { edit = true }
    }.companionFont(12).frame(minHeight: 44)
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
    if (r.knowledge ?? []).isEmpty {
      ContentUnavailableView(
        "正在整理这场沟通", systemImage: "sparkles",
        description: Text(RecordingFormat.status(r) + "；完成后会给你一条复盘消息。"))
      ForEach((r.jobs ?? []).filter { ["failed", "interrupted", "cancelled"].contains($0.status) })
      { job in
        Text(job.error ?? "整理尚未完成")
        Button("重试整理") {
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

struct CompanionMemory: View {
  @EnvironmentObject var store: Store
  @State private var tab = "长期资料"
  @State private var filter = "全部"
  @State private var upload = false
  private var hasContent: Bool {
    !store.personalState.documents.isEmpty || !store.companionRecordings.isEmpty
      || !(store.companionMemory?.expressions.isEmpty ?? true)
      || !(store.companionMemory?.discoveries.isEmpty ?? true)
  }
  var body: some View {
    VStack(spacing: 0) {
      CompanionPageHeader(title: "记忆库") {
        Button {
          upload = true
        } label: {
          Image(systemName: "plus").frame(width: 40, height: 40).background(
            Warm.white, in: Circle()
          ).overlay(Circle().stroke(CompanionStyle.line))
        }.frame(minWidth: 44, minHeight: 44).accessibilityLabel("上传资料")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if hasContent {
            Text("你的资料与沟通积累").companionFont(12).foregroundStyle(RecordingFormat.secondary)
            if let first = store.companionMemory?.discoveries.first { discoveryCard(first) }
            CompanionTabs(values: ["长期资料", "表达积累"], selection: $tab)
            if tab == "长期资料" { documents } else { expressions }
          } else {
            emptyState
          }
          if !(store.companionMemory?.discoveries.isEmpty ?? true) {
            NavigationLink("查看全部发现与集中确认") { CompanionDiscoveryList() }.companionFont(12).frame(
              minHeight: 44)
          }
          if let error = store.personalImportError {
            Text(error).companionFont(13).foregroundStyle(.red)
          }
          NavigationLink("我的介绍与资料") { PersonalProfilePage() }.companionFont(12).frame(minHeight: 44)
        }.padding(18).frame(maxWidth: 700).frame(maxWidth: .infinity)
      }
    }.background(Warm.paper).toolbar(.hidden, for: .navigationBar)
      .fileImporter(
        isPresented: $upload,
        allowedContentTypes: [
          .pdf, UTType(filenameExtension: "docx") ?? .data,
          UTType(filenameExtension: "pptx") ?? .data, .plainText,
          UTType(filenameExtension: "md") ?? .plainText,
        ], allowsMultipleSelection: true
      ) { result in
        if case .success(let urls) = result {
          Task { await store.addOnboardingFiles(urls) }
        } else if case .failure(let error) = result, !ImportedDocumentFiles.isCancellation(error) {
          store.personalImportError = error.localizedDescription
        }
      }
      .task {
        while !Task.isCancelled {
          await store.restorePersonalProfile()
          try? await store.reloadCompanion()
          do { try await Task.sleep(for: .seconds(5)) } catch { break }
        }
      }
  }
  private var emptyState: some View {
    VStack(spacing: 18) {
      Mascot(size: 105).frame(maxWidth: .infinity, alignment: .leading)
      Text("把你的经验，慢慢种在这里。").companionFont(18, weight: .bold).multilineTextAlignment(.center).frame(
        maxWidth: .infinity)
      Text("先添加资料。聊过的内容，会逐渐变成你的表达积累。").companionFont(13).foregroundStyle(RecordingFormat.secondary)
        .multilineTextAlignment(.center)
      Button {
        upload = true
      } label: {
        Text("添加第一份资料").frame(maxWidth: .infinity)
      }.buttonStyle(
        CompanionButtonStyle(primary: true))
    }.padding(.top, 45)
  }
  private func discoveryCard(_ first: PersonalDiscovery) -> some View {
    NavigationLink {
      CompanionDiscoveryPage(discovery: first)
    } label: {
      CompanionPanel(color: Warm.lavender) {
        HStack {
          Label("最近一个发现", systemImage: "leaf")
          Spacer()
          Text(first.status == "pending" ? "待集中核对" : "已确认")
        }.companionFont(11)
        Text(first.title).companionFont(17, weight: .semibold)
        Text(first.text).companionFont(13).lineLimit(3)
        Text("看看依据与下一步 →").companionFont(12, weight: .semibold).foregroundStyle(Warm.purple)
          .padding(.top, 5)
      }
    }.buttonStyle(.plain)
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
  @ViewBuilder private var expressions: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(["全部", "客户常问", "值得复用", "需要改善"], id: \.self) { value in
          Button {
            filter = value
          } label: {
            Text(value).companionFont(11).padding(.horizontal, 12).frame(minHeight: 32).background(
              filter == value ? Warm.sage : Warm.white, in: Capsule()
            ).overlay(Capsule().stroke(CompanionStyle.line))
          }.buttonStyle(.plain).frame(minHeight: 44).accessibilityAddTraits(
            filter == value ? .isSelected : [])
        }
      }
    }
    let rows = (store.companionMemory?.expressions ?? []).filter {
      filter == "全部" || $0.tags.contains(filter)
    }
    if rows.isEmpty {
      Text("还没有表达积累").companionFont(16, weight: .semibold)
      Text("录音同步并完成复盘后，有原文依据的表达会自动沉淀在这里。").companionFont(13).foregroundStyle(
        RecordingFormat.secondary)
    }
    ForEach(rows) { e in
      NavigationLink {
        CompanionExpressionPage(expression: e)
      } label: {
        CompanionExpressionRow(expression: e)
      }.buttonStyle(.plain)
    }
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
            Text("你当时怎么说").companionFont(12).foregroundStyle(RecordingFormat.secondary)
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
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text(discovery.title).companionFont(27, weight: .bold)
        Text(discovery.status == "confirmed" ? "已确认的跨场发现" : "AI 跨场发现 · 待集中核对").font(.caption)
          .foregroundStyle(Warm.purple)
        CompanionPanel { Text(discovery.text).companionFont(15).lineSpacing(7) }
        if discovery.reference_status == "superseded" {
          Text("依据已修订，请重新核对。").foregroundStyle(Warm.purple)
        }
        Text("一起看看原话").font(.headline)
        CompanionEvidenceList(refs: discovery.evidence_refs)
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
      companionRecordings = decode(
        [RecordingRecord].self,
        [
          ("preview-a", "华味餐饮 · 产品方案沟通"), ("preview-b", "晴川零售 · 需求了解"),
          ("preview-c", "南岸门店 · 方案讨论"),
        ].map {
          [
            "id": $0.0, "title": $0.1, "pipeline_status": "done",
            "started_at": "2026-10-16T06:00:00Z", "duration_ms": 1_920_000,
            "transcript_revision": 1,
            "segments": [
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
              "body": ["text": "先对齐服务与实施范围，再比较价格。"], "quote": "请先确认服务范围，再安排三家门店试点。",
              "tags": ["需要改善", "客户常问"], "version": 1, "source_session_id": "preview-a",
              "evidence_refs": [ref], "reference_status": "current",
            ]
          ],
          "discoveries": [
            [
              "id": "preview-discovery", "title": "客户问价格时，先对齐包含什么。", "text": "先比较服务范围，再继续讨论报价。",
              "status": "pending", "version": 1, "evidence_refs": [ref],
              "reference_status": "current",
            ]
          ],
        ])
    }
  }
#endif
