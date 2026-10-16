import UIKit
import XCTest
import module_spplinkKit
import AVFoundation
import SwiftUI
@testable import CanDid

private final class OnboardingStubProtocol: URLProtocol {

    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "onboarding-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class SoundcoreAudioTests: XCTestCase {
    @MainActor func testMarkerUploadSurvivesFailureAndRespectsBackendIdentity() async throws {
        URLProtocol.registerClass(OnboardingStubProtocol.self)
        let path=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("PendingMarkerUploads.json")
        let backup=try? Data(contentsOf:path)
        defer {URLProtocol.unregisterClass(OnboardingStubProtocol.self);OnboardingStubProtocol.handler=nil;if let backup {try? backup.write(to:path)} else {try? FileManager.default.removeItem(at:path)}}
        let sid=UUID().uuidString;let api=API(base:"http://onboarding-test.invalid",token:"mark-test")
        OnboardingStubProtocol.handler={_ in throw URLError(.notConnectedToInternet)}
        let first=SpeechController()
        do {try await first.saveMarkers([1500,4500,1500],sessionID:sid,api:api);XCTFail("must preserve failed upload")} catch {}
        let restored=SpeechController();XCTAssertEqual(restored.pendingMarkers.first {$0.id==sid}?.times,[1500,4500])
        var requests=0
        OnboardingStubProtocol.handler={request in
            requests+=1
            var payload=request.httpBody ?? Data()
            if payload.isEmpty,let stream=request.httpBodyStream {
                stream.open();defer {stream.close()}
                var buffer=[UInt8](repeating:0,count:4096)
                while stream.hasBytesAvailable {let count=stream.read(&buffer,maxLength:buffer.count);if count<=0 {break};payload.append(contentsOf:buffer.prefix(count))}
            }
            let body=try JSONSerialization.jsonObject(with:payload) as? [String:Any]
            XCTAssertEqual((body?["marks"] as? [[String:Any]])?.compactMap {$0["t_ms"] as? Int},[1500,4500])
            return Data("{\"data\":[]}".utf8)
        }
        await restored.flushMarkers(api:API(base:api.base,token:"another-account"));XCTAssertEqual(requests,0)
        await restored.flushMarkers(api:api);XCTAssertEqual(requests,1)
        XCTAssertFalse(restored.pendingMarkers.contains {$0.id==sid})
    }
    func testNativeVisionReadsImageAndMixedPDFPages() throws {
        let image=UIGraphicsImageRenderer(size:CGSize(width:1000,height:500)).image {ctx in
            UIColor.white.setFill();ctx.fill(CGRect(x:0,y:0,width:1000,height:500))
            ("Delivery 3 weeks\nPrice 180000" as NSString).draw(at:CGPoint(x:60,y:80),withAttributes:[.font:UIFont.systemFont(ofSize:42),.foregroundColor:UIColor.black])
        }
        let result=try NativeDocumentOCR.recognizeImage(image)
        XCTAssertTrue(result.0.contains("180000"));XCTAssertTrue(result.0.lowercased().contains("delivery"))
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".pdf")
        defer {try? FileManager.default.removeItem(at:url)}
        let pdf=UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:600,height:800))
        try pdf.writePDF(to:url) {ctx in
            ctx.beginPage();("Text page" as NSString).draw(at:CGPoint(x:40,y:80),withAttributes:[.font:UIFont.systemFont(ofSize:32)])
            ctx.beginPage();image.draw(in:CGRect(x:0,y:30,width:600,height:300))
        }
        let pages=try NativeDocumentOCR.recognize(url)
        XCTAssertEqual(pages.count,2);XCTAssertTrue((pages[1]["text"] as? String ?? "").contains("180000"))
    }

    func testCustomerPreparationOrderingUsesMeetingTimeThenCreationAndKeepsOverdueVisible() throws {
        func pack(_ id:String,_ meeting:String?,_ created:String)->CompanionPreparation {
            CompanionPreparation(id:id,client:id,goal:"试点",scenario:"sales",scheduled_at:meeting,sections:[],status:"ready",version:1,created_at:created)
        }
        let older=pack("earlier","2026-10-18T10:00:00+08:00","2026-10-16T04:00:00Z")
        let later=pack("later","2026-10-19T09:00:00+08:00","2026-10-16T01:00:00Z")
        let unknownA=pack("unknown-a",nil,"2026-10-16T02:00:00Z")
        let unknownB=pack("unknown-b",nil,"2026-10-16T03:00:00Z")
        let overdue=pack("overdue","2020-01-01T00:00:00Z","")
        var finished=later;finished.id="completed";finished.status="completed"
        XCTAssertEqual(CustomerWorkspacePresentation.preparations([unknownA,older,finished,overdue,unknownB,later]).map(\.id),["later","earlier","overdue","unknown-b","unknown-a"])
    }
    @MainActor func testCustomerDraftsAndNewConversationStaySeparate() async throws {
        let store=Store(localDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.seedCompanionPreview();store.clearChatRecovery()
        await store.selectProjectSpace("preview-customer-0");store.saveChatDraft("甲客户草稿")
        await store.selectProjectSpace("preview-customer-1");XCTAssertEqual(store.chatDraft,"");store.saveChatDraft("乙客户草稿")
        await store.selectProjectSpace("preview-customer-0");XCTAssertEqual(store.chatDraft,"甲客户草稿")
        store.beginNewCustomerConversation();XCTAssertNil(store.chatThread);XCTAssertTrue(store.newWorkspacePending)
        store.saveChatDraft("新会话草稿")
        await store.selectProjectSpace("preview-customer-1");XCTAssertEqual(store.chatDraft,"乙客户草稿")
        store.beginNewCustomerConversation();XCTAssertEqual(store.chatDraft,"新会话草稿")
        store.clearChatRecovery()
    }
    @MainActor func testRestoringArchivedCustomerLeavesNewConversationMode() async throws {
        URLProtocol.registerClass(OnboardingStubProtocol.self)
        defer {URLProtocol.unregisterClass(OnboardingStubProtocol.self);OnboardingStubProtocol.handler=nil}
        let store=Store(localDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.seedCompanionPreview();store.clearChatRecovery();store.base="http://onboarding-test.invalid";store.remote=true
        var archived=store.projectSpaces[1];archived.status="archived"
        var restored=archived;restored.status="active";restored.version+=1
        let thread=ChatThread(id:restored.default_thread_id,title:restored.name,status:"idle",activity:[],message_count:0,updated_at:"",workspace_id:restored.id)
        func object<T:Encodable>(_ value:T)throws->Any {try JSONSerialization.jsonObject(with:JSONEncoder().encode(value))}
        let restoredJSON=try object(restored),threadJSON=try object(thread)
        OnboardingStubProtocol.handler={request in
            let path=request.url!.path
            if path.hasSuffix("/restore") {return try JSONSerialization.data(withJSONObject:restoredJSON)}
            if path=="/v1/project-spaces" {return try JSONSerialization.data(withJSONObject:["data":[restoredJSON],"next_cursor":NSNull()])}
            if path=="/v1/chat/threads" {return try JSONSerialization.data(withJSONObject:["data":[threadJSON],"next_cursor":NSNull()])}
            return try JSONSerialization.data(withJSONObject:["thread":threadJSON,"messages":[],"tasks":[]])
        }
        store.beginNewCustomerConversation();XCTAssertTrue(store.newWorkspacePending)
        await store.archiveProjectSpace(restore:true,selected:archived)
        XCTAssertFalse(store.newWorkspacePending)
        XCTAssertEqual(store.chatThread?.id,restored.default_thread_id)
        XCTAssertEqual(store.currentProjectSpace?.id,restored.id)
        store.clearChatRecovery()
    }
    @MainActor func testDismissedTaskRecoveryPersistsAndIsScopedToAttemptAndThread() throws {
        let store=Store(localDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.chatThread=ChatThread(id:"recovery-test-"+UUID().uuidString,title:"Test",status:"idle",activity:[],message_count:0,updated_at:"")
        var task=AgentTask(id:"stopped",thread_id:store.chatThread!.id,turn_id:"turn",status:"cancelled",attempt:1,tool_steps:[])
        XCTAssertFalse(store.isChatTaskDismissed(task))
        store.dismissChatTask(task)
        XCTAssertTrue(store.isChatTaskDismissed(task))
        task.attempt=2;XCTAssertFalse(store.isChatTaskDismissed(task))
        task.attempt=1;task.thread_id="other";XCTAssertFalse(store.isChatTaskDismissed(task))
        store.clearChatRecovery()
    }
    @MainActor func testShortVoiceMigrationDropsAudioAndRetainsOnlyUnresolvedReceipts() throws {
        let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        let folder=root.appendingPathComponent("VoiceInputs")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let audio=folder.appendingPathComponent(UUID().uuidString+".pcm")
        try Data([0,1,2]).write(to:audio)
        let records=[VoiceRecovery(id:"unfinished",path:audio.path,created:Date(),backend:"test",thread:"one",workspace:"a",text:"未完成",unknown:false),VoiceRecovery(id:"receipt",path:"",created:Date(),backend:"test",thread:"one",workspace:"a",text:"等待回执",requestID:"r",unknown:true)]
        let file=root.appendingPathComponent("VoiceRecovery.json")
        try JSONEncoder().encode(records).write(to:file)
        let voice=VoiceSessionController()
        XCTAssertFalse(FileManager.default.fileExists(atPath:audio.path))
        XCTAssertEqual(voice.recoveries.map(\.id),["receipt"])
        XCTAssertEqual(voice.recoveries.first?.path,"")
        voice.removeRecovery("receipt")
    }
    @MainActor func testUnsentVoiceTextPreservesTypedDraftInOriginalWorkspace() throws {
        let store=Store(localDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let thread="voice-draft-"+UUID().uuidString
        store.chatThread=ChatThread(id:thread,title:"Test",status:"idle",activity:[],message_count:0,updated_at:"")
        store.saveChatDraft("正在输入")
        store.restoreUnsentVoiceText("语音文字",threadID:thread)
        XCTAssertEqual(store.chatDraft,"正在输入\n语音文字")
        store.restoreUnsentVoiceText("语音文字",threadID:thread)
        XCTAssertEqual(store.chatDraft,"正在输入\n语音文字")
        store.restoreUnsentVoiceText("其他空间语音",threadID:"other")
        XCTAssertEqual(store.chatDraft,"正在输入\n语音文字")
        store.clearChatRecovery()
    }
    @MainActor func testVoiceReceiptReconciliationNeverResendsAndDoesNotLoseTypedText() async throws {
        URLProtocol.registerClass(OnboardingStubProtocol.self)
        defer {URLProtocol.unregisterClass(OnboardingStubProtocol.self);OnboardingStubProtocol.handler=nil}
        for state in ["accepted","unknown","accepted-during-cancel"] {
            let store=Store(localDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            store.base="http://onboarding-test.invalid";store.remote=true
            let tid="receipt-"+UUID().uuidString
            store.chatThread=ChatThread(id:tid,title:"Receipt",status:"idle",activity:[],message_count:0,updated_at:"")
            store.saveChatDraft("typed")
            let row=VoiceRecovery(id:UUID().uuidString,path:"",created:Date(),backend:store.voice.identity(store.api),thread:tid,workspace:"workspace",text:"spoken",requestID:UUID().uuidString,unknown:true)
            let file=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VoiceRecovery.json")
            try JSONEncoder().encode([row]).write(to:file)
            var posts:[String]=[]
            OnboardingStubProtocol.handler={request in
                let path=request.url!.path
                if request.httpMethod=="POST" {posts.append(path);return try JSONSerialization.data(withJSONObject:["status":"cancelled","task_id":state=="accepted-during-cancel" ? "accepted-task" as Any : NSNull()])}
                if path.contains("/requests/") {return try JSONSerialization.data(withJSONObject:["status":state=="accepted" ? "accepted":"unknown"])}
                return try JSONSerialization.data(withJSONObject:["thread":["id":tid,"title":"Receipt","status":"idle","activity":[],"message_count":0,"updated_at":""],"messages":[],"tasks":[]])
            }
            let voice=VoiceSessionController();voice.refreshRecoveries(store:store)
            for _ in 0..<100 {if voice.recoveries.isEmpty && !store.chatLoading {break};try await Task.sleep(for:.milliseconds(10))}
            XCTAssertTrue(voice.recoveries.isEmpty)
            XCTAssertFalse(posts.contains(where:{$0=="/v1/voice/turns"}))
            XCTAssertEqual(posts.count,state=="accepted" ? 0:1)
            XCTAssertEqual(store.chatDraft,state=="unknown" ? "typed\nspoken":"typed")
            store.clearChatRecovery()
        }
    }
    func testRelativeMeetingTimeUsesUnambiguous24HourClock() throws {
        let tomorrow=try XCTUnwrap(Calendar.current.date(byAdding:.day,value:1,to:Date()))
        let afternoon=try XCTUnwrap(Calendar.current.date(bySettingHour:14,minute:7,second:0,of:tomorrow))
        XCTAssertEqual(CompanionStyle.meetingTime(ISO8601DateFormatter().string(from:afternoon)),"明天 14:07")
        XCTAssertEqual(CompanionStyle.meetingTime(nil),"时间待定")
    }
    func testQuestionGroupingKeepsOriginalOrderAndUnknownSpeakers() throws {
        let json = #"[{"id":"a","text":"为什么价格不同？","start_ms":1000,"end_ms":2000,"speaker":"unknown","speaker_id":"x"},{"id":"b","text":"先确认服务范围。","start_ms":2000,"end_ms":3000,"speaker":"unknown","speaker_id":"y"},{"id":"c","text":"When can we start?","start_ms":5000,"end_ms":6000,"speaker":"self","speaker_id":"z"},{"id":"d","text":"时间仍待核实。","start_ms":6000,"end_ms":7000,"speaker":"unknown","speaker_id":"x"}]"#
        let lines=try JSONDecoder().decode([RecordingSentence].self,from:Data(json.utf8))
        let pairs=CompanionExchange.extract(Array(lines.reversed()))
        XCTAssertEqual(pairs.map(\.id),["a","c"])
        XCTAssertEqual(pairs[0].following.map(\.id),["b"])
        XCTAssertEqual(pairs[1].following.map(\.id),["d"])
        XCTAssertEqual(pairs[0].following[0].speaker,"unknown","问答呈现不能猜测本人身份")
        XCTAssertTrue(CompanionExchange.extract([]).isEmpty)
    }
    @MainActor func testSpeechPauseDuringPreparationAndBetweenClips() async throws {
        let store=Store(localDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let controller=store.speech;let resources=store.audio
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {controller.stopPlayback();try? FileManager.default.removeItem(at:folder);URLProtocol.unregisterClass(OnboardingStubProtocol.self);OnboardingStubProtocol.handler=nil}
        let file=folder.appendingPathComponent("speech.wav")
        let format=AVAudioFormat(standardFormatWithSampleRate:24000,channels:1)!
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:12000)!;buffer.frameLength=12000
        for i in 0..<12000 {buffer.floatChannelData![0][i]=0}
        try AVAudioFile(forWriting:file,settings:format.settings).write(from:buffer)
        let wav=try Data(contentsOf:file)
        var submissions=0
        URLProtocol.registerClass(OnboardingStubProtocol.self)
        OnboardingStubProtocol.handler={request in
            let path=request.url!.path
            if path.hasSuffix("/speak") {submissions+=1;return Data(#"{"id":"job","kind":"tts","object_id":"m","status":"completed"}"#.utf8)}
            if path.hasSuffix("/speech-clips") {return Data(#"{"data":[{"id":"a","part":0},{"id":"b","part":1}],"next_cursor":null}"#.utf8)}
            if path.contains("/speech/") {return wav}
            return Data(#"{"id":"job","kind":"tts","object_id":"m","status":"completed"}"#.utf8)
        }
        let message=ChatMessage(id:"m",role:"assistant",content:"测试。",sources:[],tool_steps:[],created_at:"")
        let api=API(base:"http://onboarding-test.invalid",token:"test")
        controller.speak(message,api:api,resources:resources)
        XCTAssertEqual(controller.playbackState,.preparing)
        controller.pauseSpeechPlayback()
        try await Task.sleep(for:.milliseconds(500))
        XCTAssertEqual(controller.playbackState,.paused,controller.notice ?? "下载完成不能解除暂停")
        XCTAssertFalse(controller.playing)
        let renderer=ImageRenderer(content:SpeechPlaybackBar(speech:controller).environmentObject(store).padding(12).frame(width:402).background(Warm.paper))
        renderer.scale=3
        let snapshot=try XCTUnwrap(renderer.uiImage)
        let attachment=XCTAttachment(image:snapshot);attachment.name="tts-paused-controls";attachment.lifetime = .keepAlways;add(attachment)
        controller.speak(message,api:api,resources:resources)
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertEqual(submissions,1,"同一消息继续不得重复提交")
        NotificationCenter.default.post(name:UIApplication.didEnterBackgroundNotification,object:nil)
        try await Task.sleep(for:.milliseconds(650))
        XCTAssertEqual(controller.playbackState,.paused,"跨越下一片段仍保持暂停")
        controller.pausePlayback()
        try await Task.sleep(for:.milliseconds(1300))
        XCTAssertEqual(controller.playbackState,.idle)
        XCTAssertNil(resources.owner)
    }
    @MainActor func testStoppedSpeechIgnoresLateSubmissionFailures() async throws {
        let controller=SpeechController();let resources=AudioResources()
        defer {controller.stopPlayback();URLProtocol.unregisterClass(OnboardingStubProtocol.self);OnboardingStubProtocol.handler=nil}
        URLProtocol.registerClass(OnboardingStubProtocol.self)
        OnboardingStubProtocol.handler={_ in Thread.sleep(forTimeInterval:0.15);throw URLError(.cannotConnectToHost)}
        let api=API(base:"http://onboarding-test.invalid",token:"test")
        let first=ChatMessage(id:"first",role:"assistant",content:"第一条",sources:[],tool_steps:[],created_at:"")
        var second=first;second.id="second"
        controller.speak(first,api:api,resources:resources)
        try await Task.sleep(for:.milliseconds(20))
        controller.speak(second,api:api,resources:resources)
        XCTAssertEqual(controller.spokenMessage?.id,"second")
        controller.stopPlayback()
        try await Task.sleep(for:.milliseconds(400))
        XCTAssertEqual(controller.playbackState,.idle);XCTAssertNil(controller.spokenMessage)
        XCTAssertNil(controller.notice,"已停止轮次的迟到错误不能覆盖当前界面")
        XCTAssertNil(resources.owner)
    }
    @MainActor func testStreamPauseGatePersistsAcrossIncomingBuffersAndStop() {
        let capture=VoiceCapture.shared
        capture.pausePlayback()
        XCTAssertFalse(capture.playbackGate.canPlay)
        capture.pausePlayback()
        XCTAssertFalse(capture.playbackGate.canPlay)
        capture.resumePlayback()
        XCTAssertTrue(capture.playbackGate.canPlay)
        capture.pausePlayback();capture.stopPlayback()
        XCTAssertTrue(capture.playbackGate.canPlay,"新一代播放不继承旧暂停")
    }
    @MainActor func testSharedMeetingLeaseSurvivesVoiceRelease() throws {
        let resources=AudioResources()
        let meeting=try resources.acquire(.meeting);let voice=try resources.acquire(.voice)
        XCTAssertThrowsError(try resources.acquire(.manualSpeech))
        resources.release(voice)
        XCTAssertTrue(resources.owns(meeting));XCTAssertFalse(resources.voiceActive)
        resources.release(meeting);XCTAssertNil(resources.owner)
    }
    @MainActor func testSentencePlaybackSeeksStopsAtEndAndRestarts() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root);URLProtocol.unregisterClass(OnboardingStubProtocol.self);OnboardingStubProtocol.handler=nil}
        let file=root.appendingPathComponent("sentence.wav")
        let format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!
        buffer.frameLength=48000
        for index in 0..<48000 {buffer.floatChannelData![0][index]=Float(sin(Double(index)*2*Double.pi*440/16000)*0.1)}
        try AVAudioFile(forWriting:file,settings:format.settings).write(from:buffer)
        XCTAssertTrue(URLProtocol.registerClass(OnboardingStubProtocol.self))
        var requested=""
        OnboardingStubProtocol.handler={request in requested=request.url!.absoluteString;return try JSONSerialization.data(withJSONObject:["url":file.absoluteString])}
        let store=Store(localDirectory:root.appendingPathComponent("store"));store.base="http://onboarding-test.invalid"
        try await store.playRecording("sentence-test",startMS:500,endMS:1200)
        XCTAssertTrue(requested.contains("/v1/sessions/sentence-test/audio?start_ms=500"))
        XCTAssertEqual(store.recordingPlaybackStartMS,500);XCTAssertEqual(store.recordingPlaybackEndMS,1200)
        let deadline=Date().addingTimeInterval(6)
        while store.recordingPlaybackPlaying && Date()<deadline {try await Task.sleep(for:.milliseconds(100))}
        XCTAssertFalse(store.recordingPlaybackPlaying,"只播当前句，不能继续播下一句")
        XCTAssertGreaterThanOrEqual(store.recordingPlaybackPositionMS,1000)
        XCTAssertLessThanOrEqual(store.recordingPlaybackPositionMS,1300)
        store.toggleRecordingPlayback()
        XCTAssertTrue(store.recordingPlaybackPlaying)
        store.stopPlayback();XCTAssertNil(store.recordingPlaybackID);XCTAssertFalse(store.audio.voiceActive)
        OnboardingStubProtocol.handler={request in
            if request.url!.path.contains("cancelled"){Thread.sleep(forTimeInterval:0.2)}
            return try JSONSerialization.data(withJSONObject:["url":file.absoluteString])
        }
        let pending=Task{try await store.playRecording("cancelled",startMS:500,endMS:1200)}
        try await Task.sleep(for:.milliseconds(50));store.stopPlayback()
        do{try await pending.value;XCTFail("停止后的旧请求不能恢复播放")}catch{}
        XCTAssertNil(store.recordingPlaybackID)
        XCTAssertFalse(store.recordingPlaybackPlaying)
        do{try await store.playRecording("invalid",startMS:2000,endMS:1000);XCTFail("不能播放倒置时间范围")}catch{}
    }

    func testProviderFileCopyValidatesActualBytesAndCleansFailedCopies() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let source=root.appendingPathComponent("简历.PDF"),destination=root.appendingPathComponent("Copies")
        let bytes=Data("%PDF-test-bytes".utf8);try bytes.write(to:source)
        let local=try await ImportedDocumentFiles.copy(source,into:destination,maxBytes:100)
        XCTAssertEqual(try Data(contentsOf:local),bytes)
        XCTAssertNotEqual(local,source);XCTAssertEqual(local.pathExtension,"pdf")
        try FileManager.default.removeItem(at:local)
        do {_=try await ImportedDocumentFiles.copy(source,into:destination,maxBytes:2);XCTFail("Oversized document must fail")} catch {}
        let empty=root.appendingPathComponent("empty.pdf");try Data().write(to:empty)
        do {_=try await ImportedDocumentFiles.copy(empty,into:destination,maxBytes:100);XCTFail("Empty document must fail")} catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:destination.path).isEmpty)
        XCTAssertTrue(ImportedDocumentFiles.isCancellation(CocoaError(.userCancelled)))
    }
    @MainActor func testDocumentImportErrorSurvivesSuccessfulProfileSync() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=Store(localDirectory:root);store.base="http://onboarding-test.invalid";store.remote=true
        await store.addOnboardingFiles([root.appendingPathComponent("missing.pdf")])
        XCTAssertNotNil(store.personalImportError)
        let issue=store.personalImportError
        await store.syncPersonalProfile()
        XCTAssertEqual(store.personalImportError,issue)
        XCTAssertTrue(store.personalState.documents.isEmpty)
        store.remote=false
    }
    @MainActor func testImportedDocumentResolvesAfterContainerMoveAndLegacyAbsolutePath() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let source=root.appendingPathComponent("resume.pdf");try Data("%PDF-local-original".utf8).write(to:source)
        let old=root.appendingPathComponent("OldContainer"),new=root.appendingPathComponent("NewContainer")
        let store=Store(localDirectory:old);await store.addOnboardingFiles([source])
        let item=try XCTUnwrap(store.personalState.documents.first)
        XCTAssertTrue(try XCTUnwrap(item.localPath).hasPrefix("OnboardingFiles/"))
        let original=try XCTUnwrap(ImportedDocumentFiles.localURL(item.localPath!,in:old))
        store.personalState.documents[0].localPath=original.path;store.persistOnboarding()
        try FileManager.default.moveItem(at:old,to:new)
        let restored=Store(localDirectory:new)
        let row=try XCTUnwrap(restored.personalState.documents.first)
        let recovered=try XCTUnwrap(ImportedDocumentFiles.localURL(row.localPath!,in:new))
        XCTAssertEqual(try Data(contentsOf:recovered),Data("%PDF-local-original".utf8))
        XCTAssertNil(ImportedDocumentFiles.localURL("../../private.pdf",in:new))
        await restored.removePersonalDocument(row)
        XCTAssertFalse(FileManager.default.fileExists(atPath:recovered.path))
    }
    private func speakerRecord() throws -> RecordingRecord {
        let json = #"{"id":"unit-speakers","pipeline_status":"done","transcript_revision":1,"segments":[{"id":"a","speaker":"self","speaker_id":"part0:0","speaker_name":"林晓","text":"确认目标。","start_ms":0,"end_ms":1000},{"id":"b","speaker":"unknown","speaker_id":"part0:1","text":"明确排期。","start_ms":1000,"end_ms":2000},{"id":"c","speaker":"unknown","speaker_id":"part1:0","text":"讨论交付。","start_ms":60000,"end_ms":61000}]}"#
        return try JSONDecoder().decode(RecordingRecord.self,from:Data(json.utf8))
    }
    @MainActor func testContinuousEntryOpensInEveryBuildAndKeepsReadinessGuard() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:folder)}
        let store=Store(localDirectory:folder)
        XCTAssertTrue(Store.isolatedTestRun,"Release unit hosts must not connect to the real cloud")
        store.voice.enter(store:store)
        XCTAssertTrue(store.voice.showContinuous,"Continuous conversation must also open in Release")
        XCTAssertEqual(store.voice.phase,.failed)
        XCTAssertEqual(store.voice.notice,"请先连接 Candid，再开始语音对话。")
        XCTAssertFalse(store.voice.active)
        XCTAssertFalse(store.audio.voiceActive,"Unavailable prerequisites must not acquire the microphone")
        store.voice.exit()
        XCTAssertFalse(store.voice.showContinuous)
    }
    func testSpeakerDraftKeepsChunkIDsSeparateAndOnlySendsEdits() throws {
        let record=try speakerRecord()
        var draft=RecordingSpeakerDraft(record.segments!)
        XCTAssertEqual(draft.ids,["part0:0","part0:1","part1:0"])
        XCTAssertTrue(draft.changes.isEmpty)
        draft.names["part0:0"]="  林晓  "
        XCTAssertTrue(draft.changes.isEmpty)
        draft.names["part0:1"]=" 王总 "
        XCTAssertEqual(draft.changes.count,1)
        XCTAssertEqual(draft.changes[0]["name"] as? String,"王总")
        XCTAssertEqual(draft.changes[0]["is_self"] as? Bool,false)
        XCTAssertTrue(draft.selfIDs.contains("part0:0"))
        draft.names["part1:0"]="王总"
        XCTAssertEqual(draft.changes.count,2)
        XCTAssertEqual(Set(draft.changes.compactMap{$0["speaker_id"] as? String}),["part0:1","part1:0"])
        draft.names["part0:0"]=" "
        XCTAssertEqual(draft.changes.first?["name"] as? String,"")
        draft.names["part0:1"]=String(repeating:"名",count:101)
        XCTAssertTrue(draft.invalidName)
        XCTAssertTrue(RecordingSpeakerDraft(record.segments!).changes.isEmpty)
    }
    func testEmptySpeakerNameFallsBackToIdentityLabel() throws {
        var line=(try speakerRecord()).segments![0]
        line.speaker_name=" ";XCTAssertEqual(RecordingFormat.speakerName(line),"本人")
        line.speaker="other";XCTAssertEqual(RecordingFormat.speakerName(line),"说话人 1 · 第1段")
        line.speaker_name=" 王总 ";XCTAssertEqual(RecordingFormat.speakerName(line),"王总")
    }
    @MainActor func testFailedConnectionDoesNotReplaceCredentialsOrPersonalDraft() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder); URLProtocol.unregisterClass(OnboardingStubProtocol.self); OnboardingStubProtocol.handler = nil }
        URLProtocol.registerClass(OnboardingStubProtocol.self)
        let store = Store(localDirectory: folder)
        let previousBase = store.base, previousToken = TokenVault.read()
        store.changePersonalProfile(PersonalProfile(introduction: "未同步的介绍"))
        OnboardingStubProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do { try await store.connect(token: "mock-candidate-token", backend: "http://onboarding-test.invalid"); XCTFail("Expected connection rejection") }
        catch { }
        XCTAssertEqual(store.base, previousBase)
        XCTAssertEqual(TokenVault.read(), previousToken)
        XCTAssertEqual(store.personalState.profile.introduction, "未同步的介绍")
        XCTAssertFalse(store.remote)
        store.base = "http://onboarding-test.invalid"; store.remote = true
        OnboardingStubProtocol.handler = { _ in Data("{\"profile\":{\"display_name\":\"Other device\",\"introduction\":\"新的后端资料\",\"scenarios\":[]},\"version\":4,\"completed\":true,\"documents\":[]}".utf8) }
        await store.readLatestPersonalProfile()
        XCTAssertEqual(store.personalState.version, 0)
        XCTAssertEqual(store.personalRemoteVersion, 4)
        await store.syncPersonalProfile()
        XCTAssertTrue(store.personalState.profileDirty)
        XCTAssertEqual(store.personalState.profile.introduction, "未同步的介绍")
        store.remote = false
    }
    func testOnboardingCacheMigrationKeepsProfileWhenOptionalStateIsMissing() throws {
        var state = OnboardingState(); state.profile.introduction = "已有个人介绍"; state.completed = true
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        value.removeValue(forKey: "removedDocumentIDs")
        let restored = try OnboardingState.restore(JSONSerialization.data(withJSONObject: value))
        XCTAssertEqual(restored.profile.introduction, state.profile.introduction)
        XCTAssertTrue(restored.completed)
        XCTAssertTrue(restored.removedDocumentIDs.isEmpty)
    }
    @MainActor func testBackendRestoreCannotSkipOpenOnboardingAndExplicitSaveUsesFreshRequest() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder); URLProtocol.unregisterClass(OnboardingStubProtocol.self); OnboardingStubProtocol.handler = nil }
        URLProtocol.registerClass(OnboardingStubProtocol.self)
        let store = Store(localDirectory: folder); store.base = "http://onboarding-test.invalid"; store.remote = true
        let response = Data("{\"profile\":{\"display_name\":\"Lin\",\"introduction\":\"本人背景\",\"scenarios\":[\"sales\"]},\"version\":2,\"completed\":true,\"documents\":[]}".utf8)
        OnboardingStubProtocol.handler = { _ in response }
        await store.restorePersonalProfile()
        XCTAssertFalse(store.onboarding)
        XCTAssertEqual(store.personalState.profile.display_name, "Lin")
        store.personalEditing = true
        store.changePersonalProfile(PersonalProfile(introduction: "正在编辑的草稿"))
        await store.syncPersonalProfile()
        XCTAssertTrue(store.personalState.profileDirty)
        let oldRequest = store.personalState.requestID
        store.completeOnboarding()
        XCTAssertNotEqual(store.personalState.requestID, oldRequest)
        await store.syncPersonalProfile()
        for _ in 0..<20 where store.personalSyncing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.onboarding)
        XCTAssertFalse(store.personalState.completionPending)
    }
    @MainActor func testOnboardingCompletionAndDraftSurviveStoreReloadOffline() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(localDirectory: folder)
        XCTAssertFalse(store.onboarding)
        let profile = PersonalProfile(display_name: "Lin", introduction: "我做产品设计。", scenarios: ["sales", "interview"])
        store.changePersonalProfile(profile)
        store.personalState.step = 2; store.persistOnboarding()
        let restored = Store(localDirectory: folder)
        XCTAssertEqual(restored.personalState.profile, profile)
        XCTAssertEqual(restored.personalState.step, 2)
        XCTAssertFalse(restored.onboarding)
        restored.completeOnboarding()
        let completed = Store(localDirectory: folder)
        XCTAssertTrue(completed.onboarding)
        XCTAssertTrue(completed.personalState.completionPending)
        XCTAssertTrue(completed.personalState.profileDirty)
        XCTAssertEqual(completed.personalState.profile, profile)
    }
    @MainActor func testSkipDoesNotInventProfileAndLegacyCompletedUserIsNotForcedBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(localDirectory: folder)
        store.completeOnboarding()
        XCTAssertTrue(store.personalState.profile.isEmpty)
        XCTAssertTrue(Store(localDirectory: folder).onboarding)
        try FileManager.default.removeItem(at: store.personalStateURL)
        store.onboarding = true; store.persist()
        let migrated = Store(localDirectory: folder)
        XCTAssertTrue(migrated.onboarding)
        XCTAssertTrue(migrated.personalState.profile.isEmpty)
    }
    @MainActor func testAudioLeaseSharesCaptureAndRejectsPlaybackConflict() throws {
        let resources=AudioResources();let voice=try resources.acquire(.voice)
        let meeting=try resources.acquire(.meeting)
        XCTAssertTrue(resources.owns(voice));XCTAssertTrue(resources.owns(meeting))
        XCTAssertThrowsError(try resources.acquire(.manualSpeech))
        XCTAssertThrowsError(try resources.acquire(.voice))
        resources.release(voice);XCTAssertTrue(resources.owns(meeting));XCTAssertFalse(resources.voiceActive)
        resources.release(voice);XCTAssertTrue(resources.owns(meeting))
        resources.release(meeting);XCTAssertNil(resources.owner)
    }
    @MainActor func testExportPaginatesLongTextAndKeepsChinese() throws {
        let text=String(repeating:"粤语原话与承诺日期，不混入内部纪要。\n",count:240)
        let value=ProductExport(title:"沟通跟进",text:text,internal:false)
        let pdf=try ProductRenderer.render(value,format:"PDF")[0]
        let bytes=try Data(contentsOf:pdf);XCTAssertTrue(bytes.starts(with:Data("%PDF".utf8)))
        let images=try ProductRenderer.render(value,format:"图片卡片");XCTAssertGreaterThan(images.count,1)
        let file=try ProductRenderer.render(value,format:"文字")[0]
        XCTAssertTrue(try String(contentsOf:file,encoding:.utf8).contains("粤语原话"))
        for url in [pdf,file]+images {try? FileManager.default.removeItem(at:url)}
    }
    func testVADHandlesFragmentedSilentPCMWithoutInventingSpeech() throws {
        let detector = try VoiceActivityDetector()
        XCTAssertTrue(try detector.frames(Data(repeating: 0, count: 318)).isEmpty)
        let frames = try detector.frames(Data(repeating: 0, count: 962))
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames.allSatisfy { $0.0.count == 640 && !$0.1 && $0.2 == 0 })
        XCTAssertTrue(try detector.frames(Data()).isEmpty)
    }
    private func fixture(in folder: URL, packets: Int = 50) throws -> URL {
        var error: Int32 = 0
        let encoder = try XCTUnwrap(opus_encoder_create(16_000, 2, OPUS_APPLICATION_AUDIO, &error))
        XCTAssertEqual(error, OPUS_OK)
        defer { opus_encoder_destroy(encoder) }
        var data = Data()
        for frame in 0..<packets {
            var pcm = [Int16](repeating: 0, count: 640)
            for index in pcm.indices {
                let position = Double(frame * 320 + index / 2)
                let angle = position * (2.0 * Double.pi * 440.0 / 16_000.0)
                pcm[index] = Int16(sin(angle) * 8000.0)
            }
            var packet = [UInt8](repeating: 0, count: 160)
            let count = opus_encode(encoder, pcm, 320, &packet, 160)
            XCTAssertGreaterThan(count, 0)
            XCTAssertEqual(opus_packet_pad(&packet, count, 160), OPUS_OK)
            data.append(contentsOf: packet)
        }
        let url = folder.appendingPathComponent("synthetic-sdk-packets.opus")
        try data.write(to: url)
        return url
    }
    func testRawOpusDecodesToStereoWavWithExactDuration() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = try fixture(in: folder)
        let wav = folder.appendingPathComponent("decoded.wav")
        XCTAssertEqual(try SoundcoreAudio.decode(raw: raw, wav: wav), 1000)
        let audio = try AVAudioFile(forReading: wav)
        XCTAssertEqual(audio.length, 16_000)
        XCTAssertEqual(audio.fileFormat.channelCount, 2)
        XCTAssertEqual(audio.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(try Data(contentsOf: wav).count, 44 + 64_000)
    }
    func testRejectsTruncatedPacketWithoutOutput() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("truncated.opus")
        let wav = folder.appendingPathComponent("decoded.wav")
        try Data(repeating: 0, count: 159).write(to: raw)
        XCTAssertThrowsError(try SoundcoreAudio.decode(raw: raw, wav: wav))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
    }
    func testConvertsToPlayableM4A() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = try fixture(in: folder)
        let result = folder.appendingPathComponent("playable.m4a")
        let duration = try await SoundcoreAudio.convert(raw: raw, destination: result)
        XCTAssertEqual(duration, 1000)
        let asset = AVURLAsset(url: result)
        let playable = try await asset.load(.isPlayable)
        let length = try await asset.load(.duration)
        XCTAssertTrue(playable)
        XCTAssertEqual(length.seconds, 1, accuracy: 0.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("playable.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path))
    }
    func testConversionDoesNotOverwriteExistingRecording() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = try fixture(in: folder)
        let result = folder.appendingPathComponent("existing.m4a")
        let original = Data("existing recording".utf8)
        try original.write(to: result)
        do {
            _ = try await SoundcoreAudio.convert(raw: raw, destination: result)
            XCTFail("Existing recording must not be overwritten")
        } catch { XCTAssertEqual(try Data(contentsOf: result), original) }
    }
    @MainActor func testSimulatorRejectsHardwareInitialization() throws {
        guard Soundcore.simulator else { return }
        let device = Soundcore()
        XCTAssertThrowsError(try device.initialize(SoundcoreAuth()))
        XCTAssertFalse(device.ready)
        XCTAssertFalse(device.scanning)
    }
}

