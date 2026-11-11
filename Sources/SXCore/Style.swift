import Foundation
import CryptoKit

public struct MIDI: Equatable {
    public let status: UInt8
    public let data1: UInt8
    public let data2: UInt8

    // A voice is local routing metadata. The MIDI status still names the logical part.
    public let voice: UInt8?

    public init(_ status: UInt8, _ data1: UInt8, _ data2: UInt8 = 0, voice: UInt8? = nil) {
        self.status = status
        self.data1 = data1
        self.data2 = data2
        self.voice = voice
    }

    public var channel: UInt8 { status & 15 }
    public var kind: UInt8 { status & 0xf0 }
    public var size: Int {
        if status >= 0xf8 { return 1 }
        return kind == 0xc0 || kind == 0xd0 ? 2 : 3
    }
    public func onChannel(_ channel: UInt8) -> MIDI { MIDI(kind | channel, data1, data2) }
    public func withNote(_ note: UInt8) -> MIDI { MIDI(status, note, data2, voice: voice) }
}

public struct Style {
    public struct Event {
        public let tick: Int
        public let midi: MIDI

        public init(tick: Int, midi: MIDI) {
            self.tick = tick
            self.midi = midi
        }
    }

    public struct Section {
        public let name: String
        public let length: Int
        public let events: [Event]
        public let firstNoteTickByPart: [UInt8: Int]
        let rules: [UInt8: Rule]
        let channelsWithGuitarTones: Set<UInt8>
    }

    struct Rule {
        let destination: UInt8
        let root: Int
        let chordID: Int
        let noteMask: Int
        let chordMask: UInt64
        let rangeLow: UInt8
        let rangeHigh: UInt8
        let zones: [Zone]

        struct Zone {
            let ntr: UInt8
            let ntt: UInt8
            let highKey: Int
            let low: Int
            let high: Int
            let retrigger: UInt8
        }

        func zone(_ note: UInt8) -> Zone {
            zones[note < rangeLow ? 0 : note > rangeHigh ? 2 : 1]
        }
    }

    public struct VoiceAddress: Codable, Equatable {
        public let msb: UInt8
        public let lsb: UInt8
        public let program: UInt8

        public init(msb: UInt8, lsb: UInt8, program: UInt8) {
            self.msb = msb
            self.lsb = lsb
            self.program = program
        }
    }

    public struct OneTouchSetting {
        public struct Voice {
            public let address: VoiceAddress
            public let enabled: Bool?
            public let volume: UInt8?
            public let pan: UInt8?
            public let octave: Int?
        }
        public let voices: [UInt8: Voice]
    }

