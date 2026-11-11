import Foundation
import SXCore

struct SongMeter: Codable, Hashable {
    let beats: Int
    let unit: Int
    var name: String { "\(beats)/\(unit)" }
    func ticks(_ ppq: Int) -> Int { ppq * beats * 4 / unit }

    init(_ beats: Int, _ unit: Int) { self.beats = beats; self.unit = unit }
    init(_ style: Style) { self.init(style.beatsPerBar, style.beatUnit) }

    static let choices = [Self(2, 2), Self(3, 2), Self(2, 4), Self(3, 4), Self(4, 4), Self(5, 4), Self(6, 4), Self(7, 4),
                          Self(3, 8), Self(5, 8), Self(6, 8), Self(7, 8), Self(9, 8), Self(12, 8)]
}

struct SongKey: Codable, Hashable {
    let fifths: Int
    let minor: Bool

    static let cMajor = Self(fifths: 0, minor: false)
    static let choices = (-7...7).flatMap {
        [Self(fifths: $0, minor: false), Self(fifths: $0, minor: true)]
    }
    private static let majorNames = ["C♭", "G♭", "D♭", "A♭", "E♭", "B♭", "F", "C",
                                     "G", "D", "A", "E", "B", "F♯", "C♯"]
    private static let minorNames = ["A♭", "E♭", "B♭", "F", "C", "G", "D", "A",
                                     "E", "B", "F♯", "C♯", "G♯", "D♯", "A♯"]
    var tonic: Int { modulo12(fifths * 7 + (minor ? 9 : 0)) }
    var tonicName: String { (minor ? Self.minorNames : Self.majorNames)[fifths + 7] }
    var name: String { tonicName + (minor ? " 小调" : " 大调") }
    private var scale: [Int] { minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11] }

    func spell(_ pitchClass: Int) -> String {
        let letters = Array("CDEFGAB")
        let naturals = [0, 2, 4, 5, 7, 9, 11]
        let pitch = modulo12(pitchClass)
        let relative = modulo12(pitch - tonic)
        if let degree = scale.firstIndex(of: relative) ?? (minor && relative == 11 ? 6 : nil),
           let letter = tonicName.first, let first = letters.firstIndex(of: letter) {
            let index = (first + degree) % letters.count
            switch modulo12(pitch - naturals[index]) {
            case 0: return String(letters[index])
            case 1: return String(letters[index]) + "♯"
            case 11: return String(letters[index]) + "♭"
            default: break
            }
        }
        let chromatic = fifths < 0
            ? ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]
            : ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "G♯", "A", "B♭", "B"]
        return chromatic[pitch]
    }

    func transpose(_ bar: String, from source: SongKey) -> String {
        bar.split(whereSeparator: \.isWhitespace).map { token in
            let fields = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let symbol = fields.first, let chord = parseChord(symbol) else { return String(token) }
            let originalDegree = modulo12(chord.root - source.tonic)
            let degree = source.scale.firstIndex(of: originalDegree)
            let changeMode = source.minor != minor

            func pitch(_ value: Int) -> Int {
                let relative = modulo12(value - source.tonic)
                if changeMode, let position = source.scale.firstIndex(of: relative) { return tonic + scale[position] }
                return tonic + relative
            }

            var quality = chord.quality
            if changeMode, let degree, !(degree == 4 && quality == .seventh) {
                let sourceTriads: [Chord.Quality] = source.minor
                    ? [.minor, .diminished, .major, .minor, .minor, .major, .major]
                    : [.major, .minor, .minor, .major, .major, .minor, .diminished]
                let targetTriads: [Chord.Quality] = minor
                    ? [.minor, .diminished, .major, .minor, .minor, .major, .major]
                    : [.major, .minor, .minor, .major, .major, .minor, .diminished]
                let sourceSevenths: [Chord.Quality] = source.minor
                    ? [.minorSeventh, .halfDiminished, .majorSeventh, .minorSeventh, .minorSeventh, .majorSeventh, .seventh]
                    : [.majorSeventh, .minorSeventh, .minorSeventh, .majorSeventh, .seventh, .minorSeventh, .halfDiminished]
                let targetSevenths: [Chord.Quality] = minor
                    ? [.minorSeventh, .halfDiminished, .majorSeventh, .minorSeventh, .minorSeventh, .majorSeventh, .seventh]
                    : [.majorSeventh, .minorSeventh, .minorSeventh, .majorSeventh, .seventh, .minorSeventh, .halfDiminished]
                if quality == sourceTriads[degree] { quality = targetTriads[degree] }
                else if quality == sourceSevenths[degree] { quality = targetSevenths[degree] }
            }
            let suffix = Chord(root: 0, quality: quality).name.dropFirst()
            let bass = chord.bass.map { "/" + spell(pitch($0)) } ?? ""
            let timing = fields.count == 2 ? ":" + fields[1] : ""
            return spell(pitch(chord.root)) + suffix + bass + timing
        }.joined(separator: " ")
    }
}

