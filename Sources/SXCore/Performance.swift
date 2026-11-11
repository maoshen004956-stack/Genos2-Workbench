import Foundation

public struct PerformanceAsset: Codable, Equatable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    public init(url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 256 * 1_024 * 1_024 else { throw StyleError.invalid("文件超过 256 MB") }
        self.init(name: url.lastPathComponent, data: try Data(contentsOf: url, options: .mappedIfSafe))
    }
}

public struct PerformanceMedia: Codable {
    public var song: PerformanceAsset?
    public var audio: PerformanceAsset?
    public var lyrics: PerformanceAsset?
    public var pads: [Int: PerformanceAsset] = [:]
    public var padOptions: [Int: PadOptions] = [:]
    public var minorChords = false
    public var audioLinkName: String?
    public var audioLinkSimultaneous: Bool?

    public init() {}
}

public struct PadOptions: Codable {
    public var sync = false
    public var followChord = false
    public var yamahaChordMatch: Bool?
    public var audioLinkGain: Float?
    public var repeatPlayback = false
    public var sourceRoot: UInt8 = 0

    public init() {}
}

public struct MIDIPad {
    public let ticksPerQuarter: Int
    public let tempo: Double
    public private(set) var active = true
    private let events: [Style.Event]
    private let duration: Int
    private let options: PadOptions
    private var position = 0
    private var event = 0
    private var notes: [UInt16: [UInt8]] = [:]

    public init(file: MIDIFile, options: PadOptions) throws {
        ticksPerQuarter = file.ticksPerQuarter
        tempo = file.tempo
        events = file.tracks.flatMap { $0 }.sorted { $0.tick < $1.tick }
        guard events.contains(where: { $0.midi.kind == 0x90 && $0.midi.data2 > 0 }) else {
            throw StyleError.invalid("MIDI Pad 文件没有音符")
        }
        duration = max(1, file.duration)
        self.options = options
    }

    public mutating func advance(_ ticks: Int, chord: Chord?) -> [MIDI] {
        guard active else { return [] }
        var remaining = max(0, ticks)
        var output: [MIDI] = []
        repeat {
            let step = min(remaining, duration - position)
            position += step
            remaining -= step
            while event < events.count && events[event].tick <= position {
                let message = events[event].midi
                event += 1
                switch message.kind {
                case 0x80, 0x90:
                    let key = UInt16(message.channel) * 128 + UInt16(message.data1)
                    if message.kind == 0x90 && message.data2 > 0 {
                        let originalRoot = Int(options.sourceRoot % 12)
                        let offset = options.followChord && message.channel != 9
                            ? (chord?.root ?? originalRoot) - originalRoot : 0
                        var note = Int(message.data1) + offset
                        if options.followChord, options.yamahaChordMatch == true, message.channel != 9,
                           let chord {
                            let relative = (Int(message.data1) - originalRoot + 12) % 12
                            let original = [0, 4, 7, 11]
                            let tones = chord.quality.intervals
                            if let index = original.firstIndex(of: relative), index < tones.count {
                                note += tones[index] - relative
                            }
                        }
                        if note < 0 { note += 12 }
                        if note > 127 { note -= 12 }
                        let pitch = UInt8(clamping: note)
                        notes[key, default: []].append(pitch)
                        output.append(MIDI(message.status, pitch, message.data2))
                    } else if var held = notes[key], !held.isEmpty {
                        let pitch = held.removeFirst()
                        notes[key] = held.isEmpty ? nil : held
                        if !notes.contains(where: { $0.key / 128 == UInt16(message.channel) && $0.value.contains(pitch) }) {
                            output.append(MIDI(0x80 | message.channel, pitch))
                        }
                    }
                case 0xb0, 0xe0, 0xd0:
                    output.append(message)
                default: break
                }
            }
            if position == duration {
                output += stop()
                if options.repeatPlayback { active = true; position = 0; event = 0 }
            }
        } while remaining > 0 && active
        return output
    }

    public mutating func stop() -> [MIDI] {
        let channels = Set(events.map { $0.midi.channel })
        var output = channels.sorted().map { MIDI(0xb0 | $0, 64) }
        for key in notes.keys.sorted() {
            output += Set(notes[key] ?? []).sorted().map { MIDI(0x80 | UInt8(key / 128), $0) }
        }
        active = false
        notes.removeAll(keepingCapacity: true)
        return output
    }
}

public struct PerformanceRecorder {
    private let started: TimeInterval
    private var events: [Style.Event] = []
    private var notes: Set<UInt16> = []
    private var sustain: Set<UInt8> = []

    public init(at time: TimeInterval, setup: [MIDI]) {
        started = time
        events = setup.map { Style.Event(tick: 0, midi: $0) }
    }

    public mutating func append(_ message: MIDI, at time: TimeInterval) {
        let tick = Int(max(0, time - started) * 960)
        events.append(Style.Event(tick: tick, midi: message))
        let key = UInt16(message.channel) * 128 + UInt16(message.data1)
        if message.kind == 0x90 && message.data2 > 0 { notes.insert(key) }
        else if message.kind == 0x80 || message.kind == 0x90 { notes.remove(key) }
        if message.kind == 0xb0 && message.data1 == 64 {
            if message.data2 >= 64 { sustain.insert(message.channel) } else { sustain.remove(message.channel) }
        }
    }

    public mutating func finish(at time: TimeInterval) -> Data {
        for channel in sustain.sorted() { append(MIDI(0xb0 | channel, 64), at: time) }
        for key in notes.sorted() { append(MIDI(0x80 | UInt8(key / 128), UInt8(key % 128)), at: time) }
        return MIDIFile.encode(events: events)
    }
}