// SDK metadata is used for server-side license headers, never a user-entered version.
extension SoundcoreAudioTests {
    func testSoundcoreSDKMetadataForAuthorizationHeaders() {
        let sdk = module_spplinkKit.SoundcoreSDK.companion
        let product = sdk.getProductCode()
        let version = sdk.getVersion()
        XCTAssertEqual(product, "D3200")
        XCTAssertTrue(["V1.3.01", "V1.3.02"].contains(version), "Vendor SDK must match Anker configured versions; rerun prepare-soundcore.sh")
        print("SOUNDCORE_SDK_METADATA=\(product)|\(version)")
    }
}

private final class SoundcoreAuthAcceptanceListener: NSObject, OnAuthResultListener {
    let completed: (AuthResult) -> Void
    private let lock = NSLock()
    private var delivered = false
    init(completed: @escaping (AuthResult) -> Void) { self.completed = completed }
    func onAuthResult(result: AuthResult) {
        lock.lock(); let first = !delivered; delivered = true; lock.unlock()
        if first { completed(result) }
    }
}
extension SoundcoreAudioTests {
    func testSoundcoreDiscoveryKeepsDistinctDevicesSharingAServiceUUID() {
        let first = SoundcoreDevice(name: "D3200", mac: "AA:01", uuid: "shared-service")
        let second = SoundcoreDevice(name: "D3200", mac: "AA:02", uuid: "shared-service")
        XCTAssertNotEqual(first.id, second.id)
        let callbacks = SoundcoreCallbacks()
        var result: CanDid.SoundcoreDevice?
        callbacks.event = { if case .scan(let device) = $0 { result = device } }
        let model = BlueDeviceModel()
        model.macAddress = first.mac; model.uuid = first.uuid; model.productCode = "D3200"; model.bindingStatus = "1"
        callbacks.onScanSuccess(device: model)
        XCTAssertEqual(result?.mac, first.mac)
        XCTAssertEqual(result?.productCode, "D3200")
        XCTAssertTrue(result?.bound == true)
        XCTAssertEqual(result?.uuid, CanDid.SoundcoreDevice.serviceUUID)
        // SDK productCode/uuid are optional; a valid scanned MAC must remain discoverable.
        model.productCode = nil; model.uuid = nil
        callbacks.onScanSuccess(device: model)
        XCTAssertEqual(result?.mac, first.mac)
        XCTAssertEqual(result?.uuid, CanDid.SoundcoreDevice.serviceUUID)
    }
    func testSoundcoreGrantExpiryAndPhoneIdentity() throws {
        let id = try SoundcoreAuth.phoneID()
        XCTAssertEqual(id, try SoundcoreAuth.phoneID())
        XCTAssertNotNil(UUID(uuidString: id))
        var auth = SoundcoreAuth(userID: "owner", deviceID: id, token: "token", expiresAt: Date().timeIntervalSince1970 + 3600)
        XCTAssertTrue(auth.valid)
        auth.expiresAt = Date().timeIntervalSince1970 - 1
        XCTAssertFalse(auth.valid)
    }
    // Explicit opt-in: a locally minted, private fixture in the simulator app's Caches.
    // Ordinary unit runs do not contact Anker or embed any credential in source.
    @MainActor func testSoundcoreLiveSDKAuthorizationWhenPrivateFixtureProvided() async throws {
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("soundcore-auth-acceptance.private.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("No private live-authorization fixture") }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let data = json["data"] as! [String: Any]
        let license = data["license"] as! [String: Any]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: license, options: [.sortedKeys]), as: UTF8.self)
        let done = expectation(description: "Actual SDK accepts freshly minted QA grant")
        let listener = SoundcoreAuthAcceptanceListener { result in
            XCTAssertTrue(result.success, "SDK auth failed: \(result.error?.code ?? 0)")
            print("SOUNDCORE_LIVE_SDK_AUTH success=\(result.success) online=\(result.isOnline) licenseValid=\(result.licenseValid) code=\(result.error?.code ?? 0)")
            done.fulfill()
        }
        let auth = AuthService.shared
        auth.setEnvironment(environment: .development)
        auth.updateServerUrl(baseUrl: "https://speaker-api-qa.anker-in.com")
        auth.doInitAuth(userId: license["user_id"] as! String, deviceId: license["device_id"] as! String,
            token: data["token"] as! String, licenseJson: text, license_signature: data["license_signature"] as! String,
            sdkVersion: SoundcoreSDK.companion.getVersion(), productCode: SoundcoreSDK.companion.getProductCode(), listener: listener)
        await fulfillment(of: [done], timeout: 30)
        auth.release()
    }
}