    public let audioClips: [String: StyleAudioClip]
    public let oneTouchSettings: [OneTouchSetting]
    public let id: String
    public let voices: [UInt8: VoiceAddress]
    /// Channel setup before the first style section (mix, expression and effects).
    public let initialControllers: [UInt8: [UInt8: UInt8]]
    public let name: String
    public let ticksPerQuarter: Int
    public let beatsPerBar: Int
    public let beatUnit: Int
    public let bpm: Double
    public let sections: [Section]
    public let guitarChannels: Set<UInt8>
    public let programs: [UInt8: UInt8]
    public let diagnostics: [String]
    public var ticksPerBar: Int { ticksPerQuarter * beatsPerBar * 4 / beatUnit }

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
    }

    public init(data: Data, name: String) throws {
        var file = Cursor(bytes: Array(data))
        let header = try file.chunk("MThd")
        guard header.count >= 6, header[0] == 0, header[1] == 0,
              header[2] == 0, header[3] == 1, header[4] < 128 else {
            throw StyleError.invalid("需要单轨、PPQ 格式的 Yamaha Style")
        }
        let division = Int(header[4]) * 256 + Int(header[5])
        guard division > 0 else { throw StyleError.invalid("MIDI PPQ 为零") }

        var track = Cursor(bytes: try file.styleTrack())
        var rules: [String: [UInt8: Rule]] = [:]
        var ignored = Set<String>()
        var foundCASM = false
        var ots: [OneTouchSetting] = []
        var audioArrangement: [UInt8]?
        var audioFiles: [UInt8]?
        var editableAudio: [String: StyleAudioClip] = [:]
        while !file.empty {
            let (tag, body) = try file.chunk()
            if tag == "AASM" { audioArrangement = body; continue }
            if tag == "AFil" { audioFiles = body; continue }
            if tag == "SXAu" {
                let (section, clip) = try StyleAudioClip.readEditable(body)
                editableAudio[section] = clip
                continue
            }
            if tag == "OTSc" {
                do { ots = try Self.readOTS(body) }
                catch { ignored.insert("One Touch Setting 数据无效：\(error.localizedDescription)") }
                continue
            }
            guard tag == "CASM" else { continue }
            foundCASM = true
            var casm = Cursor(bytes: body)
            while !casm.empty {
                let (tag, bytes) = try casm.chunk()
                guard tag == "CSEG" else { ignored.insert("CASM \(tag)"); continue }
                var segment = Cursor(bytes: bytes)
                let names = String(decoding: try segment.chunk("Sdec"), as: UTF8.self).split(separator: ",")
                var legacyChannels: [UInt8: Rule] = [:]
                var legacyNTT: [UInt8: UInt8] = [:]
                while !segment.empty {
                    let (tag, bytes) = try segment.chunk()
                    if tag == "Cntt", bytes.count == 2 {
                        legacyNTT[bytes[0]] = bytes[1]
                        continue
                    }
                    guard tag == "Ctb2" || tag == "Ctab" else { ignored.insert("CASM \(tag)"); continue }
                    let modern = tag == "Ctb2"
                    guard bytes.count >= (modern ? 40 : 26), bytes[0] < 16,
                          (8...15).contains(bytes[9]), bytes[18] < 12 else {
                        throw StyleError.invalid("CASM \(tag) 声部参数无效")
                    }
                    let zones: [Rule.Zone]
                    if modern {
                        var parsed: [Rule.Zone] = []
                        for base in [22, 28, 34] {
                            let ntr = bytes[base], ntt = bytes[base + 1]
                            let key = Int(bytes[base + 2]), low = Int(bytes[base + 3]), high = Int(bytes[base + 4])
                            parsed.append(Rule.Zone(ntr: ntr, ntt: ntt, highKey: key, low: low, high: high,
                                                    retrigger: bytes[base + 5]))
                        }
                        zones = parsed
                    } else {
                        let legacy = bytes[21]
                        let table: UInt8 = legacy == 3 ? 0x81 : legacy == 4 ? 3 : legacy
                        zones = Array(repeating: Rule.Zone(ntr: bytes[20], ntt: table, highKey: Int(bytes[22]),
                                                           low: Int(bytes[23]), high: Int(bytes[24]), retrigger: bytes[25]), count: 3)
                    }
                    let noteMask = (Int(bytes[11]) << 8) | Int(bytes[12])
                    let chordMask: UInt64 = bytes[13...17].reduce(0) { ($0 << 8) | UInt64($1) }
                    let rule = Rule(destination: bytes[9], root: Int(bytes[18]), chordID: Int(bytes[19]),
                                    noteMask: noteMask, chordMask: chordMask,
                                    rangeLow: modern ? bytes[20] : 0, rangeHigh: modern ? bytes[21] : 127, zones: zones)
                    if bytes[9] > 9 {
                        let activeZones = zones.enumerated().filter { index, _ in
                            index == 1 || (index == 0 && rule.rangeLow > 0)
                                || (index == 2 && rule.rangeHigh < 127)
                        }
                        for (_, zone) in activeZones where zone.ntr > 1 || zone.ntt & 0x7f > 10 || zone.retrigger > 5 {
                            ignored.insert("部分 NTR/NTT/RTR 转换近似（\(zone.ntr)/\(zone.ntt & 0x7f)/\(zone.retrigger)）")
                        }
                    }
                    if modern {
                        for label in names { rules[String(label), default: [:]][bytes[0]] = rule }
                    } else {
                        legacyChannels[bytes[0]] = rule
                    }
                }
                for (channel, rule) in legacyChannels {
                    let zones = rule.zones.map { zone in
                        Rule.Zone(ntr: zone.ntr, ntt: legacyNTT[channel] ?? zone.ntt, highKey: zone.highKey,
                                  low: zone.low, high: zone.high, retrigger: zone.retrigger)
                    }
                    let updated = Rule(destination: rule.destination, root: rule.root, chordID: rule.chordID,
                                       noteMask: rule.noteMask, chordMask: rule.chordMask,
                                       rangeLow: rule.rangeLow, rangeHigh: rule.rangeHigh, zones: zones)
                    for label in names { rules[String(label), default: [:]][channel] = updated }
                }
            }
        }
        guard foundCASM else { throw StyleError.invalid("缺少 CASM") }

        var sections: [Section] = []
        var programs: [UInt8: UInt8] = [:]
        var voices: [UInt8: VoiceAddress] = [:]
        var initialControllers: [UInt8: [UInt8: UInt8]] = [:]
        var msb: [UInt8: UInt8] = [:]
        var lsb: [UInt8: UInt8] = [:]
        var events: [Event] = []
        var running: UInt8?
        var start = 0
        var tick = 0
        var current: String?
        var tempo = 500_000
        var beats = 4
        var unit = 4
        var sff2 = false
        var ended = false

        func closeSection() {
            guard let name = current, tick > start else { return }
            let sectionRules = rules[name] ?? [:]
            var firstNoteTickByPart: [UInt8: Int] = [:]
            var pitchedGuitarChannels = Set<UInt8>()
            for event in events {
                let midi = event.midi
                guard midi.kind == 0x90, midi.data2 > 0 else { continue }
                let rule = sectionRules[midi.channel]
                let part = rule?.destination ?? midi.channel
                if part >= 8, firstNoteTickByPart[part] == nil { firstNoteTickByPart[part] = event.tick }
                if midi.data1 < 96, rule?.zone(midi.data1).ntr == 2 { pitchedGuitarChannels.insert(midi.channel) }
            }
            sections.append(Section(name: name, length: tick - start, events: events,
                                    firstNoteTickByPart: firstNoteTickByPart, rules: sectionRules,
                                    channelsWithGuitarTones: pitchedGuitarChannels))
        }

        while !track.empty && !ended {
            tick += try track.vlq()
            let next = try track.peek()
            let status: UInt8
            if next >= 128 {
                status = try track.byte()
            } else if let previous = running {
                status = previous
            } else {
                throw StyleError.invalid("MIDI running status 缺失")
            }
            switch status {
            case 0xff:
                let kind = try track.byte()
                let body = try track.take(track.vlq())
                switch kind {
                case 0x06:
                    let marker = String(decoding: body, as: UTF8.self)
                    if marker == "SFF2" { sff2 = true }
                    if ["Main ", "Intro ", "Fill In ", "Ending ", "Break"].contains(where: marker.hasPrefix) {
                        closeSection()
                        current = marker
                        start = tick
                        events.removeAll(keepingCapacity: true)
                    }
                case 0x51 where current == nil && body.count == 3:
                    tempo = max(1, Int(body[0]) << 16 | Int(body[1]) << 8 | Int(body[2]))
                case 0x58 where current == nil && body.count >= 2 && body[0] > 0 && body[1] <= 7:
                    beats = Int(body[0])
                    unit = 1 << Int(body[1])
                case 0x2f:
                    closeSection()
                    ended = true
                default: break
                }
            case 0xf0, 0xf7:
                running = nil
                _ = try track.take(track.vlq())
            case 0x80...0xef:
                running = status
                let kind = status & 0xf0
                let a = try track.byte()
                let b: UInt8 = kind == 0xc0 || kind == 0xd0 ? 0 : try track.byte()
                guard a < 128, b < 128 else { throw StyleError.invalid("MIDI 数据字节无效") }
                let midi = MIDI(status, a, b)
                if current != nil {
                    events.append(Event(tick: tick - start, midi: midi))
                } else if kind == 0xc0 {
                    programs[midi.channel] = a
                    voices[midi.channel] = VoiceAddress(msb: msb[midi.channel, default: 0],
                                                       lsb: lsb[midi.channel, default: 0], program: a)
                } else if kind == 0xb0 {
                    initialControllers[midi.channel, default: [:]][a] = b
                    if a == 0 { msb[midi.channel] = b }
                    if a == 32 { lsb[midi.channel] = b }
                }
            default:
                throw StyleError.invalid("不支持的 MIDI 状态 \(status)")
            }
        }
        guard sff2, ended, sections.contains(where: { $0.name.hasPrefix("Main ") }) else {
            throw StyleError.invalid("需要带主奏段及结束标记的 SFF2 Style")
        }
        id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        self.voices = voices
        self.initialControllers = initialControllers
        self.oneTouchSettings = ots
        self.name = name
        ticksPerQuarter = division
        beatsPerBar = beats
        beatUnit = unit
        bpm = 60_000_000 / Double(tempo)
        self.sections = sections
        self.guitarChannels = Set(sections.flatMap { section in
            section.channelsWithGuitarTones.compactMap { section.rules[$0]?.destination }
        })
        self.programs = programs
        if let audioArrangement, let audioFiles {
            audioClips = try StyleAudioClip.decode(arrangement: audioArrangement, audio: audioFiles)
                .merging(editableAudio, uniquingKeysWith: { _, edited in edited })
        } else {
            audioClips = editableAudio
            if audioArrangement != nil || audioFiles != nil { ignored.insert("音频 Style 缺少 AASM 或 AFil 区块") }
        }
        diagnostics = ignored.sorted()
    }

    public func bendVoiceCounts(limit: Int = 8) -> [UInt8: Int] {
        guard limit > 0 else { return [:] }
        var counts: [UInt8: Int] = [:]
        for section in sections {
            var held: [UInt8: Int] = [:]
            var pressed: [UInt16: Int] = [:]
            for event in section.events {
                let midi = event.midi
                guard midi.kind == 0x80 || midi.kind == 0x90,
                      let rule = section.rules[midi.channel], rule.destination > 9,
                      (1...2).contains(rule.zone(midi.data1).retrigger) else { continue }
                let key = UInt16(midi.channel) * 128 + UInt16(midi.data1)
                if midi.kind == 0x90 && midi.data2 > 0 {
                    pressed[key, default: 0] += 1
                    held[rule.destination, default: 0] += 1
                    counts[rule.destination] = min(limit, max(counts[rule.destination, default: 0], held[rule.destination, default: 0]))
                } else if pressed[key, default: 0] > 0 {
                    pressed[key, default: 0] -= 1
                    held[rule.destination, default: 0] -= 1
                }
            }
        }
        return counts
    }

    private static func readOTS(_ bytes: [UInt8]) throws -> [OneTouchSetting] {
        var chunk = Cursor(bytes: bytes)
        var presets: [OneTouchSetting] = []
        while !chunk.empty {
            let track = try MIDIFile.readTrack(chunk.chunk("MTrk"), systemMessages: true)
            var controls: [UInt8: [UInt8: UInt8]] = [:]
            var addresses: [UInt8: VoiceAddress] = [:]
            for event in track.events where event.midi.channel < 4 {
                let m = event.midi
                if m.kind == 0xb0 { controls[m.channel, default: [:]][m.data1] = m.data2 }
                if m.kind == 0xc0 {
                    let cc = controls[m.channel, default: [:]]
                    addresses[m.channel] = VoiceAddress(msb: cc[0, default: 0], lsb: cc[32, default: 0], program: m.data1)
                }
            }
            var enabled: [UInt8: Bool] = [:]
            var octaves: [UInt8: Int] = [:]
            for message in track.system where message.count == 9
                && message.prefix(5).elementsEqual([0x43, 0x73, 1, 0x50, 8])
                && message[5] < 4 && message[8] == 0xf7 {
                let part = message[5]
                if message[6] == 0 { enabled[part] = message[7] != 0 }
                if message[6] == 3 && (61...67).contains(message[7]) { octaves[part] = Int(message[7]) - 64 }
            }
            let voices = Dictionary(uniqueKeysWithValues: addresses.map { part, address in
                (part, OneTouchSetting.Voice(address: address, enabled: enabled[part],
                                             volume: controls[part]?[7], pan: controls[part]?[10], octave: octaves[part]))
            })
            presets.append(OneTouchSetting(voices: voices))
        }
        return presets
    }

}

