import Foundation
import AVFoundation
import SXCore

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
}
