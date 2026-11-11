import Foundation
import Darwin
import SXCore

final class FluidAPI {
    typealias Reset = @convention(c) (OpaquePointer?) -> Int32
    typealias Gain = @convention(c) (OpaquePointer?, Float) -> Void
    typealias NewSettings = @convention(c) () -> OpaquePointer?
    typealias Delete = @convention(c) (OpaquePointer?) -> Void
    typealias NewSynth = @convention(c) (OpaquePointer?) -> OpaquePointer?
    typealias SetNumber = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Double) -> Int32
    typealias SetInteger = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32) -> Int32
    typealias LoadFont = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32) -> Int32
    typealias TwoInts = @convention(c) (OpaquePointer?, Int32, Int32) -> Int32
    typealias ThreeInts = @convention(c) (OpaquePointer?, Int32, Int32, Int32) -> Int32
    typealias FourInts = @convention(c) (OpaquePointer?, Int32, Int32, Int32, Int32) -> Int32
    typealias OneInt = @convention(c) (OpaquePointer?, Int32) -> Int32
    typealias RenderFloat = @convention(c) (OpaquePointer?, Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafeMutableRawPointer?, Int32, Int32) -> Int32

    let systemReset: Reset
    let setGain: Gain
    let handle: UnsafeMutableRawPointer
    let newSettings: NewSettings
    let deleteSettings: Delete
    let settingsNumber: SetNumber
    let settingsInteger: SetInteger
    let newSynth: NewSynth
    let deleteSynth: Delete
    let loadFont: LoadFont
    let setChannelType: TwoInts
    let selectProgram: FourInts
    let noteOn: ThreeInts
    let noteOff: TwoInts
    let control: ThreeInts
    let keyPressure: ThreeInts
    let channelPressure: TwoInts
    let pitchBend: TwoInts
    let allNotesOff: OneInt
    let renderFloat: RenderFloat

    init(url: URL) throws {
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            throw invalid("无法加载高品质音源引擎，请重新安装伴奏工作台。")
        }
        func load<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let symbol = dlsym(handle, name) else { throw invalid("音源引擎缺少 \(name)，请重新安装应用。") }
            return unsafeBitCast(symbol, to: type)
        }
        do {
            systemReset = try load("fluid_synth_system_reset", Reset.self)
            setGain = try load("fluid_synth_set_gain", Gain.self)
            newSettings = try load("new_fluid_settings", NewSettings.self)
            deleteSettings = try load("delete_fluid_settings", Delete.self)
            settingsNumber = try load("fluid_settings_setnum", SetNumber.self)
            settingsInteger = try load("fluid_settings_setint", SetInteger.self)
            newSynth = try load("new_fluid_synth", NewSynth.self)
            deleteSynth = try load("delete_fluid_synth", Delete.self)
            loadFont = try load("fluid_synth_sfload", LoadFont.self)
            setChannelType = try load("fluid_synth_set_channel_type", TwoInts.self)
            selectProgram = try load("fluid_synth_program_select", FourInts.self)
            noteOn = try load("fluid_synth_noteon", ThreeInts.self)
            noteOff = try load("fluid_synth_noteoff", TwoInts.self)
            control = try load("fluid_synth_cc", ThreeInts.self)
            keyPressure = try load("fluid_synth_key_pressure", ThreeInts.self)
            channelPressure = try load("fluid_synth_channel_pressure", TwoInts.self)
            pitchBend = try load("fluid_synth_pitch_bend", TwoInts.self)
            allNotesOff = try load("fluid_synth_all_notes_off", OneInt.self)
            renderFloat = try load("fluid_synth_write_float", RenderFloat.self)
        } catch {
            dlclose(handle)
            throw error
        }
        self.handle = handle
    }

    deinit { dlclose(handle) }
}

