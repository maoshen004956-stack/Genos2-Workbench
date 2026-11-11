import Foundation

public struct StyleNote: Identifiable, Equatable {
    public let id = UUID()
    public var tick: Int
    public var duration: Int
    public var pitch: UInt8
    public var velocity: UInt8

    public init(tick: Int, duration: Int, pitch: UInt8, velocity: UInt8) {
        self.tick = tick
        self.duration = duration
        self.pitch = pitch
        self.velocity = velocity
    }
}

public struct CASMEdit: Equatable {
    public var ntr: UInt8
    public var ntt: UInt8
    public var highKey: UInt8
    public var low: UInt8
    public var high: UInt8
    public var retrigger: UInt8

    init(_ zone: Style.Rule.Zone) {
        ntr = zone.ntr
        ntt = zone.ntt
        highKey = UInt8(clamping: zone.highKey)
        low = UInt8(clamping: zone.low)
        high = UInt8(clamping: zone.high)
        retrigger = zone.retrigger
    }

    public var slashBass: Bool {
        get { ntt & 128 != 0 }
        set { ntt = newValue ? ntt | 128 : ntt & 127 }
    }
    public var table: UInt8 {
        get { ntt & 127 }
        set { ntt = (ntt & 128) | (newValue & 127) }
    }
}

public struct StyleDocument {
    public let asset: PerformanceAsset
    public let style: Style

    public init(asset: PerformanceAsset) throws {
        self.asset = asset
        style = try Style(data: asset.data, name: URL(fileURLWithPath: asset.name).deletingPathExtension().lastPathComponent)
    }

    public func notes(section: String, channel: UInt8) -> [StyleNote] {
        guard let part = style.sections.first(where: { $0.name == section }) else { return [] }
        var held: [UInt8: [(Int, UInt8)]] = [:]
        var result: [StyleNote] = []
        for event in part.events where event.midi.channel == channel {
            let midi = event.midi
            if midi.kind == 0x90 && midi.data2 > 0 {
                held[midi.data1, default: []].append((event.tick, midi.data2))
            } else if (midi.kind == 0x80 || midi.kind == 0x90), var queue = held[midi.data1], !queue.isEmpty {
                let (start, velocity) = queue.removeFirst()
                held[midi.data1] = queue
                result.append(StyleNote(tick: start, duration: max(1, event.tick - start),
                                        pitch: midi.data1, velocity: velocity))
            }
        }
        for pitch in held.keys.sorted() {
            for (tick, velocity) in held[pitch] ?? [] {
                result.append(StyleNote(tick: tick, duration: max(1, part.length - tick),
                                        pitch: pitch, velocity: velocity))
            }
        }
        return result.sorted { ($0.tick, $0.pitch) < ($1.tick, $1.pitch) }
    }

    public func rule(section: String, channel: UInt8, zone: Int) -> CASMEdit? {
        guard (0...2).contains(zone), let rule = style.sections.first(where: { $0.name == section })?.rules[channel] else { return nil }
        return CASMEdit(rule.zones[zone])
    }

    public func update(section: String, channel: UInt8, notes: [StyleNote]?,
                       zone: Int = 1, rule: CASMEdit? = nil) throws -> StyleDocument {
        guard let part = style.sections.first(where: { $0.name == section }), channel < 16, (0...2).contains(zone) else {
            throw StyleError.invalid("伴奏段落或声部无效")
        }
        if let rule, rule.ntr > 2 || rule.table > (rule.ntr == 2 ? 2 : 10) || rule.low > rule.high
            || rule.high > 127 || rule.highKey > 127 || rule.retrigger > 5 {
            throw StyleError.invalid("CASM 音域、转换表或重触发参数无效")
        }
        var cursor = Cursor(bytes: Array(asset.data))
        var result: [UInt8] = []
        result += MIDIFile.chunk("MThd", try cursor.chunk("MThd"))
        let track = try cursor.styleTrack()
        if let notes {
            result += MIDIFile.chunk("MTrk", try Self.rewriteTrack(track, section: section, length: part.length,
                                                                  channel: channel, notes: notes))
        } else {
            result += MIDIFile.chunk("MTrk", track)
        }
        while !cursor.empty {
            let (tag, body) = try cursor.chunk()
            if tag == "CASM", let rule {
                result += MIDIFile.chunk(tag, try Self.rewriteCASM(body, section: section, channel: channel,
                                                                 zone: zone, rule: rule))
            } else {
                result += MIDIFile.chunk(tag, body)
            }
        }
        return try StyleDocument(asset: PerformanceAsset(name: asset.name, data: Data(result)))
    }

    public func setAudioLoop(section: String, sampleRate: Int, channels: Int, pcm16: Data,
                             bpm: Double) throws -> StyleDocument {
        guard style.sections.contains(where: { $0.name == section }) else {
            throw StyleError.invalid("音频循环需要一个有效的段落")
        }
        let audio = try StyleAudioClip.editable(section: section, sampleRate: sampleRate,
                                                channels: channels, pcm16: pcm16, bpm: bpm)
        var cursor = Cursor(bytes: Array(asset.data))
        var data = MIDIFile.chunk("MThd", try cursor.chunk("MThd"))
        data += MIDIFile.chunk("MTrk", try cursor.styleTrack())
        while !cursor.empty {
            let (tag, body) = try cursor.chunk()
            if tag == "SXAu", try StyleAudioClip.readEditable(body).0 == section { continue }
            data += MIDIFile.chunk(tag, body)
        }
        data += MIDIFile.chunk("SXAu", audio)
        return try StyleDocument(asset: PerformanceAsset(name: asset.name, data: Data(data)))
    }

