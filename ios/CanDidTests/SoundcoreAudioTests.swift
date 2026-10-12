import XCTest
import AVFoundation
@testable import CanDid

final class SoundcoreAudioTests: XCTestCase {
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
