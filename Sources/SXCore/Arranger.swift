import Foundation

public struct Chord: Equatable {
    public enum Quality: Int, CaseIterable {
        case major = 0, sixth, majorSeventh, majorSeventhSharpEleven, addNine, majorSeventhNine, sixthNine, augmented
        case minor, minorSixth, minorSeventh, halfDiminished, minorNine, minorSeventhNine, minorSeventhEleven
        case minorMajorSeventh, minorMajorSeventhNine, diminished, diminishedSeventh, seventh, seventhSuspended
        case seventhFlatFive, seventhNine, seventhSharpEleven, seventhThirteen, seventhFlatNine, seventhFlatThirteen
        case seventhSharpNine, majorSeventhAugmented, seventhAugmented, octave, fifth, suspended, suspendedSecond

        var intervals: [Int] {
            let chord: [Int]
            switch self {
            case .major: chord = [4, 7]
            case .sixth: chord = [4, 7, 9]
            case .majorSeventh: chord = [4, 7, 11]
            case .majorSeventhSharpEleven: chord = [4, 7, 11, 6]
            case .addNine: chord = [4, 7, 2]
            case .majorSeventhNine: chord = [4, 7, 11, 2]
            case .sixthNine: chord = [4, 7, 9, 2]
            case .augmented: chord = [4, 8]
            case .minor: chord = [3, 7]
            case .minorSixth: chord = [3, 7, 9]
            case .minorSeventh: chord = [3, 7, 10]
            case .halfDiminished: chord = [3, 6, 10]
            case .minorNine: chord = [3, 7, 2]
            case .minorSeventhNine: chord = [3, 7, 10, 2]
            case .minorSeventhEleven: chord = [3, 7, 10, 5]
            case .minorMajorSeventh: chord = [3, 7, 11]
            case .minorMajorSeventhNine: chord = [3, 7, 11, 2]
            case .diminished: chord = [3, 6]
            case .diminishedSeventh: chord = [3, 6, 9]
            case .seventh: chord = [4, 7, 10]
            case .seventhSuspended: chord = [5, 7, 10]
            case .seventhFlatFive: chord = [4, 6, 10]
            case .seventhNine: chord = [4, 7, 10, 2]
            case .seventhSharpEleven: chord = [4, 7, 10, 6]
            case .seventhThirteen: chord = [4, 7, 10, 9]
            case .seventhFlatNine: chord = [4, 7, 10, 1]
            case .seventhFlatThirteen: chord = [4, 7, 10, 8]
            case .seventhSharpNine: chord = [4, 7, 10, 3]
            case .majorSeventhAugmented: chord = [4, 8, 11]
            case .seventhAugmented: chord = [4, 8, 10]
            case .octave: chord = []
            case .fifth: chord = [7]
            case .suspended: chord = [5, 7]
            case .suspendedSecond: chord = [2, 7]
            }
            return [0] + chord
        }

        var isMinor: Bool { intervals.dropFirst().first == 3 }

        var suffix: String { Self.suffixes[rawValue] }

        private static let suffixes = [
            "", "6", "maj7", "maj7♯11", "add9", "maj9", "6/9", "aug", "m", "m6", "m7", "m7♭5",
            "m(add9)", "m9", "m11", "mMaj7", "mMaj9", "dim", "dim7", "7", "7sus4", "7♭5", "9",
            "7♯11", "13", "7♭9", "7♭13", "7♯9", "maj7♯5", "7♯5", "8", "5", "sus4", "sus2"
        ]

    }

    public let root: Int
    public let quality: Quality
    public let bass: Int?
    public var name: String {
        let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        return names[root] + quality.suffix + (bass.map { "/" + names[$0] } ?? "")
    }

    public init(root: Int, quality: Quality = .major, bass: Int? = nil) {
        self.root = pitchClass(root)
        self.quality = quality
        self.bass = bass.map(pitchClass)
    }

