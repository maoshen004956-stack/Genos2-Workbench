import Foundation

public struct YamahaPadBank {
    public struct Slot {
        public let asset: PerformanceAsset
        public let options: PadOptions
    }

    public let slots: [Slot?]

    public init(asset: PerformanceAsset) throws {
        var bytes = Array(asset.data)
        if bytes.count >= 132, bytes[128..<132].elementsEqual("MThd".utf8) { bytes.removeFirst(128) }
        var reader = Cursor(bytes: bytes)
        let header = try reader.chunk("MThd")
        guard header.count >= 6, header[0...3].elementsEqual([0, 1, 0, 5]), header[4] < 128 else {
            throw StyleError.invalid("需要包含四个 MIDI Pad 的 Yamaha Multi Pad Bank")
        }
        let division = Int(header[4]) * 256 + Int(header[5])
        guard division > 0 else { throw StyleError.invalid("Multi Pad 的 MIDI 时基无效") }

        let settings = try MIDIFile.readTrack(reader.chunk("MTrk"))
        let flags = Dictionary(settings.texts.compactMap { text -> (String, [Bool])? in
            let code = String(text.prefix(2))
            let bits = Array(text.dropFirst(2))
            guard ["CM", "RP"].contains(code), bits.count == 4, bits.allSatisfy({ $0 == "0" || $0 == "1" || (code == "CM" && $0 == "2") }) else { return nil }
            return (code, bits.map { $0 != "0" })
        }, uniquingKeysWith: { _, latest in latest })
        guard let chord = flags["CM"], let repeatPlayback = flags["RP"] else {
            throw StyleError.invalid("Yamaha Multi Pad 缺少 CM / RP 设置")
        }

        let stem = URL(fileURLWithPath: asset.name).deletingPathExtension().lastPathComponent
        slots = try (0..<4).map { index in
            let track = try MIDIFile.readTrack(reader.chunk("MTrk"))
            guard track.events.contains(where: { $0.midi.kind == 0x90 && $0.midi.data2 > 0 }) else { return nil }
            var options = PadOptions()
            options.followChord = chord[index]
            options.yamahaChordMatch = chord[index]
            options.repeatPlayback = repeatPlayback[index]
            let data = MIDIFile.encode(events: track.events, ticksPerQuarter: division, tempo: settings.tempo ?? 120,
                                       duration: track.duration)
            let namePrefix = "N\(index + 1)"
            let label = settings.texts.first { $0.hasPrefix(namePrefix) }
                .map { String($0.dropFirst(2).prefix { $0 != "\0" }).trimmingCharacters(in: .whitespaces) }
            let name = label ?? track.texts.first(where: { !$0.isEmpty }) ?? "\(stem) \(index + 1)"
            return Slot(asset: PerformanceAsset(name: name + ".mid", data: data), options: options)
        }
    }
}