/// This object is used by exactly one synthesis thread at a time. The realtime host supplies its lock.
final class FluidSynthSession {
    let api: FluidAPI
    let settings: OpaquePointer
    let synth: OpaquePointer
    let fontID: Int32
    let tracks: [PerformanceTrack]
    var mixes: [AccompanimentPart: PartMix]
    var muted = Set<AccompanimentPart>()
    private var programs: [AccompanimentPart: UInt8] = [:]
    private var controllers: [AccompanimentPart: [UInt8: UInt8]] = [:]

    init(tracks: [PerformanceTrack], soundFont: URL, library: URL, mix: [AccompanimentPart: PartMix],
         masterGain: Double, reverb: Bool) throws {
        guard masterGain.isFinite, (0...1).contains(masterGain) else { throw invalid("总音量必须在 0 到 100% 之间。") }
        let api = try FluidAPI(url: library)
        self.api = api
        guard let settings = api.newSettings() else { throw invalid("无法创建高品质音源设置。") }
        self.settings = settings
        var created: OpaquePointer?
        do {
            for (key, value) in [("synth.sample-rate", 48_000.0), ("synth.gain", 2 * max(0, min(1, masterGain))),
                                 ("synth.reverb.damp", 0.3), ("synth.reverb.level", 0.7), ("synth.reverb.room-size", 0.5),
                                 ("synth.reverb.width", 0.8), ("synth.chorus.depth", 3.6), ("synth.chorus.level", 0.55),
                                 ("synth.chorus.speed", 0.36)] {
                guard api.settingsNumber(settings, key, value) == 0 else { throw invalid("音源设置失败：\(key)。") }
            }
            for (key, value): (String, Int32) in [("synth.polyphony", 512), ("synth.cpu-cores", 1),
                                                ("synth.reverb.active", reverb ? 1 : 0), ("synth.chorus.active", 1),
                                                ("synth.chorus.nr", 4), ("synth.threadsafe-api", 0)] {
                guard api.settingsInteger(settings, key, value) == 0 else { throw invalid("音源设置失败：\(key)。") }
            }
            guard let synth = api.newSynth(settings) else { throw invalid("无法启动高品质音源。") }
            created = synth
            let id = soundFont.path.withCString { api.loadFont(synth, $0, 1) }
            guard id >= 0 else { throw invalid("无法加载音色库「\(soundFont.lastPathComponent)」，请使用标准 SF2 格式。") }
            self.synth = synth; fontID = id
        } catch {
            if let created { api.deleteSynth(created) }
            api.deleteSettings(settings)
            throw error
        }
        self.tracks = tracks
        mixes = mix
        try reset()
    }

    deinit { api.deleteSynth(synth); api.deleteSettings(settings) }

    func reset() throws {
        _ = api.systemReset(synth)
        // FluidSynth queues DSP changes even with threadsafe-api disabled. When
        // seeking while paused there is no audio callback to consume the reset,
        // so old voices otherwise remain in its render queue while the complete
        // controller history is replayed. Discard two internal blocks before
        // restoring channel state; this retires old voices and clears effects.
        // Two blocks also cover a partially consumed 64-frame synth buffer.
        try drainCommands()
        programs.removeAll(keepingCapacity: true); controllers.removeAll(keepingCapacity: true)
        for track in tracks {
            let part = track.part
            programs[part] = track.program
            controllers[part] = [7: 100, 10: 64, 11: 127, 91: 40, 93: 0]
            guard api.setChannelType(synth, Int32(part.rawValue), part.isDrum ? 1 : 0) == 0 else { throw invalid("无法设置乐器通道。") }
            try selectProgram(part)
            for controller: UInt8 in [7, 10, 11, 91, 93] { applyController(controller, for: part) }
        }
    }