    public static func recognize(_ notes: Set<UInt8>, previous: Chord? = nil) -> Chord? {
        let classes = Set(notes.map { Int($0) % 12 })
        guard classes.count >= 3 else { return nil }
        var roots: [Int] = []
        if let bass = notes.min() { roots.append(Int(bass) % 12) }
        if let previous, !roots.contains(previous.root) { roots.append(previous.root) }
        roots += classes.sorted().filter { !roots.contains($0) }
        let qualities: [Quality] = [
            .major, .minor, .seventh, .majorSeventh, .minorSeventh, .sixth, .minorSixth,
            .halfDiminished, .minorMajorSeventh, .diminished, .diminishedSeventh, .augmented,
            .seventhSuspended, .suspended, .suspendedSecond
        ] + Quality.allCases.filter { $0.intervals.count >= 4 }
        // Prefer a previously recognized seventh to a sixth inversion with the same notes.
        if let previous, classes == Set(previous.quality.intervals.map({ pitchClass(previous.root + $0) })) {
            return previous
        }
        for root in roots {
            for quality in qualities where classes == Set(quality.intervals.map({ pitchClass(root + $0) })) {
                return Chord(root: root, quality: quality)
            }
        }
        return nil
    }
}

private func pitchClass(_ note: Int) -> Int { (note % 12 + 12) % 12 }

public struct Arranger {
    private struct Lane: Hashable, Comparable {
        let part: UInt8
        var voice: UInt8? = nil

        static func < (lhs: Lane, rhs: Lane) -> Bool {
            (lhs.part, lhs.voice ?? 0) < (rhs.part, rhs.voice ?? 0)
        }
    }

    private struct Key: Hashable {
        let channel: UInt8
        let note: UInt8
        var voice: UInt8? = nil
        var lane: Lane { Lane(part: channel, voice: voice) }
    }
    private struct Sounding {
        let output: Key
        let velocity: UInt8
    }

    public let style: Style
    public private(set) var chord: Chord?
    public private(set) var sectionName: String?
    public private(set) var sectionEpoch = 0
    public private(set) var pendingSection: String?
    public private(set) var position = 0
    public private(set) var main = "Main A"
    public var autoFill = true
    public var polyphonicVoices: [UInt8: Int] = [:]

    private var section: Style.Section?
    private var eventIndex = 0
    private var nextMain: String?
    private var notes: [Key: [Sounding?]] = [:]
    private var soundingCount: [Key: Int] = [:]
    private var sustain: Set<UInt8> = []
    private var fingering: GuitarFingering?
    private var bendOffsets: [Lane: Int] = [:]
    private var lastVoiceUse: [Lane: Int] = [:]
    private var voiceClock = 0
    private var sustainedVoices: [Key: [Sounding?]] = [:]
    private var styleWheels: [UInt8: Int] = [:]
    private var bankMSB: [UInt8: UInt8] = [:]
    private var bankLSB: [UInt8: UInt8] = [:]
    private var switchedChannels: Set<UInt8> = []

    public init(style: Style) { self.style = style }
    public var isPlaying: Bool { section != nil }
    public var sectionLength: Int { section?.length ?? 0 }

    public mutating func setChord(_ value: Chord) -> [MIDI] {
        guard value != chord else { return [] }
        chord = value
        fingering = nil
        guard let section else { return [] }
        var messages: [MIDI] = []
        var changes: [Lane: [(Key, Int, Sounding, Key?, UInt8, Bool)]] = [:]
        let keys = Set(notes.keys).union(sustainedVoices.keys).sorted { ($0.channel, $0.note) < ($1.channel, $1.note) }
        for key in keys {
            let rule = section.rules[key.channel]
            let zone = rule?.zone(key.note)
            let behavior = zone?.retrigger ?? 1
            let converted = outputKey(key, in: section)
            for released in [false, true] {
                let voices = (released ? sustainedVoices[key] : notes[key]) ?? []
                for (index, entry) in voices.enumerated() {
                    guard let voice = entry, voice.output.channel > 9 else { continue }
                    var target = converted
                    if (behavior == 2 || behavior == 4), let output = converted {
                        let octave = Int(voice.output.note) / 12 * 12
                        let root = (zone?.ntt ?? 0) & 0x80 != 0 ? value.bass ?? value.root : value.root
                        let pitch = octave + root
                        target = Key(channel: output.channel, note: UInt8(pitch <= 127 ? pitch : pitch - 12))
                    }
                    changes[voice.output.lane, default: []].append((key, index, voice, target, behavior, released))
                }
            }
        }

        for lane in changes.keys.sorted() {
            guard let held = changes[lane] else { continue }
            let requested = held.compactMap { _, _, voice, target, rule, _ -> Int? in
                guard (rule == 1 || rule == 2), let target else { return nil }
                return Int(target.note) - Int(voice.output.note)
            }
            let proposed = requested.first ?? 0
            let offset = abs(proposed) < bendRange(lane) && requested.allSatisfy { $0 == proposed } ? proposed : 0
            var attacks: [(Key, UInt8)] = []
            for (key, index, voice, target, rule, released) in held {
                if (rule == 1 || rule == 2), let target,
                   Int(target.note) - Int(voice.output.note) == offset { continue }
                messages += release(voice.output)
                var replacement: Sounding?
                if let target, rule != 0, (0...127).contains(Int(target.note) - offset) {
                    let output = Key(channel: target.channel, note: UInt8(Int(target.note) - offset), voice: lane.voice)
                    replacement = Sounding(output: output, velocity: voice.velocity)
                    attacks.append((output, voice.velocity))
                }
                if released { sustainedVoices[key]?[index] = replacement } else { notes[key]?[index] = replacement }
            }
            if offset != bendOffsets[lane, default: 0] { messages += setBend(offset, lane: lane) }
            for (output, velocity) in attacks { messages += strike(output, velocity: velocity) }
        }
        return messages
    }

