import SwiftUI

struct RoleplaySetup:View {
    @EnvironmentObject var store:Store
    var workspaceID:String?=nil
    var preparationID:String?=nil
    var itemID:String?=nil
    var parent:PracticeSession?=nil
    var retryTurnID:String?=nil
    init(workspaceID:String?=nil,preparationID:String?=nil,itemID:String?=nil,parent:PracticeSession?=nil,retryTurnID:String?=nil,initialScenario:String="sales") {
        self.workspaceID=workspaceID;self.preparationID=preparationID;self.itemID=itemID;self.parent=parent;self.retryTurnID=retryTurnID
        _scenario=State(initialValue:parent?.scenario ?? initialScenario)
    }
    @State private var scenario="sales"
    @State private var goal=""
    @State private var style="自然交流"
    @State private var minutes=10
    @State private var context:PracticeContext?
    @State private var excluded:Set<String>=[]
    @State private var sources=false
    @State private var issue:String?
    @State private var loading=false
    @State private var opened:PracticeSession?
    @State private var creating=false
    @State private var request=UUID().uuidString
    var body:some View {
        VStack(spacing:0){
            ScrollView{VStack(alignment:.leading,spacing:20){
                Text(itemID==nil ? "先练一场，再去沟通":"把这道题练顺").companionFont(25,weight:.bold)
                Text(preparationID != nil ? "已带入这份准备包的目标与资料。":workspaceID != nil ? "已带入当前空间的关联资料。":"用已有积累，模拟一次真实交流。").companionFont(13).foregroundStyle(RecordingFormat.secondary)
                CompanionTabs(values:["销售模拟","面试模拟"],selection:Binding(get:{scenario=="sales" ? "销售模拟":"面试模拟"},set:{scenario=$0=="销售模拟" ? "sales":"interview";context=nil;goal="";excluded=[];request=UUID().uuidString}))
                    .disabled(itemID != nil || preparationID != nil || parent != nil)
                HStack(spacing:12){Image(systemName:"person").foregroundStyle(Warm.purple).frame(width:40,height:40).background(Warm.lavender,in:RoundedRectangle(cornerRadius:13));VStack(alignment:.leading,spacing:5){Text(context?.persona ?? (scenario=="sales" ? "采购负责人":"业务面试官")).companionFont(17,weight:.semibold);Text("围绕目标交流，根据你的回答追问").companionFont(11).foregroundStyle(RecordingFormat.secondary)}}
                CompanionPanel(color:Warm.lavender){Text("这次想练什么").companionFont(12).foregroundStyle(RecordingFormat.secondary);TextEditor(text:$goal).frame(minHeight:75).scrollContentBackground(.hidden).companionFont(16).accessibilityIdentifier("practice-goal");Text("目标可直接修改，不必再填一张表。").companionFont(11).foregroundStyle(RecordingFormat.secondary)}
                Button{sources=true}label:{HStack{Text(context?.sources.isEmpty==false ? "使用 \((context?.sources.count ?? 0)-excluded.count) 份相关资料":"未关联资料 · 使用通用场景");Spacer();Image(systemName:"chevron.right")}.companionFont(13).frame(minHeight:44)}.foregroundStyle(Warm.ink)
                HStack{Text("对方风格");Spacer();Picker("对方风格",selection:$style){ForEach(["自然交流","追问更深入","更谨慎，有异议"],id:\.self){Text($0)}}.labelsHidden()}.companionFont(13)
                HStack{Text("预计练习");Spacer();Picker("预计练习时长",selection:$minutes){ForEach([5,10,20],id:\.self){Text("约 \($0) 分钟").tag($0)}}.labelsHidden()}.companionFont(13)
                Text("按你的节奏聊，可以随时结束或继续。\n过程中不打分；需要帮助时，点一下“提示”。").companionFont(12).foregroundStyle(RecordingFormat.secondary).lineSpacing(5)
                NavigationLink{RoleplayHistory()}label:{Label("练习记录",systemImage:"clock")}.companionFont(13).frame(minHeight:44)
                if loading{ProgressView("正在查找相关资料…").companionFont(12)}
                if let issue{Text(issue).companionFont(13).foregroundStyle(.red);Button("重试"){Task{await load()}}}
            }.padding(22).frame(maxWidth:700).frame(maxWidth:.infinity)}
            VStack(spacing:12){Button{Task{await begin()}}label:{Label(creating ? "正在准备…":"开始模拟",systemImage:"mic").frame(maxWidth:.infinity)}.buttonStyle(CompanionButtonStyle(primary:true)).disabled(creating || loading || goal.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityIdentifier("practice-start")
                Text("语音为主，随时切换打字 · 练习独立保存").companionFont(11).foregroundStyle(RecordingFormat.secondary)
            }.padding(.horizontal,22).padding(.vertical,14).frame(maxWidth:700)
        }.companionReport("模拟练习")
        .task(id:scenario){await load()}
        .sheet(isPresented:$sources){NavigationStack{List{if let context{ForEach(context.sources){source in Toggle(isOn:Binding(get:{!excluded.contains(source.id)},set:{if $0{excluded.remove(source.id)}else{excluded.insert(source.id)}})){VStack(alignment:.leading,spacing:5){Text(source.title);Text(source.kind=="faq" ? "问题与表达积累":source.kind=="knowledge" ? "沟通复盘":"背景资料").font(.caption).foregroundStyle(.secondary)}}}};if context?.sources.isEmpty != false{Text("可以先用通用场景练习，之后再补充资料。")}}.navigationTitle("本场使用的资料").toolbar{Button("完成"){sources=false}}}}
        .navigationDestination(item:$opened){session in RoleplaySessionPage(initial:session,autoListen:true)}
    }
    private func load() async{
        guard store.remote else{issue="请连接后端以使用真实模拟练习。";return}
        loading=true;defer{loading=false}
        do{var url="/v1/practice/context?scenario="+scenario
            if let workspaceID{url+="&workspace_id="+workspaceID};if let preparationID{url+="&preparation_id="+preparationID};if let itemID{url+="&item_id="+itemID}
            let value:PracticeContext=try await store.api.call(url);context=value;if goal.isEmpty{goal=parent?.goal ?? value.goal};if scenario != value.scenario{scenario=value.scenario};issue=nil
        }catch{issue=error.localizedDescription;if goal.isEmpty{goal=scenario=="sales" ? "问清需求，推进一个明确的下一步":"清楚讲出个人贡献，并接住追问"}}
    }
    private func begin() async{creating=true;defer{creating=false}
        do{var body:[String:Any]=["client_request_id":request,"scenario":scenario,"goal":goal,"style":style,"duration_minutes":minutes,"excluded_source_ids":Array(excluded)]
            if let workspaceID{body["workspace_id"]=workspaceID};if let preparationID{body["preparation_id"]=preparationID};if let itemID{body["item_id"]=itemID};if let parent,let retryTurnID{body["parent_id"]=parent.id;body["retry_turn_id"]=retryTurnID}
            let value:PracticeSession=try await store.api.call("/v1/practice/sessions",method:"POST",body:body);opened=value;request=UUID().uuidString;issue=nil
        }catch{issue=error.localizedDescription}
    }
}
extension PracticeSession:Hashable {
    static func ==(a:PracticeSession,b:PracticeSession)->Bool{a.id==b.id}
    func hash(into hasher:inout Hasher){hasher.combine(id)}
}
struct RoleplayHistory:View {
    @EnvironmentObject var store:Store
    @State private var rows:[PracticeSession]=[]
    @State private var issue:String?
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:15){Text("练习记录").companionFont(25,weight:.bold);Text("不计入真实沟通次数与表达趋势。").companionFont(12).foregroundStyle(RecordingFormat.secondary)
        ForEach(rows){s in NavigationLink{RoleplaySessionPage(initial:s)}label:{CompanionPanel{Text(s.goal).companionFont(16,weight:.semibold);Text((s.scenario=="sales" ? "销售模拟":"面试模拟")+" · \(s.turns.filter{$0.role=="user"}.count) 次回答 · "+(s.state=="completed" ? "已复盘":"可继续")).companionFont(12).foregroundStyle(RecordingFormat.secondary)}}.buttonStyle(.plain)}
        if rows.isEmpty{Text("还没有练习，从一场模拟开始。").companionFont(14)};if let issue{Text(issue).foregroundStyle(.red)}
    }.padding(22).frame(maxWidth:700).frame(maxWidth:.infinity)}.companionReport("练习记录").task{do{let result:PracticeList=try await store.api.call("/v1/practice/sessions");rows=result.data}catch{issue=error.localizedDescription}}}
}
struct RoleplaySessionPage:View {
    @EnvironmentObject var store:Store
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller=PracticeController()
    let initial:PracticeSession
    var autoListen=false
    @State private var showTranscript=false
    @State private var adopting:PracticeCorrection?
    @State private var adoptionIndex=0
    @State private var adoptedText=""
    @State private var adoptionNotice:String?
    @State private var saving=false
    private var session:PracticeSession{controller.session ?? initial}
    var body:some View{VStack(spacing:0){
        if let review=session.review{reviewPage(review)}else{conversation}
    }.companionReport(session.review==nil ? "模拟进行中":"练后复盘")
        .toolbar{ToolbarItem(placement:.topBarTrailing){if session.review==nil{Button("结束"){Task{await controller.command("finish")}}.disabled(controller.busy)}else{Button("完整对话"){showTranscript=true}}}}
        .task{controller.configure(store);controller.accept(initial);if autoListen && store.capabilities?.asr_configured==true{await controller.startVoice()}else{controller.textMode=true};while !Task.isCancelled{await controller.refresh();do{try await Task.sleep(for:.milliseconds(650))}catch{break}}}
        .onChange(of:scenePhase){_,v in if v != .active{controller.pause()}}
        .onDisappear{controller.close()}
        .sheet(isPresented:$controller.hintPresented){NavigationStack{VStack(alignment:.leading,spacing:20){Text("给你一个小提示").companionFont(23,weight:.bold);Text(session.error ?? session.hint ?? "正在整理提示…").companionFont(16);if session.error != nil{Button("重试提示"){Task{await controller.retry()}}};Text("看完继续，对方会保持原来的角色。").companionFont(12).foregroundStyle(RecordingFormat.secondary);Button("继续模拟"){controller.hintPresented=false;Task{if store.capabilities?.asr_configured==true{await controller.startVoice()}else{controller.textMode=true}}}.buttonStyle(CompanionButtonStyle(primary:true));Spacer()}.padding(24).background(Warm.paper).toolbar{Button("关闭"){controller.hintPresented=false}}}.presentationDetents([.medium])}
        .sheet(isPresented:$showTranscript){NavigationStack{ScrollView{turns.padding(22)}.companionReport("本场完整对话").toolbar{Button("关闭"){showTranscript=false}}}}
        .sheet(isPresented:Binding(get:{adopting != nil},set:{if !$0{adopting=nil}})){NavigationStack{VStack(alignment:.leading,spacing:16){Text("保存为我的新说法").companionFont(23,weight:.bold);Text("先按你的真实情况调整。练习中的角色发言不会保存为事实。").companionFont(12);TextEditor(text:$adoptedText).frame(minHeight:150).padding(10).background(Warm.white,in:RoundedRectangle(cornerRadius:12));if let adoptionNotice{Text(adoptionNotice).companionFont(13)};Button(saving ? "正在保存…":"保存说法"){Task{await adopt()}}.buttonStyle(CompanionButtonStyle(primary:true)).disabled(saving || adoptedText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty);Spacer()}.padding(22).background(Warm.paper).toolbar{Button("取消"){adopting=nil}}}}
    }
    private var conversation:some View{VStack(spacing:0){
        VStack(alignment:.leading,spacing:8){Text(session.persona).companionFont(24,weight:.bold);Text(session.goal).companionFont(13).foregroundStyle(Warm.purple);HStack{Text(session.stage);Spacer();Text("\(session.turns.filter{$0.role=="user"}.count) 次回答")}.companionFont(11).foregroundStyle(RecordingFormat.secondary)}.padding(.horizontal,22).padding(.bottom,14)
        ScrollViewReader{proxy in ScrollView{VStack(alignment:.leading,spacing:22){turns;if session.state=="thinking"{HStack{ProgressView();Text("正在回应…").companionFont(12)}};Color.clear.frame(height:1).id("practice-bottom")}.padding(22)}.onChange(of:session.turns.count){_,_ in proxy.scrollTo("practice-bottom",anchor:.bottom)}}
        VStack(spacing:12){if let notice=controller.notice{Text(notice).companionFont(12).foregroundStyle(.red);if session.error != nil{Button("重试这一轮"){Task{await controller.retry()}}}}
            if controller.textMode{TextField("说说你的想法…",text:$controller.draft,axis:.vertical).lineLimit(2...5).padding(12).background(Warm.white,in:RoundedRectangle(cornerRadius:12)).accessibilityIdentifier("practice-answer");Button("发送回答"){Task{await controller.send(controller.draft)}}.buttonStyle(CompanionButtonStyle(primary:true)).disabled(controller.busy || controller.draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityIdentifier("practice-send")}
            else{Text(controller.speaking ? "可以随时开口打断":controller.listening ? "我在听，你可以直接说":"已暂停，准备好再继续").companionFont(15);if !controller.draft.isEmpty{Text(controller.draft).companionFont(14).foregroundStyle(Warm.purple).accessibilityIdentifier("practice-live-caption")};Text("短暂停顿继续听，说完后自然接话").companionFont(11).foregroundStyle(RecordingFormat.secondary)}
            HStack{Button{controller.toggleText()}label:{Label(controller.textMode ? "切回语音":"打字回答",systemImage:controller.textMode ? "mic":"keyboard").labelStyle(.titleAndIcon)}.accessibilityIdentifier("practice-text-toggle");Spacer();Button{if controller.listening{controller.pause()}else{Task{await controller.startVoice()}}}label:{Image(systemName:controller.listening ? "pause.fill":"play.fill").frame(width:60,height:60).foregroundStyle(controller.listening ? .white:Warm.ink).background(controller.listening ? Warm.purple:CompanionStyle.line,in:Circle())}.accessibilityLabel(controller.listening ? "暂停练习":"继续练习");Spacer();Button{Task{await controller.command("hint")}}label:{Label("提示",systemImage:"lightbulb")}.disabled(controller.busy)}.companionFont(12).foregroundStyle(Warm.purple).frame(minHeight:60)
        }.padding(18).frame(maxWidth:700).background(Warm.paper)
    }.frame(maxWidth:700).frame(maxWidth:.infinity)}
    private var turns:some View{ForEach(session.turns){turn in VStack(alignment:.leading,spacing:7){HStack(spacing:6){if turn.role=="assistant"{Mascot(size:22)};Text(turn.role=="user" ? "我":session.persona).companionFont(11).foregroundStyle(RecordingFormat.secondary)};Text(turn.text).companionFont(turn.role=="user" ? 14:16).lineSpacing(6).textSelection(.enabled).padding(turn.role=="user" ? 13:0).frame(maxWidth:.infinity,alignment:.leading).background(turn.role=="user" ? Warm.lavender:Color.clear,in:RoundedRectangle(cornerRadius:16))}.padding(.leading,turn.role=="user" ? 26:0).id(turn.id)}}
    private func reviewPage(_ review:PracticeReview)->some View{ScrollView{VStack(alignment:.leading,spacing:22){Text(session.goal).companionFont(25,weight:.bold);Text((session.scenario=="sales" ? "销售模拟":"面试模拟")+" · \(session.turns.filter{$0.role=="user"}.count) 次回答").companionFont(12).foregroundStyle(RecordingFormat.secondary);CompanionPanel(color:Warm.sage){Text("这次的沟通").companionFont(17,weight:.semibold);Text(review.summary).companionFont(15)}
        ForEach(Array(review.improvements.enumerated()),id:\.offset){index,item in VStack(alignment:.leading,spacing:13){Text(index==0 ? "先练好这一点":"也可以这样改").companionFont(18,weight:.semibold);Text(item.reason).companionFont(14);Text("你的原话").companionFont(11).foregroundStyle(RecordingFormat.secondary);Text("“"+item.quote+"”").companionFont(15);NavigationLink{RoleplaySetup(workspaceID:session.workspace_id,itemID:session.item_id,parent:session,retryTurnID:item.turn_id)}label:{Label("重练这一段",systemImage:"arrow.counterclockwise")}.buttonStyle(CompanionButtonStyle(primary:true));CompanionPanel(color:Warm.lavender){Text("试试这样说").companionFont(15,weight:.semibold);Text(item.suggested_text).companionFont(14);Button("保存为我的新说法"){adoptionIndex=index;adoptedText=item.suggested_text;adoptionNotice=nil;adopting=item}.frame(minHeight:44).companionFont(13)}}}
        if !review.strengths.isEmpty{Text("值得保留的地方").companionFont(18,weight:.semibold);ForEach(review.strengths,id:\.self){Text($0).companionFont(14)}}
        Text("练习独立保存，不计入真实沟通次数。").companionFont(12).foregroundStyle(RecordingFormat.secondary)
        if !session.sources.isEmpty{Text("本场使用的资料").companionFont(16,weight:.semibold);ForEach(session.sources){source in Label(source.title,systemImage:"doc.text").companionFont(12)}}
        NavigationLink{RoleplaySetup(workspaceID:session.workspace_id,initialScenario:session.scenario)}label:{Text("再练一场").frame(maxWidth:.infinity)}.buttonStyle(CompanionButtonStyle(primary:true))
    }.padding(22).frame(maxWidth:700).frame(maxWidth:.infinity)}}
    private func adopt()async{saving=true;defer{saving=false};do{var body:[String:Any]=["correction_index":adoptionIndex,"text":adoptedText];if session.item_id != nil,let version=session.item_version{body["expected_version"]=version};_ = try await store.api.raw("/v1/practice/sessions/"+session.id+"/adopt",method:"POST",body:body);adopting=nil;controller.notice="已保存到记忆库，练习仍独立保留。"}catch{adoptionNotice=error.localizedDescription}}
}