public enum StyleError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case let .invalid(message): return message }
    }
}

struct Cursor {
    let bytes: [UInt8]
    var offset = 0
    var empty: Bool { offset == bytes.count }

    func peek() throws -> UInt8 {
        guard !empty else { throw StyleError.invalid("文件提前结束") }
        return bytes[offset]
    }

    mutating func byte() throws -> UInt8 {
        let value = try peek()
        offset += 1
        return value
    }

    mutating func take(_ length: Int) throws -> [UInt8] {
        guard length <= bytes.count - offset else { throw StyleError.invalid("文件区块提前结束") }
        let start = offset
        offset += length
        return Array(bytes[start..<offset])
    }

    mutating func vlq() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            let next = try byte()
            value = value << 7 | Int(next & 127)
            if next < 128 { return value }
        }
        throw StyleError.invalid("MIDI 变长值超出四字节")
    }

    mutating func styleTrack() throws -> [UInt8] {
        let start = offset
        let track = try chunk("MTrk")
        // Some Live Audio styles have an old MTrk length that overlaps CASM.
        // Require a valid CASM header directly after MIDI End of Track.
        let endMarker: [UInt8] = [0xff, 0x2f, 0, 0x43, 0x41, 0x53, 0x4d]
        guard track.count >= endMarker.count + 8 else { return track }
        for index in stride(from: track.count - endMarker.count, through: max(0, track.count - 2048), by: -1)
            where track[index..<(index + endMarker.count)].elementsEqual(endMarker) {
            let casmStart = start + 8 + index + 3
            guard casmStart + 12 <= bytes.count, bytes[(casmStart + 8)..<(casmStart + 12)].elementsEqual("CSEG".utf8) else { continue }
            let length = bytes[(casmStart + 4)..<(casmStart + 8)].reduce(0) { ($0 << 8) | Int($1) }
            guard length >= 8, length <= bytes.count - casmStart - 8 else { continue }
            offset = casmStart
            return Array(track.prefix(index + 3))
        }
        return track
    }

    mutating func chunk() throws -> (String, [UInt8]) {
        let tag = String(decoding: try take(4), as: UTF8.self)
        let length = try take(4).reduce(0) { ($0 << 8) | Int($1) }
        return (tag, try take(length))
    }

    mutating func chunk(_ expected: String) throws -> [UInt8] {
        let (tag, body) = try chunk()
        guard tag == expected else { throw StyleError.invalid("需要 \(expected)，实际为 \(tag)") }
        return body
    }
}