    public mutating func clearChord() -> [MIDI] {
        guard chord != nil else { return [] }
        chord = nil
        fingering = nil
        var messages: [MIDI] = []
        let sustainedHarmony = sustain.filter { $0 > 9 }.sorted()
        for channel in sustainedHarmony {
            sustain.remove(channel)
            messages.append(MIDI(0xb0 | channel, 64))
            messages += releaseSustained(part: channel)
        }
        let keys = notes.keys.sorted { ($0.channel, $0.note) < ($1.channel, $1.note) }
        for key in keys {
            guard var voices = notes[key] else { continue }
            for index in voices.indices {
                guard let voice = voices[index], voice.output.channel > 9 else { continue }
                messages += release(voice.output)
                voices[index] = nil
            }
            notes[key] = voices
        }
        for lane in bendOffsets.keys.sorted() { messages += setBend(0, lane: lane) }
        return messages
    }

    public mutating func start(_ name: String? = nil) -> [MIDI] {
        guard let selected = find(name ?? main) ?? style.sections.first(where: { $0.name.hasPrefix("Main ") }) else {
            return []
        }
        let offs = clearNotes()
        pendingSection = nil
        nextMain = nil
        enter(selected)
        return offs + advance(0)
    }

    public mutating func selectMain(_ name: String) {
        guard find(name) != nil else { return }
        if !isPlaying { main = name; return }
        let letter = String(name.suffix(1))
        if autoFill || sectionName == name, let fill = find("Fill In " + letter + letter) {
            pendingSection = fill.name
            nextMain = name
        } else {
            pendingSection = name
            nextMain = nil
        }
    }

    public mutating func triggerFill(_ name: String, semiBar: Bool) -> [MIDI] {
        guard isPlaying, name.hasPrefix("Fill In "), let fill = find(name) else { return [] }
        let target = "Main " + name.suffix(1)
        nextMain = find(target)?.name ?? main
        let bar = max(1, style.ticksPerBar)
        let half = bar / 2
        guard semiBar, position % bar < half, half < fill.length else {
            pendingSection = fill.name
            return []
        }
        let messages = clearNotes()
        pendingSection = nil
        enter(fill)
        position = half
        eventIndex = fill.events.firstIndex { $0.tick >= half } ?? fill.events.count
        return messages + advance(0)
    }

    public mutating func resetSection() -> [MIDI] {
        guard let section else { return [] }
        let messages = clearNotes()
        enter(section)
        return messages + advance(0)
    }

    public mutating func selectSection(_ name: String) {
        guard find(name) != nil, isPlaying else { return }
        pendingSection = name
        nextMain = nil
    }

    public mutating func stop() -> [MIDI] {
        let messages = clearNotes()
        section = nil
        sectionName = nil
        pendingSection = nil
        nextMain = nil
        position = 0
        return messages
    }