    /// Consume queued DSP updates without advancing the song's musical cursor.
    /// Used only while rebuilding a seek target, before its held notes are restored.
    func drainCommands() throws {
        var left = [Float](repeating: 0, count: 128)
        var right = [Float](repeating: 0, count: 128)
        let status = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                api.renderFloat(synth, 128, l.baseAddress, 0, 1, r.baseAddress, 0, 1)
            }
        }
        guard status == 0 else { throw invalid("音源定位失败，请重新开始试听。") }
    }

    func selectProgram(_ part: AccompanimentPart) throws {
        let program = mixes[part]?.program ?? programs[part] ?? 0
        if api.selectProgram(synth, Int32(part.rawValue), fontID, part.isDrum ? 128 : 0, Int32(program)) == 0 { return }
        // Complete GM banks may omit optional GS drum kits. Keep explicit choices strict.
        if part.isDrum, mixes[part]?.program == nil,
           api.selectProgram(synth, Int32(part.rawValue), fontID, 128, 0) == 0 { return }
        throw invalid("音色库缺少「\(part.name)」需要的第 \(program + 1) 号音色，请使用完整的 General MIDI SF2 音色库。")
    }

    func applyController(_ controller: UInt8, for part: AccompanimentPart) {
        let original = controllers[part]?[controller] ?? 0
        let override: UInt8?
        switch controller {
        case 7: override = muted.contains(part) ? 0 : mixes[part]?.volume
        case 10: override = mixes[part]?.pan
        case 91: override = mixes[part]?.reverb
        default: override = nil
        }
        _ = api.control(synth, Int32(part.rawValue), Int32(controller), Int32(override ?? original))
    }

    func setMix(_ value: PartMix, for part: AccompanimentPart) throws {
        let old = mixes[part] ?? PartMix()
        guard old != value else { return }
        mixes[part] = value
        if old.program != value.program { try selectProgram(part) }
        if old.volume != value.volume { applyController(7, for: part) }
        if old.pan != value.pan { applyController(10, for: part) }
        if old.reverb != value.reverb { applyController(91, for: part) }
    }

    func setMutedParts(_ parts: Set<AccompanimentPart>) {
        let changed = muted.symmetricDifference(parts)
        muted = parts
        for part in changed { applyController(7, for: part) }
    }

    func dispatch(_ midi: MIDI, part: AccompanimentPart, notes: Bool = true) throws {
        let channel = Int32(part.rawValue), a = Int32(midi.data1), b = Int32(midi.data2)
        switch midi.kind {
        case 0x80 where notes: _ = api.noteOff(synth, channel, a)
        case 0x90 where notes:
            if b == 0 { _ = api.noteOff(synth, channel, a) }
            else { _ = api.noteOn(synth, channel, a, b) }
        case 0xa0 where notes: _ = api.keyPressure(synth, channel, a, b)
        case 0xb0:
            controllers[part, default: [:]][midi.data1] = midi.data2
            applyController(midi.data1, for: part)
        case 0xc0:
            programs[part] = midi.data1
            try selectProgram(part)
        case 0xd0: _ = api.channelPressure(synth, channel, a)
        case 0xe0: _ = api.pitchBend(synth, channel, a | (b << 7))
        default: break
        }
    }

    func release() {
        for track in tracks {
            _ = api.control(synth, Int32(track.part.rawValue), 64, 0)
            _ = api.allNotesOff(synth, Int32(track.part.rawValue))
        }
    }
}

final class FluidPlaybackState {
    struct Event {
        let frame: Int64
        let order: Int
        let part: AccompanimentPart
        let midi: MIDI
    }
    let session: FluidSynthSession
    let musicFrames: Int64
    let totalFrames: Int64
    let events: [Event]
    var cursor: Int64 = 0
    private var next = 0
    private var released = false

