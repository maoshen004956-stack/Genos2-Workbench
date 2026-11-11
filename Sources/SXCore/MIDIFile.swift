import Foundation

public struct MIDIFile {
    public let ticksPerQuarter: Int
    public let tempo: Double
    public let tracks: [[Style.Event]]
    public let duration: Int

    public init(data: Data) throws {
        var file = Cursor(bytes: Array(data))
        let header = try file.chunk("MThd")
        guard header.count >= 6, header[0] == 0, header[1] <= 1, header[4] < 128 else {
            throw StyleError.invalid("需要 PPQ 格式的 MIDI 文件（Format 0 或 1）")
        }
        let count = Int(header[2]) << 8 | Int(header[3])
        let division = Int(header[4]) << 8 | Int(header[5])
        guard count > 0, division > 0 else { throw StyleError.invalid("MIDI 头部无效") }
        let parsed = try (0..<count).map { _ in try Self.readTrack(file.chunk("MTrk")) }
        ticksPerQuarter = division
        tempo = parsed.compactMap(\.tempo).first ?? 120
        tracks = parsed.map(\.events)
        duration = parsed.map(\.duration).max() ?? 0
    }

    struct Track {
        var events: [Style.Event] = []
        var system: [[UInt8]] = []
        var texts: [String] = []
        var tempo: Double?
        var duration = 0
    }

    static func readTrack(_ bytes: [UInt8], systemMessages: Bool = false) throws -> Track {
        var cursor = Cursor(bytes: bytes)
        var running: UInt8?
        var result = Track()
        while !cursor.empty {
            result.duration += try cursor.vlq()
            let first = try cursor.peek()
            let status: UInt8
            if first >= 128 {
                status = try cursor.byte()
            } else if let running {
                status = running
            } else {
                throw StyleError.invalid("MIDI running status 缺失")
            }
            switch status {
            case 0x80...0xef:
                running = status
                let a = try cursor.byte()
                let b: UInt8 = status & 0xe0 == 0xc0 ? 0 : try cursor.byte()
                guard a < 128, b < 128 else { throw StyleError.invalid("MIDI 数据字节无效") }
                result.events.append(Style.Event(tick: result.duration, midi: MIDI(status, a, b)))
            case 0xf0, 0xf7:
                running = nil
                let length = try cursor.vlq()
                let message = try cursor.take(length)
                if systemMessages { result.system.append(message) }
            case 0xff:
                let type = try cursor.byte()
                let length = try cursor.vlq()
                let meta = try cursor.take(length)
                if type == 0x2f { return result }
                if [1, 3, 6].contains(type), let text = String(bytes: meta, encoding: .utf8) {
                    result.texts.append(text)
                }
                if type == 0x51, meta.count == 3, result.tempo == nil {
                    let microseconds = meta.reduce(0) { ($0 << 8) | Int($1) }
                    if microseconds > 0 { result.tempo = 60_000_000 / Double(microseconds) }
                }
            default:
                throw StyleError.invalid("不支持的 MIDI 状态 \(status)")
            }
        }
        throw StyleError.invalid("MIDI 缺少轨道结束标记")
    }

    public static func encode(events: [Style.Event], ticksPerQuarter: Int = 480, tempo: Double = 120, duration: Int? = nil) -> Data {
        let ppq = UInt16(min(32767, max(1, ticksPerQuarter)))
        let rate = tempo.isFinite && tempo > 0 ? tempo : 120
        let micros = UInt32(min(16_777_215, max(1, 60_000_000 / rate)))
        var track: [UInt8] = [0, 0xff, 0x51, 3, UInt8(truncatingIfNeeded: micros >> 16),
                              UInt8(truncatingIfNeeded: micros >> 8), UInt8(truncatingIfNeeded: micros)]
        var previous = 0
        for event in events.sorted(by: { $0.tick < $1.tick }) where (0x80...0xef).contains(event.midi.status) {
            let tick = max(previous, event.tick)
            track += variableLength(tick - previous)
            let midi = event.midi
            track += [midi.status, midi.data1]
            if midi.size == 3 { track.append(midi.data2) }
            previous = tick
        }
        track += variableLength(max(0, (duration ?? previous) - previous)) + [0xff, 0x2f, 0]
        return Data(chunk("MThd", [0, 0, 0, 1, UInt8(ppq >> 8), UInt8(truncatingIfNeeded: ppq)])
                    + chunk("MTrk", track))
    }

    static func chunk(_ tag: String, _ body: [UInt8]) -> [UInt8] {
        let size = UInt32(body.count).bigEndian
        return Array(tag.utf8) + withUnsafeBytes(of: size) { Array($0) } + body
    }

    static func variableLength(_ value: Int) -> [UInt8] {
        var rest = min(0x0fff_ffff, max(0, value))
        var bytes = [UInt8(rest & 127)]
        rest >>= 7
        while rest > 0 {
            bytes.append(UInt8(rest & 127) | 128)
            rest >>= 7
        }
        return bytes.reversed()
    }
}