    public mutating func advance(_ ticks: Int) -> [MIDI] {
        var remaining = max(0, ticks)
        var messages: [MIDI] = []
        while let section {
            let barLength = max(1, style.ticksPerBar)
            let nextBar = (position / barLength + 1) * barLength
            let boundary = pendingSection == nil ? section.length : min(nextBar, section.length)
            let step = min(remaining, boundary - position)
            let target = position + step
            while eventIndex < section.events.count {
                let event = section.events[eventIndex]
                guard event.tick <= target else { break }
                if event.tick < boundary || event.midi.kind == 0x80 || (event.midi.kind == 0x90 && event.midi.data2 == 0) {
                    messages += consume(event.midi, in: section)
                }
                eventIndex += 1
            }
            position = target
            remaining -= step
            guard position == boundary else { break }
            let successor: Style.Section?
            if let pending = pendingSection {
                successor = find(pending)
                pendingSection = nil
            } else if section.name.hasPrefix("Ending ") {
                successor = nil
            } else if section.name.hasPrefix("Main ") {
                successor = section
            } else {
                successor = find(nextMain ?? main)
                nextMain = nil
            }
            messages += clearNotes()
            guard let successor else {
                self.section = nil
                sectionName = nil
                position = 0
                break
            }
            enter(successor)
        }
        return messages
    }

    private func find(_ name: String) -> Style.Section? { style.sections.first { $0.name == name } }

    private mutating func enter(_ section: Style.Section) {
        self.section = section
        sectionName = section.name
        sectionEpoch &+= 1
        position = 0
        eventIndex = 0
        bankMSB.removeAll(keepingCapacity: true)
        bankLSB.removeAll(keepingCapacity: true)
        if section.name.hasPrefix("Main ") { main = section.name }
    }

    private mutating func consume(_ midi: MIDI, in section: Style.Section) -> [MIDI] {
        let key = Key(channel: midi.channel, note: midi.data1)
        let destination = section.rules[midi.channel]?.destination ?? midi.channel
        guard destination >= 8 else { return [] }
        switch midi.kind {
        case 0x90 where midi.data2 > 0:
            var messages: [MIDI] = []
            var output = outputKey(key, in: section)
            if let desired = output {
                let rule = section.rules[key.channel]?.zone(key.note).retrigger
                if rule == 1 || rule == 2, let voice = availableVoice(part: desired.channel) {
                    output?.voice = voice
                    let lane = Lane(part: desired.channel, voice: voice)
                    voiceClock += 1
                    lastVoiceUse[lane] = voiceClock
                    messages += setBend(0, lane: lane, initializeVoice: true)
                } else {
                    let pitch = Int(desired.note) - bendOffsets[desired.lane, default: 0]
                    output = (0...127).contains(pitch) ? Key(channel: desired.channel, note: UInt8(pitch)) : nil
                }
            }
            notes[key, default: []].append(output.map { Sounding(output: $0, velocity: midi.data2) })
            if let output { messages += strike(output, velocity: midi.data2) }
            return messages
        case 0x80, 0x90:
            guard var voices = notes[key], !voices.isEmpty else { return [] }
            let voice = voices.removeFirst()
            notes[key] = voices.isEmpty ? nil : voices
            guard let voice else { return [] }
            if voice.output.voice != nil, sustain.contains(destination) {
                sustainedVoices[key, default: []].append(voice)
                return []
            }
            return release(voice.output) + centerIfSilent(destination)
        case 0xb0:
            if midi.data1 == 0 { bankMSB[midi.channel] = midi.data2; return [] }
            if midi.data1 == 32 { bankLSB[midi.channel] = midi.data2; return [] }
            if midi.data1 == 64 {
                if midi.data2 >= 64 { sustain.insert(destination) } else { sustain.remove(destination) }
            }
            if [120, 121, 123].contains(midi.data1) { return [] }
            if midi.data1 == 64, midi.data2 < 64 {
                return [midi.onChannel(destination)] + releaseSustained(part: destination) + centerIfSilent(destination)
            }
            return [midi.onChannel(destination)]
        case 0xe0:
            styleWheels[destination] = Int(midi.data1) + 128 * Int(midi.data2) - 8192
            let voices = Set(soundingCount.keys.filter { $0.channel == destination }.map(\.lane))
                .filter { $0.voice != nil }.sorted()
            return [wheel(lane: Lane(part: destination))] + voices.map(wheel)
        case 0xc0:
            switchedChannels.insert(destination)
            let initial = style.voices[midi.channel] ?? style.voices[destination]
            return programChange(channel: destination, msb: bankMSB[midi.channel] ?? initial?.msb ?? 0,
                                 lsb: bankLSB[midi.channel] ?? initial?.lsb ?? 0, program: midi.data1)
        case 0xd0:
            return [midi.onChannel(destination)]
        default:
            return []
        }
    }