private func modulo12(_ value: Int) -> Int { (value % 12 + 12) % 12 }

struct Chart {
    struct Segment {
        let styleSection: String
        let name: String
        var bars: [String] = []
        var lengthInBars: Int?
    }

    var style = ""
    var bpm: Double?
    var key: SongKey?
    var meter: SongMeter?
    var mutedParts: Set<AccompanimentPart> = []
    var mix: [AccompanimentPart: PartMix] = [:]
    var segments: [Segment] = []

    init(style: String, bpm: Double?, key: SongKey? = nil, meter: SongMeter? = nil,
         mutedParts: Set<AccompanimentPart> = [], mix: [AccompanimentPart: PartMix] = [:], segments: [Segment]) {
        self.style = style
        self.bpm = bpm
        self.key = key
        self.meter = meter
        self.mutedParts = mutedParts
        self.mix = mix
        self.segments = segments
    }

    init(contents: String) throws {
        for (index, raw) in contents.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") { continue }

            if line.hasPrefix("["), let bracket = line.firstIndex(of: "]") {
                let section = line[line.index(after: line.startIndex)..<bracket]
                    .trimmingCharacters(in: .whitespaces)
                let name = line[line.index(after: bracket)...].trimmingCharacters(in: .whitespaces)
                segments.append(Segment(styleSection: section, name: name.isEmpty ? section : name))
            } else if segments.isEmpty {
                let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2 else { throw invalid("第 \(index + 1) 行需要填写 style 或 bpm") }
                switch pair[0] {
                case "style": style = pair[1]
                case "bpm":
                    guard let value = Double(pair[1]), (20...400).contains(value) else {
                        throw invalid("bpm 必须在 20 到 400 之间")
                    }
                    bpm = value
                default: throw invalid("第 \(index + 1) 行无法识别设置「\(pair[0])」")
                }
            } else {
                let bars = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                guard !bars.contains("") else { throw invalid("第 \(index + 1) 行有空小节") }
                segments[segments.count - 1].bars += bars
            }
        }
        guard !style.isEmpty, !segments.isEmpty else { throw invalid("和弦表需要填写 style 和至少一个段落") }
    }
}

func invalid(_ message: String) -> StyleError { .invalid(message) }

func styleURL(_ path: String, root: URL) -> URL {
    path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
}

func pitch(_ spelling: Substring) -> Int? {
    let naturals: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
    guard let letter = spelling.first, let base = naturals[letter] else { return nil }
    switch spelling.dropFirst() {
    case "": return base
    case "#", "♯": return (base + 1) % 12
    case "b", "♭": return (base + 11) % 12
    default: return nil
    }
}

