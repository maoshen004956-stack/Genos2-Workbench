import AppKit
import AVFoundation
import SwiftUI
import SXCore

@main
struct VerifyAudio {
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }

    @MainActor static func main() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("genos2-audio-qa-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "com.local.genos2.audio-qa." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        check(workspace.style != nil, "Style library missing")
        let song = try IRealImport.parse(data: Data("irealbook://Audio QA=Test=Waltz=F-=n=T34*A[F-7|G-7|Ab^7 G-7|F-7Z".utf8))[0]
        let style = workspace.suggestedStyle(for: song)!
        try workspace.loadIRealSong(song, stylePath: style.path, undoManager: nil)
        workspace.draft.bpm = "180"
        let source = workspace.soundFontURL, library = SoundSources.libraryURL
        try AudioRenderer.validate(soundFont: source, library: library)
        let chart = Chart(style: workspace.draft.stylePath, bpm: 180, key: workspace.key, meter: workspace.meter,
                          segments: workspace.draft.blocks.map { .init(styleSection: $0.pattern, name: $0.name, bars: $0.bars) })
        let result = try renderArrangement(chart, style: workspace.style!)
        let wav = output.appendingPathComponent("试听示例.wav")
        let summary = try AudioRenderer.render(result, soundFont: source, library: library, destination: wav)
        let file = try AVAudioFile(forReading: wav)
        check(file.processingFormat.sampleRate == 48_000 && file.processingFormat.channelCount == 2, "WAV format")
        check(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 24, "24 bit depth")
        check(summary.peak > 0.001 && summary.peak.isFinite, "Non-silent audio")
        check(abs(summary.musicDuration - 4) < 0.01, "3/4 duration")
        check(summary.peak * summary.attenuation <= 0.892, "No clipping in exported WAV")
        print("WAV verified: 48 kHz / 24 bit / stereo, peak \(summary.peak), music \(summary.musicDuration)s")

        let before = try workspace.projectData()
        workspace.togglePreview()
        workspace.setMix(.bass) { $0.volume = 87; $0.pan = 48 }
        check(workspace.preview == .loading, "Mix while loading must not cancel")
        let deadline = Date().addingTimeInterval(20)
        while workspace.preview == .loading && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if let message = workspace.message { throw invalid(message) }
        check(workspace.preview == .playing, "Realtime audio started")
        try await Task.sleep(for: .milliseconds(200))
        workspace.setMix(.bass) { $0.volume = 52; $0.program = 32; $0.reverb = 30 }
        workspace.setPart(.rhythm2, enabled: false)
        workspace.soloPart = .bass
        check(workspace.preview == .playing, "Live mix does not interrupt playback")
        workspace.togglePreview()
        check(workspace.preview == .paused, "Pause")
        let paused = workspace.previewProgress
        try await Task.sleep(for: .milliseconds(150))
        check(workspace.previewProgress == paused, "Paused playhead is stable")
        workspace.seekPreview(0.55)
        check(workspace.previewPosition?.barNumber == 3, "Seek updates chord highlight")
        workspace.soloPart = nil
        workspace.togglePreview()
        check(workspace.preview == .playing, "Resume")
        try await Task.sleep(for: .milliseconds(120))
        workspace.stopPreview()
        check(workspace.preview == .idle && workspace.previewPosition == nil, "Stop clears playback state")

        let saved = try workspace.projectData()
        let project = output.appendingPathComponent("mix.genos2song")
        try saved.write(to: project)
        workspace.resetMix()
        try workspace.loadProject(at: project, undoManager: nil)
        check(workspace.partMix(.bass).volume == 52 && workspace.partMix(.bass).program == 32, "Mix survives reopen")
        workspace.soloPart = .phrase2
        try workspace.loadIRealSong(song, stylePath: style.path, undoManager: nil)
        check(workspace.soloPart == nil, "Import clears previous solo")
        let legacy = output.appendingPathComponent("legacy.genos2song")
        var json = try JSONSerialization.jsonObject(with: before) as! [String: Any]
        json["version"] = 1
        try JSONSerialization.data(withJSONObject: json).write(to: legacy)
        try workspace.loadProject(at: legacy, undoManager: nil)
        check(workspace.draft.title == "Audio QA", "Version 1 project still opens")

        let original = try workspace.projectData()
        var badJSON = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        var badDraft = badJSON["draft"] as! [String: Any]
        badDraft["soundFont"] = ["id": "../unsafe.sf2", "name": "Invalid"]
        badJSON["draft"] = badDraft
        try JSONSerialization.data(withJSONObject: badJSON).write(to: project)
        do { try workspace.loadProject(at: project, undoManager: nil); preconditionFailure("Unsafe sound reference accepted") }
        catch { check(try workspace.projectData() == original, "Failed open does not modify project") }

        _ = NSApplication.shared
        let host = NSHostingView(rootView: SoundMixerView(workspace: workspace)
            .environment(\.locale, Locale(identifier: "zh_Hans")).preferredColorScheme(.light).background(Color.white))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("mixer.png"))
        }
        print("Workspace live mixing, pause/resume/seek, project compatibility and solo reset passed.")
        print("QA artifacts: \(output.path)")
    }
}
