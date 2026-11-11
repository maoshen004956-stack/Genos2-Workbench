import Foundation
import AVFoundation
import SXCore
import Darwin

@main
struct VerifyFluid {
    static var library: URL { URL(fileURLWithPath: CommandLine.arguments[2]) }
    static var font: URL { URL(fileURLWithPath: CommandLine.arguments[1]) }
    static var styleURL: URL { URL(fileURLWithPath: CommandLine.arguments[3]).appendingPathComponent("jazz/MediumJazzWaltz.T555.sst") }
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 4 else {
            throw invalid("Usage: VerifyAudio <GeneralUser-GS.sf2> <libfluidsynth.dylib> <Genos2-style-folder>")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("genos-audio-check-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        try AudioRenderer.validate(soundFont: font, library: library)
        print("GM128 + standard drum validation passed")
        let missingKitTrack = PerformanceTrack(part: .rhythm1, style: try Style(url: styleURL), mix: .init(program: 126))
        _ = try FluidSynthSession(tracks: [missingKitTrack], soundFont: font, library: library, mix: [:], masterGain: 0.8, reverb: true)
        do {
            _ = try FluidSynthSession(tracks: [missingKitTrack], soundFont: font, library: library, mix: [.rhythm1: .init(program: 126)], masterGain: 0.8, reverb: true)
            preconditionFailure("Explicit missing kit accepted")
        } catch { precondition(error.localizedDescription.contains("127")) }
        print("Automatic drum fallback and explicit missing-kit rejection passed")

        let style = try Style(url: styleURL)
        let chart = Chart(style: style.name, bpm: 240, key: .init(fifths: -4, minor: true), meter: .init(3,4), segments: [
            .init(styleSection: "Main A", name: "A", bars: ["Fm7", "Gm7", "Abmaj7 Gm7", "Fm7"], lengthInBars: nil)
        ])
        let result = try renderArrangement(chart, style: style)
        let destination = output.appendingPathComponent("sample.wav")
        let start = Date()
        let summary = try AudioRenderer.render(result, soundFont: font, library: library, destination: destination)
        let file = try AVAudioFile(forReading: destination)
        precondition(file.fileFormat.sampleRate == 48000 && file.fileFormat.channelCount == 2)
        precondition(file.length == Int64(summary.duration * 48000))
        precondition(summary.peak > 0.001 && summary.peak * summary.attenuation <= 0.892)
        print("WAV", summary.duration, "seconds; peak", summary.peak, "attenuation", summary.attenuation, "render",Date().timeIntervalSince(start),"s")
        let saved = try Data(contentsOf: destination)
        do { _ = try AudioRenderer.render(result, soundFont: font, library: library, destination: destination, cancelled: {true}); preconditionFailure("Cancellation accepted") }
        catch is CancellationError { precondition(tryData(destination) == saved) }
        print("Cancelled render preserves destination")
        var loud = PerformanceTrack(part: .chord1, style: style, mix: .init(program: 56, volume: 127))
        loud.write(MIDI(0xb0, 11, 127), at: 0)
        for key: UInt8 in 36...96 { loud.write(MIDI(0x90, key, 127), at: 0); loud.write(MIDI(0x80, key), at: style.ticksPerBar) }
        let stress = ArrangementResult(style: style, meter: .init(3,4), key: .cMajor, bpm: 180,
                                       duration: style.ticksPerBar, tracks: [loud], markers: [], harmony: [])
        let limited = try AudioRenderer.render(stress, soundFont: font, library: library,
                    destination: output.appendingPathComponent("stress.wav"))
        precondition(limited.peak > 0.891 && limited.attenuation < 1 && limited.peak * limited.attenuation <= 0.892)
        print("Overload attenuation verified",limited.peak,limited.attenuation)
        try verifyRepeatedSeeks(style: style)

        let player = try FluidAudioPlayer(arrangement: result, soundFont: font, library: library)
        try player.play()
        try await Task.sleep(for: .milliseconds(400))
        precondition(player.position > 0.1 && player.isPlaying)
        player.pause()
        let paused = player.position
        try await Task.sleep(for: .milliseconds(200))
        precondition(player.position == paused && !player.isPlaying)
        player.seek(to: 1.25)
        precondition(abs(player.position - 1.25) < 0.0001)
        try player.play()
        player.setMix(.init(program: 4, volume: 70, pan: 20, reverb: 20), for: .chord1)
        player.setMutedParts([.rhythm1])
        try await Task.sleep(for: .milliseconds(200))
        precondition(player.position > 1.3 && player.isPlaying && player.errorMessage == nil)
        player.setMix(.init(), for: .chord1)
        player.setMutedParts([])
        player.setMasterGain(0.5)
        player.seek(to: player.musicDuration - 0.1)
        try await Task.sleep(for: .seconds(5))
        precondition(!player.isPlaying && player.position >= player.duration && player.errorMessage == nil)
        player.stop()
        print("Realtime playback/pause/resume/seek/live mix/mute/master gain/tail completion passed")
    }
    static func tryData(_ url: URL) -> Data { try! Data(contentsOf: url) }

    /// Synthetic long-song automation catches paused seeks that enqueue thousands
    /// of DSP updates without consuming them. No user chart is required.
    static func verifyRepeatedSeeks(style: Style) throws {
        let parts: [AccompanimentPart] = [.chord1, .pad, .phrase1]
        let tracks = parts.map { part -> PerformanceTrack in
            var track = PerformanceTrack(part: part, style: style, mix: .init(program: 48))
            for bar in 0..<96 {
                let start = bar * style.ticksPerBar
                for (cc, value): (UInt8, UInt8) in [(101, 0), (100, 0), (6, 12), (38, 0), (101, 127), (100, 127)] {
                    track.write(MIDI(0xb0, cc, value), at: start)
                }
                for key: UInt8 in [48, 52, 55] { track.write(MIDI(0x90, key, 88), at: start) }
                for step in 0..<8 {
                    let tick = start + step * style.ticksPerBar / 8
                    track.write(MIDI(0xb0, 10, UInt8(32 + (bar + step) % 64)), at: tick)
                    track.write(MIDI(0xb0, 11, UInt8(80 + (bar + step) % 40)), at: tick)
                }
                for key: UInt8 in [48, 52, 55] { track.write(MIDI(0x80, key), at: start + style.ticksPerBar) }
            }
            return track
        }
        let long = ArrangementResult(style: style, meter: SongMeter(style), key: .cMajor, bpm: 120,
                                     duration: 96 * style.ticksPerBar, tracks: tracks, markers: [], harmony: [])
        let state = try FluidPlaybackState(arrangement: long, soundFont: font, library: library)
        typealias SetLog = @convention(c) (Int32, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
        typealias GetValue = @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<Int32>?) -> Int32
        let log = unsafeBitCast(dlsym(state.session.api.handle, "fluid_set_log_function")!, to: SetLog.self)
        let sensitivity = unsafeBitCast(dlsym(state.session.api.handle, "fluid_synth_get_pitch_wheel_sens")!, to: GetValue.self)
        let warnings = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        warnings.initialize(to: 0)
        let callback: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { _, _, data in
            data!.assumingMemoryBound(to: Int.self).pointee += 1
        }
        let previous = log(2, unsafeBitCast(callback, to: UnsafeMutableRawPointer.self), warnings)
        defer { _ = log(2, previous, nil); warnings.deallocate() }
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
        defer { left.deallocate(); right.deallocate() }
        try state.render(left: left, right: right, frames: 1024)
        for _ in 0..<4 {
            for bar in [0, 8, 16, 24, 40, 50, 58, 66, 74, 82, 84, 88, 92, 95] {
                let target = (Double(bar) + 0.1) / 96 * Double(state.musicFrames) / 48_000
                try state.seek(to: target) // no render between seeks, as when paused
                precondition(abs(Double(state.cursor) / 48_000 - target) <= 1.0 / 48_000)
                var range: Int32 = 0
                precondition(sensitivity(state.session.synth, Int32(parts[0].rawValue), &range) == 0 && range == 12,
                             "Seek must preserve ordered RPN pitch-bend range commands")
            }
        }
        precondition(warnings.pointee == 0, "Paused long seeks overflowed the FluidSynth queue")
        try state.render(left: left, right: right, frames: 1024)
        let peak = (0..<1024).reduce(Float(0)) { max($0, abs(left[$1]), abs(right[$1])) }
        precondition(peak > 0.0001 && (0..<1024).allSatisfy { left[$0].isFinite && right[$0].isFinite },
                     "Restored held notes must render finite, audible audio")

        var sustained = PerformanceTrack(part: .pad, style: style, mix: .init(program: 48))
        sustained.write(MIDI(0xb0, 64, 127), at: 0)
        sustained.write(MIDI(0x90, 60, 100), at: 0)
        sustained.write(MIDI(0x80, 60), at: style.ticksPerBar / 4)
        sustained.write(MIDI(0xb0, 64, 0), at: style.ticksPerBar)
        let pedalSong = ArrangementResult(style: style, meter: SongMeter(style), key: .cMajor, bpm: 120,
                                          duration: 2 * style.ticksPerBar, tracks: [sustained], markers: [], harmony: [])
        let pedal = try FluidPlaybackState(arrangement: pedalSong, soundFont: font, library: library)
        try pedal.seek(to: Double(pedal.musicFrames) / 48_000 * 0.25)
        try pedal.render(left: left, right: right, frames: 1024)
        precondition((0..<1024).contains { abs(left[$0]) > 0.0001 || abs(right[$0]) > 0.0001 }, "Sustain pedal note missing after seek")
        try pedal.seek(to: Double(pedal.musicFrames) / 48_000 * 0.75)
        try pedal.render(left: left, right: right, frames: 1024)
        precondition((0..<1024).allSatisfy { abs(left[$0]) < 0.00001 && abs(right[$0]) < 0.00001 }, "Old notes survived pedal-up seek")
        precondition(warnings.pointee == 0)
        print("96-bar continuous automation: 56 paused seeks, zero warnings, exact cursor, RPN range, audible resume and sustain restoration passed")
    }
}