func parseChord(_ symbol: Substring) -> Chord? {
    let rootLength = symbol.dropFirst().first.map { "#♯b♭".contains($0) } == true ? 2 : 1
    guard let root = pitch(symbol.prefix(rootLength)) else { return nil }
    var suffix = symbol.dropFirst(rootLength)
    var bass: Int?
    if let slash = suffix.lastIndex(of: "/"), let inversion = pitch(suffix[suffix.index(after: slash)...]) {
        bass = inversion
        suffix = suffix[..<slash]
    }
    let aliases = ["maj": "", "M": "", "M7": "maj7", "M9": "maj9", "min": "m",
                   "min7": "m7", "sus": "sus4", "ø": "m7♭5", "ø7": "m7♭5", "+": "aug"]
    let normalized = String(suffix).replacingOccurrences(of: "#", with: "♯")
        .replacingOccurrences(of: "b", with: "♭")
    let name = "C" + (aliases[normalized] ?? normalized)
    guard let quality = Chord.Quality.allCases.first(where: { Chord(root: 0, quality: $0).name == name }) else {
        return nil
    }
    return Chord(root: root, quality: quality, bass: bass == root ? nil : bass)
}

func chordChanges(in bar: String, style: Style, meter: SongMeter? = nil, context: String) throws -> [(Int, Chord)] {
    let tokens = bar.split(whereSeparator: \.isWhitespace)
    let explicit = tokens.contains { $0.contains(":") }
    let meter = meter ?? SongMeter(style)
    let ticks = meter.ticks(style.ticksPerQuarter)
    var position = 0
    var changes: [(Int, Chord)] = []
    for token in tokens {
        let fields = token.split(separator: ":", omittingEmptySubsequences: false)
        guard let symbol = fields.first, let chord = parseChord(symbol) else {
            throw invalid("\(context) 的和弦「\(token)」无法识别")
        }
        let duration: Int
        if explicit {
            guard fields.count == 2, let beats = Double(fields[1]), beats > 0,
                  beats <= Double(meter.beats) else {
                throw invalid("\(context) 中每个和弦都需要有效的拍数，如 Dm7:1 G7:3")
            }
            let exact = beats * Double(ticks) / Double(meter.beats)
            guard abs(exact - exact.rounded()) < 0.0001, exact.rounded() >= 1 else {
                throw invalid("\(context) 中的拍数超出 MIDI 时间精度")
            }
            duration = Int(exact.rounded())
        } else {
            guard ticks % tokens.count == 0 else {
                throw invalid("\(context) 的和弦无法等分，请逐个标明拍数")
            }
            duration = ticks / tokens.count
        }
        changes.append((position, chord))
        position += duration
    }
    guard position == ticks else {
        throw invalid("\(context) 的和弦时值需要填满 \(meter.name) 的一小节")
    }
    return changes
}

struct PlannedSegment {
    let entry: Chart.Segment
    let pattern: Style.Section
    let length: Int
    let span: Int
    let changes: [Int: Chord]
    let harmony: [(Int, Chord)]

    init(entry: Chart.Segment, style: Style, meter: SongMeter? = nil) throws {
        guard let pattern = style.sections.first(where: { $0.name == entry.styleSection }) else {
            throw invalid("风格「\(style.name)」没有段落「\(entry.styleSection)」")
        }
        guard !entry.bars.isEmpty else { throw invalid("「\(entry.name)」需要填写和弦") }
        let barTicks = style.ticksPerBar
        let meter = meter ?? SongMeter(style)
        let songBarTicks = meter.ticks(style.ticksPerQuarter)
        let naturalBars = (pattern.length + barTicks - 1) / barTicks
        let writtenLength = entry.lengthInBars ?? (pattern.name.hasPrefix("Main ") ? entry.bars.count : nil)
        let availableBars = writtenLength ?? naturalBars
        guard songBarTicks > 0, (1...0x0fff_ffff / max(barTicks, songBarTicks)).contains(availableBars) else {
            throw invalid("「\(entry.name)」的小节数超出 MIDI 范围")
        }
        guard entry.bars.count <= availableBars else {
            throw invalid("「\(entry.name)」最多可填写 \(availableBars) 小节")
        }
        let length = writtenLength.map { $0 * barTicks } ?? pattern.length
        var changes: [Int: Chord] = [:]
        var harmony: [(Int, Chord)] = []
        for (bar, text) in entry.bars.enumerated() {
            let context = "「\(entry.name)」第 \(bar + 1) 小节"
            for (tick, chord) in try chordChanges(in: text, style: style, meter: meter, context: context) {
                let offset = bar * barTicks + rescaleTicks(tick, from: songBarTicks, to: barTicks)
                guard offset < length else { throw invalid("\(context) 的换和弦位置超过原段落长度") }
                guard changes[offset] == nil else { throw invalid("\(context) 的换和弦位置过于接近") }
                changes[offset] = chord
                harmony.append((bar * songBarTicks + tick, chord))
            }
        }
        self.entry = entry
        self.pattern = pattern
        self.length = length
        self.span = availableBars * songBarTicks
        self.changes = changes
        self.harmony = harmony
    }
}

