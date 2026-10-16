import XCTest
import AVFoundation
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
