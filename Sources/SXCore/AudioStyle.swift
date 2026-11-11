import Foundation

public struct StyleAudioClip {
    public let sampleRate: Int
    public let channels: Int
    public let frameCount: Int
    public let volume: Float
    public let pan: Float
    public let sourceTempo: Double?
    private let pcm: Data

    private init(rate: Int, channels: Int, pcm: Data, volume: Float, pan: Float, sourceTempo: Double? = nil) {
        sampleRate = rate
        self.channels = channels
        frameCount = pcm.count / (channels * 2)
        self.pcm = pcm
        self.volume = volume
        self.pan = pan
        self.sourceTempo = sourceTempo
    }

    public func writeWAV(to url: URL) throws {
        var data = Data("RIFF".utf8)
        func write<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        write(UInt32(36 + pcm.count))
        data.append(contentsOf: "WAVEfmt ".utf8)
        write(UInt32(16))
        write(UInt16(1))
        write(UInt16(channels))
        write(UInt32(sampleRate))
        write(UInt32(sampleRate * channels * 2))
        write(UInt16(channels * 2))
        write(UInt16(16))
        data.append(contentsOf: "data".utf8)
        write(UInt32(pcm.count))
        data.append(pcm)
        try data.write(to: url, options: .atomic)
    }

    static func editable(section: String, sampleRate: Int, channels: Int, pcm16: Data, bpm: Double) throws -> [UInt8] {
        let name = Array(section.utf8)
        guard name.count <= 64, !name.isEmpty, (8000...192000).contains(sampleRate),
              (1...2).contains(channels), (20...500).contains(bpm), !pcm16.isEmpty,
              pcm16.count % (2 * channels) == 0, pcm16.count < 128 * 1024 * 1024 else { throw invalid() }
        let metadata = [UInt8(name.count)] + name + [UInt8(channels)]
        let rate = withUnsafeBytes(of: UInt32(sampleRate).bigEndian) { Array($0) }
        let tempo = withUnsafeBytes(of: UInt32((bpm * 1000).rounded()).bigEndian) { Array($0) }
        return metadata + rate + tempo + pcm16
    }

    static func readEditable(_ bytes: [UInt8]) throws -> (String, StyleAudioClip) {
        var reader = Cursor(bytes: bytes)
        let name = try reader.take(Int(reader.byte()))
        let channels = Int(try reader.byte())
        let sampleRate = integer(ArraySlice(try reader.take(4)))
        let bpm = Double(integer(ArraySlice(try reader.take(4)))) / 1000
        let pcm = try reader.take(bytes.count - reader.offset)
        guard !name.isEmpty, name.count <= 64, (1...2).contains(channels), (8000...192000).contains(sampleRate),
              (20...500).contains(bpm), !pcm.isEmpty, pcm.count % (2 * channels) == 0 else { throw invalid() }
        return (String(decoding: name, as: UTF8.self),
                StyleAudioClip(rate: sampleRate, channels: channels, pcm: Data(pcm), volume: 1, pan: 0, sourceTempo: bpm))
    }

    static func decode(arrangement: [UInt8], audio: [UInt8]) throws -> [String: StyleAudioClip] {
        var assets: [String: (rate: Int, channels: Int, pcm: Data, section: String?)] = [:]
        var files = Cursor(bytes: audio)
        while !files.empty {
            let (tag, body) = try files.chunk()
            guard tag == "ADSg" else { continue }
            var descriptor = Cursor(bytes: body)
            let name = text(try descriptor.chunk("ANdc"))
            guard !name.isEmpty else { throw invalid() }
            var wave = Cursor(bytes: try descriptor.chunk("AWav"))
            guard try wave.take(4).elementsEqual("WAVE".utf8) else { throw invalid() }
            let format = try wave.chunk("Afmt")
            guard format.count >= 16, integer(format[0..<2]) == 1, integer(format[14..<16]) == 16 else {
                throw StyleError.invalid("音频 Style 需要 16 位 PCM")
            }
            let channels = integer(format[2..<4])
            let rate = integer(format[4..<8])
            guard (1...2).contains(channels), (8000...192000).contains(rate) else { throw invalid() }

            var pcm: Data?
            var section: String?
            while !wave.empty {
                let (tag, payload) = try wave.chunk()
                if tag == "Adat" { pcm = try littleEndianPCM(payload, channels: channels) }
                if tag == "Sdec" { section = text(payload) }
            }
            guard let pcm else { throw invalid() }
            assets[name] = (rate, channels, pcm, section)
        }

        var clips: [String: StyleAudioClip] = [:]
        var sections = Cursor(bytes: arrangement)
        while !sections.empty {
            let (tag, bytes) = try sections.chunk()
            guard tag == "ASEG" else { continue }
            var entry = Cursor(bytes: bytes)
            let name = text(try entry.chunk("Adec"))
            let table = try entry.chunk("Atab")
            guard !name.isEmpty, table.count >= 11 else { throw invalid() }
            let filename = text(Array(table.dropFirst(10)))
            guard let asset = assets[filename] ?? assets.values.first(where: { $0.section == name }) else {
                throw StyleError.invalid("音频 Style 的 \(name) 缺少音频素材「\(filename)」")
            }
            var volume: Float = 1
            var pan: Float = 0
            if !entry.empty {
                let mix = try entry.chunk("AMix")
                if mix.count >= 2, let controls = try? MIDIFile.readTrack(Array(mix.dropFirst(2))) {
                    for event in controls.events where event.midi.kind == 0xb0 {
                        if event.midi.data1 == 7 { volume = Float(event.midi.data2) / 127 }
                        if event.midi.data1 == 10 { pan = min(1, Float(Int(event.midi.data2) - 64) / 63) }
                    }
                }
            }
            clips[name] = StyleAudioClip(rate: asset.rate, channels: asset.channels, pcm: asset.pcm, volume: volume, pan: pan)
        }
        guard !clips.isEmpty else { throw invalid() }
        return clips
    }

    private static func invalid() -> StyleError { .invalid("AASM / AFil 音频 Style 区块无效") }

    private static func integer(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    private static func text(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func littleEndianPCM(_ bytes: [UInt8], channels: Int) throws -> Data {
        let strideSize = channels * 2
        guard bytes.count >= strideSize, bytes.count % strideSize == 0 else { throw invalid() }
        // Some legacy writers put big-endian samples in the same container. Compare
        // first differences in an active segment and prefer the documented Phraser LE stream on ties.
        var little = 0.0
        var big = 0.0
        let probe = min(bytes.count, 32768)
        if probe > strideSize + 1 {
            for offset in stride(from: strideSize, to: probe - 1, by: strideSize) {
                let last = offset - strideSize
                let a = Int(Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8))
                let b = Int(Int16(bitPattern: UInt16(bytes[last]) | UInt16(bytes[last + 1]) << 8))
                let c = Int(Int16(bitPattern: UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])))
                let d = Int(Int16(bitPattern: UInt16(bytes[last]) << 8 | UInt16(bytes[last + 1])))
                little += Double(abs(a - b))
                big += Double(abs(c - d))
            }
        }
        guard big * 3 < little else { return Data(bytes) }
        var swapped = bytes
        for index in stride(from: 0, to: swapped.count, by: 2) { swapped.swapAt(index, index + 1) }
        return Data(swapped)
    }
}