private func rescaleTicks(_ tick: Int, from: Int, to: Int) -> Int {
    from == to ? tick : (tick * to + from / 2) / from
}

func retimeChordBar(_ text: String, from previous: SongMeter, to next: SongMeter, style: Style) -> String {
    guard previous != next, text.contains(":"),
          let changes = try? chordChanges(in: text, style: style, meter: previous, context: "") else { return text }
    let oldTicks = previous.ticks(style.ticksPerQuarter)
    let newTicks = next.ticks(style.ticksPerQuarter)
    let positions = changes.map { rescaleTicks($0.0, from: oldTicks, to: newTicks) } + [newTicks]
    guard zip(positions, positions.dropFirst()).allSatisfy({ $0 < $1 }) else { return text }
    return text.split(whereSeparator: \.isWhitespace).enumerated().map { index, token in
        let chord = token.prefix { $0 != ":" }
        let beats = Double(positions[index + 1] - positions[index]) * Double(next.beats) / Double(newTicks)
        return chord + ":" + String(format: "%.9g", beats)
    }.joined(separator: " ")
}

struct PerformanceTrack {
    let part: AccompanimentPart
    let name: String
    let program: UInt8
    var events: [Style.Event] = []
    var noteOnCount = 0
    private var playing: [UInt8: UInt8] = [:]
    private var bankMSB: UInt8
    private var bankLSB: UInt8
    private var drumVoice: Style.VoiceAddress
    private let mix: PartMix
    private let guitar: Bool
    var isDrum: Bool { part.isDrum }
    var channel: UInt8 { part.channel }

    init(part: AccompanimentPart, style: Style, mix: PartMix = .init()) {
        self.part = part
        self.mix = mix
        guitar = style.guitarChannels.contains(part.rawValue)
        let selectedProgram = mix.program ?? part.program(in: style)
        program = selectedProgram
        let instrument = part.isDrum
            ? generalMIDIDrumKits.first(where: { $0.program == selectedProgram })?.name ?? "鼓组"
            : generalMIDIInstrumentNames[Int(selectedProgram)]
        name = part.name + " · " + instrument
        let voice = part.voice(in: style)
        bankMSB = voice.msb
        bankLSB = voice.lsb
        drumVoice = voice
        add(MIDI(0xc0 | channel, program), at: 0)
        let setup = style.initialControllers[part.rawValue] ?? [:]
        // Yamaha bank/NRPN/DSP parameters cannot be sent blindly to a GM synth.
        // Preserve portable expression and tone controls, followed by mixer overrides.
        for control: UInt8 in [1, 7, 10, 11, 64, 71, 72, 73, 74, 91, 93] {
            let fallback: UInt8? = control == 7 ? 100 : control == 10 ? 64 : control == 11 ? 127 : nil
            if let value = override(control) ?? setup[control] ?? fallback {
                add(MIDI(0xb0 | channel, control, value), at: 0)
            }
        }
    }

