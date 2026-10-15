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
