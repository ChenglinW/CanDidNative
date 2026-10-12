import Foundation
import AVFoundation

enum SoundcoreAudio {
    // SDK v1.3.01 Q&A: headerless Opus, 160-byte packets, 20 ms, 16 kHz stereo.
    static let packetBytes = 160
    static let sampleRate: Int32 = 16_000
    static let channels: Int32 = 2
    static let frameSamples: Int32 = 320

    static func decode(raw: URL, wav: URL) throws -> Int {
        guard !FileManager.default.fileExists(atPath: wav.path) else { throw PrototypeError.message("转换目标已有文件，请避免覆盖已有音频。") }
        let input = try FileHandle(forReadingFrom: raw)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        guard size > 0, size % UInt64(packetBytes) == 0, size <= 25 * 1024 * 1024 else {
            throw PrototypeError.message("设备音频为空、不完整或超过 25MB，保留设备原文件以便重新同步。")
        }
        try input.seek(toOffset: 0)
        var code: Int32 = 0
        guard let decoder = opus_decoder_create(sampleRate, channels, &code), code == OPUS_OK else {
            throw PrototypeError.message("无法初始化 soundcore 音频解码器。")
        }
        defer { opus_decoder_destroy(decoder) }
        guard FileManager.default.createFile(atPath: wav.path, contents: wavHeader(pcmBytes: 0)) else {
            throw PrototypeError.message("无法创建音频转换文件。")
        }
        let output = try FileHandle(forWritingTo: wav)
        defer { try? output.close() }
        try output.seekToEnd()
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: wav) } }
        var pcm = [Int16](repeating: 0, count: Int(frameSamples * channels))
        var bytes: UInt32 = 0
        while let packet = try input.read(upToCount: packetBytes), !packet.isEmpty {
            guard packet.count == packetBytes else { throw PrototypeError.message("设备音频尾包不完整，请重新同步。") }
            let samples = packet.withUnsafeBytes { data in
                opus_decode(decoder, data.bindMemory(to: UInt8.self).baseAddress, Int32(packet.count), &pcm, frameSamples, 0)
            }
            guard samples == frameSamples else {
                throw PrototypeError.message("设备音频格式与 SDK 文档不一致或数据损坏（\(samples)），请重新同步。")
            }
            let chunk = pcm.withUnsafeBytes { Data($0) }
            try output.write(contentsOf: chunk)
            bytes += UInt32(chunk.count)
        }
        try output.seek(toOffset: 0)
        try output.write(contentsOf: wavHeader(pcmBytes: bytes))
        try output.synchronize()
        complete = true
        return Int(bytes) * 1000 / (Int(sampleRate) * Int(channels) * 2)
    }

    static func convert(raw: URL, destination: URL) async throws -> Int {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw PrototypeError.message("这个场次已有录音，不能覆盖。") }
        let wav = destination.deletingPathExtension().appendingPathExtension("wav")
        let milliseconds = try await Task.detached(priority: .userInitiated) { try decode(raw: raw, wav: wav) }.value
        defer { try? FileManager.default.removeItem(at: wav) }
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: wav), presetName: AVAssetExportPresetAppleM4A) else {
            throw PrototypeError.message("无法转换为可回放音频。设备原文件仍保留。")
        }
        export.outputURL = destination
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw PrototypeError.message("音频转换失败，请重新同步设备文件。")
        }
        return milliseconds
    }

    private static func wavHeader(pcmBytes: UInt32) -> Data {
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(pcmBytes + 36); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(channels))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * channels * 2))
        append(UInt16(channels * 2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(pcmBytes)
        return data
    }
}