    private mutating func outputKey(_ key: Key, in section: Style.Section) -> Key? {
        let rule = section.rules[key.channel]
        let channel = rule?.destination ?? key.channel
        guard channel >= 8 else { return nil }
        if channel <= 9 { return Key(channel: channel, note: key.note) }
        guard let chord else { return nil }
        guard let rule else { return Key(channel: channel, note: key.note) }
        guard rule.noteMask & (1 << chord.root) != 0,
              rule.chordMask & (UInt64(1) << chord.quality.rawValue) != 0 else { return nil }

        let zone = rule.zone(key.note)
        let table = zone.ntt & 0x7f
        let bassRoot = zone.ntt & 0x80 != 0 ? chord.bass ?? chord.root : chord.root
        let original = Int(key.note)
        var note: Int
        if zone.ntr == 2, table <= 2 {
            if original >= 96 {
                // Keep articulation-only phrases, such as GuitarSerenade's Intro A.
                guard !section.channelsWithGuitarTones.contains(key.channel) else { return nil }
                return Key(channel: channel, note: key.note)
            }
            if fingering == nil { fingering = GuitarFingering(chord: chord) }
            guard let voiced = fingering?.note(for: original, table: table, bassRoot: bassRoot) else { return nil }
            note = voiced
        } else {
            var offset = pitchClass(bassRoot - rule.root)
            if zone.ntr == 0 && bassRoot > zone.highKey % 12 { offset -= 12 }
            if zone.ntr == 1 && offset > 6 { offset -= 12 }
            if table == 0 && zone.ntr == 1 { offset = 0 }
            note = original + offset

            let relative = pitchClass(original - rule.root)
            let source = Chord.Quality(rawValue: rule.chordID) ?? .major
            switch table {
            case 3...10:
                note += scaleCorrection(relative, table: table, source: source, target: chord.quality)
            case 1, 2:
                let destination = chord.quality.intervals
                if let index = source.intervals.firstIndex(of: relative), index < destination.count {
                    note += destination[index] - relative
                } else if table == 2 && !destination.contains(relative),
                          let correction = [-1, 1, -2, 2].first(where: {
                              destination.contains(pitchClass(relative + $0))
                          }) {
                    note += correction
                }
            default: break
            }
        }

        if zone.low <= zone.high {
            while note < zone.low { note += 12 }
            while note > zone.high { note -= 12 }
            guard note >= zone.low else { return nil }
        }
        guard (0...127).contains(note) else { return nil }
        return Key(channel: channel, note: UInt8(note))
    }

    // Yamaha SFF2 pairs each scale table with a variant that also converts the fifth.
    private func scaleCorrection(_ interval: Int, table: UInt8, source: Chord.Quality,
                                 target: Chord.Quality) -> Int {
        let degrees = Self.minorDegrees[Int(table - 3) / 2]
        let sourceMinor = source.isMinor
        let targetMinor = target.isMinor
        if sourceMinor != targetMinor {
            if targetMinor && degrees.contains(interval) { return -1 }
            if sourceMinor && degrees.contains(interval + 1) { return 1 }
        }
        if table.isMultiple(of: 2) {
            let sourceFifth = source.intervals.first { (6...8).contains($0) } ?? 7
            let targetFifth = target.intervals.first { (6...8).contains($0) } ?? 7
            if interval == sourceFifth { return targetFifth - sourceFifth }
        }
        return 0
    }

    private static let minorDegrees = [[4], [4, 9], [4, 9, 11], [4, 11]]

    private func programChange(channel: UInt8, msb: UInt8, lsb: UInt8, program: UInt8) -> [MIDI] {
        [MIDI(0xb0 | channel, 0, msb), MIDI(0xb0 | channel, 32, lsb), MIDI(0xc0 | channel, program)]
    }

    private func availableVoice(part: UInt8) -> UInt8? {
        let count = min(15, polyphonicVoices[part, default: 0])
        guard count > 0 else { return nil }
        let used = Set(soundingCount.keys.filter { $0.channel == part }.compactMap(\.voice))
        return (1...UInt8(count)).filter { !used.contains($0) }.min {
            lastVoiceUse[Lane(part: part, voice: $0), default: 0] < lastVoiceUse[Lane(part: part, voice: $1), default: 0]
        }
    }

