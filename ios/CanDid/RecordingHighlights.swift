import SwiftUI

struct HighlightLink:Decodable,Identifiable {var id:String;var title:String}
struct HighlightAction:Decodable,Identifiable {var id:String;var text:String;var kind:String}
struct RecordingHighlight:Decodable,Identifiable {
  var id:String;var mark_ids:[String];var times_ms:[Int];var start_ms:Int;var end_ms:Int
  var title:String;var summary:String;var topics:[String];var suggestion:String;var status:String
  var segments:[RecordingSentence];var faq_links:[HighlightLink];var related_actions:[HighlightAction]
}
struct RecordingHighlights:Decodable {var items:[RecordingHighlight];var job_id:String?;var status:String;var error:String?}

struct RecordingHighlightsSection:View {
  let recordID:String
  let value:RecordingHighlights
  let onChange:()->Void
  var body:some View {
    if !value.items.isEmpty {
      VStack(alignment:.leading,spacing:12) {
        Label("你标记的重点",systemImage:"bookmark.fill").companionFont(17,weight:.semibold).foregroundStyle(Warm.purple)
        ForEach(value.items) {highlight in
          NavigationLink {RecordingHighlightPage(recordID:recordID,highlight:highlight,onChange:onChange)} label: {
            VStack(alignment:.leading,spacing:8) {
              HStack(alignment:.top) {Text(highlight.title).companionFont(16,weight:.semibold);Spacer();Image(systemName:"chevron.right").font(.caption)}
              Text(highlight.times_ms.map {RecordingFormat.clock($0/1000)}.joined(separator:" · ")+" · "+String(highlight.mark_ids.count)+" 次标记").companionFont(12).foregroundStyle(RecordingFormat.secondary)
              Text(highlight.summary.isEmpty ? (highlight.segments.isEmpty ? "原文准备好后自动整理，标记已保存。":"正在整理这一段，可先查看原文和回听。") : highlight.summary).companionFont(14).lineLimit(3)
              Divider()
            }.padding(.vertical,8).frame(maxWidth:.infinity,minHeight:70,alignment:.leading).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityIdentifier("recording-highlight-"+highlight.id)
        }
        if let error=value.error {Text(error).companionFont(12).foregroundStyle(RecordingFormat.secondary)}
      }
    }
  }
}
struct RecordingHighlightPage:View {
  @EnvironmentObject var store:Store
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize
  let recordID:String
  @State var highlight:RecordingHighlight
  let onChange:()->Void
  @State private var issue:String?
  @State private var question=""
  @State private var answer=""
  @State private var asking=false
  @State private var requestID=UUID().uuidString
  @State private var submittedQuestion:String?
  @State private var showRename=false
  @State private var title=""
  @State private var currentJob:BusinessJob?
  var body:some View {ScrollView {
    VStack(alignment:.leading,spacing:18) {
      HStack(alignment:.top) {
        Text(highlight.title).companionFont(22,weight:.bold)
        Spacer()
        Menu {Button("修改标题") {title=highlight.title;showRename=true};Button("移除这段重点的标记",role:.destructive) {Task {await remove()}}} label:{Image(systemName:"ellipsis").frame(width:44,height:44)}.accessibilityLabel("重点操作")
      }
      if !highlight.summary.isEmpty {Text(highlight.summary).companionFont(15).lineSpacing(6).textSelection(.enabled)}
      if !highlight.topics.isEmpty {Text(highlight.topics.joined(separator:" · ")).companionFont(12).foregroundStyle(Warm.purple)}
      if typeSize.isAccessibilitySize {
        VStack(alignment:.leading,spacing:8) {clipPlayback;fullTranscript}.companionFont(13)
      } else {HStack {clipPlayback;Spacer();fullTranscript}.companionFont(13)}
      if let currentJob,["failed","interrupted","cancelled"].contains(currentJob.status) {
        Text(currentJob.error ?? "重点整理尚未完成").companionFont(12).foregroundStyle(RecordingFormat.secondary)
        Button("继续整理重点") {Task {do {_ = try await store.api.raw("/v1/business-jobs/"+currentJob.id+"/retry",method:"POST");await refresh()} catch {issue=error.localizedDescription}}}.frame(minHeight:44)
      }
      ForEach(highlight.segments) {line in
        VStack(alignment:.leading,spacing:6) {
          HStack {Text(RecordingFormat.speakerName(line)+" · "+RecordingFormat.clock(line.start_ms/1000)).companionFont(12).foregroundStyle(Warm.purple);Spacer();CompanionSentencePlay(recordID:recordID,line:line)}
          Text(line.text).companionFont(14).lineSpacing(6).textSelection(.enabled)
        }.frame(maxWidth:.infinity,alignment:.leading)
      }
      if !highlight.suggestion.isEmpty {Text("可以继续做什么").companionFont(17,weight:.semibold);Text(highlight.suggestion).companionFont(14)}
      if !highlight.faq_links.isEmpty {
        Text("相关 FAQ 与表达").companionFont(17,weight:.semibold)
        ForEach(highlight.faq_links) {link in NavigationLink {HighlightFAQPage(id:link.id)} label:{HStack {Text(link.title);Spacer();Image(systemName:"chevron.right")}.frame(maxWidth:.infinity,minHeight:44).contentShape(Rectangle())}.buttonStyle(.plain)}
      }
      if !highlight.related_actions.isEmpty {Text("已整理的跟进与待核实").companionFont(17,weight:.semibold);ForEach(highlight.related_actions) {Text($0.text).companionFont(14)}}
      Divider()
      Text("围绕这一段问 Candid").companionFont(17,weight:.semibold)
      TextField("这里怎么回答更好？还需要跟进什么？",text:$question,axis:.vertical).textFieldStyle(.roundedBorder).accessibilityIdentifier("mark-question")
      Button(asking ? "正在思考…":"问 Candid") {Task {await ask()}}.buttonStyle(CompanionButtonStyle(primary:true)).disabled(asking || question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || highlight.segments.isEmpty)
      if !answer.isEmpty {Text(answer).companionFont(15).lineSpacing(7).textSelection(.enabled).accessibilityIdentifier("mark-answer")}
      if let issue {Text(issue).companionFont(13).foregroundStyle(.red)}
    }.frame(maxWidth:.infinity,alignment:.leading).padding(18).frame(maxWidth:700).frame(maxWidth:.infinity)
  }.companionReport("标记的重点").onDisappear {if store.recordingPlaybackID==recordID {store.stopPlayback()}}
    .task {while !Task.isCancelled {await refresh();do {try await Task.sleep(for:.seconds(5))} catch {break}}}
    .sheet(isPresented:$showRename) {NavigationStack {Form {TextField("重点标题",text:$title);Button("保存") {Task {do {let _:RecordingHighlights=try await store.api.call("/v1/recordings/"+recordID+"/marks/"+highlight.id,method:"PATCH",body:["title":title]);showRename=false;await refresh();onChange()} catch {issue=error.localizedDescription}}}.disabled(title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}.navigationTitle("修改标题").toolbar {Button("取消") {showRename=false}}}}
  }
  private var clipPlayback:some View {
    Button {Task {await store.perform {
      if store.recordingPlaybackID==recordID && store.recordingPlaybackStartMS==highlight.start_ms && store.recordingPlaybackEndMS==highlight.end_ms {store.toggleRecordingPlayback()}
      else {try await store.playRecording(recordID,startMS:highlight.start_ms,endMS:highlight.end_ms)}
    }}} label:{Label(store.recordingPlaybackID==recordID && store.recordingPlaybackPlaying ? "暂停回听":"回听这一段",systemImage:store.recordingPlaybackID==recordID && store.recordingPlaybackPlaying ? "pause.fill":"play.fill")}.frame(minHeight:44)
  }
  private var fullTranscript:some View {NavigationLink("展开原文") {CompanionRecordingPage(id:recordID,focusMS:highlight.times_ms.first)}.frame(minHeight:44)}
  private func refresh() async {
    do {
      let record:RecordingRecord=try await store.api.call("/v1/recordings/"+recordID)
      if let value=record.highlights?.items.first(where:{$0.id==highlight.id}) {highlight=value}
      currentJob=record.jobs?.first {$0.id==record.highlights?.job_id}
    } catch {if !Task.isCancelled {issue=error.localizedDescription}}
  }
  private func remove() async {
    do {_ = try await store.api.raw("/v1/recordings/"+recordID+"/highlights/"+highlight.id,method:"DELETE");onChange();dismiss()} catch {issue=error.localizedDescription}
  }
  private func ask() async {
    guard !asking else{return};asking=true;issue=nil;defer {asking=false}
    if submittedQuestion != question {requestID=UUID().uuidString;submittedQuestion=question}
    let api=store.api
    do {
      let task:AgentTask=try await api.call("/v1/recordings/"+recordID+"/highlights/"+highlight.id+"/ask",method:"POST",body:["question":submittedQuestion ?? question,"client_request_id":requestID])
      for _ in 0..<180 {
        try Task.checkCancellation()
        let state:AgentTask=try await api.call("/v1/agent/tasks/"+task.id)
        if let text=state.partial_text,!text.isEmpty {answer=text}
        if !state.active {
          if state.status=="completed" {let detail:ChatDetail=try await api.call("/v1/chat/threads/"+task.thread_id);answer=detail.messages.last {$0.task_id==task.id && $0.role=="assistant"}?.content ?? answer;submittedQuestion=nil}
          else {issue=state.error?.message ?? "回答中断，可重新提问"}
          break
        }
        try await Task.sleep(for:.seconds(1))
      }
    } catch {if !Task.isCancelled {issue=error.localizedDescription}}
  }
}
private struct HighlightFAQPage:View {
  @EnvironmentObject var store:Store
  let id:String
  @State private var item:LibraryItem?
  @State private var issue:String?
  var body:some View {Group {if let item {LibraryFAQDetail(item:item)} else if let issue {Text(issue)} else {ProgressView("正在读取说法")}}.task {do {item=try await store.api.call("/v1/library/items/"+id)} catch {issue=error.localizedDescription}}}
}
