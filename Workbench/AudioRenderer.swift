import Foundation
import AVFoundation
import Darwin

struct AudioRenderSummary {
    let duration: Double
    let musicDuration: Double
    let peak: Float
    let attenuation: Float
}

/// Uses the same FluidSynth scheduler as realtime preview and writes an atomic 48 kHz / 24-bit stereo WAV.
enum AudioRenderer {
    static func validate(soundFont: URL, library: URL) throws {
        let session = try FluidSynthSession(tracks: [], soundFont: soundFont, library: library,
                                           mix: [:], masterGain: 0.8, reverb: true)
        for program in 0..<128 {
            guard session.api.selectProgram(session.synth, 0, session.fontID, 0, Int32(program)) == 0 else {
                throw invalid("这个音色库缺少第 \(program + 1) 号旋律音色。请选择包含 128 种乐器及标准鼓组的完整 General MIDI SF2 音色库。")
            }
        }
        _ = session.api.setChannelType(session.synth, 9, 1)
        guard session.api.selectProgram(session.synth, 9, session.fontID, 128, 0) == 0 else {
            throw invalid("这个音色库缺少标准鼓组。请选择完整的 General MIDI SF2 音色库。")
        }
    }

    static func render(_ arrangement: ArrangementResult, soundFont: URL, library: URL, destination: URL,
                       mix: [AccompanimentPart: PartMix] = [:], masterGain: Double = 0.8, reverb: Bool = true,
                       progress: (Double) -> Void = { _ in }, cancelled: () -> Bool = { false }) throws -> AudioRenderSummary {
        func checkCancellation() throws { if cancelled() { throw CancellationError() } }
        try checkCancellation()
        let state = try FluidPlaybackState(arrangement: arrangement, soundFont: soundFont, library: library,
                                          mix: mix, masterGain: masterGain, reverb: reverb)
        let directory = destination.deletingLastPathComponent().appendingPathComponent(".genos-audio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporaryFloat = directory.appendingPathComponent("mix.caf")
        let temporaryWAV = directory.appendingPathComponent("mix.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let capacity: AVAudioFrameCount = 1024
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var intermediateSettings = format.settings
        intermediateSettings[AVLinearPCMIsNonInterleaved] = false
        var floatWriter: AVAudioFile? = try AVAudioFile(forWriting: temporaryFloat, settings: intermediateSettings)
        var peak: Float = 0
        var reported = -1
        while state.cursor < state.totalFrames {
            try checkCancellation()
            let count = Int(min(Int64(capacity), state.totalFrames - state.cursor))
            buffer.frameLength = AVAudioFrameCount(count)
            let channels = buffer.floatChannelData!
            try state.render(left: channels[0], right: channels[1], frames: count)
            for channel in 0..<2 {
                for frame in 0..<count {
                    let value = channels[channel][frame]
                    guard value.isFinite else { throw invalid("音色库生成了无效的音频数据。") }
                    peak = max(peak, abs(value))
                }
            }
            try floatWriter!.write(from: buffer)
            let percent = Int(Double(state.cursor) / Double(state.totalFrames) * 85)
            if percent != reported { progress(Double(percent) / 100); reported = percent }
        }
        floatWriter = nil
        try checkCancellation()
        // Constant attenuation prevents overload without compressing or boosting quiet passages.
        let ceiling: Float = 0.8912509 // -1 dBFS
        let attenuation: Float = peak > ceiling ? ceiling / peak : 1
        let reader = try AVAudioFile(forReading: temporaryFloat)
        var writer: AVAudioFile? = try AVAudioFile(forWriting: temporaryWAV, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        var cursor: Int64 = 0
        while cursor < state.totalFrames {
            try checkCancellation()
            try reader.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(capacity), state.totalFrames - cursor)))
            guard buffer.frameLength > 0 else { throw invalid("音频中间文件不完整。") }
            if attenuation < 1 {
                for channel in 0..<2 {
                    for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] *= attenuation }
                }
            }
            try writer!.write(from: buffer)
            cursor += Int64(buffer.frameLength)
            let percent = 85 + Int(Double(cursor) / Double(state.totalFrames) * 15)
            if percent != reported { progress(Double(percent) / 100); reported = percent }
        }
        writer = nil
        try checkCancellation()
        guard rename(temporaryWAV.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        progress(1)
        return AudioRenderSummary(duration: Double(state.totalFrames) / 48_000,
                                  musicDuration: Double(state.musicFrames) / 48_000, peak: peak, attenuation: attenuation)
    }
}