    mutating func write(_ midi: MIDI, at tick: Int) {
        switch midi.kind {
        case 0x90 where midi.data2 > 0:
            let note = isDrum ? YamahaVoices.drumNote(midi.data1, voice: drumVoice) : midi.data1
            let previous = playing.updateValue(note, forKey: midi.data1)
            if let previous, previous != note, !playing.values.contains(previous) {
                add(MIDI(0x80 | channel, previous), at: tick)
            }
            if previous == note || playing.contains(where: { $0.key != midi.data1 && $0.value == note }) {
                add(MIDI(0x80 | channel, note), at: tick)
            }
            add(MIDI(0x90 | channel, note, midi.data2), at: tick)
            noteOnCount += 1
        case 0x80, 0x90:
            if let note = playing.removeValue(forKey: midi.data1), !playing.values.contains(note) {
                add(MIDI(0x80 | channel, note), at: tick)
            }
        case 0xb0 where midi.data1 == 0: bankMSB = midi.data2
        case 0xb0 where midi.data1 == 32: bankLSB = midi.data2
        case 0xc0:
            let voice = Style.VoiceAddress(msb: bankMSB, lsb: bankLSB, program: midi.data1)
            if isDrum { drumVoice = voice }
            if mix.program == nil {
                let gm = isDrum ? YamahaVoices.drumProgram(voice)
                    : YamahaVoices.melodicProgram(voice, guitar: guitar, bass: part == .bass)
                add(MIDI(0xc0 | channel, gm), at: tick)
            }
        case 0xb0:
            add(MIDI(0xb0 | channel, midi.data1, override(midi.data1) ?? midi.data2), at: tick)
        case 0xd0, 0xe0:
            add(midi.onChannel(channel), at: tick)
        default: break
        }
    }

    private func override(_ control: UInt8) -> UInt8? {
        switch control {
        case 7: return mix.volume
        case 10: return mix.pan
        case 91: return mix.reverb
        default: return nil
        }
    }

    private mutating func add(_ midi: MIDI, at tick: Int) {
        events.append(Style.Event(tick: tick, midi: midi))
    }
}