    private struct RawEvent {
        let tick: Int
        let bytes: [UInt8]
    }

    private static func rewriteTrack(_ bytes: [UInt8], section: String, length: Int, channel: UInt8,
                                     notes: [StyleNote]) throws -> [UInt8] {
        var cursor = Cursor(bytes: bytes)
        var tick = 0
        var running: UInt8?
        var sectionStart: Int?
        var track: [RawEvent] = []
        var edited: [RawEvent] = []

        while !cursor.empty {
            tick += try cursor.vlq()
            let next = try cursor.peek()
            let status: UInt8
            if next >= 128 { status = try cursor.byte() }
            else if let running { status = running }
            else { throw StyleError.invalid("MIDI running status 缺失") }
            var event = [status]
            var boundary = false
            var startsSection = false
            if status == 0xff {
                let type = try cursor.byte()
                let size = try cursor.vlq()
                let body = try cursor.take(size)
                event += [type] + MIDIFile.variableLength(size) + body
                if type == 6 {
                    let name = String(decoding: body, as: UTF8.self)
                    boundary = ["Main ", "Intro ", "Fill In ", "Ending ", "Break"].contains { name.hasPrefix($0) }
                    startsSection = name == section
                }
                if type == 0x2f { boundary = true }
            } else if status == 0xf0 || status == 0xf7 {
                running = nil
                let size = try cursor.vlq()
                event += MIDIFile.variableLength(size) + (try cursor.take(size))
            } else if (0x80...0xef).contains(status) {
                running = status
                event += try cursor.take(status & 0xe0 == 0xc0 ? 1 : 2)
            } else {
                throw StyleError.invalid("不支持的 MIDI 状态 \(status)")
            }

            if boundary, let start = sectionStart {
                for note in notes {
                    guard (0..<length).contains(note.tick), note.duration > 0,
                          note.pitch < 128, (1...127).contains(note.velocity) else {
                        throw StyleError.invalid("音符时间、音高或力度超出范围")
                    }
                    let end = note.tick + min(length - note.tick, note.duration)
                    edited.append(RawEvent(tick: start + note.tick, bytes: [0x90 | channel, note.pitch, note.velocity]))
                    edited.append(RawEvent(tick: start + end, bytes: [0x80 | channel, note.pitch, 0]))
                }
                track += edited.sorted { lhs, rhs in
                    if lhs.tick != rhs.tick { return lhs.tick < rhs.tick }
                    return lhs.bytes[0] & 0xf0 != 0x90 && rhs.bytes[0] & 0xf0 == 0x90
                }
                edited.removeAll()
                sectionStart = nil
            }

            if sectionStart != nil {
                let kind = status & 0xf0
                if status & 15 != channel || (kind != 0x80 && kind != 0x90) {
                    edited.append(RawEvent(tick: tick, bytes: event))
                }
            } else {
                track.append(RawEvent(tick: tick, bytes: event))
            }
            if startsSection { sectionStart = tick }
        }

        var output: [UInt8] = []
        var previous = 0
        for event in track {
            output += MIDIFile.variableLength(event.tick - previous) + event.bytes
            previous = event.tick
        }
        return output
    }

    private static func rewriteCASM(_ bytes: [UInt8], section: String, channel: UInt8,
                                    zone: Int, rule: CASMEdit) throws -> [UInt8] {
        var casm = Cursor(bytes: bytes)
        var output: [UInt8] = []
        var modified = false
        while !casm.empty {
            let (tag, body) = try casm.chunk()
            guard tag == "CSEG" else { output += MIDIFile.chunk(tag, body); continue }
            var segment = Cursor(bytes: body)
            let names = String(decoding: try segment.chunk("Sdec"), as: UTF8.self).split(separator: ",")
            guard names.contains(Substring(section)) else { output += MIDIFile.chunk(tag, body); continue }
            var replacement = MIDIFile.chunk("Sdec", Array(section.utf8))
            var found = false
            while !segment.empty {
                let (entry, bytes) = try segment.chunk()
                var payload = bytes
                if entry == "Ctb2", bytes.count >= 40, bytes[0] == channel {
                    let offset = [22, 28, 34][zone]
                    payload.replaceSubrange(offset..<(offset + 6),
                                            with: [rule.ntr, rule.ntt, rule.highKey, rule.low, rule.high, rule.retrigger])
                    found = true
                }
                replacement += MIDIFile.chunk(entry, payload)
            }
            if found {
                let others = names.filter { $0 != section }.joined(separator: ",")
                if !others.isEmpty {
                    let first = 8 + names.joined(separator: ",").utf8.count
                    output += MIDIFile.chunk(tag, MIDIFile.chunk("Sdec", Array(others.utf8)) + Array(body.dropFirst(first)))
                }
                output += MIDIFile.chunk(tag, replacement)
                modified = true
            } else {
                output += MIDIFile.chunk(tag, body)
            }
        }
        guard modified else { throw StyleError.invalid("此声部没有可编辑的 Ctb2 转换规则") }
        return output
    }
}