    init(arrangement: ArrangementResult, soundFont: URL, library: URL, mix: [AccompanimentPart: PartMix] = [:],
         masterGain: Double = 0.8, reverb: Bool = true) throws {
        let secondsPerTick = (60_000_000 / arrangement.bpm).rounded() / (1_000_000 * Double(arrangement.style.ticksPerQuarter))
        let duration = Double(arrangement.duration) * secondsPerTick
        guard duration.isFinite, duration > 0, duration <= 3_600 else { throw invalid("试听和音频导出支持一小时以内的编曲，请拆分较长歌曲。") }
        musicFrames = Int64((duration * 48_000).rounded())
        totalFrames = musicFrames + 4 * 48_000
        guard totalFrames <= (Int64(UInt32.max) - 4096) / 6 else { throw invalid("WAV 文件将超过 4 GB，请拆分导出。") }
        var events: [Event] = []
        for track in arrangement.tracks {
            for event in track.events {
                events.append(Event(frame: Int64((Double(event.tick) * secondsPerTick * 48_000).rounded()),
                                    order: events.count, part: track.part, midi: event.midi))
            }
        }
        self.events = events.sorted { $0.frame == $1.frame ? $0.order < $1.order : $0.frame < $1.frame }
        session = try FluidSynthSession(tracks: arrangement.tracks, soundFont: soundFont, library: library,
                                       mix: mix, masterGain: masterGain, reverb: reverb)
    }

    func seek(to seconds: Double) throws {
        guard seconds.isFinite else { return }
        try session.reset()
        cursor = Int64((max(0, min(seconds, Double(musicFrames) / 48_000)) * 48_000).rounded())
        next = 0; released = false
        var held: [AccompanimentPart: [UInt8: UInt8]] = [:]
        var sustained: [AccompanimentPart: [UInt8: UInt8]] = [:]
        var pedals: [AccompanimentPart: Bool] = [:]
        var pendingCommands = 0
        while next < events.count, events[next].frame < cursor {
            let event = events[next], midi = event.midi, part = event.part
            switch midi.kind {
            case 0x90 where midi.data2 > 0:
                held[part, default: [:]][midi.data1] = midi.data2
                sustained[part]?[midi.data1] = nil
            case 0x80, 0x90:
                if let velocity = held[part]?.removeValue(forKey: midi.data1), pedals[part] == true {
                    sustained[part, default: [:]][midi.data1] = velocity
                }
            case 0xb0 where midi.data1 == 64:
                pedals[part] = midi.data2 >= 64
                if midi.data2 < 64 { sustained[part] = [:] }
            case 0xb0 where midi.data1 == 120 || midi.data1 == 123:
                held[part] = [:]; sustained[part] = [:]
            default: break
            }
            try session.dispatch(midi, part: part, notes: false)
            if [0xb0, 0xc0, 0xd0, 0xe0].contains(midi.kind) {
                pendingCommands += 1
                // Preserve the order of RPN/NRPN, reset and relative controllers.
                // Replaying a long history without rendering would overflow
                // FluidSynth's DSP queue, particularly when playback is paused.
                if pendingCommands == 32 {
                    try session.drainCommands()
                    pendingCommands = 0
                }
            }
            next += 1
        }
        try session.drainCommands()
        for part in AccompanimentPart.allCases {
            for (key, velocity) in held[part] ?? [:] {
                try session.dispatch(MIDI(0x90, key, velocity), part: part)
            }
            for (key, velocity) in sustained[part] ?? [:] {
                try session.dispatch(MIDI(0x90, key, velocity), part: part)
                try session.dispatch(MIDI(0x80, key), part: part)
            }
        }
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) throws {
        var written = 0
        while written < frames, cursor < totalFrames {
            while next < events.count, events[next].frame <= cursor {
                try session.dispatch(events[next].midi, part: events[next].part)
                next += 1
            }
            if !released && cursor >= musicFrames { session.release(); released = true }
            let eventFrame = next < events.count ? max(cursor + 1, events[next].frame) : totalFrames
            let boundary = released ? totalFrames : musicFrames
            let count = Int(min(Int64(frames - written), totalFrames - cursor, eventFrame - cursor, boundary - cursor))
            guard count > 0 else { throw invalid("音频渲染时序无效。") }
            guard session.api.renderFloat(session.synth, Int32(count), left + written, 0, 1, right + written, 0, 1) == 0 else {
                throw invalid("高品质音源渲染失败。")
            }
            cursor += Int64(count); written += count
        }
        if written < frames {
            (left + written).initialize(repeating: 0, count: frames - written)
            (right + written).initialize(repeating: 0, count: frames - written)
        }
    }
}