extension SoundcoreAudioTests {
    func testDeviceLivePCMHandlesFragmentationDuplicatesAndMissingPackets() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = try Data(contentsOf: fixture(in: folder, packets: 3))
        let decoder = try DevicePCMDecoder()
        XCTAssertTrue(try decoder.decode(Data(raw.prefix(80)), sequence: 1).0.isEmpty)
        let complete = try decoder.decode(Data(raw[80..<160]), sequence: 2)
        XCTAssertEqual(complete.0.count, 640)
        XCTAssertFalse(complete.1)
        XCTAssertTrue(try decoder.decode(Data(raw[80..<160]), sequence: 2).0.isEmpty)
        let gap = try decoder.decode(Data(raw[320..<480]), sequence: 4)
        XCTAssertEqual(gap.0.count, 640)
        XCTAssertTrue(gap.1)
        XCTAssertTrue(gap.0.contains { $0 != 0 })
    }
    func testDifferentRecordingBeansNeverShareAnImportOrLiveSessionKey() {
        let api = API(base: "https://fixture.invalid", token: "fixture")
        let first = CanDid.SoundcoreDevice(name: "soundcore Work", mac: "AA:01", uuid: CanDid.SoundcoreDevice.serviceUUID, serial: "SN-A", productCode: "")
        let second = CanDid.SoundcoreDevice(name: "soundcore Work", mac: "AA:02", uuid: CanDid.SoundcoreDevice.serviceUUID, serial: "SN-B", productCode: "")
        XCTAssertTrue(first.likelyRecorder)
        XCTAssertNotEqual(first.recordingID, second.recordingID)
        XCTAssertNotEqual(DeviceRecordingMap.requestID(api: api, fileID: 1, deviceID: first.recordingID), DeviceRecordingMap.requestID(api: api, fileID: 1, deviceID: second.recordingID))
        XCTAssertFalse(CanDid.SoundcoreDevice(name: "Nearby headphones", mac: "AA:03", uuid: CanDid.SoundcoreDevice.serviceUUID, productCode: "").likelyRecorder)
    }
}

extension SoundcoreAudioTests {
    func testVendorConcatenatedTransferFileStaysInsideOwnedDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = URL(fileURLWithPath: SoundcoreTransferPaths.sdkDirectory(folder) + "1792140465.opus")
        try Data(repeating: 1, count: 160).write(to: file)
        XCTAssertEqual(try SoundcoreTransferPaths.completedFile(file.path, in: folder), file.resolvingSymlinksInPath())
        // Reproduce the real SDK behavior with the old missing slash; that sibling remains rejected.
        let misplaced = URL(fileURLWithPath: folder.path + "1792140465.opus")
        try Data(repeating: 1, count: 160).write(to: misplaced)
        XCTAssertThrowsError(try SoundcoreTransferPaths.completedFile(misplaced.path, in: folder))
        let link = folder.appendingPathComponent("linked.opus")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: misplaced)
        XCTAssertThrowsError(try SoundcoreTransferPaths.completedFile(link.path, in: folder))
        XCTAssertThrowsError(try SoundcoreTransferPaths.completedFile(folder.path, in: folder))
    }
}