    private mutating func releaseSustained(part: UInt8) -> [MIDI] {
        var messages: [MIDI] = []
        for key in sustainedVoices.keys.sorted(by: { ($0.channel, $0.note) < ($1.channel, $1.note) }) {
            guard let voices = sustainedVoices[key] else { continue }
            let remaining = voices.compactMap { $0 }.filter { voice in
                guard voice.output.channel == part else { return true }
                messages += release(voice.output)
                return false
            }
            sustainedVoices[key] = remaining.isEmpty ? nil : remaining.map(Optional.some)
        }
        return messages
    }

    private mutating func centerIfSilent(_ channel: UInt8) -> [MIDI] {
        let lane = Lane(part: channel)
        guard bendOffsets[lane] != nil, !sustain.contains(channel),
              !soundingCount.keys.contains(where: { $0.lane == lane }) else { return [] }
        return setBend(0, lane: lane)
    }

    private func bendRange(_ lane: Lane) -> Int { lane.voice == nil ? 12 : 48 }

    private mutating func setBend(_ offset: Int, lane: Lane, initializeVoice: Bool = false) -> [MIDI] {
        let wasWide = bendOffsets[lane] != nil
        bendOffsets[lane] = offset == 0 ? nil : offset
        var messages: [MIDI] = []
        if initializeVoice || (lane.voice == nil && (offset != 0) != wasWide) {
            let status = 0xb0 | lane.part
            let range = lane.voice != nil || offset != 0 ? UInt8(bendRange(lane)) : 2
            messages = [MIDI(status, 101, 0, voice: lane.voice), MIDI(status, 100, 0, voice: lane.voice),
                        MIDI(status, 6, range, voice: lane.voice), MIDI(status, 38, 0, voice: lane.voice),
                        MIDI(status, 101, 127, voice: lane.voice), MIDI(status, 100, 127, voice: lane.voice)]
        }
        return messages + [wheel(lane: lane)]
    }

    private func wheel(lane: Lane) -> MIDI {
        let style = styleWheels[lane.part, default: 0]
        let offset = bendOffsets[lane, default: 0]
        let deviation = lane.voice != nil || offset != 0 ? (offset * 8192 + style * 2) / bendRange(lane) : style
        let value = min(16383, max(0, 8192 + deviation))
        return MIDI(0xe0 | lane.part, UInt8(value & 127), UInt8(value >> 7), voice: lane.voice)
    }

    private mutating func strike(_ key: Key, velocity: UInt8) -> [MIDI] {
        soundingCount[key, default: 0] += 1
        return [MIDI(0x90 | key.channel, key.note, velocity, voice: key.voice)]
    }

    private mutating func release(_ key: Key) -> [MIDI] {
        guard let count = soundingCount[key] else { return [] }
        if count > 1 {
            soundingCount[key] = count - 1
            return []
        }
        soundingCount[key] = nil
        return [MIDI(0x80 | key.channel, key.note, 0, voice: key.voice)]
    }

    private mutating func clearNotes() -> [MIDI] {
        var messages = sustain.sorted().map { MIDI(0xb0 | $0, 64) }
            + soundingCount.keys.sorted { ($0.channel, $0.note) < ($1.channel, $1.note) }
                .map { MIDI(0x80 | $0.channel, $0.note, 0, voice: $0.voice) }
        let bentLanes = Set(styleWheels.keys.map { Lane(part: $0) }).union(bendOffsets.keys)
        styleWheels.removeAll(keepingCapacity: true)
        for lane in bentLanes.sorted() { messages += setBend(0, lane: lane) }
        for channel in switchedChannels.sorted() {
            let base = style.voices[channel] ?? Style.VoiceAddress(msb: 0, lsb: 0, program: channel == 10 ? 33 : 0)
            messages += programChange(channel: channel, msb: base.msb, lsb: base.lsb, program: base.program)
        }
        switchedChannels.removeAll(keepingCapacity: true)
        sustain.removeAll(keepingCapacity: true)
        notes.removeAll(keepingCapacity: true)
        sustainedVoices.removeAll(keepingCapacity: true)
        soundingCount.removeAll(keepingCapacity: true)
        return messages
    }
}