func encodeMIDI(ppq: Int, meter: SongMeter, key: SongKey?, bpm: Double, duration: Int,
                markers: [(Int, String)], tracks: [PerformanceTrack]) -> Data {
    func bigEndian(_ value: Int, bytes: Int) -> [UInt8] {
        (0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    func vlq(_ value: Int) -> [UInt8] {
        var remainder = value >> 7
        var bytes = [UInt8(value & 127)]
        while remainder > 0 {
            bytes.append(UInt8(remainder & 127) | 128)
            remainder >>= 7
        }
        return bytes.reversed()
    }
    func chunk(_ tag: String, _ payload: [UInt8]) -> [UInt8] {
        Array(tag.utf8) + bigEndian(payload.count, bytes: 4) + payload
    }
    func textEvent(_ kind: UInt8, _ value: String) -> [UInt8] {
        let bytes = Array(value.utf8)
        return [0xff, kind] + vlq(bytes.count) + bytes
    }
    func finish(_ track: inout [UInt8], after tick: Int) {
        track += vlq(duration - tick) + [0xff, 0x2f, 0]
    }

    let tempo = Int((60_000_000 / bpm).rounded())
    var conductor: [UInt8] = [0, 0xff, 0x51, 3] + bigEndian(tempo, bytes: 3)
    conductor += [0, 0xff, 0x58, 4, UInt8(meter.beats), UInt8(meter.unit.trailingZeroBitCount),
                  UInt8(max(1, 96 / meter.unit)), 8]
    if let key {
        conductor += [0, 0xff, 0x59, 2, UInt8(bitPattern: Int8(key.fifths)), key.minor ? 1 : 0]
    }
    var previous = 0
    for (tick, marker) in markers {
        conductor += vlq(tick - previous) + textEvent(0x06, marker)
        previous = tick
    }
    finish(&conductor, after: previous)
    let header = [0, 1] + bigEndian(tracks.count + 1, bytes: 2) + bigEndian(ppq, bytes: 2)
    var file = Data(chunk("MThd", header))
    file.append(contentsOf: chunk("MTrk", conductor))
    let encodedEvents = portableMIDIEvents(tracks)
    for (index, track) in tracks.enumerated() {
        var payload = [0] + textEvent(0x03, track.name)
        previous = 0
        for event in encodedEvents[index] {
            let midi = event.midi
            payload += vlq(event.tick - previous) + [midi.status, midi.data1]
            if midi.size == 3 { payload.append(midi.data2) }
            previous = event.tick
        }
        finish(&payload, after: previous)
        file.append(contentsOf: chunk("MTrk", payload))
    }
    return file
}

/// Standard GM has one percussion channel. Independent drum kits, pan and effects
/// remain intact in PerformanceTrack for the audio renderer. When both rhythm
/// parts are exported as GM MIDI, use a shared standard kit and fold each part's
/// volume/expression into note velocity instead of sending conflicting controllers.
func portableMIDIEvents(_ tracks: [PerformanceTrack]) -> [[Style.Event]] {
    let drums = tracks.indices.filter { tracks[$0].isDrum }
    guard drums.count > 1 else { return tracks.map(\.events) }
    var output = tracks.map(\.events)
    for index in drums {
        var volume = 100, expression = 127
        var sounding: Set<UInt8> = []
        var events: [Style.Event] = []
        if index == drums.first {
            for midi in [MIDI(0xc9, 0), MIDI(0xb9, 7, 127), MIDI(0xb9, 11, 127),
                         MIDI(0xb9, 10, 64), MIDI(0xb9, 91, 40), MIDI(0xb9, 93, 0)] {
                events.append(.init(tick: 0, midi: midi))
            }
        }
        for event in tracks[index].events {
            let midi = event.midi
            switch midi.kind {
            case 0xb0 where midi.data1 == 7: volume = Int(midi.data2)
            case 0xb0 where midi.data1 == 11: expression = Int(midi.data2)
            case 0x90 where midi.data2 > 0:
                let velocity = UInt8((Double(midi.data2) * Double(volume * expression) / (127 * 127)).rounded())
                if velocity > 0 {
                    sounding.insert(midi.data1)
                    events.append(.init(tick: event.tick, midi: MIDI(0x99, midi.data1, velocity)))
                }
            case 0x80, 0x90:
                if sounding.remove(midi.data1) != nil { events.append(.init(tick: event.tick, midi: MIDI(0x89, midi.data1))) }
            default: break
            }
        }
        output[index] = events
    }

    // A note-off from one rhythm part must not end the other part's overlapping
    // note on the shared channel. Evaluate all releases/attacks at each tick
    // together because a MIDI player may merge simultaneous track events in any order.
    struct Item { let track: Int; let event: Int; let midi: MIDI }
    var byTick: [Int: [Item]] = [:]
    for track in drums {
        for (index, event) in output[track].enumerated() where event.midi.kind == 0x80 || event.midi.kind == 0x90 {
            byTick[event.tick, default: []].append(.init(track: track, event: index, midi: event.midi))
        }
    }
    var owners: [UInt8: Set<Int>] = [:]
    var removed: [Int: Set<Int>] = [:]
    for tick in byTick.keys.sorted() {
        let events = byTick[tick]!
        for item in events where item.midi.kind == 0x80 { owners[item.midi.data1, default: []].remove(item.track) }
        for item in events where item.midi.kind == 0x90 { owners[item.midi.data1, default: []].insert(item.track) }
        var released: Set<UInt8> = []
        for item in events where item.midi.kind == 0x80 {
            if !(owners[item.midi.data1]?.isEmpty ?? true) || !released.insert(item.midi.data1).inserted {
                removed[item.track, default: []].insert(item.event)
            }
        }
    }
    for track in drums {
        output[track] = output[track].enumerated().compactMap { removed[track]?.contains($0.offset) == true ? nil : $0.element }
    }
    return output
}

struct ArrangementResult {
    let style: Style
    let meter: SongMeter
    let key: SongKey?
    let bpm: Double
    let duration: Int
    let tracks: [PerformanceTrack]
    let markers: [(tick: Int, name: String)]
    let harmony: [(tick: Int, chord: Chord)]

    var ticksPerBar: Int { meter.ticks(style.ticksPerQuarter) }
    var barCount: Int { duration / ticksPerBar }
    var midi: Data {
        encodeMIDI(ppq: style.ticksPerQuarter, meter: meter, key: key, bpm: bpm, duration: duration,
                   markers: markers, tracks: tracks)
    }
}

func renderArrangement(_ chart: Chart, style: Style) throws -> ArrangementResult {
    guard style.ticksPerBar > 0 else { throw invalid("Style 的小节时值无效") }
    guard !chart.segments.isEmpty else { throw invalid("请先添加段落") }
    guard chart.mix.values.allSatisfy(\.isValid) else { throw invalid("乐器与混音设置必须在 0–127 之间。") }
    let meter = chart.meter ?? SongMeter(style)
    let songBarTicks = meter.ticks(style.ticksPerQuarter)
    let plan = try chart.segments.map { try PlannedSegment(entry: $0, style: style, meter: meter) }
    let bpm = chart.bpm ?? style.bpm
    let duration = plan.reduce(0) { $0 + $1.span }
    guard duration <= 0x0fff_ffff,
          60_000_000 / bpm <= 0xff_ffff else { throw invalid("歌曲长度、速度或拍号超出 MIDI 格式范围") }

    var arranger = Arranger(style: style)
    let enabled = Set(AccompanimentPart.allCases).subtracting(chart.mutedParts)
    guard !enabled.isEmpty else { throw invalid("请至少选择一个要输出的乐器声部。") }
    var tracks = AccompanimentPart.allCases.map { PerformanceTrack(part: $0, style: style, mix: chart.mix[$0] ?? .init()) }
    var start = 0
    var markers: [(Int, String)] = []
    var harmony: [(Int, Chord)] = []

    func write(_ messages: [MIDI], at tick: Int) {
        for midi in messages where midi.channel >= 8 {
            tracks[Int(midi.channel) - 8].write(midi, at: tick)
        }
    }

    for segment in plan {
        markers.append((start, segment.entry.name))
        harmony += segment.harmony.map { (start + $0.0, $0.1) }
        for tick in 0..<segment.length {
            let absolute = start + rescaleTicks(tick, from: style.ticksPerBar, to: songBarTicks)
            let restart = tick % segment.pattern.length == 0
            if restart && tick > 0 { write(arranger.stop(), at: absolute) }
            if let chord = segment.changes[tick] { write(arranger.setChord(chord), at: absolute) }
            if restart {
                write(arranger.start(segment.pattern.name), at: absolute)
            } else {
                write(arranger.advance(1), at: absolute)
            }
        }
        write(arranger.stop(), at: start + rescaleTicks(segment.length, from: style.ticksPerBar, to: songBarTicks))
        start += segment.span
    }
    let audibleTracks = tracks.filter { enabled.contains($0.part) && $0.noteOnCount > 0 }
    guard !audibleTracks.isEmpty else { throw invalid("所选乐器声部在当前编曲里没有可播放的音符。") }
    return ArrangementResult(style: style, meter: meter, key: chart.key, bpm: bpm, duration: duration, tracks: audibleTracks,
                             markers: markers, harmony: harmony)
}

func render(_ chart: Chart, style: Style, output: URL) throws {
    let result = try renderArrangement(chart, style: style)
    let data = result.midi
    let verification = try MIDIFile(data: data)
    guard verification.duration == result.duration, verification.tracks.count == result.tracks.count + 1 else {
        throw invalid("导出的 MIDI 未通过复读检查")
    }
    try data.write(to: output, options: .atomic)
    for (marker, segment) in zip(result.markers, chart.segments) {
        print("第 \(marker.tick / style.ticksPerBar + 1) 小节  \(marker.name) [\(segment.styleSection)]")
    }
    print("\(style.beatsPerBar)/\(style.beatUnit)，\(String(format: "%.2f", result.bpm)) BPM，\(result.barCount) 小节，\(result.tracks.count) 轨")
    print(result.tracks.map { "\($0.name) \($0.noteOnCount)" }.joined(separator: " · "))
    print(output.path)
    for note in style.diagnostics where !note.hasPrefix("One Touch Setting") { print(note) }
}
